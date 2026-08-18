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
import AlertUI

// LuminaGram: "Tools" hub - replaces the placeholder wired in LuminaGramSettingsController.swift
// (`.tools` case, `luminaGramPlaceholderController`). This is the entry point for every
// Utility & interface feature in this bucket: bookmarks, quick replies, encrypted backup,
// stories-off, unread digest, precise counts, sticker size, seconds timestamps.
//
// INTEGRATION NOTE for whoever wires the hub: LuminaGramSettingsController.swift's `.tools`
// entry currently pushes `luminaGramPlaceholderController(...)`. Swap that one call site to
// `luminaToolsController(context: arguments.context)` (same signature shape as
// `luminaGramSettingsController`) - see this fork's task report for the exact diff, since
// LuminaGramSettingsController.swift itself was off-limits to edit directly here.
//
// Two things intentionally NOT here: (1) the multi-account cap - that is a raised
// constant (AccountUtils.swift), not a toggle, so it has nothing to surface in Settings
// UI; existing "Add Account" flow already reflects the new limit. (2) hide-input-AI-button -
// no in-composer AI/rewrite button exists in this Telegram-iOS branch to hide (see the task
// report), so no dormant toggle is shown for it.
public func luminaToolsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaToolsControllerArguments(
        context: context,
        pushController: { c in
            pushControllerImpl?(c)
        },
        updateSettings: { f in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, f).start()
        },
        pickStickerScale: { currentValue in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let makeAction: (Int32, String) -> TextAlertAction = { value, title in
                TextAlertAction(type: value == currentValue ? .defaultAction : .genericAction, title: title, action: {
                    let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.stickerScale = value
                        return settings
                    }).start()
                })
            }
            presentControllerImpl?(textAlertController(context: context, title: LuminaL10n.tr("Sticker Size"), text: LuminaL10n.tr("Choose how large stickers render in chats."), actions: [
                makeAction(75, LuminaL10n.tr("Small (75%)")),
                makeAction(100, LuminaL10n.tr("Default (100%)")),
                makeAction(125, LuminaL10n.tr("Large (125%)")),
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
            ], actionLayout: .vertical))
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Tools")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaToolsControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

private final class LuminaToolsControllerArguments {
    let context: AccountContext
    let pushController: (ViewController) -> Void
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void
    let pickStickerScale: (Int32) -> Void

    init(context: AccountContext, pushController: @escaping (ViewController) -> Void, updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void, pickStickerScale: @escaping (Int32) -> Void) {
        self.context = context
        self.pushController = pushController
        self.updateSettings = updateSettings
        self.pickStickerScale = pickStickerScale
    }
}

private enum LuminaToolsSection: Int32 {
    case screens
    case stories
    case display
}

private enum LuminaToolsEntry: ItemListNodeEntry {
    case screensHeader
    case bookmarks
    case quickReplies
    case backup

    case storiesHeader
    case storiesFullyOff(Bool)
    case storiesHidePostEntry(Bool, Bool) // (value, enabled)
    case storiesFooter

    case displayHeader
    case unreadDigest(Bool)
    case disableNumberRounding(Bool)
    case timeWithSeconds(Bool)
    case stickerScale(Int32)
    case displayFooter

    var section: ItemListSectionId {
        switch self {
        case .screensHeader, .bookmarks, .quickReplies, .backup:
            return LuminaToolsSection.screens.rawValue
        case .storiesHeader, .storiesFullyOff, .storiesHidePostEntry, .storiesFooter:
            return LuminaToolsSection.stories.rawValue
        case .displayHeader, .unreadDigest, .disableNumberRounding, .timeWithSeconds, .stickerScale, .displayFooter:
            return LuminaToolsSection.display.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .screensHeader:
            return 0
        case .bookmarks:
            return 1
        case .quickReplies:
            return 2
        case .backup:
            return 3
        case .storiesHeader:
            return 10
        case .storiesFullyOff:
            return 11
        case .storiesHidePostEntry:
            return 12
        case .storiesFooter:
            return 13
        case .displayHeader:
            return 20
        case .unreadDigest:
            return 21
        case .disableNumberRounding:
            return 22
        case .timeWithSeconds:
            return 23
        case .stickerScale:
            return 24
        case .displayFooter:
            return 25
        }
    }

    static func <(lhs: LuminaToolsEntry, rhs: LuminaToolsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaToolsControllerArguments
        switch self {
        case .screensHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("SCREENS"), sectionId: self.section)
        case .bookmarks:
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Bookmarks"), label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaBookmarksController(context: arguments.context))
            })
        case .quickReplies:
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Quick Replies"), label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaQuickRepliesController(context: arguments.context))
            })
        case .backup:
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Backup"), label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaBackupController(context: arguments.context))
            })
        case .storiesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("STORIES"), sectionId: self.section)
        case let .storiesFullyOff(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Stories Tray"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.storiesFullyOff = value
                    return settings
                }
            })
        case let .storiesHidePostEntry(value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide My Story Prompt"), value: value, enableInteractiveChanges: enabled, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.storiesHidePostEntry = value
                    return settings
                }
            })
        case .storiesFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Hides the stories strip in chats and the story ring around avatars app-wide. Does not touch anyone's stories on the server.")), sectionId: self.section)
        case .displayHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("DISPLAY"), sectionId: self.section)
        case let .unreadDigest(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Unread Digest on Return"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.unreadDigest = value
                    return settings
                }
            })
        case let .disableNumberRounding(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Precise Counts"), text: LuminaL10n.tr("No 1.2K / 3.4M rounding"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.disableNumberRounding = value
                    return settings
                }
            })
        case let .timeWithSeconds(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Seconds in Timestamps"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.timeWithSeconds = value
                    return settings
                }
            })
        case let .stickerScale(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: LuminaL10n.tr("Sticker Size"), label: "\(value)%", sectionId: self.section, style: .blocks, action: {
                arguments.pickStickerScale(value)
            })
        case .displayFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("These options and everything else under LuminaGram are stored on this device only.")), sectionId: self.section)
        }
    }
}

private func luminaToolsControllerEntries(settings: LuminaSettings) -> [LuminaToolsEntry] {
    return [
        .screensHeader,
        .bookmarks,
        .quickReplies,
        .backup,

        .storiesHeader,
        .storiesFullyOff(settings.storiesFullyOff),
        .storiesHidePostEntry(settings.storiesFullyOff ? true : settings.storiesHidePostEntry, !settings.storiesFullyOff),
        .storiesFooter,

        .displayHeader,
        .unreadDigest(settings.unreadDigest),
        .disableNumberRounding(settings.disableNumberRounding),
        .timeWithSeconds(settings.timeWithSeconds),
        .stickerScale(settings.stickerScale),
        .displayFooter
    ]
}
