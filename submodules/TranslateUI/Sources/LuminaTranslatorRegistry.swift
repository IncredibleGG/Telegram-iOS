import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram — registry of the available LuminaTranslatorEngine providers (iOS twin of
// Android's LuminaTranslators and desktop's MakeTranslateEngine/MakeCurrentTranslateEngine in
// lumina_translate_providers.cpp). Insertion order (Telegram first) is preserved for the
// provider picker; byId falls back to Telegram for an unknown/corrupt stored id, matching
// Android's LuminaTranslators.byId. LuminaSettings.defaultSettings.translateEngine is
// "google_web" (free, keyless), so translation works out of the box before any key is
// entered — that default lives in LuminaSettings.swift, not here.
public enum LuminaTranslatorRegistry {
    private static let engines: [LuminaTranslatorEngine] = [
        LuminaTelegramEngine(),
        LuminaGoogleWebEngine(),
        LuminaDeepLEngine(),
        LuminaLLMEngine()
    ]

    // Unwrapped providers, for the picker UI.
    public static var all: [LuminaTranslatorEngine] {
        return self.engines
    }

    public static func byId(_ id: String?) -> LuminaTranslatorEngine {
        // "google" is the historical spelling of the keyless web engine id
        // ("google_web"); map it so a profile that stored the old value resolves to
        // the real engine instead of silently falling back to engines[0] (Telegram).
        let resolvedId = (id == "google") ? "google_web" : id
        if let resolvedId, let found = self.engines.first(where: { $0.id == resolvedId }) {
            return found
        }
        return self.engines[0]
    }

    // The provider selected in LuminaSettings.translateEngine, wrapped in LuminaGlossary so
    // glossary / do-not-translate protection applies everywhere without every call site
    // remembering to add it itself. This is the entry point translate-before-send,
    // explain-a-message and the provider test button all use.
    public static func current(context: AccountContext) -> Signal<LuminaTranslatorEngine, NoError> {
        return luminaCurrentSettings(context: context)
        |> map { settings -> LuminaTranslatorEngine in
            let engine = self.byId(settings.translateEngine)
            return LuminaGlossary.wrap(engine, terms: settings.glossaryTerms)
        }
    }
}
