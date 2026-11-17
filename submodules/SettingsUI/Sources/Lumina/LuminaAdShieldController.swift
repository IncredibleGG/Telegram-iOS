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

// LuminaGram: 「隱藏重複廣告」(Hide Repeated Ads) settings page, reached from the Chat page of the LuminaGram hub
// (LuminaChatController.swift). One ItemListController over the LuminaSettings SharedData entry, like the other
// Lumina pages. The engine and its data live in TelegramUIPreferences (LuminaAdShield*.swift); this page only edits
// LuminaSettings and calls LuminaAdShieldService for 清除本機資料.
//
//  1. The switch (default off). The first time it is turned on, an explainer comes first (開啟 / 取消).
//  2. 靈敏度 寬鬆 / 標準（預設）/ 積極, each explained in one line of the footer.
//  3. 豁免 contacts / bots / replies and mentions of me (all on by default); own and admins' messages never fold.
//  4. 試運行: only label would-be folds.
//  5. 清除本機資料 (confirm): ForgetAll for every account, per-group modes and image tables.
//  6. Footer: everything is computed locally; turning the feature off clears its local data.

private final class LuminaAdShieldControllerArguments {
    let toggleEnabled: (Bool, Bool) -> Void
    let setSensitivity: (LuminaAdShield.Sensitivity) -> Void
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void
    let clearLocalData: () -> Void

    init(toggleEnabled: @escaping (Bool, Bool) -> Void, setSensitivity: @escaping (LuminaAdShield.Sensitivity) -> Void, updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void, clearLocalData: @escaping () -> Void) {
        self.toggleEnabled = toggleEnabled
        self.setSensitivity = setSensitivity
        self.updateSettings = updateSettings
        self.clearLocalData = clearLocalData
    }
}

private enum LuminaAdShieldSection: Int32 {
    case main
    case sensitivity
    case exemptions
    case trial
    case data
}

private enum LuminaAdShieldEntry: ItemListNodeEntry {
    case enabled(Bool, explainerShown: Bool)

    case sensitivityHeader
    case sensitivity(LuminaAdShield.Sensitivity, selected: Bool)
    case sensitivityFooter

    case exemptionsHeader
    case exemptContacts(Bool)
    case exemptBots(Bool)
    case exemptReplies(Bool)
    case exemptionsFooter

    case trialRun(Bool)

    case clearData
    case dataFooter

    var section: ItemListSectionId {
        switch self {
        case .enabled:
            return LuminaAdShieldSection.main.rawValue
        case .sensitivityHeader, .sensitivity, .sensitivityFooter:
            return LuminaAdShieldSection.sensitivity.rawValue
        case .exemptionsHeader, .exemptContacts, .exemptBots, .exemptReplies, .exemptionsFooter:
            return LuminaAdShieldSection.exemptions.rawValue
        case .trialRun:
            return LuminaAdShieldSection.trial.rawValue
        case .clearData, .dataFooter:
            return LuminaAdShieldSection.data.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .enabled:
            return 0
        case .sensitivityHeader:
            return 10
        case let .sensitivity(sensitivity, _):
            switch sensitivity {
            case .loose:
                return 11
            case .standard:
                return 12
            case .aggressive:
                return 13
            }
        case .sensitivityFooter:
            return 14
        case .exemptionsHeader:
            return 20
        case .exemptContacts:
            return 21
        case .exemptBots:
            return 22
        case .exemptReplies:
            return 23
        case .exemptionsFooter:
            return 24
        case .trialRun:
            return 30
        case .clearData:
            return 40
        case .dataFooter:
            return 41
        }
    }

    static func <(lhs: LuminaAdShieldEntry, rhs: LuminaAdShieldEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaAdShieldControllerArguments
        switch self {
        case let .enabled(value, explainerShown):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Hide Repeated Ads"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEnabled(value, explainerShown)
            })
        case .sensitivityHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("SENSITIVITY"), sectionId: self.section)
        case let .sensitivity(sensitivity, selected):
            return ItemListCheckboxItem(presentationData: presentationData, title: luminaAdShieldSensitivityTitle(sensitivity), style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setSensitivity(sensitivity)
            })
        case .sensitivityFooter:
            let lines = LuminaAdShield.Sensitivity.allCases.map { sensitivity -> String in
                return String(format: LuminaL10n.tr("%@: %@"), luminaAdShieldSensitivityShortTitle(sensitivity), luminaAdShieldSensitivityDescription(sensitivity))
            }
            return ItemListTextItem(presentationData: presentationData, text: .plain(lines.joined(separator: "\n")), sectionId: self.section)
        case .exemptionsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("EXCEPTIONS"), sectionId: self.section)
        case let .exemptContacts(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Contacts"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.adShieldExemptContacts = value
                    return settings
                }
            })
        case let .exemptBots(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Bots"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.adShieldExemptBots = value
                    return settings
                }
            })
        case let .exemptReplies(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Replies and Mentions of Me"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.adShieldExemptReplies = value
                    return settings
                }
            })
        case .exemptionsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Your own messages and admins' messages are never folded.")), sectionId: self.section)
        case let .trialRun(value):
            return ItemListSwitchItem(presentationData: presentationData, title: LuminaL10n.tr("Trial Run"), text: LuminaL10n.tr("Only mark messages as “Suspected repeated ad” without folding them"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.adShieldDryRun = value
                    return settings
                }
            })
        case .clearData:
            return ItemListActionItem(presentationData: presentationData, title: LuminaL10n.tr("Clear Local Data"), kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.clearLocalData()
            })
        case .dataFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Everything is computed on this device. Turning this off also clears its local data.")), sectionId: self.section)
        }
    }
}

private func luminaAdShieldSensitivityTitle(_ sensitivity: LuminaAdShield.Sensitivity) -> String {
    switch sensitivity {
    case .loose:
        return LuminaL10n.tr("Relaxed")
    case .standard:
        return LuminaL10n.tr("Standard (Default)")
    case .aggressive:
        return LuminaL10n.tr("Aggressive")
    }
}

private func luminaAdShieldSensitivityShortTitle(_ sensitivity: LuminaAdShield.Sensitivity) -> String {
    switch sensitivity {
    case .loose:
        return LuminaL10n.tr("Relaxed")
    case .standard:
        return LuminaL10n.tr("Standard")
    case .aggressive:
        return LuminaL10n.tr("Aggressive")
    }
}

private func luminaAdShieldSensitivityDescription(_ sensitivity: LuminaAdShield.Sensitivity) -> String {
    switch sensitivity {
    case .loose:
        return LuminaL10n.tr("The same content with a link appears 4+ times within 72 hours, or is re-posted by 3+ people")
    case .standard:
        return LuminaL10n.tr("The same content with a link appears for the 3rd time within 7 days, or is re-posted by 2+ people")
    case .aggressive:
        return LuminaL10n.tr("Content with a link folds from its 2nd appearance; long text without links folds when 3+ people re-post it")
    }
}

private func luminaAdShieldControllerEntries(settings: LuminaSettings, pendingEnable: Bool) -> [LuminaAdShieldEntry] {
    let sensitivity = settings.luminaAdShieldSensitivity
    var entries: [LuminaAdShieldEntry] = []
    entries.append(.enabled(settings.adShieldEnabled || pendingEnable, explainerShown: settings.adShieldExplainerShown))
    entries.append(.sensitivityHeader)
    for value in LuminaAdShield.Sensitivity.allCases {
        entries.append(.sensitivity(value, selected: value == sensitivity))
    }
    entries.append(.sensitivityFooter)
    entries.append(.exemptionsHeader)
    entries.append(.exemptContacts(settings.adShieldExemptContacts))
    entries.append(.exemptBots(settings.adShieldExemptBots))
    entries.append(.exemptReplies(settings.adShieldExemptReplies))
    entries.append(.exemptionsFooter)
    entries.append(.trialRun(settings.adShieldDryRun))
    entries.append(.clearData)
    entries.append(.dataFooter)
    return entries
}

public func luminaAdShieldSettingsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?
    let accountManager = context.sharedContext.accountManager

    // While the first-enable explainer is up, the switch stays on; 取消 turns it back off (the settings never changed,
    // so without this the list would keep showing the switch the user flipped).
    let pendingEnable = ValuePromise<Bool>(false, ignoreRepeated: true)

    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void = { f in
        let _ = updateLuminaSettingsInteractively(accountManager: accountManager, f).startStandalone()
    }

    let arguments = LuminaAdShieldControllerArguments(
        toggleEnabled: { value, explainerShown in
            if value && !explainerShown {
                pendingEnable.set(true)
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerImpl?(textAlertController(context: context, title: LuminaL10n.tr("Hide Repeated Ads"), text: LuminaAdShieldTexts.explainerText(), actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                        pendingEnable.set(false)
                    }),
                    TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Turn On"), action: {
                        let _ = (updateLuminaSettingsInteractively(accountManager: accountManager, { settings in
                            var settings = settings
                            settings.adShieldEnabled = true
                            settings.adShieldExplainerShown = true
                            return settings
                        })
                        |> deliverOnMainQueue).startStandalone(completed: {
                            // By now the stored value is on; drop the override so later changes show as they are.
                            Queue.mainQueue().after(0.5, {
                                pendingEnable.set(false)
                            })
                        })
                    })
                ], dismissOnOutsideTap: false))
            } else {
                pendingEnable.set(false)
                updateSettings { settings in
                    var settings = settings
                    settings.adShieldEnabled = value
                    if value {
                        settings.adShieldExplainerShown = true
                    }
                    return settings
                }
            }
        },
        setSensitivity: { sensitivity in
            updateSettings { settings in
                var settings = settings
                settings.adShieldSensitivity = sensitivity.rawValue
                return settings
            }
        },
        updateSettings: updateSettings,
        clearLocalData: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            presentControllerImpl?(textAlertController(context: context, title: nil, text: LuminaL10n.tr("Clear all Hide Repeated Ads data on this device, including the per-group settings?"), actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: LuminaL10n.tr("Clear"), action: {
                    LuminaAdShieldService.shared.clearAllLocalData()
                    updateSettings { settings in
                        var settings = settings
                        settings.adShieldDialogs = []
                        return settings
                    }
                })
            ]))
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings]),
        pendingEnable.get()
    )
    |> map { presentationData, sharedData, pendingEnable -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Hide Repeated Ads")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaAdShieldControllerEntries(settings: settings, pendingEnable: pendingEnable), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
