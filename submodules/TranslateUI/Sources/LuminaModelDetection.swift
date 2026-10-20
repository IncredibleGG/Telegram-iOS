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
// and user-entered http:// endpoints keep working. The returned data[].id list (also models[] or
// a bare array, like Android) is shown as a picker; choosing one saves it as the model
// (LuminaSettings.translateModel, shared by the LLM translation engine and Explain).

public enum LuminaModelListError {
    // No LLM key in the Keychain.
    case noKey
    // HTTP 401 / 403 (or a 200 reply whose error object says so).
    case keyRejected
    // HTTP 404 / 405 (or a 200 reply whose error object says so).
    case noModelList
    // Transport failure, timeout, TLS, refused redirect or an unusable base URL.
    case cannotConnect
    // A valid list with no usable ids.
    case empty
    // Anything else (quota, 5xx, other statuses, a reply that is not JSON): the shared provider
    // error text.
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

// Picker order, the same rule as Android's LuminaLlm.orderModels (the baseline):
// Ids that are clearly not chat models (image, speech, embedding, moderation, realtime). They are
// hidden unless hiding them would leave nothing, in which case everything is shown.
private let luminaNonChatModelMarkers: [String] = ["image", "dall-e", "tts", "whisper", "embedding", "moderation", "transcribe", "audio", "realtime"]

// Families that are almost always chat-completion models; these are listed first.
private let luminaChatModelMarkers: [String] = ["gpt", "chat", "claude", "gemini", "gemma", "deepseek", "qwen", "llama", "mistral", "mixtral", "glm", "kimi", "moonshot", "grok", "command", "sonnet", "opus", "haiku", "doubao", "ernie", "hunyuan", "minimax", "yi-", "turbo"]

// Chat-capable but rarely what a translator wants (coding / review / search / reserve pools):
// listed last.
private let luminaLessLikelyModelMarkers: [String] = ["codex", "review", "reserve", "search", "computer-use", "guard"]

// 0 = likely chat model, 1 = unknown, 2 = less likely.
private func luminaModelRank(_ lower: String) -> Int {
    if luminaLessLikelyModelMarkers.contains(where: { lower.contains($0) }) {
        return 2
    }
    if luminaChatModelMarkers.contains(where: { lower.contains($0) }) || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
        return 0
    }
    return 1
}

// Digit runs compare by value ("gpt-10" > "gpt-9"), everything else by UTF-16 unit; when one
// string is a prefix of the other the shorter sorts first. Port of Android's
// LuminaLlm.naturalCompare: negative when a < b, 0 when equal, positive when a > b.
func luminaNaturalCompare(_ a: String, _ b: String) -> Int {
    let a = Array(a.utf16)
    let b = Array(b.utf16)
    func isDigit(_ unit: UInt16) -> Bool {
        return unit >= 0x30 && unit <= 0x39
    }
    var i = 0
    var j = 0
    while i < a.count && j < b.count {
        let ca = a[i]
        let cb = b[j]
        if isDigit(ca) && isDigit(cb) {
            var ei = i
            while ei < a.count && isDigit(a[ei]) {
                ei += 1
            }
            var ej = j
            while ej < b.count && isDigit(b[ej]) {
                ej += 1
            }
            // Leading zeros do not count, but a run keeps at least one digit.
            var si = i
            while si < ei - 1 && a[si] == 0x30 {
                si += 1
            }
            var sj = j
            while sj < ej - 1 && b[sj] == 0x30 {
                sj += 1
            }
            if ei - si != ej - sj {
                return (ei - si) - (ej - sj)
            }
            for k in 0 ..< (ei - si) where a[si + k] != b[sj + k] {
                return Int(a[si + k]) - Int(b[sj + k])
            }
            i = ei
            j = ej
        } else {
            if ca != cb {
                return Int(ca) - Int(cb)
            }
            i += 1
            j += 1
        }
    }
    return (a.count - i) - (b.count - j)
}

// De-duplicated, likely chat models first, then unknown ids, then the less likely ones; within a
// group the newest-looking version first (reverse natural order).
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
    let keyed = pool.enumerated().map { item -> (offset: Int, rank: Int, lower: String, id: String) in
        let lower = item.element.lowercased()
        return (offset: item.offset, rank: luminaModelRank(lower), lower: lower, id: item.element)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        let order = luminaNaturalCompare(rhs.lower, lhs.lower)
        if order != 0 {
            return order < 0
        }
        return lhs.offset < rhs.offset
    }
    return sorted.map { $0.id }
}

private enum LuminaModelListReply {
    case ids([String])
    case failure(LuminaModelListError)
}

// An HTTP-like status (400...599) embedded in a JSON error object, or 0.
private func luminaEmbeddedStatus(_ value: Any?) -> Int {
    var status = 0
    if let number = value as? NSNumber {
        status = number.intValue
    } else if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 3, let parsed = Int(trimmed) {
            status = parsed
        }
    }
    return (400 ... 599).contains(status) ? status : 0
}

// A 2xx /models reply that carries {"error": ...} instead of a list (some relays answer 200 that
// way), mapped like an HTTP error of the model listing. Same rule as Android's
// LuminaLlm.modelsErrorInReply; the body is only classified, nothing from it is shown.
private func luminaModelsErrorInReply(_ json: [String: Any]) -> LuminaModelListError {
    let errorObject = json["error"]
    let errorDict = errorObject as? [String: Any]
    var status = 0
    if let errorDict {
        status = luminaEmbeddedStatus(errorDict["code"])
        if status == 0 {
            status = luminaEmbeddedStatus(errorDict["status"])
        }
    }
    if status == 0 {
        status = luminaEmbeddedStatus(json["status"])
    }
    if status == 0 {
        status = luminaEmbeddedStatus(json["code"])
    }
    if status == 404 || status == 405 {
        return .noModelList
    }
    if status > 0 {
        let error = luminaClassifyHTTPError(statusCode: status, body: nil, model: nil)
        if case .keyRejected = error {
            return .keyRejected
        }
        return .other(error)
    }
    var hint = ""
    if let errorDict {
        hint = [luminaJSONString(errorDict["type"]), luminaJSONString(errorDict["code"]), luminaJSONString(errorDict["message"])].joined(separator: " ")
    } else if let text = errorObject as? String {
        hint = text
    }
    hint = hint.lowercased()
    let keyMarkers = ["api key", "api_key", "apikey", "unauthorized", "unauthenticated", "authentication", "invalid token", "invalid_token", "forbidden", "permission"]
    if keyMarkers.contains(where: { hint.contains($0) }) {
        return .keyRejected
    }
    let quotaMarkers = ["quota", "rate limit", "rate_limit", "insufficient", "balance"]
    if quotaMarkers.contains(where: { hint.contains($0) }) {
        return .other(.rateLimited)
    }
    return .other(.badResponse)
}

// Reads a 2xx /models reply: an OpenAI-style {"data":[...]}, {"models":[...]} or a bare array,
// whose entries are strings or objects with "id" (or "name"). A reply that is not JSON cannot be
// read; a JSON object with no list is an empty list. Same rules as Android's
// LuminaLlm.parseModelIds; only the model ids are kept.
private func luminaParseModelListReply(_ data: Data) -> LuminaModelListReply {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        return .failure(.other(.badResponse))
    }
    let list: [Any]
    if let array = json as? [Any] {
        list = array
    } else if let dict = json as? [String: Any] {
        if dict["error"] != nil && dict["data"] == nil && dict["models"] == nil {
            return .failure(luminaModelsErrorInReply(dict))
        }
        if let items = dict["data"] as? [Any] {
            list = items
        } else if let items = dict["models"] as? [Any] {
            list = items
        } else {
            list = []
        }
    } else {
        return .failure(.other(.badResponse))
    }
    var ids: [String] = []
    for item in list {
        var id = ""
        if let text = item as? String {
            id = text
        } else if let entry = item as? [String: Any] {
            id = luminaJSONString(entry["id"])
            if id.isEmpty {
                id = luminaJSONString(entry["name"])
            }
        }
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty && id.count <= 200 {
            ids.append(id)
        }
    }
    return .ids(ids)
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
            let ids: [String]
            switch luminaParseModelListReply(data) {
            case let .ids(value):
                ids = value
            case let .failure(error):
                return .fail(error)
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
