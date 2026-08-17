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

// LuminaGram — the Translation sub-screen of the LuminaGram settings hub (reached from
// LuminaGramSettingsController's "Translation" row, which currently pushes a placeholder —
// see this task's report for the one-line hub wiring needed there).
//
// Purely reactive, no local view-state: every row reads LuminaSettings off
// context.sharedContext.accountManager.sharedData(keys:) and writes through
// updateLuminaSettingsInteractively, exactly like TranslatonSettingsController.swift (this
// fork's own translation settings screen) and LuminaGramSettingsController.swift already do.
// The two API-key fields are the one exception: they live in LuminaKeychain (never
// LuminaSettings — see LuminaKeychain.swift's header), read fresh on every entries rebuild and
// written on every keystroke via LuminaKeychain.set, which needs no promise/state of its own.
public func luminaTranslateSettingsController(context: AccountContext) -> ViewController {
    let arguments = LuminaTranslateSettingsControllerArguments(
        updateSettings: { f in
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, f).start()
        },
        updateDeepLKey: { value in
            LuminaKeychain.set(value, forKey: LuminaKeychainKey.translateProviderAPIKey(providerId: "deepl"))
        },
        updateLLMKey: { value in
            LuminaKeychain.set(value, forKey: LuminaKeychainKey.translateProviderAPIKey(providerId: "llm"))
        },
        testProvider: {
            luminaTestCurrentProvider(context: context)
        }
    )

    let signal = combineLatest(
        queue: Queue.mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Translation"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaTranslateSettingsControllerEntries(settings: settings), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}

private final class LuminaTranslateSettingsControllerArguments {
    let updateSettings: (@escaping (LuminaSettings) -> LuminaSettings) -> Void
    let updateDeepLKey: (String) -> Void
    let updateLLMKey: (String) -> Void
    let testProvider: () -> Void

    init(updateSettings: @escaping (@escaping (LuminaSettings) -> LuminaSettings) -> Void, updateDeepLKey: @escaping (String) -> Void, updateLLMKey: @escaping (String) -> Void, testProvider: @escaping () -> Void) {
        self.updateSettings = updateSettings
        self.updateDeepLKey = updateDeepLKey
        self.updateLLMKey = updateLLMKey
        self.testProvider = testProvider
    }
}

private enum LuminaTranslateSettingsSection: Int32 {
    case mode
    case languages
    case display
    case beforeSend
    case explain
    case provider
    case glossary
}

private enum LuminaTranslateSettingsEntry: ItemListNodeEntry {
    case modeHeader
    case modeManual(Bool)
    case modeAllChats(Bool)
    case scopePrivate(Bool)
    case scopeGroup(Bool)

    case languagesHeader
    case readLang(String)
    case sendLang(String)
    case groupSkipMyLanguages(Bool)
    case myLanguages(String)
    case languagesFooter

    case displayHeader
    case dualLanguageDisplay(Bool)
    case foldOriginalLongMessages(Bool)

    case beforeSendHeader
    case translateBeforeSend(Bool)
    case translateBeforeSendConfirm(Bool)
    case beforeSendFooter

    case explainHeader
    case explainMessage(Bool)

    case providerHeader
    case providerOption(index: Int, id: String, name: String, selected: Bool)
    case providerBaseUrl(String)
    case providerModel(String)
    case providerPrompt(String)
    case providerDeepLKey(String)
    case providerLLMKey(String)
    case providerTest
    case providerFooter

    case glossaryHeader
    case glossaryTerms(String)
    case glossaryFooter

    var section: ItemListSectionId {
        switch self {
        case .modeHeader, .modeManual, .modeAllChats, .scopePrivate, .scopeGroup:
            return LuminaTranslateSettingsSection.mode.rawValue
        case .languagesHeader, .readLang, .sendLang, .groupSkipMyLanguages, .myLanguages, .languagesFooter:
            return LuminaTranslateSettingsSection.languages.rawValue
        case .displayHeader, .dualLanguageDisplay, .foldOriginalLongMessages:
            return LuminaTranslateSettingsSection.display.rawValue
        case .beforeSendHeader, .translateBeforeSend, .translateBeforeSendConfirm, .beforeSendFooter:
            return LuminaTranslateSettingsSection.beforeSend.rawValue
        case .explainHeader, .explainMessage:
            return LuminaTranslateSettingsSection.explain.rawValue
        case .providerHeader, .providerOption, .providerBaseUrl, .providerModel, .providerPrompt, .providerDeepLKey, .providerLLMKey, .providerTest, .providerFooter:
            return LuminaTranslateSettingsSection.provider.rawValue
        case .glossaryHeader, .glossaryTerms, .glossaryFooter:
            return LuminaTranslateSettingsSection.glossary.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .modeHeader: return 0
        case .modeManual: return 1
        case .modeAllChats: return 2
        case .scopePrivate: return 3
        case .scopeGroup: return 4
        case .languagesHeader: return 5
        case .readLang: return 6
        case .sendLang: return 7
        case .groupSkipMyLanguages: return 8
        case .myLanguages: return 9
        case .languagesFooter: return 10
        case .displayHeader: return 11
        case .dualLanguageDisplay: return 12
        case .foldOriginalLongMessages: return 13
        case .beforeSendHeader: return 14
        case .translateBeforeSend: return 15
        case .translateBeforeSendConfirm: return 16
        case .beforeSendFooter: return 17
        case .explainHeader: return 18
        case .explainMessage: return 19
        case .providerHeader: return 20
        case let .providerOption(index, _, _, _): return Int32(100 + index)
        case .providerBaseUrl: return 120
        case .providerModel: return 121
        case .providerPrompt: return 122
        case .providerDeepLKey: return 123
        case .providerLLMKey: return 124
        case .providerTest: return 125
        case .providerFooter: return 126
        case .glossaryHeader: return 127
        case .glossaryTerms: return 128
        case .glossaryFooter: return 129
        }
    }

    static func <(lhs: LuminaTranslateSettingsEntry, rhs: LuminaTranslateSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaTranslateSettingsControllerArguments
        switch self {
        case .modeHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "TRANSLATE MODE", sectionId: self.section)
        case let .modeManual(selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: "Manual (per-chat toggle)", style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trMode = "manual"
                    return settings
                }
            })
        case let .modeAllChats(selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: "All Chats", style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trMode = "allChats"
                    return settings
                }
            })
        case let .scopePrivate(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Private Chats", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trScopePrivate = value
                    return settings
                }
            })
        case let .scopeGroup(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Groups & Channels", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trScopeGroup = value
                    return settings
                }
            })

        case .languagesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LANGUAGES", sectionId: self.section)
        case let .readLang(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "I read"), text: value, placeholder: "Interface language", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trReadLang = value
                    return settings
                }
            }, action: {})
        case let .sendLang(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "I send"), text: value, placeholder: "auto = recipient's language", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.trSendLang = value
                    return settings
                }
            }, action: {})
        case let .groupSkipMyLanguages(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Only Translate What I Can't Read", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.groupSkipMyLanguages = value
                    return settings
                }
            })
        case let .myLanguages(value):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: "en, ja, fr — one per line or comma-separated", maxLength: nil, sectionId: self.section, style: .blocks, capitalization: false, autocorrection: false, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.myLanguages = luminaSplitCommaOrNewlineList(value)
                    return settings
                }
            })
        case .languagesFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Language codes like en, ja, zh, pt-BR. \"I read\" and \"My Languages\" are never auto-translated for you."), sectionId: self.section)

        case .displayHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "INCOMING MESSAGES", sectionId: self.section)
        case let .dualLanguageDisplay(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Show Original + Translation", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.dualLanguageDisplay = value
                    return settings
                }
            })
        case let .foldOriginalLongMessages(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Fold Long Originals", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.foldOriginalLongMessages = value
                    return settings
                }
            })

        case .beforeSendHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "OUTGOING MESSAGES", sectionId: self.section)
        case let .translateBeforeSend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Translate Before Send", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translateBeforeSend = value
                    return settings
                }
            })
        case let .translateBeforeSendConfirm(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Confirm Before Sending", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translateBeforeSendConfirm = value
                    return settings
                }
            })
        case .beforeSendFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Also needs to be turned on per chat: long-press any message in that chat and choose Chat Translation Settings."), sectionId: self.section)

        case .explainHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "EXPLAIN", sectionId: self.section)
        case let .explainMessage(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Explain-a-Message", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.explainMessage = value
                    return settings
                }
            })

        case .providerHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "TRANSLATION PROVIDER", sectionId: self.section)
        case let .providerOption(_, id, name, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: name, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translateEngine = id
                    return settings
                }
            })
        case let .providerBaseUrl(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Base URL"), text: value, placeholder: LuminaLLMDefaults.baseUrl, type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translateBaseUrl = value
                    return settings
                }
            }, action: {})
        case let .providerModel(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Model"), text: value, placeholder: LuminaLLMDefaults.model, type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translateModel = value
                    return settings
                }
            }, action: {})
        case let .providerPrompt(value):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: LuminaLLMDefaults.prompt, maxLength: nil, sectionId: self.section, style: .blocks, capitalization: true, autocorrection: true, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.translatePrompt = value
                    return settings
                }
            })
        case let .providerDeepLKey(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "DeepL Key"), text: value, placeholder: "API key", type: .password, sectionId: self.section, textUpdated: { value in
                arguments.updateDeepLKey(value)
            }, action: {})
        case let .providerLLMKey(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "LLM Key"), text: value, placeholder: "API key", type: .password, sectionId: self.section, textUpdated: { value in
                arguments.updateLLMKey(value)
            }, action: {})
        case .providerTest:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Test Provider", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.testProvider()
            })
        case .providerFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("DeepL and LLM keys are stored in the device Keychain, never synced to Telegram or LuminaGram. Base URL/Model/Prompt apply to the LLM provider only."), sectionId: self.section)

        case .glossaryHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "GLOSSARY", sectionId: self.section)
        case let .glossaryTerms(value):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: value, placeholder: "iPhone, Acme Corp — one term per line or comma-separated", maxLength: nil, sectionId: self.section, style: .blocks, capitalization: true, autocorrection: false, textUpdated: { value in
                arguments.updateSettings { settings in
                    var settings = settings
                    settings.glossaryTerms = luminaSplitCommaOrNewlineList(value)
                    return settings
                }
            })
        case .glossaryFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("These terms are never translated. @usernames and links are always protected automatically."), sectionId: self.section)
        }
    }
}

// Shared by both the "My Languages" and "Glossary" multiline boxes: one item per line or
// comma, trimmed, empties dropped.
private func luminaSplitCommaOrNewlineList(_ text: String) -> [String] {
    return text
        .components(separatedBy: CharacterSet(charactersIn: ",\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private func luminaTranslateSettingsControllerEntries(settings: LuminaSettings) -> [LuminaTranslateSettingsEntry] {
    var entries: [LuminaTranslateSettingsEntry] = []

    entries.append(.modeHeader)
    entries.append(.modeManual(settings.trMode != "allChats"))
    entries.append(.modeAllChats(settings.trMode == "allChats"))
    entries.append(.scopePrivate(settings.trScopePrivate))
    entries.append(.scopeGroup(settings.trScopeGroup))

    entries.append(.languagesHeader)
    entries.append(.readLang(settings.trReadLang))
    entries.append(.sendLang(settings.trSendLang))
    entries.append(.groupSkipMyLanguages(settings.groupSkipMyLanguages))
    entries.append(.myLanguages(settings.myLanguages.joined(separator: ", ")))
    entries.append(.languagesFooter)

    entries.append(.displayHeader)
    entries.append(.dualLanguageDisplay(settings.dualLanguageDisplay))
    entries.append(.foldOriginalLongMessages(settings.foldOriginalLongMessages))

    entries.append(.beforeSendHeader)
    entries.append(.translateBeforeSend(settings.translateBeforeSend))
    entries.append(.translateBeforeSendConfirm(settings.translateBeforeSendConfirm))
    entries.append(.beforeSendFooter)

    entries.append(.explainHeader)
    entries.append(.explainMessage(settings.explainMessage))

    entries.append(.providerHeader)
    for (index, engine) in LuminaTranslatorRegistry.all.enumerated() {
        entries.append(.providerOption(index: index, id: engine.id, name: engine.displayName, selected: settings.translateEngine == engine.id))
    }
    entries.append(.providerBaseUrl(settings.translateBaseUrl))
    entries.append(.providerModel(settings.translateModel))
    entries.append(.providerPrompt(settings.translatePrompt))
    entries.append(.providerDeepLKey(LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: "deepl")) ?? ""))
    entries.append(.providerLLMKey(LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: "llm")) ?? ""))
    entries.append(.providerTest)
    entries.append(.providerFooter)

    entries.append(.glossaryHeader)
    entries.append(.glossaryTerms(settings.glossaryTerms.joined(separator: ", ")))
    entries.append(.glossaryFooter)

    return entries
}

private func luminaTestCurrentProvider(context: AccountContext) {
    let _ = (LuminaTranslatorRegistry.current(context: context)
    |> mapToSignal { engine -> Signal<LuminaTranslationResult?, NoError> in
        return engine.translate(text: "Hello, world!", toLang: "es", peerId: nil, context: context)
        |> map { result -> LuminaTranslationResult? in
            return result
        }
        |> `catch` { _ -> Signal<LuminaTranslationResult?, NoError> in
            return .single(nil)
        }
    }
    |> deliverOnMainQueue).start(next: { result in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let text: String
        if let result {
            text = "\"Hello, world!\" → \"\(result.text)\""
        } else {
            text = "The test translation failed. Check the provider's API key and settings."
        }
        context.sharedContext.presentGlobalController(textAlertController(context: context, title: "Test Provider", text: text, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]), nil)
    })
}
