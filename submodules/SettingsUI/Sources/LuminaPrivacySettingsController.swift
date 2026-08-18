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

// LuminaGram's "Privacy" sub-controller — the destination for the Privacy row in
// LuminaGramSettingsController.swift's hub. The privacy feature bucket did not ship its own
// settings screen (its features are gated purely from LuminaSettings / LuminaKeychain reads at
// render time), so this screen was created during wave-1 integration to expose those knobs,
// mirroring the structure of LuminaSecuritySettingsController.swift in this same module: one
// ItemListController driven by a combineLatest(presentationData, accountManager.sharedData)
// signal, toggles round-tripping through updateLuminaSettingsInteractively
// (submodules/TelegramUIPreferences/Sources/LuminaSettings.swift).
//
// The chat-lock fallback code is the one exception: like the translation provider API keys in
// LuminaTranslateSettingsController.swift, it lives in LuminaKeychain (never LuminaSettings —
// see LuminaKeychain.swift's header), read fresh on every entries rebuild and written on every
// keystroke via LuminaKeychain.set, which needs no promise/state of its own.
private final class LuminaPrivacySettingsControllerArguments {
    let updateHideOwnPhone: (Bool) -> Void
    let updateStripPhotoMetadata: (Bool) -> Void
    let updateShowRegistrationDate: (Bool) -> Void
    let updateChatLockCode: (String) -> Void

    init(
        updateHideOwnPhone: @escaping (Bool) -> Void,
        updateStripPhotoMetadata: @escaping (Bool) -> Void,
        updateShowRegistrationDate: @escaping (Bool) -> Void,
        updateChatLockCode: @escaping (String) -> Void
    ) {
        self.updateHideOwnPhone = updateHideOwnPhone
        self.updateStripPhotoMetadata = updateStripPhotoMetadata
        self.updateShowRegistrationDate = updateShowRegistrationDate
        self.updateChatLockCode = updateChatLockCode
    }
}

private enum LuminaPrivacySettingsSection: Int32 {
    case disguise
    case chatLock
}

private enum LuminaPrivacySettingsEntry: ItemListNodeEntry {
    case disguiseHeader
    case hideOwnPhone(Bool)
    case stripPhotoMetadata(Bool)
    case showRegistrationDate(Bool)
    case disguiseFooter
    case chatLockHeader
    case chatLockCode(String)
    case chatLockFooter

    var section: ItemListSectionId {
        switch self {
        case .disguiseHeader, .hideOwnPhone, .stripPhotoMetadata, .showRegistrationDate, .disguiseFooter:
            return LuminaPrivacySettingsSection.disguise.rawValue
        case .chatLockHeader, .chatLockCode, .chatLockFooter:
            return LuminaPrivacySettingsSection.chatLock.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .disguiseHeader: return 0
        case .hideOwnPhone: return 1
        case .stripPhotoMetadata: return 2
        case .showRegistrationDate: return 3
        case .disguiseFooter: return 4
        case .chatLockHeader: return 5
        case .chatLockCode: return 6
        case .chatLockFooter: return 7
        }
    }

    static func <(lhs: LuminaPrivacySettingsEntry, rhs: LuminaPrivacySettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaPrivacySettingsControllerArguments
        switch self {
        case .disguiseHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("PRIVACY & DISGUISE"), sectionId: self.section)
        case let .hideOwnPhone(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Hide My Phone Number"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateHideOwnPhone(value)
            })
        case let .stripPhotoMetadata(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Strip Photo Metadata"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateStripPhotoMetadata(value)
            })
        case let .showRegistrationDate(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Show Registration Date"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateShowRegistrationDate(value)
            })
        case .disguiseFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("These are local display and on-send options. Hiding your phone number and estimating a contact's registration date happen only on this device; photo metadata is stripped before a photo leaves your device.")), sectionId: self.section)
        case .chatLockHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("CHAT LOCK"), sectionId: self.section)
        case let .chatLockCode(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: LuminaL10n.tr("Secret Code")), text: value, placeholder: LuminaL10n.tr("Fallback code"), type: .password, sectionId: self.section, textUpdated: { value in
                arguments.updateChatLockCode(value)
            }, action: {})
        case .chatLockFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Locked chats are unlocked with Face ID / passcode. This optional code is a fallback only. It is stored in this device's Keychain, never in Telegram and never synced. Leave empty to remove it.")), sectionId: self.section)
        }
    }
}

private func luminaPrivacySettingsControllerEntries(settings: LuminaSettings) -> [LuminaPrivacySettingsEntry] {
    return [
        .disguiseHeader,
        .hideOwnPhone(settings.hideOwnPhone),
        .stripPhotoMetadata(settings.stripPhotoMetadata),
        .showRegistrationDate(settings.showRegistrationDate),
        .disguiseFooter,
        .chatLockHeader,
        .chatLockCode(LuminaKeychain.get(LuminaKeychainKey.chatLockCode) ?? ""),
        .chatLockFooter,
    ]
}

public func luminaPrivacySettingsController(context: AccountContext) -> ViewController {
    let arguments = LuminaPrivacySettingsControllerArguments(
        updateHideOwnPhone: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.hideOwnPhone = value
                return settings
            }).start()
        },
        updateStripPhotoMetadata: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.stripPhotoMetadata = value
                return settings
            }).start()
        },
        updateShowRegistrationDate: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.showRegistrationDate = value
                return settings
            }).start()
        },
        updateChatLockCode: { value in
            LuminaKeychain.set(value, forKey: LuminaKeychainKey.chatLockCode)
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
    )
    |> deliverOnMainQueue
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Privacy")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaPrivacySettingsControllerEntries(settings: settings), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}
