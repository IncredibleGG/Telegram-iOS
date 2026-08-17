import Foundation
import TelegramCore
import SwiftSignalKit

// A synchronous, main-thread-only snapshot of LuminaSettings.swift's SharedData, plus a
// change signal - the iOS analogue of desktop's Lumina::Settings::Instance() global and
// Android's static LuminaConfig.getBoolean(...) reads.
//
// WHY THIS EXISTS. LuminaSettings itself is only reachable asynchronously, through
// updateLuminaSettingsInteractively()/accountManager.sharedData(keys:) Signals (see
// LuminaSettings.swift). Several Lumina render-time gates sit inside plain synchronous
// functions that cannot themselves await a Signal - chatListNodeEntriesForView() deciding
// whether a row is hidden, an ItemList row-builder deciding whether to mask a phone number,
// a media-resource fetcher on a worker thread deciding whether to strip EXIF. Desktop hits
// the exact same shape of problem and solves it the same way: lumina_chat_lock.cpp's
// Current()/EnsureLoaded() and lumina_exif_strip.cpp's Enabled atomic are both a synchronous
// mirror of an async-loaded preference, refreshed opportunistically. This is that mirror,
// shared by every Lumina feature instead of each reinventing one.
//
// LAZY AND IDEMPOTENT, like desktop's EnsureLoaded(): call ensureSubscribed(accountManager:)
// from every call site that reads `settings` (cheap after the first call - it is a single
// Bool check), exactly as lumina_chat_lock.cpp calls EnsureLoaded() defensively in every
// accessor rather than requiring one designated startup call. The first caller anywhere in
// the app starts the subscription.
//
// FAIL OPEN. Until the first value arrives from the account manager, and for any account
// manager this was never subscribed against, `settings` reads back LuminaSettings.defaultSettings.
// Every default in that struct is already the safe/private-by-default value (stripPhotoMetadata
// = true, hideOwnPhone/lockedChats = off/empty, etc.), so a cold read is never less private
// than the shipped defaults - it just cannot yet reflect a change the user made moments ago.
//
// Main thread only: `settings`, `ensureSubscribed`, and the delivery of `changes()` all
// assume the main queue, matching every other Lumina global in this codebase.
public enum LuminaSettingsCache {
    private static var current: LuminaSettings = .defaultSettings
    private static var subscribed = false
    private static let changesPipe = ValuePipe<LuminaSettings>()
    private static var disposable: Disposable?

    public static var settings: LuminaSettings {
        return current
    }

    public static func ensureSubscribed(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        if subscribed {
            return
        }
        subscribed = true
        disposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> map { sharedData -> LuminaSettings in
            return sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
        }
        |> deliverOnMainQueue).start(next: { value in
            current = value
            changesPipe.putNext(value)
        })
    }

    // Fires every time the underlying SharedData changes - lockedChats, stripPhotoMetadata,
    // hideOwnPhone, all of it. Consumers that only care about one field (LuminaChatLock, for
    // instance) map/filter this themselves rather than this type trying to be field-specific.
    public static func changes() -> Signal<LuminaSettings, NoError> {
        return changesPipe.signal()
    }
}
