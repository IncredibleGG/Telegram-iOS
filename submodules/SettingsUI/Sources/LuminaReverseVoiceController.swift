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
import UndoUI

// LuminaGram: the composer for "reverse voice" (see LuminaReverseVoice.swift for the actual
// TTS -> Opus -> send pipeline). Reachable from the Voice & Media settings screen while the
// feature is experimental; not yet wired into the main chat composer / attachment menu - see the
// port report for why (ChatTextInputPanelNode.swift and the AttachmentButtonType enum are both
// large, heavily shared files with several exhaustive switches across other modules, too risky to
// extend correctly without being able to build).
//
// State-management pattern (ValuePromise + Atomic + updateState) mirrors
// TelegramUI/Sources/CreateChannelController.swift, the established shape for a small
// ItemListController with local editable text-field state in this codebase.
private struct LuminaReverseVoiceState: Equatable {
    var text: String
    var languageCode: String
    var isSending: Bool
}

private final class LuminaReverseVoiceControllerArguments {
    let updateText: (String) -> Void
    let updateLanguageCode: (String) -> Void
    let send: () -> Void

    init(updateText: @escaping (String) -> Void, updateLanguageCode: @escaping (String) -> Void, send: @escaping () -> Void) {
        self.updateText = updateText
        self.updateLanguageCode = updateLanguageCode
        self.send = send
    }
}

private enum LuminaReverseVoiceSection: Int32 {
    case text
    case language
    case send
}

private enum LuminaReverseVoiceEntry: ItemListNodeEntry {
    case textHeader
    case text(String)
    case textFooter
    case languageHeader
    case language(String)
    case languageFooter
    case send(Bool)

    var section: ItemListSectionId {
        switch self {
        case .textHeader, .text, .textFooter:
            return LuminaReverseVoiceSection.text.rawValue
        case .languageHeader, .language, .languageFooter:
            return LuminaReverseVoiceSection.language.rawValue
        case .send:
            return LuminaReverseVoiceSection.send.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .textHeader: return 0
        case .text: return 1
        case .textFooter: return 2
        case .languageHeader: return 3
        case .language: return 4
        case .languageFooter: return 5
        case .send: return 6
        }
    }

    static func <(lhs: LuminaReverseVoiceEntry, rhs: LuminaReverseVoiceEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaReverseVoiceControllerArguments
        switch self {
        case .textHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "MESSAGE", sectionId: self.section)
        case let .text(value):
            return ItemListMultilineInputItem(presentationData: presentationData, text: value, placeholder: "Type the message to speak…", maxLength: nil, sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateText(text)
            })
        case .textFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Spoken on-device with AVSpeechSynthesizer and sent as a real voice message. No cloud TTS, no voice cloning."), sectionId: self.section)
        case .languageHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "VOICE LANGUAGE", sectionId: self.section)
        case let .language(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: "e.g. en-US, zh-CN (leave empty to auto-detect)", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateLanguageCode(text)
            }, action: {})
        case .languageFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("BCP-47 language/voice code understood by AVSpeechSynthesisVoice."), sectionId: self.section)
        case let .send(enabled):
            return ItemListActionItem(presentationData: presentationData, title: "Send as Voice Message", kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.send()
            })
        }
    }
}

private func luminaReverseVoiceControllerEntries(state: LuminaReverseVoiceState) -> [LuminaReverseVoiceEntry] {
    var entries: [LuminaReverseVoiceEntry] = []
    entries.append(.textHeader)
    entries.append(.text(state.text))
    entries.append(.textFooter)
    entries.append(.languageHeader)
    entries.append(.language(state.languageCode))
    entries.append(.languageFooter)
    entries.append(.send(!state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isSending))
    return entries
}

public func luminaReverseVoiceController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let initialState = LuminaReverseVoiceState(text: "", languageCode: "", isSending: false)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((LuminaReverseVoiceState) -> LuminaReverseVoiceState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var dismissImpl: (() -> Void)?
    var presentUndoImpl: ((UndoOverlayContent) -> Void)?

    let arguments = LuminaReverseVoiceControllerArguments(updateText: { text in
        updateState { current in
            var updated = current
            updated.text = text
            return updated
        }
    }, updateLanguageCode: { code in
        updateState { current in
            var updated = current
            updated.languageCode = code
            return updated
        }
    }, send: {
        let current = stateValue.with { $0 }
        let trimmedText = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !current.isSending else {
            return
        }
        updateState { state in
            var updated = state
            updated.isSending = true
            return updated
        }
        let languageCode = current.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        LuminaReverseVoice.speakAndSend(context: context, peerId: peerId, spokenText: trimmedText, languageCode: languageCode.isEmpty ? nil : languageCode, completion: { result in
            updateState { state in
                var updated = state
                updated.isSending = false
                return updated
            }
            switch result {
            case .success:
                updateState { _ in LuminaReverseVoiceState(text: "", languageCode: languageCode, isSending: false) }
                presentUndoImpl?(.info(title: nil, text: "Voice message sent.", timeout: nil, customUndoText: nil))
                dismissImpl?()
            case .failure:
                presentUndoImpl?(.info(title: nil, text: "Couldn't create the voice message.", timeout: nil, customUndoText: nil))
            }
        })
    })

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Reverse Voice"), leftNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        }), rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaReverseVoiceControllerEntries(state: state), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    presentUndoImpl = { [weak controller] content in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in return false }), in: .current)
    }
    return controller
}
