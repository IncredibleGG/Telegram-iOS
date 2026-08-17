import Foundation
import TelegramCore
import SwiftSignalKit

// LuminaGram: synchronous snapshot of LuminaSettings for hot-path reads.
//
// Several Utility & interface features (precise counts, sticker size, seconds in
// timestamps, stories-off) need a LuminaSettings flag from deep inside pure formatting
// functions or leaf render nodes (NumericFormat.swift, ChatMessageStickerItemNode,
// StringForMessageTimestampStatus.swift, ChatListControllerNode, AvatarNode) that only
// have synchronous call paths - no AccountContext-free way to `await` a Signal there.
//
// This mirrors an established pattern already in this codebase: SharedAccountContext.swift
// keeps `currentChatSettings: Atomic<ChatSettings>` and `immediateExperimentalUISettingsValue:
// Atomic<ExperimentalUISettings>`, both populated once via `accountManager.sharedData(keys:)`
// and read synchronously everywhere else. LuminaSettingsCache does the same thing for
// LuminaSettings, but as a standalone singleton instead of a new AccountContext protocol
// requirement - that keeps this additive (no change to the AccountContext conformance
// surface, which has multiple implementations) at the cost of one process-wide instance
// instead of one per SharedAccountContextImpl. That is fine here: LuminaSettings is
// single-account-independent local device state (see LuminaSettings.swift), not
// per-account data.
//
// NOTE for integration: if another feature bucket also needs a synchronous LuminaSettings
// read and is tempted to add its own copy of this pattern, prefer reusing this cache
// instead - see the wiring note in this fork's task report for the one call site
// (SharedAccountContext.swift init) that starts it.
public final class LuminaSettingsCache {
    public static let shared = LuminaSettingsCache()

    private let atomic = Atomic<LuminaSettings>(value: .defaultSettings)
    private var disposable: Disposable?
    private var started = false

    private init() {}

    public func start(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        if self.started {
            return
        }
        self.started = true
        self.disposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
            let _ = self?.atomic.swap(settings)
        })
    }

    public func current() -> LuminaSettings {
        return self.atomic.with { $0 }
    }
}
