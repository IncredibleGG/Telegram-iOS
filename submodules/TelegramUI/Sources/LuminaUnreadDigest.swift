import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import UndoUI
import AccountContext

// LuminaGram: unread digest on return after absence - port of Android's LuminaDigestHelper,
// redesigned for iOS's foreground-only lifecycle (no persistent background socket, so this
// can only run "on return", which is exactly this feature's own trigger anyway - see
// IOS-PORT-PLAN.md's Utility & interface section). Called once from
// AppDelegate.applicationDidBecomeActive.
//
// v1 scope: a single lightweight toast with the total unread count across all accounts,
// shown only if the app was away past luminaDigestAbsenceThreshold. Reuses
// renderedTotalUnreadCount(accountManager:engine:) (submodules/TelegramUIPreferences/Sources/
// RenderedTotalUnreadCount.swift), the same API the chat-list badge itself is built on, so
// this never drifts from what the user already sees elsewhere. A fuller per-chat breakdown
// is a natural follow-up once this lands.
private let luminaLastForegroundTimestampKey = "LuminaGram.unreadDigest.lastForegroundTimestamp"
private let luminaDigestAbsenceThreshold: TimeInterval = 30 * 60

public func luminaMaybeShowUnreadDigest(sharedContext: SharedAccountContext) {
    guard LuminaSettingsCache.shared.current().unreadDigest else {
        return
    }

    let defaults = UserDefaults.standard
    let now = Date().timeIntervalSince1970
    let last = defaults.double(forKey: luminaLastForegroundTimestampKey)
    defaults.set(now, forKey: luminaLastForegroundTimestampKey)

    guard last > 0, now - last >= luminaDigestAbsenceThreshold else {
        return
    }

    let _ = (sharedContext.activeAccountContexts
    |> take(1)
    |> mapToSignal { _, accounts, _ -> Signal<Int32, NoError> in
        if accounts.isEmpty {
            return .single(0)
        }
        let perAccount = accounts.map { _, context, _ in
            renderedTotalUnreadCount(accountManager: sharedContext.accountManager, engine: context.engine)
            |> take(1)
            |> map { count, _ -> Int32 in
                return count
            }
        }
        return combineLatest(perAccount)
        |> map { counts -> Int32 in
            return counts.reduce(0, +)
        }
    }
    |> deliverOnMainQueue).start(next: { totalUnread in
        guard totalUnread > 0 else {
            return
        }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let text = totalUnread == 1 ? "1 unread while you were away" : "\(totalUnread) unread while you were away"
        sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), on: .root, blockInteraction: false, completion: {})
    })
}
