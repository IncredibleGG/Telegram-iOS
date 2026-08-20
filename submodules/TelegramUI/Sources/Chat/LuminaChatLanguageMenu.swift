import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import TranslateUI
import ContextUI
import PromptUI
import AppBundle
import TranslationLanguagesContextMenuContent

// LuminaGram: the small menu behind the header translate capsule -- the iOS twin of Android's
// LuminaChatLanguageMenu.java (and desktop lumina_chat_language_menu.cpp), so all three
// platforms behave alike. It is a context menu anchored NEAR the translate capsule (not a
// bottom sheet), with three rows, each opening its own picker:
//   1. Incoming -- "Them, translated to <lang>" / "Them, don't translate". Opens a language
//      picker (the same TranslationLanguagesContextMenuContent the stock translate bar uses),
//      with a "Don't translate" entry on top that disables incoming chat-translation.
//   2. Outgoing -- "Me, translated to <lang>" / "Me, don't translate". Opens the same picker
//      for translate-before-send in THIS chat; "Don't translate" disables it.
//   3. Register -- "This chat's tone: <register or not set>". Opens the register options
//      (None + presets + Custom, where Custom opens a text prompt).
//
// The presentation copies the stock translate panel's near-button context menu
// (ChatTranslationPanelNode.morePressed): makeContextController with a .reference source
// anchored to the capsule, then presentInGlobalOverlay; each row pushes a sub-menu via
// pushItems, exactly like the stock "Choose Language" flow. The anchor view is the translate
// capsule's glass background, reached through NavigationBar.luminaTranslateButtonContextSourceView.
//
// The rows are built fresh from one settings snapshot on every open, so they never carry stale
// state; each picker re-derives its target through the same interactive updaters the settings
// screens use -- nothing here caches a value past the tap.
func luminaPresentChatLanguageMenu(
    context: AccountContext,
    peerId: EnginePeer.Id,
    threadId: Int64?,
    incomingEnabled: Bool,
    incomingToLang: String?,
    presentationData: PresentationData,
    sourceView: UIView?,
    controller: ViewController,
    presentInGlobalOverlay: @escaping (ViewController) -> Void,
    present: @escaping (ViewController) -> Void
) {
    // No anchor means the translate button is not on screen; there is nothing to hang the menu
    // off, so do nothing rather than present a floating menu with no source.
    guard let sourceView else {
        return
    }
    // The outgoing half and the register live in LuminaSettings, so read one snapshot before
    // building the menu; the incoming half is already resolved into the two arguments above.
    let _ = (luminaCurrentSettings(context: context)
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { settings in
        let peerIdValue = peerId.toInt64()
        let accountManager = context.sharedContext.accountManager

        // Interface language, used to show localized language names in the rows and picker.
        var baseLanguageCode = presentationData.strings.baseLanguageCode
        let rawSuffix = "-raw"
        if baseLanguageCode.hasSuffix(rawSuffix) {
            baseLanguageCode = String(baseLanguageCode.dropLast(rawSuffix.count))
        }
        let nameLocale = Locale(identifier: baseLanguageCode)
        func languageDisplayName(_ code: String) -> String {
            if code.isEmpty {
                return code
            }
            return nameLocale.localizedString(forLanguageCode: code) ?? code
        }

        let noIcon: (PresentationTheme) -> UIImage? = { _ in return nil }
        let checkIcon: (PresentationTheme) -> UIImage? = { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
        }

        // ---- incoming (their messages) -------------------------------------------------
        // The picker highlights the current target; "off" is its own sentinel so the "Don't
        // translate" row carries the checkmark when this direction is off (mirrors Android).
        let incomingSelectedCode: String
        if incomingEnabled {
            if let toLang = incomingToLang, !toLang.isEmpty {
                incomingSelectedCode = toLang
            } else {
                // Enabled with no explicit target yet: name the interface language, which is
                // what the chat resolves to (mirrors Android getDialogTranslateTo).
                incomingSelectedCode = normalizeTranslationLanguage(baseLanguageCode)
            }
        } else {
            incomingSelectedCode = "off"
        }
        let incomingRowText: String
        if incomingEnabled {
            incomingRowText = String(format: LuminaL10n.tr("Them, translated to %@"), languageDisplayName(incomingSelectedCode))
        } else {
            incomingRowText = LuminaL10n.tr("Them, don't translate")
        }

        // ---- outgoing (my messages) ----------------------------------------------------
        // Off unless BOTH the global capability is on AND this chat is switched on (per-dialog
        // switch, default off) -- mirrors Android outgoingRowText.
        let outgoingDialogEnabled = settings.trSendEnabledDialog.first(where: { $0.peerId == peerIdValue })?.value ?? false
        let outgoingEnabled = settings.translateBeforeSend && outgoingDialogEnabled
        // The send path prefers a fixed global send language over this chat's locked one
        // (ChatActivityEnterView luminaResolveSendLang on Android); resolve it the same way.
        let perDialogSendLang = settings.trSendLangDialog.first(where: { $0.peerId == peerIdValue })?.value
        let effectiveSendLang: String
        if !settings.trSendLang.isEmpty && settings.trSendLang != "auto" {
            effectiveSendLang = settings.trSendLang
        } else if let perDialogSendLang, !perDialogSendLang.isEmpty {
            effectiveSendLang = perDialogSendLang
        } else {
            effectiveSendLang = ""
        }
        let outgoingIsAuto = effectiveSendLang.isEmpty || effectiveSendLang == "auto"
        let outgoingSelectedCode: String
        if outgoingEnabled {
            outgoingSelectedCode = outgoingIsAuto ? "" : effectiveSendLang
        } else {
            outgoingSelectedCode = "off"
        }
        let outgoingRowText: String
        if outgoingEnabled {
            let name = outgoingIsAuto ? LuminaL10n.tr("Auto (recipient's language)") : languageDisplayName(effectiveSendLang)
            outgoingRowText = String(format: LuminaL10n.tr("Me, translated to %@"), name)
        } else {
            outgoingRowText = LuminaL10n.tr("Me, don't translate")
        }

        // ---- register (tone for this chat) --------------------------------------------
        let storedRegister = LuminaRegister.get(settings: settings, peerId: peerId)
        let registerRowText: String
        if storedRegister.isEmpty {
            registerRowText = LuminaL10n.tr("This chat's tone: not set")
        } else {
            registerRowText = String(format: LuminaL10n.tr("This chat's tone: %@"), LuminaRegisterCode.displayName(storedRegister))
        }

        // The shared language list: "Don't translate" on top (its own sentinel code, so it
        // renders as a normal selectable row rather than the empty-code separator the picker
        // draws), then every supported translation language shown with its localized name. The
        // same list feeds both directions, so there is only one set of languages to keep in step.
        func languagePickerList() -> [(String, String)] {
            var list: [(String, String)] = []
            list.append(("off", LuminaL10n.tr("Don't translate")))
            for code in supportedTranslationLanguages {
                list.append((code, nameLocale.localizedString(forLanguageCode: code) ?? code))
            }
            return list
        }

        // ---- apply, per direction ------------------------------------------------------
        func applyIncoming(_ code: String) {
            if code == "off" {
                // Disabling incoming chat-translation (mirrors Android showIncomingPicker off).
                let _ = luminaSetChatTranslationEnabled(context: context, peerId: peerId, threadId: threadId, enabled: false).startStandalone()
            } else {
                // Seed-and-enable first (luminaSetChatTranslationEnabled resolves and caches a
                // ChatTranslationState even before the language scanner has run), then write the
                // target language onto the now-cached state -- the interactive updater no-ops
                // when nothing is cached yet.
                let signal = luminaSetChatTranslationEnabled(context: context, peerId: peerId, threadId: threadId, enabled: true)
                |> then(updateChatTranslationStateInteractively(engine: context.engine, peerId: peerId, threadId: threadId, { state in
                    return state?.withToLang(code).withIsEnabled(true)
                }))
                let _ = signal.startStandalone()
            }
        }

        func applyOutgoing(_ code: String) {
            let _ = updateLuminaSettingsInteractively(accountManager: accountManager, { current in
                var current = current
                if code == "off" {
                    // Turn translate-before-send off for THIS chat only (per-dialog switch); the
                    // global capability and every other chat are left untouched.
                    var enabledList = current.trSendEnabledDialog
                    enabledList.removeAll(where: { $0.peerId == peerIdValue })
                    enabledList.append(LuminaSettings.DialogBoolValue(peerId: peerIdValue, value: false))
                    current.trSendEnabledDialog = enabledList
                } else {
                    var langList = current.trSendLangDialog
                    langList.removeAll(where: { $0.peerId == peerIdValue })
                    langList.append(LuminaSettings.DialogTextValue(peerId: peerIdValue, value: code))
                    current.trSendLangDialog = langList

                    // Choosing a language turns this chat on (per-dialog switch, default off).
                    var enabledList = current.trSendEnabledDialog
                    enabledList.removeAll(where: { $0.peerId == peerIdValue })
                    enabledList.append(LuminaSettings.DialogBoolValue(peerId: peerIdValue, value: true))
                    current.trSendEnabledDialog = enabledList

                    // The send path prefers a fixed global send language over this chat's locked
                    // one, so when a fixed global governs this chat, the global is the knob this
                    // row edits -- otherwise the language just chosen would be overridden on the
                    // next send (mirrors Android showOutgoingPicker).
                    if !current.trSendLang.isEmpty && current.trSendLang != "auto" {
                        current.trSendLang = code
                    }
                    // Flip the global capability on if it was off, so the chosen language takes
                    // effect (the capability gates every per-dialog switch).
                    if !current.translateBeforeSend {
                        current.translateBeforeSend = true
                    }
                }
                return current
            }).start()
        }

        func applyRegister(_ code: String) {
            let _ = LuminaRegister.set(accountManager: accountManager, peerId: peerId, value: code).start()
        }

        func presentCustomRegister() {
            let currentCustom = LuminaRegisterCode.isCustom(storedRegister) ? LuminaRegisterCode.customText(storedRegister) : ""
            let promptScreen = promptController(
                context: context,
                text: LuminaL10n.tr("Describe this relationship"),
                value: currentCustom,
                placeholder: LuminaL10n.tr("e.g. my thesis advisor, respectful but not stiff"),
                apply: { text in
                    // An empty description is not a register: LuminaRegisterCode.custom clears it
                    // back to unset rather than storing a custom that says nothing.
                    guard let text else {
                        return
                    }
                    let _ = LuminaRegister.set(accountManager: accountManager, peerId: peerId, value: LuminaRegisterCode.custom(text)).start()
                }
            )
            present(promptScreen)
        }

        // ---- rows ----------------------------------------------------------------------
        var items: [ContextMenuItem] = []

        // Incoming: their messages, translated into my read language.
        items.append(.action(ContextMenuActionItem(text: incomingRowText, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Download"), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            c?.pushItems(items: .single(ContextController.Items(content: .custom(TranslationLanguagesContextMenuContent(
                context: context,
                languages: languagePickerList(),
                selectedLanguages: Set([incomingSelectedCode]),
                back: { [weak c] in
                    c?.popItems()
                },
                selectLanguage: { [weak c] code in
                    c?.dismiss(completion: {
                        applyIncoming(code)
                    })
                }
            )))))
        })))

        // Outgoing: my messages, translated into the other side's language before sending.
        items.append(.action(ContextMenuActionItem(text: outgoingRowText, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            c?.pushItems(items: .single(ContextController.Items(content: .custom(TranslationLanguagesContextMenuContent(
                context: context,
                languages: languagePickerList(),
                selectedLanguages: Set([outgoingSelectedCode]),
                back: { [weak c] in
                    c?.popItems()
                },
                selectLanguage: { [weak c] code in
                    c?.dismiss(completion: {
                        applyOutgoing(code)
                    })
                }
            )))))
        })))

        // Register: who this person is to you, and therefore how a translation should sound.
        items.append(.action(ContextMenuActionItem(text: registerRowText, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Customize"), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            var registerItems: [ContextMenuItem] = []
            registerItems.append(.action(ContextMenuActionItem(text: presentationData.strings.Common_Back, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
            }, iconPosition: .left, action: { c, _ in
                c?.popItems()
            })))
            registerItems.append(.separator)
            registerItems.append(.action(ContextMenuActionItem(text: LuminaL10n.tr("None"), icon: storedRegister.isEmpty ? checkIcon : noIcon, action: { c, _ in
                c?.dismiss(completion: {
                    applyRegister(LuminaRegisterCode.none)
                })
            })))
            for code in LuminaRegisterCode.presets {
                let selected = storedRegister == code
                registerItems.append(.action(ContextMenuActionItem(text: LuminaRegisterCode.displayName(code), icon: selected ? checkIcon : noIcon, action: { c, _ in
                    c?.dismiss(completion: {
                        applyRegister(code)
                    })
                })))
            }
            registerItems.append(.action(ContextMenuActionItem(text: LuminaL10n.tr("Custom"), icon: LuminaRegisterCode.isCustom(storedRegister) ? checkIcon : noIcon, action: { c, _ in
                c?.dismiss(completion: {
                    presentCustomRegister()
                })
            })))
            c?.pushItems(items: .single(ContextController.Items(content: .list(registerItems))))
        })))

        // Anchor the menu to the translate capsule, the same reference-source presentation the
        // more button and the stock translate bar use for their near-button context menus.
        let source: ContextContentSource = .reference(ChatControllerContextReferenceContentSource(controller: controller, sourceView: sourceView, insets: .zero))
        let contextController = makeContextController(presentationData: presentationData, source: source, items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        presentInGlobalOverlay(contextController)
    })
}
