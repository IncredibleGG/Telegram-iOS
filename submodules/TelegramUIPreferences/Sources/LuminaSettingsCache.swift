import Foundation
import TelegramCore
import SwiftSignalKit

// The single, canonical synchronous mirror of LuminaSettings.swift's SharedData entry - the
// iOS analogue of desktop's Lumina::Settings::Instance() global and Android's static
// LuminaConfig.getBoolean(...) reads. Three feature buckets independently reached for this
// same pattern (a privacy enum, a utility singleton, and a currentLuminaSettings Atomic on
// AccountContext); this type is the unified result they were collapsed into.
//
// WHY THIS EXISTS. LuminaSettings itself is only reachable asynchronously, through
// updateLuminaSettingsInteractively()/accountManager.sharedData(keys:) Signals (see
// LuminaSettings.swift). Many Lumina render/format-time gates sit inside plain synchronous
// functions that cannot themselves await a Signal - a pure number formatter (NumericFormat.swift),
// a timestamp string builder (StringForMessageTimestampStatus.swift), a leaf sticker render
// node, an ItemList row-builder masking a phone number, a media-resource fetcher on a worker
// thread deciding whether to strip EXIF. Desktop hits the exact same shape of problem and
// solves it the same way: lumina_chat_lock.cpp's Current()/EnsureLoaded() and
// lumina_exif_strip.cpp's Enabled atomic are both a synchronous mirror of an async-loaded
// preference. This is that mirror, shared by every Lumina feature instead of each reinventing one.
//
// ONE PROCESS-WIDE INSTANCE, Atomic-backed (thread-safe reads from any queue, unlike a
// main-thread-only static). LuminaSettings is single-account-independent local device state
// (see LuminaSettings.swift), so a process-wide singleton is correct here - it is not
// per-account data, and this deliberately avoids adding a per-SharedAccountContextImpl
// AccountContext protocol requirement (which has multiple conformers).
//
// STARTED EXACTLY ONCE, from SharedAccountContextImpl.init (SharedAccountContext.swift), which
// exists before any UI. `start`/`ensureSubscribed` are idempotent (a single Bool check after
// the first call), so context-less render paths may still call ensureSubscribed defensively -
// after startup it is a no-op.
//
// FAIL OPEN. Until the first value arrives, `current()`/`settings` read back
// LuminaSettings.defaultSettings. Every default in that struct is already the safe/private-by-
// default value (stripPhotoMetadata = true, hideOwnPhone/lockedChats = off/empty, etc.), so a
// cold read is never less private than the shipped defaults - it just cannot yet reflect a
// change the user made moments ago.
public final class LuminaSettingsCache {
    public static let shared = LuminaSettingsCache()

    private let atomic = Atomic<LuminaSettings>(value: .defaultSettings)
    private let changesPipe = ValuePipe<LuminaSettings>()
    private var disposable: Disposable?
    private var started = false

    private init() {}

    // Idempotent. Called once at startup from SharedAccountContextImpl.init; also reachable via
    // the static ensureSubscribed(accountManager:) convenience for defensive call sites.
    public func start(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        if self.started {
            return
        }
        self.started = true
        self.disposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
            let _ = self.atomic.swap(settings)
            self.changesPipe.putNext(settings)
        })
    }

    // Thread-safe synchronous read of the latest snapshot.
    public func current() -> LuminaSettings {
        return self.atomic.with { $0 }
    }

    // MARK: - Static conveniences
    //
    // Thin sugar over `shared`, kept so field-gate call sites read naturally
    // (LuminaSettingsCache.settings.hideOwnPhone). There is exactly one instance and one
    // subscription behind all of these.

    public static var settings: LuminaSettings {
        return shared.current()
    }

    public static func ensureSubscribed(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        shared.start(accountManager: accountManager)
    }

    // Fires every time the underlying SharedData changes - lockedChats, stripPhotoMetadata,
    // hideOwnPhone, all of it. Consumers that only care about one field (LuminaChatLock, for
    // instance) map/filter this themselves rather than this type trying to be field-specific.
    public static func changes() -> Signal<LuminaSettings, NoError> {
        return shared.changesPipe.signal()
    }
}
