import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext

// LuminaGram: "Notifications" hub - the #18 notification fine-control sub-screen, reached from
// the LuminaGram settings hub (LuminaGramSettingsController.swift, `.notifications` case).
// Structured exactly like LuminaChatController.swift in this same folder: one ItemListController
// driven by a combineLatest of presentationData + the LuminaSettings SharedData entry, each row
// read/writing LuminaSettings via updateLuminaSettingsInteractively.
//
// Both toggles default off, so an untouched install behaves identically to upstream. They only
// suppress presentation of the OS notification (see NotificationService.swift, where the two
// flags gate presenting the "X pinned a message" service-message notification and the
// @mention/reply-to-me notification). Nothing is marked read and no message is deleted.
public func luminaNotificationsController(context: AccountContext) -> ViewController {
    let arguments = LuminaNotificationsControllerArguments(
        context: context,
        updateSettings: { f in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, f).start()
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Notifications")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaNotificationsControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}

private final class LuminaNotificationsControllerArguments {
    let context: AccountContext
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void

    init(context: AccountContext, updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void) {
        self.context = context
        self.updateSettings = updateSettings
    }
}

private enum LuminaNotificationsSection: Int32 {
    case mute
}

private enum LuminaNotificationsEntry: ItemListNodeEntry {
    case muteHeader
    case mutePinned(Bool)
    case muteMentionReply(Bool)
    case muteFooter

    var section: ItemListSectionId {
        switch self {
        case .muteHeader, .mutePinned, .muteMentionReply, .muteFooter:
            return LuminaNotificationsSection.mute.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .muteHeader:
            return 0
        case .mutePinned:
            return 1
        case .muteMentionReply:
            return 2
        case .muteFooter:
            return 3
        }
    }

    static func <(lhs: LuminaNotificationsEntry, rhs: LuminaNotificationsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaNotificationsControllerArguments
        switch self {
        case .muteHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("NOTIFICATIONS"), sectionId: self.section)
        case let .mutePinned(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Mute Pinned Messages"), text: LuminaL10n.tr("Don't show a notification when someone pins a message in a chat."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.mutePinnedNotifications = value
                    return settings
                }
            })
        case let .muteMentionReply(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Mute Mentions & Replies"), text: LuminaL10n.tr("Don't show a notification when you are @mentioned or someone replies to your message."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.muteMentionReplyNotifications = value
                    return settings
                }
            })
        case .muteFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("These options only stop the notification from appearing on this device. Messages are not marked as read and nothing is deleted.")), sectionId: self.section)
        }
    }
}

private func luminaNotificationsControllerEntries(settings: LuminaSettings) -> [LuminaNotificationsEntry] {
    return [
        .muteHeader,
        .mutePinned(settings.mutePinnedNotifications),
        .muteMentionReply(settings.muteMentionReplyNotifications),
        .muteFooter
    ]
}
