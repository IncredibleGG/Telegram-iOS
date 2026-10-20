import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import PresentationDataUtils
import OverlayStatusController

// LuminaGram — "Detect Models" for the LLM (OpenAI-compatible) provider, same design as Android
// and desktop. Calls GET {baseURL}/models through luminaHTTPRequest, so it uses the same
// Authorization header and the same transport rules as every other LLM request: 15s timeout, a
// request carrying the key never follows a redirect to another host or from https down to http,
// and user-entered http:// endpoints keep working. The returned data[].id list is shown as a
// picker; choosing one saves it as the model (LuminaSettings.translateModel, shared by the LLM
// translation engine and Explain).

public enum LuminaModelListError {
    // No LLM key in the Keychain.
    case noKey
    // HTTP 401 / 403.
    case keyRejected
    // HTTP 404 / 405, or a reply that is not an OpenAI-style model list.
    case noModelList
    // Transport failure, timeout, TLS, refused redirect or an unusable base URL.
    case cannotConnect
    // A valid list with no usable ids.
    case empty
    // Anything else (quota, 5xx, other statuses): the shared provider error text.
    case other(LuminaTranslateError)
}

public func luminaModelListErrorText(_ error: LuminaModelListError) -> String {
    switch error {
    case .noKey:
        return LuminaL10n.tr("Enter the API key first.")
    case .keyRejected:
        return luminaTranslateErrorText(.keyRejected, usesBaseUrl: true)
    case .noModelList:
        return LuminaL10n.tr("This service does not provide a model list. Type the model name manually.")
    case .cannotConnect:
        return luminaTranslateErrorText(.network(nil), usesBaseUrl: true)
    case .empty:
        return LuminaL10n.tr("The service returned no models.")
    case let .other(error):
        return luminaTranslateErrorText(error, usesBaseUrl: true)
    }
}

// Ids that are clearly not chat models (image, speech, embedding, moderation, realtime). They are
// hidden unless hiding them would leave nothing, in which case everything is shown.
private let luminaNonChatModelMarkers: [String] = ["image", "dall-e", "tts", "whisper", "embedding", "moderation", "transcribe", "audio", "realtime"]

// Families that are almost always chat-completion models; these are listed first.
private let luminaChatModelMarkers: [String] = ["gpt", "chat", "claude", "gemini", "gemma", "deepseek", "qwen", "llama", "mistral", "mixtral", "glm", "kimi", "moonshot", "grok", "sonnet", "opus", "haiku", "command", "doubao", "ernie", "hunyuan", "minimax", "yi-", "phi-", "instruct"]

private func luminaIsLikelyChatModel(_ id: String) -> Bool {
    let lower = id.lowercased()
    if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
        return true
    }
    return luminaChatModelMarkers.contains(where: { lower.contains($0) })
}

// De-duplicated, likely chat models first, each group in natural (numeric-aware) order.
public func luminaOrderModelIds(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    var unique: [String] = []
    for id in ids {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || seen.contains(trimmed) {
            continue
        }
        seen.insert(trimmed)
        unique.append(trimmed)
    }
    let visible = unique.filter { id in
        let lower = id.lowercased()
        return !luminaNonChatModelMarkers.contains(where: { lower.contains($0) })
    }
    let pool = visible.isEmpty ? unique : visible
    let naturalOrder: (String, String) -> Bool = { lhs, rhs in
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
    let chat = pool.filter(luminaIsLikelyChatModel).sorted(by: naturalOrder)
    let others = pool.filter { !luminaIsLikelyChatModel($0) }.sorted(by: naturalOrder)
    return chat + others
}

// Fetches and orders the model list for the configured LLM base URL and key. `current` is the
// model the engine would use right now (the default when the field is empty).
public func luminaFetchLLMModels(context: AccountContext) -> Signal<(models: [String], current: String), LuminaModelListError> {
    guard let rawKey = LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: "llm")) else {
        return .fail(.noKey)
    }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
        return .fail(.noKey)
    }
    return luminaCurrentSettings(context: context)
    |> castError(LuminaModelListError.self)
    |> mapToSignal { settings -> Signal<(models: [String], current: String), LuminaModelListError> in
        let base = LuminaLLMDefaults.resolvedBaseUrl(settings.translateBaseUrl)
        let current = LuminaLLMDefaults.resolvedModel(settings.translateModel)
        guard let url = URL(string: base + "/models") else {
            return .fail(.cannotConnect)
        }
        let headers = [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json"
        ]
        return luminaHTTPRequest(url: url, method: "GET", headers: headers, body: nil)
        |> mapError { error -> LuminaModelListError in
            switch error {
            case .keyRejected:
                return .keyRejected
            case let .httpStatus(code):
                if code == 404 || code == 405 {
                    return .noModelList
                }
                return .other(error)
            case .network:
                return .cannotConnect
            default:
                return .other(error)
            }
        }
        |> mapToSignal { data -> Signal<(models: [String], current: String), LuminaModelListError> in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["data"] as? [Any] else {
                return .fail(.noModelList)
            }
            let ids: [String] = list.compactMap { item -> String? in
                if let entry = item as? [String: Any] {
                    return entry["id"] as? String
                }
                return item as? String
            }
            let ordered = luminaOrderModelIds(ids)
            if ordered.isEmpty {
                return .fail(.empty)
            }
            return .single((models: ordered, current: current))
        }
    }
}

// Runs the whole flow: progress overlay, fetch, then either the picker or an error alert.
// `present` presents a controller over the caller's screen (settings or chat). `completion` is
// called with the model the user picked, after it has been saved.
public func luminaPresentModelDetection(context: AccountContext, present: @escaping (ViewController) -> Void, completion: ((String) -> Void)? = nil) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let disposable = MetaDisposable()
    let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
        disposable.dispose()
    }))
    present(progress)
    disposable.set((luminaFetchLLMModels(context: context)
    |> deliverOnMainQueue).start(next: { [weak progress] result in
        progress?.dismiss()
        present(luminaModelPickerController(context: context, models: result.models, current: result.current, completion: completion))
    }, error: { [weak progress] error in
        progress?.dismiss()
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        present(textAlertController(context: context, title: LuminaL10n.tr("Detect Models"), text: luminaModelListErrorText(error), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    }))
}

private func luminaModelPickerController(context: AccountContext, models: [String], current: String, completion: ((String) -> Void)?) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = []
    items.append(ActionSheetTextItem(title: LuminaL10n.tr("Choose a Model"), parseMarkdown: false))
    for model in models {
        items.append(ActionSheetButtonItem(title: model, color: .accent, font: model == current ? .bold : .default, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let _ = (updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.translateModel = model
                return settings
            })
            |> deliverOnMainQueue).start(completed: {
                completion?(model)
            })
        }))
    }
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    return actionSheet
}

// Alert for a failed provider request (Test Provider, Explain). A missing model gets a second
// button that opens the model picker right away.
public func luminaProviderErrorAlert(context: AccountContext, title: String, error: LuminaTranslateError, usesBaseUrl: Bool, present: @escaping (ViewController) -> Void) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let text = luminaTranslateErrorText(error, usesBaseUrl: usesBaseUrl)
    var actions: [TextAlertAction] = []
    if error.isModelNotFound {
        actions.append(TextAlertAction(type: .genericAction, title: presentationData.strings.Common_OK, action: {}))
        actions.append(TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Detect Models"), action: {
            luminaPresentModelDetection(context: context, present: present)
        }))
    } else {
        actions.append(TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {}))
    }
    return textAlertController(context: context, title: title, text: text, actions: actions)
}
