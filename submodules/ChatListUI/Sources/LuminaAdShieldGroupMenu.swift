import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import ContextUI
import AlertUI
import PresentationDataUtils
import AppBundle

// LuminaGram「隱藏重複廣告」(hide repeated ads): the per-group mode row (product spec B), 「隱藏重複廣告」 with
// 跟隨預設（目前：開/關）/ 在此群開啟 / 在此群關閉, the group's own switch 「連管理員和頻道的也收」 (default off; repeats the
// same owner / admin / the group's channel posts fold too, members' re-posts of announcements still do not; it takes
// effect while the group is effectively on) with its help line, and 「最近 7 天已收合 N 則」 when N > 0.
//
// It lives here, in ChatListUI, because two menus show it and this is the lowest module both can reach:
//  - the chat header Lumina menu (TelegramUI, LuminaChatLanguageMenu): basic groups, supergroups, gigagroups and a
//    forum viewed as messages (`luminaAdShieldMenuItem`, the count is loaded before the menu opens);
//  - the forum's own "..." menu (ChatListControllerImpl.openMoreMenu: the topic list, and a forum viewed as
//    messages). A forum topic has no Lumina header menu, so this is where forum users reach the mode
//    (`luminaAdShieldForumMenuItem`, the count is loaded when the row is tapped).
// The fold row's 「在此群關閉」 (TelegramUI, LuminaAdShieldFold) uses `luminaAdShieldSetChatMode`.
//
// The mode is stored in LuminaSettings.adShieldDialogs, the switch in LuminaSettings.adShieldFoldPrivilegedDialogs (both
// keyed by PeerId.toInt64()). The first time the feature is turned on anywhere, the explainer comes first.

public struct LuminaAdShieldMenuInfo {
    public let eligible: Bool
    public let foldedCount: Int

    public init(eligible: Bool, foldedCount: Int) {
        self.eligible = eligible
        self.foldedCount = foldedCount
    }

    public static var none: LuminaAdShieldMenuInfo {
        return LuminaAdShieldMenuInfo(eligible: false, foldedCount: 0)
    }
}

/// Basic groups, supergroups, forums and gigagroups; never private or secret chats, broadcast channels or
/// monoforums (the same rule as TelegramUI's luminaAdShieldChatType).
public func luminaAdShieldMenuIsEligible(_ peer: EnginePeer) -> Bool {
    switch peer {
    case .legacyGroup:
        return true
    case let .channel(channel):
        guard case .group = channel.info else {
            return false
        }
        return !channel.flags.contains(.isMonoforum)
    default:
        return false
    }
}

/// The AdShield chat id of a group peer: bot-API style, basic groups `-<id>`, supergroups `-100<id>` (the same as
/// TelegramUI's luminaAdShieldGroupChatId); nil for anything else.
private func luminaAdShieldMenuChatId(_ peerId: EnginePeer.Id) -> Int64? {
    let raw = peerId.id._internalGetInt64Value()
    if peerId.namespace == Namespaces.Peer.CloudGroup {
        return -raw
    } else if peerId.namespace == Namespaces.Peer.CloudChannel {
        return Int64("-100\(raw)") ?? (-1_000_000_000_000 - raw)
    } else {
        return nil
    }
}

/// Whether the chat gets the 「隱藏重複廣告」 row, and its 7-day folded count. A big chat may take a moment to count
/// (every stored message is decided once per change); this never waits more than 0.5 s for it and reports no count
/// instead. The value may arrive on the AdShield queue: callers deliver it on the main queue.
public func luminaAdShieldMenuInfo(context: AccountContext, peerId: EnginePeer.Id) -> Signal<LuminaAdShieldMenuInfo, NoError> {
    guard let chatId = luminaAdShieldMenuChatId(peerId) else {
        return .single(.none)
    }
    let basePath = context.account.basePath
    return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> deliverOnMainQueue // LuminaAdShieldService's main-thread state is read below
    |> mapToSignal { peer -> Signal<LuminaAdShieldMenuInfo, NoError> in
        guard let peer, luminaAdShieldMenuIsEligible(peer) else {
            return .single(.none)
        }
        return LuminaAdShieldService.shared.foldedCountLast7Days(basePath: basePath, chatId: chatId, peerId: peerId.toInt64())
        |> timeout(0.5, queue: Queue.mainQueue(), alternate: .single(0))
        |> map { count -> LuminaAdShieldMenuInfo in
            return LuminaAdShieldMenuInfo(eligible: true, foldedCount: count)
        }
    }
}

/// Applies a per-group mode; the first time the feature is turned on anywhere, the explainer comes first. Also the
/// fold row's 「在此群關閉」.
public func luminaAdShieldSetChatMode(context: AccountContext, peerId: EnginePeer.Id, mode: LuminaAdShieldChatMode, present: @escaping (ViewController) -> Void) {
    let settings = LuminaAdShieldService.shared.settings ?? LuminaSettingsCache.settings
    luminaAdShieldApplyChatMode(context: context, peerId: peerId, mode: mode, settings: settings, presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: present)
}

private func luminaAdShieldApplyChatMode(context: AccountContext, peerId: EnginePeer.Id, mode: LuminaAdShieldChatMode, settings: LuminaSettings, presentationData: PresentationData, present: @escaping (ViewController) -> Void) {
    let accountManager = context.sharedContext.accountManager
    let peerIdValue = peerId.toInt64()
    let apply: () -> Void = {
        let _ = updateLuminaSettingsInteractively(accountManager: accountManager, { current in
            var updated = current.withLuminaAdShieldMode(mode, peerId: peerIdValue)
            if mode == .on {
                updated.adShieldExplainerShown = true
            }
            return updated
        }).startStandalone()
    }
    if mode == .on && !settings.adShieldExplainerShown {
        present(textAlertController(context: context, title: LuminaL10n.tr("Hide Repeated Ads"), text: LuminaAdShieldTexts.explainerText(), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Turn On"), action: {
                apply()
            })
        ]))
    } else {
        apply()
    }
}

/// 「連管理員和頻道的也收」 of the group `peerId` (its own switch, default off). Changing it re-decides the open chat.
public func luminaAdShieldSetFoldPrivileged(context: AccountContext, peerId: EnginePeer.Id, on: Bool) {
    let peerIdValue = peerId.toInt64()
    let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
        return current.withLuminaAdShieldFoldPrivileged(on, peerId: peerIdValue)
    }).startStandalone()
}

/// The submenu: Back, the three modes (checkmark on the current one), 「連管理員和頻道的也收」 (checkmark when on) with
/// its help line, and 「最近 7 天已收合 N 則」 when N > 0.
private func luminaAdShieldModeItems(context: AccountContext, peerId: EnginePeer.Id, settings: LuminaSettings, foldedCount: Int, presentationData: PresentationData, present: @escaping (ViewController) -> Void) -> [ContextMenuItem] {
    let currentMode = settings.luminaAdShieldMode(peerId: peerId.toInt64())
    let globalOn = settings.adShieldEnabled
    let checkIcon: (PresentationTheme) -> UIImage? = { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
    }
    let noIcon: (PresentationTheme) -> UIImage? = { _ in
        return nil
    }
    var items: [ContextMenuItem] = []
    items.append(.action(ContextMenuActionItem(text: presentationData.strings.Common_Back, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
    }, iconPosition: .left, action: { c, _ in
        c?.popItems()
    })))
    items.append(.separator)
    for mode in [LuminaAdShieldChatMode.followDefault, .on, .off] {
        let selected = mode == currentMode
        items.append(.action(ContextMenuActionItem(text: LuminaAdShieldTexts.modeLabel(mode, globalOn: globalOn), icon: selected ? checkIcon : noIcon, action: { c, _ in
            c?.dismiss(completion: {
                if mode != currentMode {
                    luminaAdShieldApplyChatMode(context: context, peerId: peerId, mode: mode, settings: settings, presentationData: presentationData, present: present)
                }
            })
        }, accessibilityIsSelected: selected)))
    }
    let foldPrivileged = settings.luminaAdShieldFoldPrivileged(peerId: peerId.toInt64())
    items.append(.separator)
    items.append(.action(ContextMenuActionItem(text: LuminaL10n.tr("Also fold admins and the group's channel"), icon: foldPrivileged ? checkIcon : noIcon, action: { c, _ in
        c?.dismiss(completion: {
            luminaAdShieldSetFoldPrivileged(context: context, peerId: peerId, on: !foldPrivileged)
        })
    }, accessibilityIsSelected: foldPrivileged)))
    items.append(.action(ContextMenuActionItem(text: LuminaL10n.tr("Repeats posted by the owner, admins or the group's channel itself also fold; announcements re-posted by members still don't."), textLayout: .multiline, textFont: .small, icon: noIcon, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)))
    if foldedCount > 0 {
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: LuminaAdShieldTexts.foldedLast7Days(foldedCount), textLayout: .multiline, textFont: .small, icon: noIcon, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)))
    }
    return items
}

/// The row itself; its second line names the current mode. `foldedCount` is subscribed when the row is tapped.
private func luminaAdShieldModeRow(context: AccountContext, peerId: EnginePeer.Id, settings: LuminaSettings, foldedCount: Signal<Int, NoError>, presentationData: PresentationData, present: @escaping (ViewController) -> Void) -> ContextMenuItem {
    let currentMode = settings.luminaAdShieldMode(peerId: peerId.toInt64())
    return .action(ContextMenuActionItem(text: LuminaL10n.tr("Hide Repeated Ads"), textLayout: .secondLineWithValue(LuminaAdShieldTexts.modeLabel(currentMode, globalOn: settings.adShieldEnabled)), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AntiSpam"), color: theme.contextMenu.primaryColor)
    }, action: { c, _ in
        c?.pushItems(items: foldedCount
        |> take(1)
        |> deliverOnMainQueue
        |> map { count -> ContextController.Items in
            return ContextController.Items(content: .list(luminaAdShieldModeItems(context: context, peerId: peerId, settings: settings, foldedCount: count, presentationData: presentationData, present: present)))
        })
    }))
}

/// The row of the chat header Lumina menu, for an eligible group (`info` loaded before the menu opens).
public func luminaAdShieldMenuItem(context: AccountContext, peerId: EnginePeer.Id, settings: LuminaSettings, info: LuminaAdShieldMenuInfo, presentationData: PresentationData, present: @escaping (ViewController) -> Void) -> ContextMenuItem? {
    if !info.eligible {
        return nil
    }
    return luminaAdShieldModeRow(context: context, peerId: peerId, settings: settings, foldedCount: .single(info.foldedCount), presentationData: presentationData, present: present)
}

/// The row of the forum's own "..." menu (main thread): the settings as they are now; the 7-day count is loaded when
/// the row is tapped (at most 0.5 s), so the forum menu itself never waits for it.
public func luminaAdShieldForumMenuItem(context: AccountContext, peer: EnginePeer, presentationData: PresentationData, present: @escaping (ViewController) -> Void) -> ContextMenuItem? {
    if !luminaAdShieldMenuIsEligible(peer) {
        return nil
    }
    let settings = LuminaAdShieldService.shared.settings ?? LuminaSettingsCache.settings
    let foldedCount = luminaAdShieldMenuInfo(context: context, peerId: peer.id)
    |> map { info -> Int in
        return info.foldedCount
    }
    return luminaAdShieldModeRow(context: context, peerId: peer.id, settings: settings, foldedCount: foldedCount, presentationData: presentationData, present: present)
}
