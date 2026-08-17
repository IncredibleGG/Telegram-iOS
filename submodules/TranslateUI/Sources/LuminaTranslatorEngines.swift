import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram — the four concrete LuminaTranslatorEngine implementations (iOS twin of
// Android's TelegramTranslator/GoogleWebTranslator/DeepLTranslator/LlmTranslator and
// desktop's TelegramEngine/GoogleWebEngine/DeepLEngine/LlmEngine in
// lumina_translate_providers.cpp). See LuminaTranslatorRegistry.swift for how these are
// registered and selected.

// MARK: - Shared HTTP plumbing

private let luminaTranslateHTTPTimeout: TimeInterval = 15.0

// Shared HTTP transport for the network-backed engines (DeepL, LLM). Mirrors this fork's
// existing alternativeTranslateText helper (Translate.swift) — off-queue URLSession request,
// an explicit 15s timeout (matching Android's LuminaTranslatorUtil and desktop's
// kRequestTimeoutMs), a Signal that resolves at most once. Security: never log request
// headers, bodies or the raw response — they may carry the user's API key.
func luminaHTTPRequest(url: URL, method: String, headers: [String: String], body: Data?) -> Signal<Data, LuminaTranslateError> {
    return Signal { subscriber in
        var task: URLSessionDataTask?
        Queue.concurrentDefaultQueue().async {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = luminaTranslateHTTPTimeout
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.httpBody = body
            task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    subscriber.putError(.network((error as NSError).localizedDescription))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    subscriber.putError(.network(nil))
                    return
                }
                if httpResponse.statusCode >= 400 {
                    // 429 (standard rate limit), 456 (DeepL quota) and 403 (some LLM gateways'
                    // quota code) all read as "try again later" rather than "broken".
                    let rateLimited = httpResponse.statusCode == 429 || httpResponse.statusCode == 456 || httpResponse.statusCode == 403
                    subscriber.putError(rateLimited ? .rateLimited : .network("HTTP \(httpResponse.statusCode)"))
                    return
                }
                guard let data else {
                    subscriber.putError(.network(nil))
                    return
                }
                subscriber.putNext(data)
                subscriber.putCompletion()
            }
            task?.resume()
        }
        return ActionDisposable {
            task?.cancel()
        }
    }
}

// MARK: - Telegram (default; wraps the existing MTProto messages.translateText RPC)

final class LuminaTelegramEngine: LuminaTranslatorEngine {
    let id = "telegram"
    let displayName = "Telegram"
    let needsKey = false
    let needsBaseUrl = false
    let needsModel = false

    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError> {
        let toneSignal: Signal<TranslationTone, NoError>
        if let peerId {
            toneSignal = luminaCurrentSettings(context: context)
            |> map { settings -> TranslationTone in
                return LuminaRegister.telegramTone(LuminaRegister.get(settings: settings, peerId: peerId))
            }
        } else {
            toneSignal = .single(.neutral)
        }
        return toneSignal
        |> castError(LuminaTranslateError.self)
        |> mapToSignal { tone -> Signal<LuminaTranslationResult, LuminaTranslateError> in
            return context.engine.messages.translate(text: text, toLang: normalizeTranslationLanguage(toLang), tone: tone)
            |> mapError { error -> LuminaTranslateError in
                switch error {
                case .limitExceeded:
                    return .rateLimited
                default:
                    return .network(nil)
                }
            }
            |> mapToSignal { result -> Signal<LuminaTranslationResult, LuminaTranslateError> in
                guard let result else {
                    return .fail(.network("empty"))
                }
                return .single(LuminaTranslationResult(text: result.0, detectedSourceLang: nil))
            }
        }
    }
}

// MARK: - Google (free web endpoint; delegates to this fork's existing scrape)

final class LuminaGoogleWebEngine: LuminaTranslatorEngine {
    let id = "google_web"
    let displayName = "Google"
    let needsKey = false
    let needsBaseUrl = false
    let needsModel = false

    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError> {
        // fromLang: nil -> alternativeTranslateText auto-detects the source language.
        return alternativeTranslateText(text: text, fromLang: nil, toLang: LuminaLang.google(toLang))
        |> mapError { error -> LuminaTranslateError in
            switch error {
            case .limitExceeded:
                return .rateLimited
            default:
                return .network(nil)
            }
        }
        |> mapToSignal { result -> Signal<LuminaTranslationResult, LuminaTranslateError> in
            guard let result else {
                return .fail(.network("empty"))
            }
            return .single(LuminaTranslationResult(text: result.0, detectedSourceLang: nil))
        }
    }
}

// MARK: - DeepL (bring-your-own key)

final class LuminaDeepLEngine: LuminaTranslatorEngine {
    let id = "deepl"
    let displayName = "DeepL"
    let needsKey = true
    let needsBaseUrl = false
    let needsModel = false

    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError> {
        guard let rawKey = LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: self.id)), !rawKey.isEmpty else {
            return .fail(.noKey)
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let deeplTarget = LuminaLang.deepl(toLang)

        let formalitySignal: Signal<String?, NoError>
        if let peerId {
            formalitySignal = luminaCurrentSettings(context: context)
            |> map { settings -> String? in
                return LuminaRegister.deeplFormality(stored: LuminaRegister.get(settings: settings, peerId: peerId), toLangDeepL: deeplTarget)
            }
        } else {
            formalitySignal = .single(nil)
        }

        return formalitySignal
        |> castError(LuminaTranslateError.self)
        |> mapToSignal { formality -> Signal<LuminaTranslationResult, LuminaTranslateError> in
            // Free vs Pro endpoint is chosen automatically from the key shape: DeepL free
            // keys carry a ":fx" suffix.
            let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
            guard let url = URL(string: host + "/v2/translate") else {
                return .fail(.network(nil))
            }
            var payload: [String: Any] = [
                "text": [text],
                "target_lang": deeplTarget
            ]
            if let formality {
                payload["formality"] = formality
            }
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                return .fail(.network(nil))
            }
            let headers = [
                "Authorization": "DeepL-Auth-Key \(key)",
                "Content-Type": "application/json"
            ]
            return luminaHTTPRequest(url: url, method: "POST", headers: headers, body: body)
            |> mapToSignal { data -> Signal<LuminaTranslationResult, LuminaTranslateError> in
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let translations = json["translations"] as? [[String: Any]],
                    let first = translations.first,
                    let translated = first["text"] as? String
                else {
                    return .fail(.network("bad response"))
                }
                return .single(LuminaTranslationResult(text: translated, detectedSourceLang: first["detected_source_language"] as? String))
            }
        }
    }
}

// MARK: - LLM (OpenAI-compatible chat-completions)

// One implementation covers OpenAI/GPT, Gemini (OpenAI-compat endpoint), DeepSeek and any
// self-hosted/relay gateway — the user only changes the base URL, model and key.
public enum LuminaLLMDefaults {
    public static let baseUrl = "https://api.openai.com/v1"
    public static let model = "gpt-4o-mini"
    public static let prompt = "You are a professional translator. Translate the user's message into {lang}. Output ONLY the translation, with no quotes, no notes, and no explanations. Preserve tone, emojis and formatting."

    public static func trimTrailingSlash(_ s: String) -> String {
        var s = s
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}

final class LuminaLLMEngine: LuminaTranslatorEngine {
    let id = "llm"
    let displayName = "LLM (OpenAI-compatible)"
    let needsKey = true
    let needsBaseUrl = true
    let needsModel = true

    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError> {
        guard let rawKey = LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: self.id)), !rawKey.isEmpty else {
            return .fail(.noKey)
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return luminaCurrentSettings(context: context)
        |> castError(LuminaTranslateError.self)
        |> mapToSignal { settings -> Signal<LuminaTranslationResult, LuminaTranslateError> in
            let base = LuminaLLMDefaults.trimTrailingSlash(settings.translateBaseUrl.isEmpty ? LuminaLLMDefaults.baseUrl : settings.translateBaseUrl)
            let model = settings.translateModel.isEmpty ? LuminaLLMDefaults.model : settings.translateModel
            var prompt = settings.translatePrompt.isEmpty ? LuminaLLMDefaults.prompt : settings.translatePrompt
            prompt = prompt.replacingOccurrences(of: "{lang}", with: LuminaLang.name(toLang))
            // The chat's register (client/friend/elder/…) is layered ON TOP of the user's own
            // prompt, never in place of it — see LuminaRegister.promptSuffix.
            if let peerId, let suffix = LuminaRegister.promptSuffix(stored: LuminaRegister.get(settings: settings, peerId: peerId)) {
                prompt += suffix
            }
            guard let url = URL(string: base + "/chat/completions") else {
                return .fail(.network(nil))
            }
            let payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": text]
                ]
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                return .fail(.network(nil))
            }
            let headers = [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json"
            ]
            return luminaHTTPRequest(url: url, method: "POST", headers: headers, body: body)
            |> mapToSignal { data -> Signal<LuminaTranslationResult, LuminaTranslateError> in
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let first = choices.first,
                    let message = first["message"] as? [String: Any],
                    let content = message["content"] as? String
                else {
                    return .fail(.network("bad response"))
                }
                return .single(LuminaTranslationResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), detectedSourceLang: nil))
            }
        }
    }
}
