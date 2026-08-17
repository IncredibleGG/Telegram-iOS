import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import Display
import ChatMessageBubbleContentNode

// LuminaGram: file-masquerade guard — the AccountContext/UI-aware half of `LuminaFileGuard`
// (submodules/TelegramUIPreferences/Sources/LuminaFileGuard.swift). Called from the document-tap
// hook in `ChatMessageFileBubbleContentNode.swift`'s `interactiveFileNode.activateLocalContent`
// closure (`strongSelf.luminaCheckFileGuardBeforeOpening`, wrapping the existing
// `controllerInteraction.openMessage` call).
//
// UNSURE-compiles: `ChatMessageBubbleContentItem` (the type of `item.context` /
// `item.controllerInteraction` / `item.message`) lives in the `ChatMessageBubbleContentNode`
// module per `ChatMessageFileBubbleContentNode.swift`'s own imports; this file adds that same
// import defensively but has not been compiled against it.
extension ChatMessageFileBubbleContentNode {
    func luminaCheckFileGuardBeforeOpening(item: ChatMessageBubbleContentItem, proceed: @escaping () -> Void) {
        guard let file = LuminaFileGuardHookSupport.firstFile(in: item.message) else {
            proceed()
            return
        }

        let _ = (item.context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.fileGuardEnabled else {
                proceed()
                return
            }

            let localPath = item.context.account.postbox.mediaBox.completedResourcePath(file.resource)
            let fileURL = localPath.map { URL(fileURLWithPath: $0) }
            let result = LuminaFileGuard.check(fileName: file.fileName, mimeType: file.mimeType, fileURL: fileURL)
            guard result.suspicious else {
                proceed()
                return
            }

            var text = "\"\(result.safeName)\" doesn't look like what it claims to be."
            if let realType = result.realType {
                text += "\n\nReal type: \(realType)"
            }
            if let claimedType = result.claimedType {
                text += "\nClaimed as: \(claimedType)"
            }
            text += "\n\nOpening it could run code on your device. Only continue if you trust the sender."

            let controller = textAlertController(
                sharedContext: item.context.sharedContext,
                title: "Suspicious File",
                text: text,
                actions: [
                    TextAlertAction(type: .destructiveAction, title: "Open Anyway", action: {
                        proceed()
                    }),
                    TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
                ]
            )
            item.controllerInteraction.presentController(controller, nil)
        })
    }
}

private enum LuminaFileGuardHookSupport {
    static func firstFile(in message: Message) -> TelegramMediaFile? {
        for media in message.media {
            if let file = media as? TelegramMediaFile {
                return file
            }
            if let poll = media as? TelegramMediaPoll, let file = poll.attachedMedia as? TelegramMediaFile {
                return file
            }
        }
        return nil
    }
}
