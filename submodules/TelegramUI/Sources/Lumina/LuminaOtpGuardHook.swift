import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import Display

// LuminaGram: OTP leak guard — the AccountContext/UI-aware half of `LuminaOtpGuard`
// (submodules/TelegramUIPreferences/Sources/LuminaOtpGuard.swift). Called from the send-path
// hook in `ChatController.swift`'s `sendMessages(_:media:postpone:commit:)`
// (`self.luminaCheckOtpGuardBeforeSending(...)`, added right after the `peerId` guard there).
//
// UNSURE-compiles: `TelegramEngine.EngineData.Item.Messages.TopMessage` and the
// `PeerId(namespace:id:)` / `PeerId.Id._internalFromInt64Value(_:)` construction below are
// mirrored from confirmed working call sites elsewhere in this module (AppDelegate.swift,
// ChatControllerNode.swift) and from `TelegramCore/Sources/TelegramEngine/Data/MessagesData.swift`,
// but this whole file has not been compiled.
extension ChatControllerImpl {
    func luminaCheckOtpGuardBeforeSending(_ messages: [EnqueueMessage], peerId: PeerId, proceed: @escaping () -> Void) {
        // Sending "back" to Telegram itself, or to Saved Messages, leaks nothing.
        if peerId.toInt64() == LuminaOtpGuard.serviceUserId || peerId == self.context.account.peerId {
            proceed()
            return
        }

        // Cheap test first: most sends contain no 5-6 digit run at all, and most EnqueueMessage
        // batches (media, forwards) carry no `.message(text:...)` case at all.
        let combinedText = messages.compactMap { message -> String? in
            if case let .message(text, _, _, _, _, _, _, _, _, _) = message, !text.isEmpty {
                return text
            }
            return nil
        }.joined(separator: "\n")

        guard !combinedText.isEmpty, LuminaOtpGuard.containsLoginCode(combinedText) else {
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
            guard settings.otpGuardEnabled else {
                proceed()
                return
            }

            // "Recently received from 777000" — read via TelegramEngine's TopMessage data item
            // for the service-account peer (the iOS analogue of Android's in-memory
            // MessagesController.dialogs_dict[777000].last_message_date read).
            let serviceUserPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(LuminaOtpGuard.serviceUserId))
            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.TopMessage(id: serviceUserPeerId))
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] topMessage in
                guard let self else {
                    proceed()
                    return
                }
                let now = Int32(Date().timeIntervalSince1970)
                guard LuminaOtpGuard.isRecent(serviceMessageTimestamp: topMessage?.timestamp ?? 0, now: now) else {
                    proceed()
                    return
                }

                self.present(textAlertController(
                    context: self.context,
                    updatedPresentationData: self.updatedPresentationData,
                    title: LuminaL10n.tr("Login Code Detected"),
                    text: LuminaL10n.tr("This message looks like it contains your Telegram login code. Telegram staff and real support will never ask you to send it. Send anyway?"),
                    actions: [
                        TextAlertAction(type: .destructiveAction, title: LuminaL10n.tr("Send Anyway"), action: {
                            proceed()
                        }),
                        TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Cancel"), action: {}),
                    ]
                ), in: .window(.root))
            })
        })
    }
}
