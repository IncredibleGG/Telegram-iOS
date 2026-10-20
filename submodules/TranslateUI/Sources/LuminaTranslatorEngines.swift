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

// LuminaGram: requests that carry an API key / Authorization header must not follow a redirect to
// a different host, or from https down to http - URLSession re-sends the request's custom headers
// (the key included) to the redirect target. Such a redirect is refused and surfaces as an error.
// Same-host redirects, http->https upgrades on the same host, and plain-http endpoints the user
// typed in themselves (some relays use http) keep working. Requests without credentials are
// unaffected.
private let luminaCredentialHeaderNames: Set<String> = ["authorization", "proxy-authorization", "x-goog-api-key", "x-api-key", "api-key"]

private func luminaRequestCarriesCredential(_ request: URLRequest?) -> Bool {
    guard let fields = request?.allHTTPHeaderFields else {
        return false
    }
    return fields.keys.contains(where: { luminaCredentialHeaderNames.contains($0.lowercased()) })
}

private func luminaIsAllowedCredentialRedirect(from source: URL?, to target: URL?) -> Bool {
    guard let source, let target, let sourceHost = source.host?.lowercased(), let targetHost = target.host?.lowercased(), !sourceHost.isEmpty else {
        return false
    }
    guard sourceHost == targetHost else {
        return false
    }
    let sourceScheme = source.scheme?.lowercased() ?? ""
    let targetScheme = target.scheme?.lowercased() ?? ""
    if targetScheme == "https" {
        return true
    }
    // https -> http is a downgrade; http -> http stays allowed for a user-entered http endpoint.
    return targetScheme == "http" && sourceScheme == "http"
}

private final class LuminaCredentialRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard luminaRequestCarriesCredential(task.originalRequest) else {
            completionHandler(request)
            return
        }
        if luminaIsAllowedCredentialRedirect(from: task.originalRequest?.url, to: request.url) {
            completionHandler(request)
        } else {
            // nil = do not follow; the task completes with the 3xx response, reported below.
            completionHandler(nil)
        }
    }
}

// One shared session (a URLSession retains its delegate, so it must not be created per request).
// .default matches URLSession.shared's cookie/cache behaviour; only the redirect policy differs.
private let luminaHTTPSession: URLSession = URLSession(configuration: .default, delegate: LuminaCredentialRedirectGuard(), delegateQueue: nil)

// Shared HTTP transport for the network-backed engines (DeepL, LLM). Mirrors this fork's
// existing alternativeTranslateText helper (Translate.swift) — off-queue URLSession request,
// an explicit 15s timeout (matching Android's LuminaTranslatorUtil and desktop's
// kRequestTimeoutMs), a Signal that resolves at most once. Security: never log request
// headers, bodies or the raw response — they may carry the user's API key. Errors carry only a
// generic category plus the HTTP status / transport error code, never URLs or response text.
// `model` is the LLM model name the request asked for; when set, an error reply whose JSON says
// that model does not exist becomes .modelNotFound(model) (see luminaErrorBodyNamesMissingModel).
// The error body is only inspected for that classification and then dropped.
func luminaHTTPRequest(url: URL, method: String, headers: [String: String], body: Data?, model: String? = nil) -> Signal<Data, LuminaTranslateError> {
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
            task = luminaHTTPSession.dataTask(with: request) { data, response, error in
                if let error {
                    subscriber.putError(.network("transport error \((error as NSError).code)"))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    subscriber.putError(.network(nil))
                    return
                }
                if (300 ..< 400).contains(httpResponse.statusCode) {
                    // Only reached when LuminaCredentialRedirectGuard refused the redirect.
                    subscriber.putError(.network("redirect blocked, HTTP \(httpResponse.statusCode)"))
                    return
                }
                if httpResponse.statusCode >= 400 {
                    subscriber.putError(luminaClassifyHTTPError(statusCode: httpResponse.statusCode, body: data, model: model))
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

// Status -> category, same table as Android's LuminaLlm.statusText: an error body that says the
// requested model does not exist -> model not found (checked first), 401/403 key rejected,
// 402/429 (+ DeepL's 456) quota / too many requests, 5xx temporary service error, anything else
// a plain HTTP status.
func luminaClassifyHTTPError(statusCode: Int, body: Data?, model: String?) -> LuminaTranslateError {
    if let model, luminaErrorBodyNamesMissingModel(body, statusCode: statusCode) {
        return .modelNotFound(model)
    }
    switch statusCode {
    case 401, 403:
        return .keyRejected
    case 402, 429, 456:
        return .rateLimited
    case 500 ..< 600:
        return .serverError(statusCode)
    default:
        return .httpStatus(statusCode)
    }
}

// A JSON scalar as text: strings as they are, numbers as their decimal form, anything else "".
func luminaJSONString(_ value: Any?) -> String {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return ""
}

// OpenAI-style error bodies: {"error":{"message":..,"type":..,"code":..,"param":..}}. Relays and
// other providers vary: Ollama sends {"error":"model \"x\" not found"}, Gemini's compat endpoint
// wraps the object in an array, some gateways put type/code/message at the top level. Same rule
// as Android's LuminaLlm.isModelNotFoundBody: a type/code naming model_not_found counts for any
// status; the looser checks (param is "model", or the message mentions the model and says it is
// not found / does not exist / is not supported) only for 400, 404 or an error object in a 2xx
// reply (statusCode 0). The body is only classified here, never kept, logged or shown.
func luminaErrorBodyNamesMissingModel(_ body: Data?, statusCode: Int) -> Bool {
    guard let body, !body.isEmpty, body.count <= 64 * 1024, let json = try? JSONSerialization.jsonObject(with: body) else {
        return false
    }
    var codes: [String] = []
    var params: [String] = []
    var messages: [String] = []
    func collect(_ object: Any?) {
        if let dict = object as? [String: Any] {
            for key in ["type", "code", "status"] {
                let value = luminaJSONString(dict[key])
                if !value.isEmpty {
                    codes.append(value.lowercased())
                }
            }
            let param = luminaJSONString(dict["param"])
            if !param.isEmpty {
                params.append(param.lowercased())
            }
            for key in ["message", "detail"] {
                let value = luminaJSONString(dict[key])
                if !value.isEmpty {
                    messages.append(value)
                }
            }
        } else if let value = object as? String {
            messages.append(value)
        }
    }
    var root: [String: Any]?
    if let dict = json as? [String: Any] {
        root = dict
    } else if let array = json as? [Any], let first = array.first as? [String: Any] {
        root = first
    }
    guard let root else {
        return false
    }
    collect(root["error"])
    collect(root)
    if codes.contains(where: { $0.contains("model_not_found") || $0.contains("model_not_exist") || $0.contains("modelnotfound") }) {
        return true
    }
    if statusCode > 0 && statusCode != 400 && statusCode != 404 {
        return false
    }
    if params.contains("model") {
        return true
    }
    let notFoundMarkers = ["not found", "does not exist", "not exist", "no such model", "unknown model", "invalid model", "model not available"]
    return messages.contains(where: { message in
        let lower = message.lowercased()
        if lower.contains("model") {
            if notFoundMarkers.contains(where: { lower.contains($0) }) {
                return true
            }
            if (lower.hasPrefix("model ") || lower.hasPrefix("the model ")) && lower.contains("not supported") {
                return true
            }
        }
        return message.contains("模型") && ["不存在", "不支持", "不支援", "无可用", "無可用"].contains(where: { message.contains($0) })
    })
}

// A 2xx chat/completions reply without a usable "choices" result. Some relays answer 200 with
// {"error": ...} instead: when that error says the model does not exist it is reported as such,
// anything else is an unreadable reply (same rule as Android's LuminaLlm.errorInReply). Only
// classified here; the body is never kept, logged or shown.
func luminaLLMReplyError(_ data: Data, model: String) -> LuminaTranslateError {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["choices"] == nil, json["error"] != nil, luminaErrorBodyNamesMissingModel(data, statusCode: 0) {
        return .modelNotFound(model)
    }
    return .badResponse
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
                return LuminaRegister.telegramTone(stored: LuminaRegister.get(settings: settings, peerId: peerId))
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
                    return .fail(.badResponse)
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

    // The base URL / model every LLM request uses (translation, Explain, Detect Models): the
    // stored value without surrounding whitespace (a pasted URL or model often carries a stray
    // space or newline), the default when empty, and no trailing slash on the URL.
    public static func resolvedBaseUrl(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.trimTrailingSlash(trimmed.isEmpty ? self.baseUrl : trimmed)
    }

    public static func resolvedModel(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self.model : trimmed
    }
}

final class LuminaLLMEngine: LuminaTranslatorEngine {
    let id = "llm"
    var displayName: String { return LuminaL10n.tr("LLM (OpenAI-compatible)") }
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
            let base = LuminaLLMDefaults.resolvedBaseUrl(settings.translateBaseUrl)
            let model = LuminaLLMDefaults.resolvedModel(settings.translateModel)
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
            return luminaHTTPRequest(url: url, method: "POST", headers: headers, body: body, model: model)
            |> mapToSignal { data -> Signal<LuminaTranslationResult, LuminaTranslateError> in
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let choices = json["choices"] as? [[String: Any]],
                    let first = choices.first,
                    let message = first["message"] as? [String: Any],
                    let content = message["content"] as? String
                else {
                    return .fail(luminaLLMReplyError(data, model: model))
                }
                return .single(LuminaTranslationResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), detectedSourceLang: nil))
            }
        }
    }
}
