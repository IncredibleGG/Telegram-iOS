import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import TranslateUI
import SettingsUI

// LuminaGram: the small menu behind the header translate capsule -- the iOS twin of Android's
// LuminaChatLanguageMenu.java (and desktop's lumina_chat_language_menu.cpp), so all three
// platforms behave alike. Two toggle rows -- what arrives ("Translate Their Messages") and what
// is sent ("Translate My Messages") -- each naming its own on/off state and target language,
// plus a row into the full per-chat translate settings for the send language and this chat's
// tone/register.
//
// It is built as an ActionSheetController rather than a popup anchored to the header capsule:
// anchoring to the translate button would mean reaching its node inside NavigationBarImpl, which
// this change deliberately leaves untouched. The action sheet is the reliable, always-presentable
// menu surface the chat controller already uses throughout ChatControllerNavigationButtonAction.swift.
//
// The rows are built fresh from one settings snapshot on every open, so they never carry stale
// state, and each toggle re-derives its target through the same interactive updaters the settings
// screens use -- nothing here caches a value past the tap.
func luminaPresentChatLanguageMenu(
    context: AccountContext,
    peerId: EnginePeer.Id,
    threadId: Int64?,
    incomingEnabled: Bool,
    incomingToLang: String?,
    presentationData: PresentationData,
    dismissInput: @escaping () -> Void,
    present: @escaping (ViewController) -> Void,
    push: @escaping (ViewController) -> Void
) {
    // The outgoing half lives in LuminaSettings, so read one snapshot before building the sheet;
    // the incoming half is already resolved into the two arguments above.
    let _ = (luminaCurrentSettings(context: context)
    |> take(1)
    |> deliverOnMainQueue).start(next: { settings in
        let actionSheet = ActionSheetController(presentationData: presentationData)

        // Outgoing is off unless BOTH the global capability is on AND this chat is switched on
        // (per-dialog switch, default off) -- mirrors Android's outgoingRowText.
        let outgoingDialogEnabled = settings.trSendEnabledDialog.first(where: { $0.peerId == peerId.toInt64() })?.value ?? false
        let outgoingEnabled = settings.translateBeforeSend && outgoingDialogEnabled

        // The target-language hint at the end of each row is a raw language code, shown the way
        // the per-chat / global translate settings screens present them (both use raw code
        // fields, never localized names). It is shown only while the direction is on, so an
        // unchecked row reads as plainly off (mirrors Android, whose "off" row carries no language).
        let incomingLabel: String
        if incomingEnabled, let incomingToLang, !incomingToLang.isEmpty {
            incomingLabel = incomingToLang
        } else {
            incomingLabel = ""
        }

        let perDialogSendLang = settings.trSendLangDialog.first(where: { $0.peerId == peerId.toInt64() })?.value
        let effectiveSendLang: String
        if let perDialogSendLang, !perDialogSendLang.isEmpty {
            effectiveSendLang = perDialogSendLang
        } else {
            effectiveSendLang = settings.trSendLang
        }
        let outgoingLabel: String
        if outgoingEnabled {
            outgoingLabel = (effectiveSendLang.isEmpty || effectiveSendLang == "auto") ? "auto" : effectiveSendLang
        } else {
            outgoingLabel = ""
        }

        var items: [ActionSheetItem] = []
        items.append(ActionSheetTextItem(title: LuminaL10n.tr("Chat Translation")))

        // Translate Their Messages -- translate THEIR incoming messages into my read language.
        // Toggles chat translation on/off through the same seed-and-enable path the header button
        // used before (luminaSetChatTranslationEnabled), so it still works before the language
        // scanner has cached a state.
        items.append(ActionSheetCheckboxItem(title: LuminaL10n.tr("Translate Their Messages"), label: incomingLabel, value: incomingEnabled, action: { [weak actionSheet] _ in
            actionSheet?.dismissAnimated()
            let _ = luminaSetChatTranslationEnabled(context: context, peerId: peerId, threadId: threadId, enabled: !incomingEnabled).startStandalone()
        }))

        // Translate My Messages -- translate MY outgoing messages into the other side's language
        // before sending. Flips this chat's per-dialog translate-before-send switch; turning it on
        // also flips the global capability on if it was off, so the switch actually takes effect
        // (mirrors Android's showOutgoingPicker).
        items.append(ActionSheetCheckboxItem(title: LuminaL10n.tr("Translate My Messages"), label: outgoingLabel, value: outgoingEnabled, action: { [weak actionSheet] _ in
            actionSheet?.dismissAnimated()
            let newValue = !outgoingEnabled
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var current = current
                var list = current.trSendEnabledDialog
                list.removeAll(where: { $0.peerId == peerId.toInt64() })
                list.append(LuminaSettings.DialogBoolValue(peerId: peerId.toInt64(), value: newValue))
                current.trSendEnabledDialog = list
                if newValue && !current.translateBeforeSend {
                    current.translateBeforeSend = true
                }
                return current
            }).start()
        }))

        // The send language and this chat's tone/register live in the full per-chat screen; the
        // register would be a heavy inline picker, so this row opens that screen instead -- the
        // register-parity MVP.
        items.append(ActionSheetButtonItem(title: LuminaL10n.tr("Chat Translation Settings"), color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            push(luminaChatTranslateSettingsController(context: context, peerId: peerId))
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])

        dismissInput()
        present(actionSheet)
    })
}
