import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import Display

// LuminaGram: link safety check — the AccountContext/UI-aware half of `LuminaLinkSafety`
// (submodules/TelegramUIPreferences/Sources/LuminaLinkSafety.swift). Called from the link-open
// hook in `ChatController.swift`'s `openUrl(...)` (`self.luminaCheckLinkSafetyBeforeOpening`,
// added at the very top of that function, before `commitPurposefulAction()`).
//
// UNSURE-compiles: `luminaKnownTelegramHosts` is a hand-picked approximation of the "is this an
// internal Telegram destination" check Android's `Browser.isInternalUri` does with the app's
// full authDomains/autologinDomains/instant-view host lists (`MessagesController`-backed, not
// reproduced here). A real "internal" host that isn't on this short list will incorrectly get a
// safety sheet instead of being silently skipped — annoying, not unsafe, and easy to extend.
private let luminaKnownTelegramHosts: Set<String> = ["t.me", "telegram.me", "telegram.org", "telegram.dog", "telesco.pe"]

private func luminaIsKnownTelegramHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else {
        return false
    }
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return luminaKnownTelegramHosts.contains(bare)
}

extension ChatControllerImpl {
    /// Last URL the user approved via the safety sheet, so an async re-open of the exact same
    /// string (e.g. `openResolved` calling back into `openUrl`) is not prompted twice. Extensions
    /// cannot add stored INSTANCE properties, but a stored STATIC property is fine — mirrors
    /// Android's own `static volatile String luminaLinkSafetyApprovedUrl`.
    private static var luminaApprovedLinkSafetyUrl: String?

    func luminaCheckLinkSafetyBeforeOpening(_ url: String, proceed: @escaping () -> Void) {
        guard let parsed = URL(string: url) else {
            proceed()
            return
        }
        let isInternal = luminaIsKnownTelegramHost(parsed.host)
        guard LuminaLinkSafety.shouldConfirm(url: parsed, isInternalUri: isInternal, alreadyApproved: ChatControllerImpl.luminaApprovedLinkSafetyUrl) else {
            proceed()
            return
        }

        let _ = (self.context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                proceed()
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.linkSafetyCheck else {
                proceed()
                return
            }

            let warnings = LuminaLinkSafety.warnings(for: parsed)
            var text = url
            for warning in warnings {
                text += "\n\n⚠ \(warning.text)"
            }

            self.present(textAlertController(
                context: self.context,
                updatedPresentationData: self.updatedPresentationData,
                title: "Check This Link",
                text: text,
                actions: [
                    TextAlertAction(type: .defaultAction, title: "Open", action: {
                        ChatControllerImpl.luminaApprovedLinkSafetyUrl = url
                        proceed()
                    }),
                    TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
                ]
            ), in: .window(.root))
        })
    }
}
