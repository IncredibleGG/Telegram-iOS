import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import AccountContext
import ChatPresentationInterfaceState

// LuminaGram: crypto-address paste guard — the AccountContext/UI-aware half of
// `LuminaCryptoAddress` (submodules/TelegramUIPreferences/Sources/LuminaCryptoAddress.swift).
// Called from the paste hook in `ChatTextInputPanelNode.swift`'s
// `chatInputTextNodeShouldPaste()` (`self.luminaHandleCryptoAddressPaste`).
//
// UNSURE-compiles: `LuminaSettings.cryptoClipboardGuard` has to be read through the
// accountManager's async SharedData signal (no synchronous settings cache exists for
// `LuminaSettings` yet), but `chatInputTextNodeShouldPaste()` must return its `Bool` verdict
// synchronously. The two are reconciled by always intercepting a clipboard string that matches
// the wallet-address pattern (returning `false`, "I handled this paste") and deciding
// asynchronously whether to show the guard alert or just insert the text unchanged — so with
// the setting off there is one imperceptible async hop instead of a fully synchronous no-op.
extension ChatTextInputPanelNode {
    func luminaHandleCryptoAddressPaste(_ candidate: String) {
        guard let context = self.context else {
            self.luminaInsertPastedPlainText(candidate)
            return
        }

        let _ = (context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.cryptoClipboardGuard else {
                self.luminaInsertPastedPlainText(candidate)
                return
            }

            let controller = textAlertController(
                context: context,
                title: LuminaL10n.tr("Verify Wallet Address"),
                text: LuminaL10n.tr("Clipboard-hijacking malware can silently swap a copied address for a scammer's. Check every character before you paste:") + "\n\n\(candidate)",
                actions: [
                    TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Paste"), action: { [weak self] in
                        self?.luminaInsertPastedPlainText(candidate)
                    }),
                    TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Cancel"), action: {}),
                ]
            )
            self.interfaceInteraction?.presentController(controller, nil)
        })
    }

    /// Plain-text insertion at the current selection — mirrors the existing rich-text paste
    /// branch a few lines below the hook in `chatInputTextNodeShouldPaste()` (same
    /// `updateTextInputStateAndMode` shape), kept separate here since a wallet address is always
    /// plain text with no attributes to preserve.
    private func luminaInsertPastedPlainText(_ text: String) {
        let attributedString = NSAttributedString(string: text)
        self.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
            if let inputText = current.inputText.mutableCopy() as? NSMutableAttributedString {
                inputText.replaceCharacters(in: NSMakeRange(current.selectionRange.lowerBound, current.selectionRange.count), with: attributedString)
                let updatedRange = current.selectionRange.lowerBound + attributedString.length
                return (ChatTextInputState(inputText: inputText, selectionRange: updatedRange ..< updatedRange), inputMode)
            } else {
                return (ChatTextInputState(inputText: attributedString), inputMode)
            }
        }
    }
}
