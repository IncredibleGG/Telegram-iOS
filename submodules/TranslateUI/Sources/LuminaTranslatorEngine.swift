import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram — bring-your-own-engine translation registry (iOS twin of Android's
// LuminaTranslator/LuminaTranslators and desktop's lumina_translate_providers.{h,cpp}).
//
// A LuminaTranslatorEngine turns one string into a translation for one target language.
// Implementations do their own network work off the main queue and always resolve their
// Signal on the main queue (matching alternativeTranslateText's existing convention in this
// module). The selected engine is read from LuminaSettings.translateEngine; LuminaTranslatorRegistry
// is the only place call sites need to know about — it returns the chosen engine already
// wrapped by LuminaGlossary.wrap so glossary/do-not-translate protection applies everywhere
// without every call site repeating it.
public enum LuminaTranslateError: Error {
    // No API key configured in LuminaKeychain for this provider.
    case noKey
    // HTTP 402 / 429 (and DeepL's 456 quota code): quota used up or too many requests.
    case rateLimited
    // HTTP 401 / 403: the provider rejected the API key.
    case keyRejected
    // HTTP 400 / 404 whose JSON error says the requested model does not exist. Carries the model
    // name the user typed (from settings) so the message can name it - never response text.
    case modelNotFound(String)
    // HTTP 5xx: the provider had a temporary error.
    case serverError(Int)
    // Any other non-2xx status (400, 404 / 405 without a model error, 422, ...).
    case httpStatus(Int)
    // A 2xx response the engine could not parse (wrong base URL, not an OpenAI-shaped reply).
    case badResponse
    // Transport failure: no connection, timeout, TLS, a refused redirect. message is for logging
    // only, never shown to the user.
    case network(String?)

    public var isModelNotFound: Bool {
        if case .modelNotFound = self {
            return true
        }
        return false
    }
}

// LuminaGram: the one place a LuminaTranslateError becomes user-facing text (Test Provider,
// Explain, model detection). Never includes the API key, the request URL or any response body;
// the only user data it repeats is the model name the user typed. `usesBaseUrl` is true for the
// LLM provider, whose connection problems usually come from the base URL.
public func luminaTranslateErrorText(_ error: LuminaTranslateError, usesBaseUrl: Bool) -> String {
    switch error {
    case .noKey:
        return LuminaL10n.tr("Enter the API key first.")
    case .rateLimited:
        return LuminaL10n.tr("Quota used up or too many requests. Try again later, or check your plan with the provider.")
    case .keyRejected:
        return LuminaL10n.tr("The service rejected the API key. Check that the key is correct.")
    case let .modelNotFound(model):
        return LuminaL10n.tr("The model \"%@\" does not exist on this service. Tap \"Detect Models\" to pick one.").replacingOccurrences(of: "%@", with: model)
    case .serverError:
        return LuminaL10n.tr("The service had a temporary error. Try again later.")
    case let .httpStatus(code):
        return LuminaL10n.tr("The service rejected the request (HTTP %@). Check the provider settings.").replacingOccurrences(of: "%@", with: "\(code)")
    case .badResponse:
        if usesBaseUrl {
            return LuminaL10n.tr("The service sent a reply LuminaGram cannot read. Check the base URL.")
        } else {
            return LuminaL10n.tr("The service sent a reply LuminaGram cannot read. Try again later.")
        }
    case .network:
        if usesBaseUrl {
            return LuminaL10n.tr("Cannot connect. Check the base URL and your network.")
        } else {
            return LuminaL10n.tr("Cannot connect. Check your network.")
        }
    }
}

public struct LuminaTranslationResult {
    public let text: String
    public let detectedSourceLang: String?

    public init(text: String, detectedSourceLang: String?) {
        self.text = text
        self.detectedSourceLang = detectedSourceLang
    }
}

public protocol LuminaTranslatorEngine {
    // Stable key persisted in LuminaSettings.translateEngine ("telegram", "google_web", "deepl", "llm").
    var id: String { get }
    // Human-readable brand label for the provider picker.
    var displayName: String { get }
    // True when the provider needs a user-supplied API key (LuminaKeychain, masked in the UI).
    var needsKey: Bool { get }
    // True when the provider needs a configurable base URL (self-hosted / LLM).
    var needsBaseUrl: Bool { get }
    // True when the provider needs a configurable model name (LLM).
    var needsModel: Bool { get }

    // Translate `text` into `toLang` (an ISO-ish tag such as "en" / "zh" / "pt-BR"; the
    // provider maps it to its own dialect). `peerId`, when known, lets the engine read this
    // chat's register/tone (LuminaRegister) — only the LLM and Telegram engines have any
    // channel for it; other engines simply ignore it. Resolves exactly once, on the main queue.
    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError>
}

// Read the current LuminaSettings once (not a live subscription) — the right shape for a
// one-shot translate call. Mirrors the read half of updateLuminaSettingsInteractively
// (LuminaSettings.swift): same SharedData key, same default-on-missing-entry fallback.
public func luminaCurrentSettings(context: AccountContext) -> Signal<LuminaSettings, NoError> {
    return context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    |> take(1)
    |> map { sharedData -> LuminaSettings in
        return sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
    }
}

// English display name / provider-specific dialect spelling for a language code. No
// hardcoded dialect table: Locale already knows this, and it is what the rest of this
// module (TranslatonSettingsController.swift) already uses for the same purpose.
public enum LuminaLang {
    // Full English name for an LLM system-prompt instruction ("Translate into {lang}.").
    public static func name(_ code: String) -> String {
        let normalized = normalizeTranslationLanguage(code)
        if let name = Locale(identifier: "en").localizedString(forLanguageCode: normalized) {
            return name
        }
        return normalized
    }

    // DeepL wants upper-cased target codes, with a handful of codes requiring a region
    // suffix DeepL does not infer on its own. Best-effort: DeepL's exact supported-target
    // list can change server-side, so this only covers the common cases this fork's
    // supportedTranslationLanguages list can produce.
    public static func deepl(_ code: String) -> String {
        let normalized = code.lowercased()
        switch normalized {
        case "pt-br":
            return "PT-BR"
        case "pt":
            return "PT-PT"
        case "en":
            return "EN-US"
        case "zh":
            return "ZH"
        default:
            return normalizeTranslationLanguage(code).uppercased()
        }
    }

    // Google's free web endpoint accepts the same codes this fork already uses elsewhere
    // (alternativeTranslateText passes toLang straight through unmodified).
    public static func google(_ code: String) -> String {
        return code
    }
}
