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
import AlertUI

// LuminaGram: quick-reply templates - create/edit a single template. Pushed from
// LuminaQuickRepliesController.swift (manage screen) and writes straight into
// LuminaSettings.quickReplyTemplates (submodules/TelegramUIPreferences/Sources/LuminaSettings.swift).
// Purely local, no relation to Telegram's own server-side Business "quick reply" shortcuts.

private struct LuminaQuickReplyEditState: Equatable {
    var title: String
    var text: String
}

private final class LuminaQuickReplyEditControllerArguments {
    let updateState: ((LuminaQuickReplyEditState) -> LuminaQuickReplyEditState) -> Void
    let delete: (() -> Void)?

    init(updateState: @escaping ((LuminaQuickReplyEditState) -> LuminaQuickReplyEditState) -> Void, delete: (() -> Void)?) {
        self.updateState = updateState
        self.delete = delete
    }
}

private enum LuminaQuickReplyEditSection: Int32 {
    case info
}

private enum LuminaQuickReplyEditEntry: ItemListNodeEntry {
    case titleHeader
    case title(String)
    case textHeader
    case text(String)
    case delete

    var section: ItemListSectionId {
        return LuminaQuickReplyEditSection.info.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .titleHeader:
            return 0
        case .title:
            return 1
        case .textHeader:
            return 2
        case .text:
            return 3
        case .delete:
            return 4
        }
    }

    static func <(lhs: LuminaQuickReplyEditEntry, rhs: LuminaQuickReplyEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaQuickReplyEditControllerArguments
        switch self {
        case .titleHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("SHORTCUT NAME"), sectionId: self.section)
        case let .title(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: ""), text: value, placeholder: LuminaL10n.tr("e.g. Thanks"), sectionId: self.section, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.title = text
                    return state
                }
            }, action: {})
        case .textHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("MESSAGE TEXT"), sectionId: self.section)
        case let .text(value):
            return ItemListMultilineInputItem(presentationData: presentationData, text: value, placeholder: LuminaL10n.tr("Message text to insert"), maxLength: nil, sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateState { state in
                    var state = state
                    state.text = text
                    return state
                }
            })
        case .delete:
            return ItemListActionItem(presentationData: presentationData, title: LuminaL10n.tr("Delete Template"), kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.delete?()
            })
        }
    }
}

private func luminaQuickReplyEditControllerEntries(state: LuminaQuickReplyEditState, canDelete: Bool) -> [LuminaQuickReplyEditEntry] {
    var entries: [LuminaQuickReplyEditEntry] = [
        .titleHeader,
        .title(state.title),
        .textHeader,
        .text(state.text)
    ]
    if canDelete {
        entries.append(.delete)
    }
    return entries
}

public func luminaQuickReplyEditController(context: AccountContext, template: LuminaSettings.QuickReplyTemplate?) -> ViewController {
    let initialState = LuminaQuickReplyEditState(title: template?.title ?? "", text: template?.text ?? "")
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)

    let updateState: ((LuminaQuickReplyEditState) -> LuminaQuickReplyEditState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var dismissImpl: (() -> Void)?

    let arguments = LuminaQuickReplyEditControllerArguments(updateState: updateState, delete: template == nil ? nil : {
        if let id = template?.id {
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.quickReplyTemplates.removeAll(where: { $0.id == id })
                return settings
            }).start()
        }
        dismissImpl?()
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let canSave = !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let rightNavigationButton = ItemListNavigationButton(content: .text(LuminaL10n.tr("Save")), style: .bold, enabled: canSave, action: {
            let finalState = stateValue.with { $0 }
            let id = template?.id ?? UUID().uuidString
            let saved = LuminaSettings.QuickReplyTemplate(id: id, title: finalState.title.trimmingCharacters(in: .whitespacesAndNewlines), text: finalState.text)
            let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                if let index = settings.quickReplyTemplates.firstIndex(where: { $0.id == id }) {
                    settings.quickReplyTemplates[index] = saved
                } else {
                    settings.quickReplyTemplates.append(saved)
                }
                return settings
            }).start()
            dismissImpl?()
        })

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(template == nil ? LuminaL10n.tr("New Template") : LuminaL10n.tr("Edit Template")), leftNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        }), rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaQuickReplyEditControllerEntries(state: state, canDelete: template != nil), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
