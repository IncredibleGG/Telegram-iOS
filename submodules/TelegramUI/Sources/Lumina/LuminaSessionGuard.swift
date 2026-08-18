import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import Display
import PresentationDataUtils

/// LuminaGram login/session guard — foreground poll + known-session diff, port of Android's
/// `org.telegram.messenger.LuminaSessionGuard` + `org.telegram.ui.LuminaSessionAlertBox`.
///
/// The 2026 account-takeover playbook is no longer password guessing — the attacker sends a QR
/// code, claims it is a "verification", and the moment the victim scans it they hold a live
/// authorized session. Almost nobody opens "Active sessions" on their own, so a new session sits
/// there unnoticed. This closes that gap with a purely local diff:
///
///  1. On app foreground (throttled to `minInterval`, per account) ask the official
///     `account.getAuthorizations` (via `TelegramEngine.Privacy.activeSessions()`, exactly what
///     the built-in Settings > Devices screen calls) for the user's own authorization list.
///  2. Compare the returned session hashes against `LuminaSettings.sessionGuardKnownHashes` and
///     show an alert for anything not seen before.
///
/// ToS boundaries (deliberate, mirrors Android, do not "optimise" away):
///   - Only official API calls are used: `account.getAuthorizations` / `account.resetAuthorization`
///     (via `TelegramEngine.Privacy.terminateAnotherSession`) — exactly what the built-in
///     `RecentSessionsController` screen calls.
///   - A session is NEVER terminated automatically. `terminate` only runs from an explicit tap on
///     "Not me — Terminate". Acting on the account without the user's knowledge would violate
///     Telegram's ToS.
///   - Nothing is uploaded, logged or shared. The known-session list lives only in
///     `LuminaSettings` (local SharedData, never cloud-synced — see `LuminaSettings.swift`).
///
/// Hook point: called once per active account from `AppDelegate.runForegroundTasks()`
/// (`submodules/TelegramUI/Sources/AppDelegate.swift`), the existing per-account foreground loop.
///
/// The very first successful check for an account seeds the baseline and flips the dedicated
/// `LuminaSettings.sessionGuardBaselineSeeded` flag (the analogue of Android's
/// `LuminaConfig.hasKnownSessions`). Using that flag rather than
/// `sessionGuardKnownHashes.isEmpty` means an account that baselined with zero other sessions
/// still alerts on the first new session it later gains, instead of silently re-seeding.
public enum LuminaSessionGuard {
    /// Minimum gap between two automatic (foreground) checks, per account. Avoids API flood.
    /// In-memory only (resets on relaunch) since there is no persisted per-account timestamp
    /// field on `LuminaSettings` for this — see the note above.
    private static let minInterval: Double = 30 * 60

    private static var lastCheckByAccount: [PeerId: Double] = [:]

    /// Keeps a freshly-created `ActiveSessionsContext` alive until its first real (non-loading)
    /// state arrives — it does its own network fetch on init and would otherwise be torn down
    /// (cancelling the in-flight request) as soon as this function returns. See `PeerInfo`/
    /// session-list screens elsewhere in this codebase for the same context, held as a stored
    /// property there; this static dictionary is the equivalent for a one-shot static call.
    private static var pending: [ObjectIdentifier: ActiveSessionsContext] = [:]

    /// Called once per active account from `AppDelegate.runForegroundTasks()`. Never throws;
    /// every failure path is a silent no-op so a bug here can never affect app start-up.
    public static func checkOnForeground(context: AccountContext, present: @escaping (ViewController) -> Void) {
        let accountPeerId = context.account.peerId
        let now = CFAbsoluteTimeGetCurrent()
        if let last = LuminaSessionGuard.lastCheckByAccount[accountPeerId], now - last < LuminaSessionGuard.minInterval {
            return
        }

        let _ = (context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.luminaSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? LuminaSettings.defaultSettings
            guard settings.sessionGuardEnabled else {
                return
            }
            LuminaSessionGuard.lastCheckByAccount[accountPeerId] = now

            let activeSessionsContext = context.engine.privacy.activeSessions()
            let key = ObjectIdentifier(activeSessionsContext)
            LuminaSessionGuard.pending[key] = activeSessionsContext

            let _ = (activeSessionsContext.state
            |> filter { !$0.isLoadingMore }
            |> take(1)
            |> deliverOnMainQueue).start(next: { state in
                LuminaSessionGuard.pending[key] = nil
                LuminaSessionGuard.handle(context: context, sessions: state.sessions, knownHashes: settings.sessionGuardKnownHashes, baselineSeeded: settings.sessionGuardBaselineSeeded, present: present)
            })
        })
    }

    // MARK: - internals

    private static func handle(context: AccountContext, sessions: [RecentAccountSession], knownHashes: [Int64], baselineSeeded: Bool, present: @escaping (ViewController) -> Void) {
        let others = sessions.filter { !$0.isCurrent }
        let presentHashes = Set(others.map { $0.hash })
        let knownSet = Set(knownHashes)

        if !baselineSeeded {
            // First run for this account: whatever it already has is treated as known, so a fresh
            // install (or a genuinely session-free account) never opens a wall of alerts. The
            // dedicated sessionGuardBaselineSeeded flag (not knownHashes.isEmpty) marks this done,
            // so an account that baselined with zero other sessions still alerts on the first one
            // it later gains.
            seedBaseline(context: context, hashes: Array(presentHashes))
            return
        }

        // Drop hashes that no longer exist server-side so the stored list cannot grow forever.
        let prunedKnown = knownSet.intersection(presentHashes)
        persistKnown(context: context, hashes: Array(prunedKnown))

        let fresh = others.filter { !knownSet.contains($0.hash) }
        guard !fresh.isEmpty else {
            return
        }
        showNext(context: context, queue: fresh, index: 0, present: present)
    }

    /// Walk the queue of unknown sessions one alert at a time. A session is only added to the
    /// known set when the user answers "That was me" — if terminated it is simply dropped (it no
    /// longer exists server-side, so the next prune removes it anyway).
    private static func showNext(context: AccountContext, queue: [RecentAccountSession], index: Int, present: @escaping (ViewController) -> Void) {
        guard index < queue.count else {
            return
        }
        let session = queue[index]
        let controller = textAlertController(
            sharedContext: context.sharedContext,
            title: LuminaL10n.tr("New device signed in"),
            text: alertMessage(for: session),
            actions: [
                TextAlertAction(type: .destructiveAction, title: LuminaL10n.tr("Not me — Terminate"), action: {
                    let _ = context.engine.privacy.terminateAnotherSession(id: session.hash).start(error: { _ in
                        showNext(context: context, queue: queue, index: index + 1, present: present)
                    }, completed: {
                        showTwoStepNudge(context: context, present: present)
                        showNext(context: context, queue: queue, index: index + 1, present: present)
                    })
                }),
                TextAlertAction(type: .genericAction, title: LuminaL10n.tr("That was me"), action: {
                    rememberSession(context: context, hash: session.hash)
                    showNext(context: context, queue: queue, index: index + 1, present: present)
                }),
            ]
        )
        present(controller)
    }

    private static func rememberSession(context: AccountContext, hash: Int64) {
        let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            if !settings.sessionGuardKnownHashes.contains(hash) {
                settings.sessionGuardKnownHashes.append(hash)
            }
            return settings
        }).start()
    }

    private static func persistKnown(context: AccountContext, hashes: [Int64]) {
        let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            settings.sessionGuardKnownHashes = hashes
            return settings
        }).start()
    }

    /// Records the one-time baseline for an account: adopts the currently-present sessions as
    /// known and flips sessionGuardBaselineSeeded so subsequent checks alert on anything new,
    /// even if the baseline itself was empty.
    private static func seedBaseline(context: AccountContext, hashes: [Int64]) {
        let _ = updateLuminaSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            settings.sessionGuardKnownHashes = hashes
            settings.sessionGuardBaselineSeeded = true
            return settings
        }).start()
    }

    /// A one-off nudge after a termination, pointing at the official Privacy & Security screen
    /// (which itself surfaces Two-Step Verification) — mirrors Android's `showTwoStepTip`.
    private static func showTwoStepNudge(context: AccountContext, present: @escaping (ViewController) -> Void) {
        let controller = textAlertController(
            sharedContext: context.sharedContext,
            title: LuminaL10n.tr("Session terminated"),
            text: LuminaL10n.tr("Turning on Two-Step Verification stops a repeat — a stolen login code alone won't be enough to sign in again."),
            actions: [
                TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Security Settings"), action: {
                    present(context.sharedContext.makePrivacyAndSecurityController(context: context))
                }),
                TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Later"), action: {}),
            ]
        )
        present(controller)
    }

    private static func alertMessage(for session: RecentAccountSession) -> String {
        var lines: [String] = [LuminaL10n.tr("A new device just signed in to your account.")]
        let device = [session.deviceModel, [session.platform, session.systemVersion].filter { !$0.isEmpty }.joined(separator: " ")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if !device.isEmpty {
            lines.append(LuminaL10n.tr("Device:") + " \(device)")
        }
        let app = [session.appName, session.appVersion].filter { !$0.isEmpty }.joined(separator: " ")
        if !app.isEmpty {
            lines.append(LuminaL10n.tr("App:") + " \(app)")
        }
        if !session.ip.isEmpty {
            lines.append(LuminaL10n.tr("IP:") + " \(session.ip)")
        }
        let location = [session.country, session.region].filter { !$0.isEmpty }.joined(separator: ", ")
        if !location.isEmpty {
            lines.append(LuminaL10n.tr("Location:") + " \(location)")
        }
        return lines.joined(separator: "\n")
    }
}
