import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences
import PresentationDataUtils

// LuminaGram — explain-a-message / cultural note (iOS twin of desktop's
// lumina_explain.{h,cpp}). Sends the selected message text to the user's own configured LLM
// engine and shows the result in a sheet. LLM-only — DeepL/Google/Telegram have no channel
// for this kind of open-ended request. Gated by LuminaSettings.explainMessage at the call
// site (ChatInterfaceStateContextMenus.swift's `// LuminaGram: explain-a-message` insertion);
// this function itself is unconditional once called.
//
// Deliberately reuses LuminaLLMEngine's HTTP shape (luminaHTTPRequest, LuminaKeychain,
// LuminaLLMDefaults) but NOT LuminaTranslatorEngine.translate(...) itself: explain is a
// different request (a free-form question, not "translate into {lang}"), so it builds its
// own system prompt rather than routing through the translate-prompt/register pipeline.
public func luminaExplainMessage(context: AccountContext, present: @escaping (ViewController) -> Void, text: String) {
    guard !text.isEmpty else {
        return
    }
    guard let rawKey = LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: "llm")), !rawKey.isEmpty else {
        present(luminaSimpleAlert(context: context, title: LuminaL10n.tr("Explain"), text: LuminaL10n.tr("Add an LLM API key on the Translation settings page to use Explain.")))
        return
    }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

    let _ = (luminaCurrentSettings(context: context)
    |> take(1)
    |> deliverOnMainQueue).start(next: { settings in
        let base = LuminaLLMDefaults.trimTrailingSlash(settings.translateBaseUrl.isEmpty ? LuminaLLMDefaults.baseUrl : settings.translateBaseUrl)
        let model = settings.translateModel.isEmpty ? LuminaLLMDefaults.model : settings.translateModel
        let interfaceLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let readLangName = LuminaLang.name(settings.trReadLang.isEmpty ? interfaceLang : settings.trReadLang)

        // Four labelled sections, mirroring desktop's ExplainPrompt: literal meaning, actual
        // tone/intent/subtext, cultural or slang notes (or "None"), then reply suggestions.
        let prompt = "You are explaining a chat message to someone who received it. Reply in "
            + readLangName + ". Structure your reply in exactly four short labelled sections, in "
            + "this order: 1) Literal meaning — a plain, literal explanation of what the message "
            + "says. 2) Actual tone and intent — what the sender most likely means or feels, "
            + "including any subtext. 3) Cultural or slang notes — anything a reader unfamiliar "
            + "with the sender's language or culture might miss; write \"None\" if there is "
            + "nothing notable. 4) How to reply — one or two brief, natural reply suggestions. "
            + "Keep the whole answer concise and write only the four sections, nothing else."

        guard let url = URL(string: base + "/chat/completions") else {
            present(luminaSimpleAlert(context: context, title: LuminaL10n.tr("Explain"), text: LuminaL10n.tr("Could not reach the configured LLM provider. Check the base URL in Translation settings.")))
            return
        }
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        let headers = [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json"
        ]

        let _ = (luminaHTTPRequest(url: url, method: "POST", headers: headers, body: body)
        |> map { data -> String? in
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                return nil
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        |> `catch` { _ -> Signal<String?, NoError> in
            return .single(nil)
        }
        |> deliverOnMainQueue).start(next: { explanation in
            let resultText = explanation ?? LuminaL10n.tr("Could not get an explanation. Check your LLM provider settings and try again.")
            present(luminaSimpleAlert(context: context, title: LuminaL10n.tr("Explain"), text: resultText))
        })
    })
}

private func luminaSimpleAlert(context: AccountContext, title: String, text: String) -> ViewController {
    return textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("OK"), action: {})
    ])
}
