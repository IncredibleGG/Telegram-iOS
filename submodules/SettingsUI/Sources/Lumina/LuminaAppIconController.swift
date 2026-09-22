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

// LuminaGram #24: app icon picker. Reached from the LuminaGram "Interface" sub-screen
// (LuminaInterfaceController.swift, `.appIcon` disclosure row).
//
// This invents NO new image assets. It reuses, verbatim, the platform's existing alternate
// app-icon mechanism: the app icons declared in Info.plist (CFBundleAlternateIcons), surfaced
// through context.sharedContext.applicationBindings.getAvailableAlternateIcons(), and switched
// through requestSetAlternateIconName (AppDelegate.swift -> UIApplication.setAlternateIconName).
// The horizontally scrolling selector is Telegram's own ThemeSettingsAppIconItem, the same item
// the stock Appearance screen uses. So this is purely a second, LuminaGram-branded entry point to
// the icons that already ship in the bundle - additional branded icon ART must be added later by a
// designer (see the port report / concerns), at which point it appears here automatically with no
// code change.
//
// Premium-only icons are filtered out so the picker never shows a locked row or needs the premium
// upsell flow: only the default icon and the freely selectable alternates are offered. Default =
// the app's default icon (nothing selected / requestSetAlternateIconName(nil)), so an untouched
// install keeps the stock icon.
public func luminaAppIconController(context: AccountContext) -> ViewController {
    let appIcons = context.sharedContext.applicationBindings.getAvailableAlternateIcons().filter { !$0.isPremium }

    let currentIconName: String?
    if let alternateIconName = context.sharedContext.applicationBindings.getAlternateIconName() {
        currentIconName = alternateIconName
    } else {
        currentIconName = appIcons.filter { $0.isDefault }.first?.name
    }

    let currentAppIconName = ValuePromise<String?>(currentIconName, ignoreRepeated: true)

    let arguments = LuminaAppIconControllerArguments(
        context: context,
        icons: appIcons,
        selectIcon: { icon in
            currentAppIconName.set(icon.name)
            context.sharedContext.applicationBindings.requestSetAlternateIconName(icon.isDefault ? nil : icon.name, { _ in
            })
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        currentAppIconName.get()
    )
    |> map { presentationData, iconName -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuminaL10n.tr("App Icon")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: luminaAppIconControllerEntries(iconName: iconName), style: .blocks, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}

private final class LuminaAppIconControllerArguments {
    let context: AccountContext
    let icons: [PresentationAppIcon]
    let selectIcon: (PresentationAppIcon) -> Void

    init(context: AccountContext, icons: [PresentationAppIcon], selectIcon: @escaping (PresentationAppIcon) -> Void) {
        self.context = context
        self.icons = icons
        self.selectIcon = selectIcon
    }
}

private enum LuminaAppIconSection: Int32 {
    case icon
}

private enum LuminaAppIconEntry: ItemListNodeEntry {
    case iconHeader
    // Carries only the current icon name (Equatable) so equality/redraw is driven by the
    // selection; the icon list and theme come from the arguments / presentationData in item().
    case iconItem(String?)
    case iconFooter

    var section: ItemListSectionId {
        return LuminaAppIconSection.icon.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .iconHeader:
            return 0
        case .iconItem:
            return 1
        case .iconFooter:
            return 2
        }
    }

    static func ==(lhs: LuminaAppIconEntry, rhs: LuminaAppIconEntry) -> Bool {
        switch lhs {
        case .iconHeader:
            if case .iconHeader = rhs {
                return true
            } else {
                return false
            }
        case let .iconItem(lhsName):
            if case let .iconItem(rhsName) = rhs, lhsName == rhsName {
                return true
            } else {
                return false
            }
        case .iconFooter:
            if case .iconFooter = rhs {
                return true
            } else {
                return false
            }
        }
    }

    static func <(lhs: LuminaAppIconEntry, rhs: LuminaAppIconEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuminaAppIconControllerArguments
        switch self {
        case .iconHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: LuminaL10n.tr("APP ICON"), sectionId: self.section)
        case let .iconItem(iconName):
            return ThemeSettingsAppIconItem(theme: presentationData.theme, strings: presentationData.strings, systemStyle: .glass, sectionId: self.section, icons: arguments.icons, isPremium: true, currentIconName: iconName, updated: { icon in
                arguments.selectIcon(icon)
            })
        case .iconFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(LuminaL10n.tr("Choose the app icon shown on your Home Screen. Only icons already included in the app are offered.")), sectionId: self.section)
        }
    }
}

private func luminaAppIconControllerEntries(iconName: String?) -> [LuminaAppIconEntry] {
    return [
        .iconHeader,
        .iconItem(iconName),
        .iconFooter
    ]
}
