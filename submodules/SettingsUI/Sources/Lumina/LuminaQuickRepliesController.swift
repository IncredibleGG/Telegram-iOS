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

// LuminaGram: quick-reply templates - manage screen (list, add, edit, delete). Reached
// from the "Tools" hub (LuminaToolsController.swift). The composer-side picker used to
// insert a template into the chat lives in LuminaQuickReplyPickerController.swift and
// shares the same LuminaSettings.quickReplyTemplates data but not this UI.

private final class LuminaQuickRepliesControllerArguments {
    let context: AccountContext
    let pushController: (ViewController) -> Void

    init(context: AccountContext, pushController: @escaping (ViewController) -> Void) {
        self.context = context
        self.pushController = pushController
    }
}

private enum LuminaQuickRepliesSection: Int32 {
    case templates
}

private enum LuminaQuickRepliesEntry: ItemListNodeEntry {
    case header
    case template(index: Int, template: LuminaSettings.QuickReplyTemplate)
    case add
    case footer

    var section: ItemListSectionId {
        return LuminaQuickRepliesSection.templates.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case let .template(index, _):
            return Int32(1 + index)
        case .add:
            return 10000
        case .footer:
            return 10001
        }
    }

    static func <(lhs: LuminaQuickRepliesEntry, rhs: LuminaQuickRepliesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaQuickRepliesControllerArguments
        switch self {
        case .header:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "TEMPLATES", sectionId: self.section)
        case let .template(_, template):
            return ItemListDisclosureItem(presentationData: presentationData, title: template.title, label: template.text.replacingOccurrences(of: "\n", with: " "), sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaQuickReplyEditController(context: arguments.context, template: template))
            })
        case .add:
            return ItemListActionItem(presentationData: presentationData, title: "Add Template", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaQuickReplyEditController(context: arguments.context, template: nil))
            })
        case .footer:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Insert a template while composing a message from the Quick Reply option in the text field's selection menu."), sectionId: self.section)
        }
    }
}

private func luminaQuickRepliesControllerEntries(templates: [LuminaSettings.QuickReplyTemplate]) -> [LuminaQuickRepliesEntry] {
    var entries: [LuminaQuickRepliesEntry] = [.header]
    for (index, template) in templates.enumerated() {
        entries.append(.template(index: index, template: template))
    }
    entries.append(.add)
    entries.append(.footer)
    return entries
}

public func luminaQuickRepliesController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaQuickRepliesControllerArguments(context: context, pushController: { c in
        pushControllerImpl?(c)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Quick Replies"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaQuickRepliesControllerEntries(templates: settings.quickReplyTemplates), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
