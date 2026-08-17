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

// The LuminaGram settings hub - entry point for every Lumina feature wave. Reached from
// the main Settings screen (submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources,
// PeerInfoSettingsItems.swift + PeerInfoScreenSettingsActions.swift wire the row that opens
// this). Structured exactly like the rest of this module's small settings screens (compare
// ArchiveSettingsController.swift): one ItemListController driven by a presentationData-only
// signal, since none of the five sub-sections have live state yet. Pushing from inside the
// arguments closures uses the same pushControllerImpl-captured-after-construction pattern as
// DataAndStorageSettingsController.swift, not a global window lookup.
//
// LuminaGram's own UI text below is hardcoded in English rather than routed through
// presentationData.strings. That is deliberate, not an oversight: PresentationStrings keys
// are ultimately resolved by Telegram's cloud language pack (see DefaultPresentationStrings.swift
// / the GenerateStrings pipeline), and a key this fork invents has no cloud translation - it
// would silently read English for every non-English user regardless of their selected
// language. Desktop hit the exact same wall and solved it with its own lumina_locale table
// (tdesktop/Telegram/SourceFiles/lumina/lumina_locale.{h,cpp}); building that layer for iOS
// is future work, out of scope for this foundation commit.
public func luminaGramSettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = LuminaGramSettingsControllerArguments(context: context, pushController: { c in
        pushControllerImpl?(c)
    })

    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("LuminaGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaGramSettingsControllerEntries(), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}

private final class LuminaGramSettingsControllerArguments {
    let context: AccountContext
    let pushController: (ViewController) -> Void

    init(context: AccountContext, pushController: @escaping (ViewController) -> Void) {
        self.context = context
        self.pushController = pushController
    }
}

private enum LuminaGramSettingsSection: Int32 {
    case features
}

private enum LuminaGramSettingsEntry: ItemListNodeEntry {
    case featuresHeader
    case translation
    case voice
    case security
    case privacy
    case tools
    case storedLocallyFooter

    var section: ItemListSectionId {
        return LuminaGramSettingsSection.features.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .featuresHeader:
            return 0
        case .translation:
            return 1
        case .voice:
            return 2
        case .security:
            return 3
        case .privacy:
            return 4
        case .tools:
            return 5
        case .storedLocallyFooter:
            return 6
        }
    }

    static func <(lhs: LuminaGramSettingsEntry, rhs: LuminaGramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaGramSettingsControllerArguments
        switch self {
        case .featuresHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "FEATURES", sectionId: self.section)
        case .translation:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.autoTranslate, title: "Translation", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaGramPlaceholderController(context: arguments.context, title: "Translation", text: "Per-chat translate-before-send, dual-language display, glossary and provider settings will appear here."))
            })
        case .voice:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.language, title: "Voice & Media", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaGramPlaceholderController(context: arguments.context, title: "Voice & Media", text: "Voice-to-text, reverse voice and media handling settings will appear here."))
            })
        case .security:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.security, title: "Security", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaGramPlaceholderController(context: arguments.context, title: "Security", text: "OTP guard, session guard, link and file safety checks will appear here."))
            })
        case .privacy:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.lockOrange, title: "Privacy", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaGramPlaceholderController(context: arguments.context, title: "Privacy", text: "Hidden phone number, locked chats and photo metadata stripping will appear here."))
            })
        case .tools:
            return ItemListDisclosureItem(presentationData: presentationData, icon: PresentationResourcesSettings.aiTools, title: "Tools", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(luminaGramPlaceholderController(context: arguments.context, title: "Tools", text: "Bookmarks, quick-reply templates and local encrypted backup will appear here."))
            })
        case .storedLocallyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("LuminaGram options are stored on this device only and are never synced to Telegram."), sectionId: self.section)
        }
    }
}

private func luminaGramSettingsControllerEntries() -> [LuminaGramSettingsEntry] {
    return [
        .featuresHeader,
        .translation,
        .voice,
        .security,
        .privacy,
        .tools,
        .storedLocallyFooter
    ]
}

// A single reusable placeholder screen for the five sub-sections above, until each grows
// its own controller in a later wave. Compiles and shows with zero live state, per the
// foundation task's requirement.
public func luminaGramPlaceholderController(context: AccountContext, title: String, text: String) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let entries: [LuminaGramPlaceholderEntry] = [.info(text)]
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)

        return (controllerState, (listState, Void()))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}

private enum LuminaGramPlaceholderEntry: ItemListNodeEntry {
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: LuminaGramPlaceholderEntry, rhs: LuminaGramPlaceholderEntry) -> Bool {
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}
