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

// LuminaGram: "Interface" hub - the Batch 7 navigation/folder settings sub-screen, reached from
// the LuminaGram settings hub (LuminaGramSettingsController.swift, `.interface` case). Structured
// exactly like LuminaChatController.swift in this same folder: one ItemListController driven by a
// combineLatest of presentationData + the LuminaSettings SharedData entry, each row read/writing
// LuminaSettings via updateLuminaSettingsInteractively.
//
// Every default here is the stock behavior (tab bar shown with labels, All Chats folder shown,
// standard spacing, always open to All Chats), so an untouched install behaves identically to
// upstream.
public func luminaInterfaceController(context: AccountContext) -> ViewController {
    let arguments = LuminaInterfaceControllerArguments(
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

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Interface")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaInterfaceControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}

private final class LuminaInterfaceControllerArguments {
    let context: AccountContext
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void

    init(context: AccountContext, updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void) {
        self.context = context
        self.updateSettings = updateSettings
    }
}

private enum LuminaInterfaceSection: Int32 {
    case tabBar
    case folders
}

private enum LuminaInterfaceEntry: ItemListNodeEntry {
    case tabBarHeader
    case hideTabBar(Bool)
    case tabBarHideLabels(Bool)
    case tabBarHideContacts(Bool)
    case tabBarHideCalls(Bool)
    case tabBarFooter

    case foldersHeader
    case hideAllChatsFolder(Bool)
    case compactFolderTabs(Bool)
    case wideFolderTabs(Bool)
    case rememberLastFolder(Bool)
    case foldersFooter

    var section: ItemListSectionId {
        switch self {
        case .tabBarHeader, .hideTabBar, .tabBarHideLabels, .tabBarHideContacts, .tabBarHideCalls, .tabBarFooter:
            return LuminaInterfaceSection.tabBar.rawValue
        case .foldersHeader, .hideAllChatsFolder, .compactFolderTabs, .wideFolderTabs, .rememberLastFolder, .foldersFooter:
            return LuminaInterfaceSection.folders.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .tabBarHeader:
            return 0
        case .hideTabBar:
            return 1
        case .tabBarHideLabels:
            return 2
        case .tabBarHideContacts:
            return 3
        case .tabBarHideCalls:
            return 4
        case .tabBarFooter:
            return 5
        case .foldersHeader:
            return 10
        case .hideAllChatsFolder:
            return 11
        case .compactFolderTabs:
            return 12
        case .wideFolderTabs:
            return 13
        case .rememberLastFolder:
            return 14
        case .foldersFooter:
            return 15
        }
    }

    static func <(lhs: LuminaInterfaceEntry, rhs: LuminaInterfaceEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaInterfaceControllerArguments
        switch self {
        case .tabBarHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("TAB BAR"), sectionId: self.section)
        case let .hideTabBar(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Tab Bar"), text: LuminaL10n.tr("Hide the bottom tab bar. Settings stays reachable from a button in the chat list."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.hideTabBar = value
                    return settings
                }
            })
        case let .tabBarHideLabels(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Tab Labels"), text: LuminaL10n.tr("Hide the text labels under the tab bar icons."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.tabBarHideLabels = value
                    return settings
                }
            })
        case let .tabBarHideContacts(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Contacts Tab"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.tabBarHideContacts = value
                    return settings
                }
            })
        case let .tabBarHideCalls(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Calls Tab"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.tabBarHideCalls = value
                    return settings
                }
            })
        case .tabBarFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Changes to the tab bar apply the next time the app is opened.")), sectionId: self.section)
        case .foldersHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("FOLDER TABS"), sectionId: self.section)
        case let .hideAllChatsFolder(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide \"All Chats\""), text: LuminaL10n.tr("Hide the \"All Chats\" tab from the folder bar."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.hideAllChatsFolder = value
                    return settings
                }
            })
        case let .compactFolderTabs(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Compact Folder Tabs"), text: LuminaL10n.tr("Tighten the spacing between folder tabs."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.compactFolderTabs = value
                    return settings
                }
            })
        case let .wideFolderTabs(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Wide Folder Tabs"), text: LuminaL10n.tr("Stretch the folder tabs to fill the full width."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.wideFolderTabs = value
                    return settings
                }
            })
        case let .rememberLastFolder(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Remember Last Folder"), text: LuminaL10n.tr("Reopen to the folder you used last instead of \"All Chats\"."), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.rememberLastFolder = value
                    return settings
                }
            })
        case .foldersFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("LuminaGram options are stored on this device only and are never synced to Telegram.")), sectionId: self.section)
        }
    }
}

private func luminaInterfaceControllerEntries(settings: LuminaSettings) -> [LuminaInterfaceEntry] {
    var entries: [LuminaInterfaceEntry] = []

    entries.append(.tabBarHeader)
    entries.append(.hideTabBar(settings.hideTabBar))
    entries.append(.tabBarHideLabels(settings.tabBarHideLabels))
    entries.append(.tabBarHideContacts(settings.tabBarHideContacts))
    entries.append(.tabBarHideCalls(settings.tabBarHideCalls))
    entries.append(.tabBarFooter)

    entries.append(.foldersHeader)
    entries.append(.hideAllChatsFolder(settings.hideAllChatsFolder))
    entries.append(.compactFolderTabs(settings.compactFolderTabs))
    entries.append(.wideFolderTabs(settings.wideFolderTabs))
    entries.append(.rememberLastFolder(settings.rememberLastFolder))
    entries.append(.foldersFooter)

    return entries
}
