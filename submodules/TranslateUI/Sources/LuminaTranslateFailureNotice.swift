import Foundation
import Display
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import UndoUI

// LuminaGram — tell the user once when the LLM provider fails in a way only they can fix.
//
// Chat translation (ChatTranslation.swift) and translate-before-send
// (LuminaTranslateBeforeSend.swift) both fail open: a message that cannot be translated stays
// untranslated, and translate-before-send sends the original. That is right for a network hiccup,
// but when the configured model does not exist or the API key is rejected, every request fails the
// same way and nothing on screen says why. luminaReportTranslateFailure shows a toast for those two
// errors only, at most once per app launch for the same LLM settings: changing the base URL, the
// model or the key re-arms it. A missing model gets a "Detect Models" button that opens the same
// model picker as the settings screen. The toast never blocks or delays anything; the caller has
// already decided to fail open.
private enum LuminaTranslateFailureNotice {
    // Main queue only. Holds hashes, never a key or a URL.
    static var reported = Set<String>()
}

public func luminaReportTranslateFailure(context: AccountContext, engineId: String, error: LuminaTranslateError) {
    guard engineId == "llm" else {
        return
    }
    let kind: String
    switch error {
    case .modelNotFound:
        kind = "model"
    case .keyRejected:
        kind = "key"
    default:
        return
    }
    Queue.mainQueue().async {
        // The same inputs every LLM request reads (LuminaLLMEngine.translate), hashed in memory
        // only: Hasher is seeded per launch, which is exactly the lifetime wanted here.
        let settings = LuminaSettingsCache.settings
        var hasher = Hasher()
        hasher.combine(LuminaLLMDefaults.resolvedBaseUrl(settings.translateBaseUrl))
        hasher.combine(LuminaLLMDefaults.resolvedModel(settings.translateModel))
        hasher.combine(LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: engineId)) ?? "")
        let signature = "\(kind):\(hasher.finalize())"
        if LuminaTranslateFailureNotice.reported.contains(signature) {
            return
        }
        LuminaTranslateFailureNotice.reported.insert(signature)

        let present: (ViewController) -> Void = { controller in
            context.sharedContext.presentGlobalController(controller, nil)
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let offersModelDetection = error.isModelNotFound
        present(UndoOverlayController(presentationData: presentationData, content: .info(title: LuminaL10n.tr("Translation failed"), text: luminaTranslateErrorText(error, usesBaseUrl: true), timeout: offersModelDetection ? 8.0 : nil, customUndoText: offersModelDetection ? LuminaL10n.tr("Detect Models") : nil), elevatedLayout: false, action: { action in
            if offersModelDetection, case .undo = action {
                luminaPresentModelDetection(context: context, present: present)
            }
            return false
        }))
    }
}
