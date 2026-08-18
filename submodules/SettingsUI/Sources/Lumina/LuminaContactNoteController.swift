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

// LuminaGram: private contact notes & tags - local-only, keyed by peerId in
// LuminaSettings.contactNotes (submodules/TelegramUIPreferences/Sources/LuminaSettings.swift).
// Never touches Telegram's own profile or server; distinct from Telegram's own server-synced
// "Notes" field (cachedData.note, PeerInfoScreenOpenNote.swift). Pushed from a row added to
// the profile screen (see PeerInfoScreenOpenLuminaContactNote.swift).

private struct LuminaContactNoteState: Equatable {
    var note: String
    var tags: String
}

private final class LuminaContactNoteControllerArguments {
    let updateState: ((LuminaContactNoteState) -> LuminaContactNoteState) -> Void

    init(updateState: @escaping ((LuminaContactNoteState) -> LuminaContactNoteState) -> Void) {
        self.updateState = updateState
    }
}

private enum LuminaContactNoteEntry: ItemListNodeEntry {
    case noteHeader
    case note(String)
    case tagsHeader
    case tags(String)
    case tagsFooter

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .noteHeader:
            return 0
        case .note:
            return 1
        case .tagsHeader:
            return 2
        case .tags:
            return 3
        case .tagsFooter:
            return 4
        }
    }

    static func <(lhs: LuminaContactNoteEntry, rhs: LuminaContactNoteEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaContactNoteControllerArguments
        switch self {
        case .noteHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("PRIVATE NOTE"), sectionId: self.section)
        case let .note(value):
            return ItemListMultilineInputItem(presentationData: presentationData, text: value, placeholder: LuminaL10n.tr("Only you can see this note"), maxLength: nil, sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.note = text
                    return state
                }
            })
        case .tagsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("TAGS"), sectionId: self.section)
        case let .tags(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: LuminaL10n.tr("e.g. work, family"), sectionId: self.section, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.tags = text
                    return state
                }
            }, action: {})
        case .tagsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Comma-separated. Stored only on this device, never sent to Telegram or included in this person's profile.")), sectionId: self.section)
        }
    }
}

private func luminaContactNoteControllerEntries(state: LuminaContactNoteState) -> [LuminaContactNoteEntry] {
    return [
        .noteHeader,
        .note(state.note),
        .tagsHeader,
        .tags(state.tags),
        .tagsFooter
    ]
}

public func luminaContactNoteController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let signal0 = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    |> take(1)

    let existing = (signal0 |> map { sharedData -> LuminaSettings.ContactNote? in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
        return settings.contactNotes.first(where: { $0.peerId == peerId.toInt64() })
    })

    let initialState = LuminaContactNoteState(note: "", tags: "")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)

    let updateState: ((LuminaContactNoteState) -> LuminaContactNoteState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    let arguments = LuminaContactNoteControllerArguments(updateState: updateState)

    var dismissImpl: (() -> Void)?

    let disposable = MetaDisposable()
    disposable.set((existing |> deliverOnMainQueue).start(next: { note in
        if let note {
            updateState { _ in LuminaContactNoteState(note: note.note, tags: note.tags.joined(separator: ", ")) }
        }
    }))

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightNavigationButton = ItemListNavigationButton(content: .text(LuminaL10n.tr("Save")), style: .bold, enabled: true, action: {
            let finalState = stateValue.with { $0 }
            let tags = finalState.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.contactNotes.removeAll(where: { $0.peerId == peerId.toInt64() })
                if !finalState.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tags.isEmpty {
                    settings.contactNotes.append(LuminaSettings.ContactNote(peerId: peerId.toInt64(), note: finalState.note, tags: tags))
                }
                return settings
            }).start()
            dismissImpl?()
        })

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Contact Note")), leftNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        }), rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaContactNoteControllerEntries(state: state), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    let _ = disposable
    return controller
}
