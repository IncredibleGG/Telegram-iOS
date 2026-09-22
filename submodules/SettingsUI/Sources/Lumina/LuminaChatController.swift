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

// LuminaGram: "Chat" hub - the Batch 4 chat/interaction settings sub-screen, reached from the
// LuminaGram settings hub (LuminaGramSettingsController.swift, `.chat` case). Structured exactly
// like LuminaToolsController.swift in this same folder: one ItemListController driven by a
// combineLatest of presentationData + the LuminaSettings SharedData entry, each row read/writing
// LuminaSettings via updateLuminaSettingsInteractively.
//
// Every default here is the stock behavior (double-tap edit off, every menu action shown, no
// filter keywords, call confirm off), so an untouched install behaves identically to upstream.
public func luminaChatController(context: AccountContext) -> ViewController {
    let arguments = LuminaChatControllerArguments(
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

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Chat")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaChatControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}

private final class LuminaChatControllerArguments {
    let context: AccountContext
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void

    init(context: AccountContext, updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void) {
        self.context = context
        self.updateSettings = updateSettings
    }
}

private enum LuminaChatSection: Int32 {
    case interaction
    case menu
    case filter
}

private enum LuminaChatEntry: ItemListNodeEntry {
    case interactionHeader
    case doubleTapToEdit(Bool)
    case confirmBeforeCall(Bool)
    case interactionFooter

    case menuHeader
    case menuReply(Bool)
    case menuCopy(Bool)
    case menuForward(Bool)
    case menuPin(Bool)
    case menuReport(Bool)
    case menuSave(Bool)
    case menuSelect(Bool)
    case menuFooter

    case filterHeader
    case filterKeywords(String)
    case filterFooter

    var section: ItemListSectionId {
        switch self {
        case .interactionHeader, .doubleTapToEdit, .confirmBeforeCall, .interactionFooter:
            return LuminaChatSection.interaction.rawValue
        case .menuHeader, .menuReply, .menuCopy, .menuForward, .menuPin, .menuReport, .menuSave, .menuSelect, .menuFooter:
            return LuminaChatSection.menu.rawValue
        case .filterHeader, .filterKeywords, .filterFooter:
            return LuminaChatSection.filter.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .interactionHeader:
            return 0
        case .doubleTapToEdit:
            return 1
        case .confirmBeforeCall:
            return 2
        case .interactionFooter:
            return 3
        case .menuHeader:
            return 10
        case .menuReply:
            return 11
        case .menuCopy:
            return 12
        case .menuForward:
            return 13
        case .menuPin:
            return 14
        case .menuReport:
            return 15
        case .menuSave:
            return 16
        case .menuSelect:
            return 17
        case .menuFooter:
            return 18
        case .filterHeader:
            return 20
        case .filterKeywords:
            return 21
        case .filterFooter:
            return 22
        }
    }

    static func <(lhs: LuminaChatEntry, rhs: LuminaChatEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaChatControllerArguments
        switch self {
        case .interactionHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("INTERACTION"), sectionId: self.section)
        case let .doubleTapToEdit(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Double-Tap to Edit"), text: LuminaL10n.tr("Double-tap your own message to edit it, instead of adding a reaction."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.doubleTapToEdit = value
                    return settings
                }
            })
        case let .confirmBeforeCall(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Confirm Before Calling"), text: LuminaL10n.tr("Ask for confirmation before starting a voice or video call."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.confirmBeforeCall = value
                    return settings
                }
            })
        case .interactionFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("These options change how you interact with messages on this device only.")), sectionId: self.section)
        case .menuHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("MESSAGE MENU"), sectionId: self.section)
        case let .menuReply(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Reply"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowReply = value
                    return settings
                }
            })
        case let .menuCopy(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Copy"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowCopy = value
                    return settings
                }
            })
        case let .menuForward(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Forward"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowForward = value
                    return settings
                }
            })
        case let .menuPin(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Pin"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowPin = value
                    return settings
                }
            })
        case let .menuReport(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Report"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowReport = value
                    return settings
                }
            })
        case let .menuSave(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Save / Download"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowSave = value
                    return settings
                }
            })
        case let .menuSelect(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Select"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.ctxMenuShowSelect = value
                    return settings
                }
            })
        case .menuFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Choose which actions appear in a message's long-press menu. Turning one off only hides it on this device.")), sectionId: self.section)
        case .filterHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("MESSAGE FILTER"), sectionId: self.section)
        case let .filterKeywords(value):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: LuminaL10n.tr("spam, promo — one keyword per line or comma-separated"), maxLength: nil, sectionId: self.section, style: .blocks, capitalization: false, autocorrection: false, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.messageFilterKeywords = luminaChatSplitKeywordList(value)
                    return settings
                }
            })
        case .filterFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Messages whose text contains any of these keywords are hidden from view on this device only. Nothing is deleted, and the other person is never affected.")), sectionId: self.section)
        }
    }
}

private func luminaChatSplitKeywordList(_ text: String) -> [String] {
    return text
        .components(separatedBy: CharacterSet(charactersIn: ",\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private func luminaChatControllerEntries(settings: LuminaSettings) -> [LuminaChatEntry] {
    return [
        .interactionHeader,
        .doubleTapToEdit(settings.doubleTapToEdit),
        .confirmBeforeCall(settings.confirmBeforeCall),
        .interactionFooter,

        .menuHeader,
        .menuReply(settings.ctxMenuShowReply),
        .menuCopy(settings.ctxMenuShowCopy),
        .menuForward(settings.ctxMenuShowForward),
        .menuPin(settings.ctxMenuShowPin),
        .menuReport(settings.ctxMenuShowReport),
        .menuSave(settings.ctxMenuShowSave),
        .menuSelect(settings.ctxMenuShowSelect),
        .menuFooter,

        .filterHeader,
        .filterKeywords(settings.messageFilterKeywords.joined(separator: ", ")),
        .filterFooter
    ]
}
