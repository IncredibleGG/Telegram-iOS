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

// LuminaGram: quick-reply templates - composer-side picker. Presented from
// ChatTextInputPanelNode's "Quick Reply" text-selection menu item (see the
// `_quickReply(_:)` action added there); picking a row calls `select` with the
// template text and dismisses. Read-only view over LuminaSettings.quickReplyTemplates -
// use LuminaQuickRepliesController (the "Tools" hub screen) to add/edit/delete templates.

private final class LuminaQuickReplyPickerControllerArguments {
    let select: (String) -> Void

    init(select: @escaping (String) -> Void) {
        self.select = select
    }
}

private enum LuminaQuickReplyPickerEntry: ItemListNodeEntry {
    case template(index: Int, template: LuminaSettings.QuickReplyTemplate)
    case empty

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case let .template(index, _):
            return Int32(index)
        case .empty:
            return 0
        }
    }

    static func <(lhs: LuminaQuickReplyPickerEntry, rhs: LuminaQuickReplyPickerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaQuickReplyPickerControllerArguments
        switch self {
        case let .template(_, template):
            return ItemListDisclosureItem(presentationData: presentationData, title: template.title, label: template.text.replacingOccurrences(of: "\n", with: " "), sectionId: self.section, style: .blocks, action: {
                arguments.select(template.text)
            })
        case .empty:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("No templates yet. Add some from LuminaGram Settings > Tools > Quick Replies.")), sectionId: self.section)
        }
    }
}

public func luminaQuickReplyPickerController(context: AccountContext, select: @escaping (String) -> Void) -> ViewController {
    var dismissImpl: (() -> Void)?

    let arguments = LuminaQuickReplyPickerControllerArguments(select: { text in
        select(text)
        dismissImpl?()
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        var entries: [LuminaQuickReplyPickerEntry] = []
        if settings.quickReplyTemplates.isEmpty {
            entries.append(.empty)
        } else {
            for (index, template) in settings.quickReplyTemplates.enumerated() {
                entries.append(.template(index: index, template: template))
            }
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("Quick Reply")), leftNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        }), rightNavigationButton: nil, backNavigationButton: nil)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
