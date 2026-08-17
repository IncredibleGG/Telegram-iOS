import Foundation
import TelegramCore
import SwiftSignalKit

// Single-chat lock / private folder - the iOS port of desktop's Lumina::ChatLock
// (lumina/lumina_chat_lock.{h,cpp}) and Android's LuminaChatLock.java. Behaviour is meant to
// match those two exactly, field names included, so a LuminaSettings export/backup carries
// across platforms.
//
// A locked conversation is taken out of the chat list (ChatListNodeEntries.swift) and out of
// local chat-list search until the secret code is typed into the ordinary chat-list search
// field (ChatListSearchContainerNode.swift). Reveal then lasts for the lifetime of the
// process only - it is deliberately NOT persisted, so a restart re-hides everything, exactly
// like `revealed` on the other two platforms.
//
// *** THIS IS A DISPLAY-LAYER FILTER, AND ONLY THAT (ToS 1.4) ***
//
// A hidden conversation keeps receiving messages and keeps its unread state: nothing here
// calls any read/typing/online/last-seen API, and nothing here removes the chat from the
// Postbox chat list - it only removes the row from what ChatListNodeEntriesForView() renders.
// Unread counters, folder badges and the app badge are computed elsewhere, from the Postbox
// chat list summary, and are untouched by this filter.
//
// *** FAIL OPEN, LIKE BOTH OTHER PLATFORMS ***
//
// isHidden(_:) returns false (show it) for anything it is unsure about: revealed, no code
// configured, or the peer simply not in the locked set. Losing sight of a conversation is far
// worse than briefly showing one.
//
// NO VAULT-CODE FALLBACK ON iOS. Desktop and Android fall back to the disguise vault's decoy
// unlock code when no dedicated chatLockCode is set; the disguise vault is explicitly
// out of scope for the iOS App-Store build (IOS-PORT-PLAN.md), so that fallback does not
// exist here. hasSecretCode() is therefore exactly "is LuminaKeychainKey.chatLockCode set",
// and the lock context-menu action (ChatContextMenus.swift) must refuse to lock a chat when
// it is false - locking with no code would be unrecoverable, matching desktop's
// HasSecretCode-gated window_peer_menu.cpp lock action.
public enum LuminaChatLock {
    private static var revealedFlag = false
    private static let changesPipe = ValuePipe<Void>()
    private static var settingsDisposable: Disposable?
    private static var subscribedToSettings = false

    // Process-global reveal, main thread only - mirrors desktop's Revealed()/Reveal().
    public static var revealed: Bool {
        return revealedFlag
    }

    // Membership test only, independent of the reveal flag - the context menu uses this to
    // choose between "Lock" and "Unlock".
    public static func isLocked(_ peerId: Int64) -> Bool {
        return LuminaSettingsCache.settings.lockedChats.contains(peerId)
    }

    // Whether a dedicated reveal code is configured. No vault fallback on iOS - see above.
    public static func hasSecretCode() -> Bool {
        let code = LuminaKeychain.get(LuminaKeychainKey.chatLockCode) ?? ""
        return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Should this conversation be hidden from the list and search right now? Fail-open:
    // revealed, or no code configured, or not locked all show the chat. Fine for a single
    // peer at a time (a context-menu action, say); a caller iterating many peers in one pass
    // should use hiddenPeerIdsSnapshot() instead - see its comment for why.
    public static func isHidden(_ peerId: Int64) -> Bool {
        if revealedFlag {
            return false
        }
        if !hasSecretCode() {
            return false
        }
        return isLocked(peerId)
    }

    // Precomputed once per pass, for callers that check many peers in a single pass -
    // chatListNodeEntriesForView() runs this over every row in the chat list on every
    // recompute, and hasSecretCode() reads the Keychain (a real IPC round trip to securityd,
    // unlike desktop/Android's equivalent, which is an in-memory flat_set/HashSet lookup
    // already loaded from the local prefs file). Doing that Keychain read once per recompute
    // instead of once per row is the difference between "unnoticeable" and "a real chat-list
    // scroll/redraw cost" on an account with many chats. nil means "nothing is hidden right
    // now" (revealed, no code, or nothing locked) - callers should treat nil exactly like an
    // empty set, just without allocating one.
    public static func hiddenPeerIdsSnapshot() -> Set<Int64>? {
        if revealedFlag {
            return nil
        }
        let locked = LuminaSettingsCache.settings.lockedChats
        if locked.isEmpty {
            return nil
        }
        if !hasSecretCode() {
            return nil
        }
        return Set(locked)
    }

    // Re-arms the folder for a fresh process. Never called automatically - `revealedFlag`
    // simply starts false on every launch, which is the re-arm.
    public static func reveal() {
        if !revealedFlag {
            revealedFlag = true
            changesPipe.putNext(())
        }
    }

    // Search-field helper: only attempts a reveal when it could actually do something (still
    // hidden, something is locked, a code exists), so an ordinary search never pays for the
    // string compare and a normal query is never mistaken for a reveal attempt. Mirrors
    // desktop's MaybeRevealFromQuery / Android's tryRevealFromSearch exactly, including the
    // trimmed comparison.
    @discardableResult
    public static func maybeReveal(fromQuery text: String) -> Bool {
        if revealedFlag {
            return false
        }
        if LuminaSettingsCache.settings.lockedChats.isEmpty {
            return false
        }
        let code = (LuminaKeychain.get(LuminaKeychainKey.chatLockCode) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty {
            return false
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != code {
            return false
        }
        reveal()
        return true
    }

    // Adds peerId to the locked set. Callers MUST check hasSecretCode() first (see the
    // context-menu action in ChatContextMenus.swift) - this function itself does not refuse,
    // to keep it a plain, side-effect-only setter like its desktop/Android counterparts.
    public static func lock(peerId: Int64, accountManager: AccountManager<TelegramAccountManagerTypes>) {
        let _ = updateLuminaSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            if !settings.lockedChats.contains(peerId) {
                settings.lockedChats.append(peerId)
            }
            return settings
        }).start()
    }

    public static func unlock(peerId: Int64, accountManager: AccountManager<TelegramAccountManagerTypes>) {
        let _ = updateLuminaSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            settings.lockedChats.removeAll(where: { $0 == peerId })
            return settings
        }).start()
    }

    // Fires when the locked set changes (lock/unlock, from any device state restore) OR the
    // reveal flag changes. ChatListNode.swift subscribes to this once to know when to
    // recompute chatListNodeEntriesForView(); everything else (the predicate above) is read
    // fresh on every call, so this signal only needs to say "something changed", never what.
    //
    // ensureSubscribed(accountManager:) is called lazily here too (mirroring
    // LuminaSettingsCache's own contract) so that a caller who only ever calls changes() -
    // never lock()/unlock(), which also touch the account manager - still gets notified when
    // lockedChats changes through some other path (e.g. a settings restore).
    public static func changes(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Void, NoError> {
        ensureSubscribedToSettings(accountManager: accountManager)
        return changesPipe.signal()
    }

    private static func ensureSubscribedToSettings(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        LuminaSettingsCache.ensureSubscribed(accountManager: accountManager)
        if subscribedToSettings {
            return
        }
        subscribedToSettings = true
        var previousLockedChats = LuminaSettingsCache.settings.lockedChats
        settingsDisposable = (LuminaSettingsCache.changes()
        |> deliverOnMainQueue).start(next: { settings in
            if settings.lockedChats != previousLockedChats {
                previousLockedChats = settings.lockedChats
                changesPipe.putNext(())
            }
        })
    }
}
