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

// LuminaGram's "Security" sub-controller — the destination for the Security row in
// LuminaGramSettingsController.swift's hub (submodules/SettingsUI/Sources/LuminaGramSettingsController.swift).
// NOT wired into the hub by this commit — see the final report for the one-line change needed
// there (swap the Security row's `luminaGramPlaceholderController` push for
// `luminaSecuritySettingsController(context:)`); this file deliberately does not touch that
// shared hub file itself, per the file-ownership split for this feature bucket.
//
// Structured exactly like ArchiveSettingsController.swift in this same module: one
// ItemListController driven by a `combineLatest(presentationData, accountManager.sharedData)`
// signal, toggles round-tripping through `updateLuminaSettingsInteractively`
// (submodules/TelegramUIPreferences/Sources/LuminaSettings.swift). Every toggle here already
// has a `LuminaSettings` field from the foundation commit — no new fields needed for this file.
private final class LuminaSecuritySettingsControllerArguments {
    let updateOtpGuard: (Bool) -> Void
    let updateSessionGuard: (Bool) -> Void
    let updateCryptoGuard: (Bool) -> Void
    let updateLinkSafety: (Bool) -> Void
    let updateScamKeyword: (Bool) -> Void
    let updateHomoglyph: (Bool) -> Void
    let updateFileGuard: (Bool) -> Void
    let openCheckup: () -> Void

    init(
        updateOtpGuard: @escaping (Bool) -> Void,
        updateSessionGuard: @escaping (Bool) -> Void,
        updateCryptoGuard: @escaping (Bool) -> Void,
        updateLinkSafety: @escaping (Bool) -> Void,
        updateScamKeyword: @escaping (Bool) -> Void,
        updateHomoglyph: @escaping (Bool) -> Void,
        updateFileGuard: @escaping (Bool) -> Void,
        openCheckup: @escaping () -> Void
    ) {
        self.updateOtpGuard = updateOtpGuard
        self.updateSessionGuard = updateSessionGuard
        self.updateCryptoGuard = updateCryptoGuard
        self.updateLinkSafety = updateLinkSafety
        self.updateScamKeyword = updateScamKeyword
        self.updateHomoglyph = updateHomoglyph
        self.updateFileGuard = updateFileGuard
        self.openCheckup = openCheckup
    }
}

private enum LuminaSecuritySettingsSection: Int32 {
    case guards
    case checkup
}

private enum LuminaSecuritySettingsEntry: ItemListNodeEntry {
    case guardsHeader
    case otpGuard(Bool)
    case sessionGuard(Bool)
    case cryptoGuard(Bool)
    case linkSafety(Bool)
    case scamKeyword(Bool)
    case homoglyph(Bool)
    case fileGuard(Bool)
    case guardsFooter
    case checkup
    case checkupFooter

    var section: ItemListSectionId {
        switch self {
        case .guardsHeader, .otpGuard, .sessionGuard, .cryptoGuard, .linkSafety, .scamKeyword, .homoglyph, .fileGuard, .guardsFooter:
            return LuminaSecuritySettingsSection.guards.rawValue
        case .checkup, .checkupFooter:
            return LuminaSecuritySettingsSection.checkup.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .guardsHeader: return 0
        case .otpGuard: return 1
        case .sessionGuard: return 2
        case .cryptoGuard: return 3
        case .linkSafety: return 4
        case .scamKeyword: return 5
        case .homoglyph: return 6
        case .fileGuard: return 7
        case .guardsFooter: return 8
        case .checkup: return 9
        case .checkupFooter: return 10
        }
    }

    static func <(lhs: LuminaSecuritySettingsEntry, rhs: LuminaSecuritySettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaSecuritySettingsControllerArguments
        switch self {
        case .guardsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("ANTI-SCAM GUARDS"), sectionId: self.section)
        case let .otpGuard(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Login Code Guard"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateOtpGuard(value)
            })
        case let .sessionGuard(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("New Login Alerts"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSessionGuard(value)
            })
        case let .cryptoGuard(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Wallet Address Paste Guard"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateCryptoGuard(value)
            })
        case let .linkSafety(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Link Safety Check"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateLinkSafety(value)
            })
        case let .scamKeyword(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Scam Keyword Warning"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateScamKeyword(value)
            })
        case let .homoglyph(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Look-Alike Name Warning"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateHomoglyph(value)
            })
        case let .fileGuard(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Disguised File Guard"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFileGuard(value)
            })
        case .guardsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Every guard runs on this device only. Nothing you type, paste or receive is uploaded anywhere to power these checks.")), sectionId: self.section)
        case .checkup:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.security, title: LuminaL10n.tr("Security Checkup"), label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openCheckup()
            })
        case .checkupFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Read-only status of Two-Step Verification, recovery e-mail, privacy and active sessions, using Telegram's own settings screens.")), sectionId: self.section)
        }
    }
}

private func luminaSecuritySettingsControllerEntries(settings: LuminaSettings) -> [LuminaSecuritySettingsEntry] {
    return [
        .guardsHeader,
        .otpGuard(settings.otpGuardEnabled),
        .sessionGuard(settings.sessionGuardEnabled),
        .cryptoGuard(settings.cryptoClipboardGuard),
        .linkSafety(settings.linkSafetyCheck),
        .scamKeyword(settings.scamKeywordWarning),
        .homoglyph(settings.homoglyphWarn),
        .fileGuard(settings.fileGuardEnabled),
        .guardsFooter,
        .checkup,
        .checkupFooter,
    ]
}

public func luminaSecuritySettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaSecuritySettingsControllerArguments(
        updateOtpGuard: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.otpGuardEnabled = value
                return settings
            }).start()
        },
        updateSessionGuard: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.sessionGuardEnabled = value
                return settings
            }).start()
        },
        updateCryptoGuard: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.cryptoClipboardGuard = value
                return settings
            }).start()
        },
        updateLinkSafety: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.linkSafetyCheck = value
                return settings
            }).start()
        },
        updateScamKeyword: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.scamKeywordWarning = value
                return settings
            }).start()
        },
        updateHomoglyph: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.homoglyphWarn = value
                return settings
            }).start()
        },
        updateFileGuard: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.fileGuardEnabled = value
                return settings
            }).start()
        },
        openCheckup: {
            pushControllerImpl?(luminaSecurityCheckupController(context: context))
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
    )
    |> deliverOnMainQueue
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Security")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaSecuritySettingsControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
