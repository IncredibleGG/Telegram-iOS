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
import TranslateUI

// LuminaGram — per-chat translate settings (translate-before-send enable + target language,
// and this chat's tone/register). Reached from the message context menu's "Chat Translation
// Settings" row (ChatInterfaceStateContextMenus.swift's `// LuminaGram: per-chat translate
// settings` insertion) since there is no existing per-chat "…" menu hook this task's file-
// ownership rules leave safe to extend (see this task's report).
//
// Same purely-reactive shape as LuminaTranslateSettingsController.swift: reads LuminaSettings
// off accountManager.sharedData, writes through updateLuminaSettingsInteractively (directly
// for the two per-dialog arrays here, and via LuminaRegister.set/get for the register — see
// LuminaRegister.swift). The custom-register text is the one local bit of view state (typed
// before it is committed as "custom:<text>" via LuminaRegisterCode.custom).
public func luminaChatTranslateSettingsController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let customTextValue = Atomic<String?>(value: nil)

    let arguments = LuminaChatTranslateSettingsControllerArguments(
        setBeforeSendEnabled: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                var list = settings.trSendEnabledDialog
                list.removeAll(where: { $0.peerId == peerId.toInt64() })
                list.append(LuminaSettings.DialogBoolValue(peerId: peerId.toInt64(), value: value))
                settings.trSendEnabledDialog = list
                return settings
            }).start()
        },
        setSendLang: { value in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                var list = settings.trSendLangDialog
                list.removeAll(where: { $0.peerId == peerId.toInt64() })
                if !value.isEmpty {
                    list.append(LuminaSettings.DialogTextValue(peerId: peerId.toInt64(), value: value))
                }
                settings.trSendLangDialog = list
                return settings
            }).start()
        },
        setRegister: { code in
            let _ = LuminaRegister.set(accountManager: context.sharedContext.accountManager, peerId: peerId, value: code).start()
        },
        updateCustomText: { text in
            let _ = customTextValue.swap(text)
        },
        commitCustomText: {
            let text = customTextValue.with { $0 } ?? ""
            let _ = LuminaRegister.set(accountManager: context.sharedContext.accountManager, peerId: peerId, value: LuminaRegisterCode.custom(text)).start()
        }
    )

    let signal = combineLatest(
        queue: Queue.mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Chat Translation Settings")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaChatTranslateSettingsControllerEntries(settings: settings, peerId: peerId, customTextValue: customTextValue.with { $0 }), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}

private final class LuminaChatTranslateSettingsControllerArguments {
    let setBeforeSendEnabled: (Bool) -> Void
    let setSendLang: (String) -> Void
    let setRegister: (String) -> Void
    let updateCustomText: (String) -> Void
    let commitCustomText: () -> Void

    init(setBeforeSendEnabled: @escaping (Bool) -> Void, setSendLang: @escaping (String) -> Void, setRegister: @escaping (String) -> Void, updateCustomText: @escaping (String) -> Void, commitCustomText: @escaping () -> Void) {
        self.setBeforeSendEnabled = setBeforeSendEnabled
        self.setSendLang = setSendLang
        self.setRegister = setRegister
        self.updateCustomText = updateCustomText
        self.commitCustomText = commitCustomText
    }
}

private enum LuminaChatTranslateSettingsSection: Int32 {
    case beforeSend
    case register
}

private enum LuminaChatTranslateSettingsEntry: ItemListNodeEntry {
    case beforeSendHeader
    case beforeSendEnabled(Bool)
    case sendLang(String)
    case beforeSendFooter

    case registerHeader
    case registerOption(index: Int, code: String, name: String, selected: Bool)
    case registerCustomText(String)
    case registerFooter

    var section: ItemListSectionId {
        switch self {
        case .beforeSendHeader, .beforeSendEnabled, .sendLang, .beforeSendFooter:
            return LuminaChatTranslateSettingsSection.beforeSend.rawValue
        case .registerHeader, .registerOption, .registerCustomText, .registerFooter:
            return LuminaChatTranslateSettingsSection.register.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .beforeSendHeader: return 0
        case .beforeSendEnabled: return 1
        case .sendLang: return 2
        case .beforeSendFooter: return 3
        case .registerHeader: return 4
        case let .registerOption(index, _, _, _): return Int32(10 + index)
        case .registerCustomText: return 30
        case .registerFooter: return 31
        }
    }

    static func <(lhs: LuminaChatTranslateSettingsEntry, rhs: LuminaChatTranslateSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaChatTranslateSettingsControllerArguments
        switch self {
        case .beforeSendHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("TRANSLATE BEFORE SEND"), sectionId: self.section)
        case let .beforeSendEnabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: LuminaL10n.tr("Enabled for This Chat"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setBeforeSendEnabled(value)
            })
        case let .sendLang(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: LuminaL10n.tr("Target")), text: value, placeholder: LuminaL10n.tr("auto = recipient's language"), type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.setSendLang(value)
            }, action: {})
        case .beforeSendFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Also needs the global switch on: Settings → LuminaGram → Translation → Translate Before Send.")), sectionId: self.section)

        case .registerHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("TONE FOR THIS CHAT"), sectionId: self.section)
        case let .registerOption(_, code, name, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: name, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                if LuminaRegisterCode.isCustom(code) {
                    arguments.commitCustomText()
                } else {
                    arguments.setRegister(code)
                }
            })
        case let .registerCustomText(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: LuminaL10n.tr("e.g. \"my landlord\""), type: .regular(capitalization: true, autocorrection: true), sectionId: self.section, textUpdated: { value in
                arguments.updateCustomText(value)
            }, action: {
                arguments.commitCustomText()
            })
        case .registerFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Only the LLM provider can carry tone. DeepL collapses it onto formal/informal where supported; Google and Telegram ignore it.")), sectionId: self.section)
        }
    }
}

private func luminaChatTranslateSettingsControllerEntries(settings: LuminaSettings, peerId: EnginePeer.Id, customTextValue: String?) -> [LuminaChatTranslateSettingsEntry] {
    var entries: [LuminaChatTranslateSettingsEntry] = []

    let enabled = settings.trSendEnabledDialog.first(where: { $0.peerId == peerId.toInt64() })?.value ?? false
    let sendLang = settings.trSendLangDialog.first(where: { $0.peerId == peerId.toInt64() })?.value ?? ""
    entries.append(.beforeSendHeader)
    entries.append(.beforeSendEnabled(enabled))
    entries.append(.sendLang(sendLang))
    entries.append(.beforeSendFooter)

    let stored = LuminaRegister.get(settings: settings, peerId: peerId)
    entries.append(.registerHeader)
    entries.append(.registerOption(index: 0, code: LuminaRegisterCode.none, name: LuminaL10n.tr("None"), selected: stored == LuminaRegisterCode.none))
    for (index, code) in LuminaRegisterCode.presets.enumerated() {
        entries.append(.registerOption(index: index + 1, code: code, name: LuminaRegisterCode.displayName(code), selected: stored == code))
    }
    let isCustom = LuminaRegisterCode.isCustom(stored)
    entries.append(.registerOption(index: LuminaRegisterCode.presets.count + 1, code: LuminaRegisterCode.customPrefix, name: LuminaL10n.tr("Custom"), selected: isCustom))
    if isCustom {
        entries.append(.registerCustomText(customTextValue ?? LuminaRegisterCode.customText(stored)))
    }
    entries.append(.registerFooter)

    return entries
}
