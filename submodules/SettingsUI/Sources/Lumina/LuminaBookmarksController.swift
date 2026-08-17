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
import TelegramStringFormatting

// LuminaGram: message bookmarks - browse/delete screen for the local-only bookmark list
// created from the message context menu (see the "Bookmark" action added in
// submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift). Reached from the
// "Tools" hub. Local-only alternative to Saved Messages; no server RPC.
//
// Scope note: this first wave is browse + delete only (tap a row to see the full snippet
// and delete it). Jumping straight to the original message would go through
// AccountContext's `navigateToChatController(NavigateToChatControllerParams(...))`, whose
// Location case needs an already-resolved EnginePeer (not just a PeerId) plus a dozen other
// constructor parameters - deferred rather than guessed at without being able to build.

private final class LuminaBookmarksControllerArguments {
    let context: AccountContext
    let selectBookmark: (LuminaSettings.Bookmark) -> Void

    init(context: AccountContext, selectBookmark: @escaping (LuminaSettings.Bookmark) -> Void) {
        self.context = context
        self.selectBookmark = selectBookmark
    }
}

private enum LuminaBookmarksEntry: ItemListNodeEntry {
    case bookmark(index: Int, bookmark: LuminaSettings.Bookmark)
    case empty

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case let .bookmark(index, _):
            return Int32(index)
        case .empty:
            return 0
        }
    }

    static func <(lhs: LuminaBookmarksEntry, rhs: LuminaBookmarksEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaBookmarksControllerArguments
        switch self {
        case let .bookmark(_, bookmark):
            let dateLabel = stringForMediumDate(timestamp: bookmark.timestamp, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
            return ItemListDisclosureItem(presentationData: presentationData, title: bookmark.snippet.isEmpty ? "Message" : bookmark.snippet, label: dateLabel, sectionId: self.section, style: .blocks, action: {
                arguments.selectBookmark(bookmark)
            })
        case .empty:
            return ItemListTextItem(presentationData: presentationData, text: .plain("No bookmarks yet. Add one from a message's context menu (\u{201C}Bookmark\u{201D})."), sectionId: self.section)
        }
    }
}

public func luminaBookmarksController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaBookmarksControllerArguments(context: context, selectBookmark: { bookmark in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: bookmark.snippet.isEmpty ? "Delete this bookmark?" : bookmark.snippet, actions: [
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.bookmarks.removeAll(where: { $0.peerId == bookmark.peerId && $0.messageId == bookmark.messageId && $0.messageNamespace == bookmark.messageNamespace })
                    return settings
                }).start()
            }),
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
        ]))
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings

        var entries: [LuminaBookmarksEntry] = []
        if settings.bookmarks.isEmpty {
            entries.append(.empty)
        } else {
            for (index, bookmark) in settings.bookmarks.enumerated().reversed() {
                entries.append(.bookmark(index: index, bookmark: bookmark))
            }
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Bookmarks"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
