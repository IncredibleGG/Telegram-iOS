import Foundation
import Security
import TelegramCore
import SwiftSignalKit

// LuminaGram「隱藏重複廣告」(hide repeated ads, AdShield): the iOS integration layer around the pure engine in
// LuminaAdShield.swift / LuminaAdShieldStore.swift / LuminaAdShieldAccount.swift (SPEC §8.4, §9).
//
// What lives here (no Postbox, no UI):
//  - per-group mode helpers on LuminaSettings (`adShieldDialogs`, Postbox raw peer id keys);
//  - `LuminaAdShieldService`: the process-wide owner of the AdShield queue, the install key (Keychain,
//    AfterFirstUnlockThisDeviceOnly), one `AccountStore` per logged-in account while the feature is effectively
//    on, the 5 s per-chat debounced flush, flush on background / terminate, purgeOrphans at startup, the 10 MiB
//    cap across accounts, ForgetAll on logout and when the feature becomes fully inactive, "Clear Local Data" and
//    the emergency wipe entry point, and the similar-image (dHash) table of SPEC §5.4;
//  - `LuminaAdShieldChatSession`: the main-thread (chatId, msgId) → Decision cache of one open chat plus the
//    runtime-only UI state (expanded segments, "already shown unfolded", trial run) the chat list reads.
//
// The platform side (TelegramUI/Sources/Lumina/LuminaAdShieldHook.swift) maps Postbox messages to
// `LuminaAdShield.MessageInput`, builds the `ChatContext`, decodes thumbnails and feeds sessions.
//
// THREADING. Everything under "AdShield queue" below runs only on `queue` (a serial SwiftSignalKit queue): the
// engine objects are not thread-safe by design. Everything under "main thread" runs only on the main queue. The
// UI thread never touches an engine object; it copies what a batch needs and reads published decisions.
//
// PRIVACY. Nothing here logs. Files hold only keyed hashes, ids, dates and flags (SPEC §8.3); the image table
// holds keyed sender hashes, 64-bit dHashes, aspect buckets, photo ids and dates (SPEC §5.4).
//
// FEATURE OFF (default): no key is read or created, no AccountStore exists, nothing is observed and no file or
// directory is created. Leftover data of a previous run is deleted once settings and accounts are known.

// MARK: - Per-group mode (LuminaSettings.adShieldDialogs)

public enum LuminaAdShieldChatMode: Equatable {
    /// Follow the global switch (no entry in adShieldDialogs).
    case followDefault
    /// 在此群開啟
    case on
    /// 在此群關閉
    case off
}

public extension LuminaSettings {
    /// The per-group mode of `peerId` (Postbox raw id, `PeerId.toInt64()`).
    func luminaAdShieldMode(peerId: Int64) -> LuminaAdShieldChatMode {
        for entry in self.adShieldDialogs where entry.peerId == peerId {
            return entry.value ? .on : .off
        }
        return .followDefault
    }

    /// Whether hiding repeated ads is in effect in the group `peerId`.
    func luminaAdShieldIsOn(peerId: Int64) -> Bool {
        switch self.luminaAdShieldMode(peerId: peerId) {
        case .on:
            return true
        case .off:
            return false
        case .followDefault:
            return self.adShieldEnabled
        }
    }

    /// The global switch is on or at least one group is switched on: the engine may run.
    var luminaAdShieldAnyOn: Bool {
        return self.adShieldEnabled || self.adShieldDialogs.contains(where: { $0.value })
    }

    var luminaAdShieldSensitivity: LuminaAdShield.Sensitivity {
        return LuminaAdShield.Sensitivity(rawValue: self.adShieldSensitivity) ?? .standard
    }

    var luminaAdShieldEngineSettings: LuminaAdShield.Settings {
        return LuminaAdShield.Settings(
            sensitivity: self.luminaAdShieldSensitivity,
            exemptContacts: self.adShieldExemptContacts,
            exemptBots: self.adShieldExemptBots,
            exemptReplies: self.adShieldExemptReplies,
            dryRun: self.adShieldDryRun
        )
    }

    /// A copy with the per-group mode of `peerId` replaced.
    func withLuminaAdShieldMode(_ mode: LuminaAdShieldChatMode, peerId: Int64) -> LuminaSettings {
        var result = self
        result.adShieldDialogs.removeAll(where: { $0.peerId == peerId })
        switch mode {
        case .followDefault:
            break
        case .on:
            result.adShieldDialogs.append(DialogBoolValue(peerId: peerId, value: true))
        case .off:
            result.adShieldDialogs.append(DialogBoolValue(peerId: peerId, value: false))
        }
        return result
    }
}

// MARK: - Shared texts

/// Texts used by both the settings page (SettingsUI) and the in-chat menu (TelegramUI).
public enum LuminaAdShieldTexts {
    /// The five lines of the first-enable explainer, as one bulleted text.
    public static func explainerText() -> String {
        let lines = [
            LuminaL10n.tr("Hidden only on this device; your other devices are not synced."),
            LuminaL10n.tr("Nothing is deleted or reported; other members and the sender see no change."),
            LuminaL10n.tr("Only hashes and message IDs are stored, never the text."),
            LuminaL10n.tr("You can tap to show them, or turn this off, at any time."),
            LuminaL10n.tr("Does not apply to private chats, channels or secret chats.")
        ]
        return lines.map { "• " + $0 }.joined(separator: "\n")
    }

    /// "最近 7 天已收合 N 則"
    public static func foldedLast7Days(_ count: Int) -> String {
        if count == 1 {
            return LuminaL10n.tr("1 message folded in the last 7 days")
        }
        return String(format: LuminaL10n.tr("%@ messages folded in the last 7 days"), "\(count)")
    }

    /// The label of a per-group mode, "跟隨預設（目前：開）" etc.
    public static func modeLabel(_ mode: LuminaAdShieldChatMode, globalOn: Bool) -> String {
        switch mode {
        case .followDefault:
            return globalOn ? LuminaL10n.tr("Follow Default (Currently On)") : LuminaL10n.tr("Follow Default (Currently Off)")
        case .on:
            return LuminaL10n.tr("On in This Group")
        case .off:
            return LuminaL10n.tr("Off in This Group")
        }
    }
}

// MARK: - Batch input

/// One message to observe, prepared by the platform on the AdShield queue.
public struct LuminaAdShieldObserveItem {
    public var input: LuminaAdShield.MessageInput
    /// Stripped thumbnail (`TelegramMediaImage.immediateThumbnailData`) of a directly attached photo (SPEC §5.4).
    public var photoThumbnail: Data?
    /// Aspect-ratio group of that photo (`luminaAdShieldAspectBucket`).
    public var photoAspect: Int8

    public init(input: LuminaAdShield.MessageInput, photoThumbnail: Data? = nil, photoAspect: Int8 = 0) {
        self.input = input
        self.photoThumbnail = photoThumbnail
        self.photoAspect = photoAspect
    }
}

/// Aspect-ratio group used by the similar-image rule (SPEC §5.4 "長寬比同組"): five groups, so two uploads of the same
/// picture always share one while a portrait banner never matches a landscape one.
public func luminaAdShieldAspectBucket(width: Int32, height: Int32) -> Int8 {
    if width <= 0 || height <= 0 {
        return 0
    }
    let ratio = Double(width) / Double(height)
    if ratio < 0.6 {
        return -2
    } else if ratio < 0.85 {
        return -1
    } else if ratio <= 1.18 {
        return 0
    } else if ratio <= 1.67 {
        return 1
    } else {
        return 2
    }
}

/// 64-bit difference hash of a 9×8 8-bit grayscale image (row-major, 72 bytes): bit 8·y + x is set when pixel
/// (x, y) is brighter than pixel (x + 1, y). nil for any other size.
public func luminaAdShieldDifferenceHash(gray9x8 pixels: [UInt8]) -> UInt64? {
    if pixels.count != 72 {
        return nil
    }
    var hash: UInt64 = 0
    var bit: UInt64 = 0
    for y in 0 ..< 8 {
        for x in 0 ..< 8 {
            if pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                hash |= UInt64(1) << bit
            }
            bit += 1
        }
    }
    return hash
}

// MARK: - Fold segments (UI stage helper)

/// A run of consecutive folded units of the rendered chat (SPEC §9.2, product spec C).
public struct LuminaAdShieldFoldSegment: Equatable {
    /// Indices into the `units` array given to `foldSegments(units:)`; the first one is the segment head, where the
    /// fold row goes. The others are hidden (never removed from the message list / model).
    public let unitRange: Range<Int>
    /// Every message id of the segment (all album members included).
    public let messageIds: [Int32]
    /// Number of folded units (an album counts once): the {n} of the fold row.
    public let unitCount: Int
    /// The segment contains a message replying to / mentioning me (Decision.replyToMe): use the "回覆你的" text.
    public let containsReplyToMe: Bool
    /// For a single-unit segment, Decision.occurrence (the {k} of "7 天內第 {k} 次出現"); 0 otherwise.
    public let occurrence: Int
    /// The reader tapped the fold row (or jumped to a member): show all members under a slim header.
    public let isExpanded: Bool
}

// MARK: - Similar-image table (SPEC §5.4)

/// Per chat: (H("sender", id), dHash, aspect group, photo id, mapped id, date), at most 500 entries and 7 days.
/// Stored next to the chat file as `<hex(H("chat", chatId))>.img.bin` with the engine's header layout (magic
/// "LGAS", keyCheck at byte 16), so purgeOrphans, the total cap, ForgetAll and wipeRoot cover it unchanged.
final class LuminaAdShieldImageTable {
    struct Entry: Equatable {
        var sender: UInt64
        var dhash: UInt64
        var aspect: Int8
        var photoId: Int64
        var mappedId: Int64
        var date: Int64
    }

    static let maxEntries = 500
    static let window: Int64 = 7 * 86400
    static let maxDistance = 8
    static let kind: UInt16 = 0x4D49 // "IM"
    static let version: UInt16 = 1
    static let headerSize = 40
    static let entrySize = 41

    var entries: [Entry] = []
    var dirty = false

    init() {
    }

    /// Drops entries older than 7 days (by message date).
    func prune(now: Int64) {
        let before = self.entries.count
        self.entries.removeAll(where: { now > $0.date + LuminaAdShieldImageTable.window })
        if self.entries.count != before {
            self.dirty = true
        }
    }

    /// The photo id this photo is observed with: the id an earlier similar photo of the same sender was observed
    /// with (Hamming ≤ 8, same aspect group, dates at most 7 days apart), else its own id. Re-observing the same
    /// photo returns the same answer.
    func resolve(sender: UInt64, dhash: UInt64, aspect: Int8, photoId: Int64, date: Int64, now: Int64) -> Int64 {
        self.prune(now: now)
        for e in self.entries where e.sender == sender && e.photoId == photoId {
            return e.mappedId
        }
        if date < 0 || date > LuminaAdShield.maxDate || now > date + LuminaAdShieldImageTable.window {
            return photoId
        }
        var best: Entry?
        var bestDistance = Int.max
        for e in self.entries where e.sender == sender && e.aspect == aspect {
            let gap = e.date > date ? e.date - date : date - e.date
            if gap > LuminaAdShieldImageTable.window {
                continue
            }
            let distance = (e.dhash ^ dhash).nonzeroBitCount
            if distance > LuminaAdShieldImageTable.maxDistance {
                continue
            }
            var better = false
            if let current = best {
                if distance != bestDistance {
                    better = distance < bestDistance
                } else if e.date != current.date {
                    better = e.date < current.date
                } else {
                    better = e.mappedId < current.mappedId
                }
            } else {
                better = true
            }
            if better {
                best = e
                bestDistance = distance
            }
        }
        let mapped = best?.mappedId ?? photoId
        self.entries.append(Entry(sender: sender, dhash: dhash, aspect: aspect, photoId: photoId, mappedId: mapped, date: date))
        while self.entries.count > LuminaAdShieldImageTable.maxEntries {
            var oldest = 0
            for i in 1 ..< self.entries.count {
                let a = self.entries[i]
                let b = self.entries[oldest]
                if a.date < b.date || (a.date == b.date && a.photoId < b.photoId) {
                    oldest = i
                }
            }
            self.entries.remove(at: oldest)
        }
        self.dirty = true
        return mapped
    }

    func serialize(key: [UInt8], chatId: Int64) -> [UInt8] {
        var body = LuminaAdShield.ByteWriter()
        for e in self.entries {
            body.u64(e.sender)
            body.u64(e.dhash)
            body.u8(UInt8(bitPattern: e.aspect))
            body.i64(e.photoId)
            body.i64(e.mappedId)
            body.i64(e.date)
        }
        var w = LuminaAdShield.ByteWriter()
        w.bytes.append(contentsOf: [0x4C, 0x47, 0x41, 0x53]) // "LGAS"
        w.u16(LuminaAdShieldImageTable.kind)
        w.u16(LuminaAdShieldImageTable.version)
        w.u32(UInt32(truncatingIfNeeded: self.entries.count))
        w.u32(0)
        w.u64(AdShieldTables.keyedHash(key16: key, tag: "check", payload: "LGAS"))
        w.u64(LuminaAdShield.khash(key, "chat", LuminaAdShield.dec(chatId)))
        w.u64(AdShieldTables.keyedHashBytes(key16: key, tag: "body", payload: body.bytes))
        w.bytes.append(contentsOf: body.bytes)
        return w.bytes
    }

    /// nil for anything that is not exactly a valid table of this key and chat (the caller starts empty and the
    /// next flush replaces the file).
    static func deserialize(_ data: [UInt8], key: [UInt8], chatId: Int64) -> LuminaAdShieldImageTable? {
        var r = LuminaAdShield.ByteReader(data)
        guard let magic = r.take(4), magic == [0x4C, 0x47, 0x41, 0x53],
              r.u16() == LuminaAdShieldImageTable.kind,
              r.u16() == LuminaAdShieldImageTable.version,
              let count = r.u32(),
              r.u32() == 0,
              r.u64() == AdShieldTables.keyedHash(key16: key, tag: "check", payload: "LGAS"),
              r.u64() == LuminaAdShield.khash(key, "chat", LuminaAdShield.dec(chatId)),
              let bodyHash = r.u64() else {
            return nil
        }
        if Int(count) > LuminaAdShieldImageTable.maxEntries || data.count != LuminaAdShieldImageTable.headerSize + Int(count) * LuminaAdShieldImageTable.entrySize {
            return nil
        }
        if AdShieldTables.keyedHashBytes(key16: key, tag: "body", payload: Array(data[LuminaAdShieldImageTable.headerSize...])) != bodyHash {
            return nil
        }
        let table = LuminaAdShieldImageTable()
        for _ in 0 ..< Int(count) {
            guard let sender = r.u64(), let dhash = r.u64(), let aspect = r.u8(), let photoId = r.i64(), let mappedId = r.i64(), let date = r.i64() else {
                return nil
            }
            if date < 0 || date > LuminaAdShield.maxDate {
                return nil
            }
            table.entries.append(Entry(sender: sender, dhash: dhash, aspect: Int8(bitPattern: aspect), photoId: photoId, mappedId: mappedId, date: date))
        }
        if !r.atEnd {
            return nil
        }
        return table
    }
}

// MARK: - Policy

/// Which chats may be observed (bot-API chat ids), derived from LuminaSettings on the main thread.
struct LuminaAdShieldPolicy: Equatable {
    var globalOn: Bool
    var onChats: Set<Int64>
    var offChats: Set<Int64>

    static let off = LuminaAdShieldPolicy(globalOn: false, onChats: [], offChats: [])

    var anyOn: Bool {
        return self.globalOn || !self.onChats.isEmpty
    }

    func allows(_ chatId: Int64) -> Bool {
        if self.onChats.contains(chatId) {
            return true
        }
        return self.globalOn && !self.offChats.contains(chatId)
    }
}

/// What a session asks the AdShield queue to do for one chat.
struct LuminaAdShieldBatch {
    let userId: Int64
    let basePath: String
    let chatId: Int64
    let context: LuminaAdShield.ChatContext
    let settings: LuminaAdShield.Settings
    let prepare: () -> [LuminaAdShieldObserveItem]
    let deletes: [Int32]
    let notAd: Int32?
    let decideIds: [Int32]
}

// MARK: - AdShield queue state

/// Owned by the AdShield queue; never touched from another thread.
private final class LuminaAdShieldQueueState {
    final class Account {
        let userId: Int64
        let basePath: String
        var store: LuminaAdShield.AccountStore?
        /// Loaded chats, least recently used first.
        var lru: [Int64] = []
        var dirty = Set<Int64>()
        var flushTimers: [Int64: SwiftSignalKit.Timer] = [:]
        var images: [Int64: LuminaAdShieldImageTable] = [:]
        /// The last ChatContext a session used, for the per-group 7-day count.
        var contexts: [Int64: LuminaAdShield.ChatContext] = [:]
        /// 7-day folded count per chat, valid while the store version, settings and hour stay the same.
        var foldedCounts: [Int64: (version: Int, settings: LuminaAdShield.Settings, hour: Int64, count: Int)] = [:]
        var startupDone = false
        var appliedPolicy: LuminaAdShieldPolicy?

        var root: String {
            return LuminaAdShield.joinPath(self.basePath, LuminaAdShieldService.rootDirectoryName)
        }

        init(userId: Int64, basePath: String) {
            self.userId = userId
            self.basePath = basePath
        }
    }

    var key: [UInt8]?
    /// By account directory (`Account.basePath`): two accounts of the same user id (production / test DC) never
    /// share a store.
    var accounts: [String: Account] = [:]
    var policy: LuminaAdShieldPolicy = .off
    var settingsKnown = false
    var accountsKnown = false
    var thumbnailHasher: ((Data) -> UInt64?)?
    var lastCapCheck: Double = 0
}

private final class LuminaAdShieldWeakSession {
    weak var value: LuminaAdShieldChatSession?

    init(_ value: LuminaAdShieldChatSession) {
        self.value = value
    }
}

// MARK: - Service

public final class LuminaAdShieldService {
    public static let shared = LuminaAdShieldService()

    /// Created inside an existing `account-<id>` directory only (SPEC §8.1, iOS); never with intermediates.
    public static let rootDirectoryName = "lumina-adshield"

    static let flushDelay: Double = 5.0
    static let capCheckInterval: Double = 60.0
    static let countWindow: Int64 = 7 * 86400

    // ---- AdShield queue ----
    private let queue = Queue(name: "org.luminagram.adshield", qos: .utility)
    private let fs: LuminaAdShieldFileSystem
    /// Tests only: replaces the Keychain key.
    private let keyProvider: (() -> [UInt8]?)?
    private let state = LuminaAdShieldQueueState()

    // ---- main thread ----
    private var started = false
    private var settingsDisposable: Disposable?
    private var chatIdForPeer: (Int64) -> Int64? = { _ in nil }
    private var accountPaths: [String: Int64]?
    private var sessions: [LuminaAdShieldWeakSession] = []
    private var toastShown = Set<String>()
    private let settingsValue = ValuePromise<LuminaSettings?>(nil, ignoreRepeated: true)
    /// nil until the first LuminaSettings value has been read from SharedData.
    public private(set) var settings: LuminaSettings?

    /// `shared` uses the disk and the Keychain; the conformance checker passes a temp directory and a fixed key.
    init(fs: LuminaAdShieldFileSystem = LuminaAdShieldDiskFileSystem(), keyProvider: (() -> [UInt8]?)? = nil) {
        self.fs = fs
        self.keyProvider = keyProvider
    }

    // MARK: Main thread: lifecycle

    /// Called once from SharedAccountContextImpl.init (main thread). `chatIdForPeer` maps a Postbox raw peer id
    /// (`PeerId.toInt64()`) of a group to its bot-API chat id (nil for anything else); `thumbnailHasher` turns
    /// an `immediateThumbnailData` into a dHash and runs on the AdShield queue.
    public func start(accountManager: AccountManager<TelegramAccountManagerTypes>, chatIdForPeer: @escaping (Int64) -> Int64?, thumbnailHasher: @escaping (Data) -> UInt64?) {
        if self.started {
            return
        }
        self.started = true
        self.chatIdForPeer = chatIdForPeer
        let state = self.state
        self.queue.async {
            state.thumbnailHasher = thumbnailHasher
        }
        self.settingsDisposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let self else {
                return
            }
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
            self.settingsLoaded(settings)
        })
    }

    /// A LuminaSettings value from SharedData (main thread): the AdShield queue learns the new policy first, then the
    /// observers hear about it, so their next batch always runs under the new policy.
    func settingsLoaded(_ settings: LuminaSettings) {
        self.settings = settings
        self.pushEnvironment()
        self.settingsValue.set(settings)
    }

    /// The logged-in accounts (main thread): account directory (`Account.basePath`, the existing `account-<id>`)
    /// → user id. An account that disappears is logged out / removed: its AdShield data is forgotten.
    public func updateAccounts(_ accounts: [String: Int64]) {
        if self.accountPaths == accounts {
            return
        }
        self.accountPaths = accounts
        self.pushEnvironment()
    }

    /// LuminaSettings as the service sees them (main thread; nil until loaded).
    public var settingsSignal: Signal<LuminaSettings?, NoError> {
        return self.settingsValue.get()
    }

    /// Whether the engine may run at all (main thread).
    public var isAnyOn: Bool {
        return self.settings?.luminaAdShieldAnyOn ?? false
    }

    /// The bot-API chat id of a group (Postbox raw peer id), nil for anything else.
    public func chatId(forPeer peerId: Int64) -> Int64? {
        return self.chatIdForPeer(peerId)
    }

    private func policy(for settings: LuminaSettings) -> LuminaAdShieldPolicy {
        var on = Set<Int64>()
        var off = Set<Int64>()
        for entry in settings.adShieldDialogs {
            guard let chatId = self.chatIdForPeer(entry.peerId) else {
                continue
            }
            if entry.value {
                on.insert(chatId)
            } else {
                off.insert(chatId)
            }
        }
        return LuminaAdShieldPolicy(globalOn: settings.adShieldEnabled, onChats: on, offChats: off)
    }

    private func pushEnvironment() {
        guard let settings = self.settings else {
            return
        }
        let policy = self.policy(for: settings)
        let accounts = self.accountPaths
        self.queue.async { [weak self] in
            self?.qApplyEnvironment(accounts: accounts, policy: policy, settingsKnown: true)
        }
    }

    // MARK: Main thread: data management

    /// Write every pending chat now (app goes to the background).
    public func flushAll() {
        self.queue.async { [weak self] in
            self?.qFlushAll()
        }
    }

    /// Same, but waits for the AdShield queue (app terminates).
    public func flushAllSynchronously() {
        self.queue.sync {
            self.qFlushAll()
        }
    }

    /// 清除本機資料: ForgetAll (whole AdShield directory) for every logged-in account, image tables included; open
    /// chats start over. The caller clears the per-group modes in LuminaSettings. If the feature stays on, new
    /// stores are created (a forgotten AccountStore refuses writes for good).
    public func clearAllLocalData() {
        self.queue.async { [weak self] in
            self?.qWipeAll(reactivate: true)
        }
        self.toastShown.removeAll()
        for session in self.liveSessions() {
            session.resetAfterDataCleared()
        }
    }

    /// Emergency wipe entry point for a future iOS panic wipe (iOS has none yet): wipeRoot of every account's
    /// AdShield directory (orphans and image tables included) and the per-group modes in LuminaSettings. Open chats
    /// start over; if the global switch is still on, the next batch creates fresh stores.
    public func panicWipe(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        self.queue.async { [weak self] in
            self?.qWipeAll(reactivate: false)
        }
        self.toastShown.removeAll()
        for session in self.liveSessions() {
            session.resetAfterDataCleared()
        }
        let _ = updateLuminaSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            settings.adShieldDialogs = []
            return settings
        }).start()
    }

    /// Main thread. Messages deleted in the account `basePath` (TelegramCore deletedMessages): channel and
    /// supergroup messages by bot-API chat id, plus account-global ids (basic groups). Applied to the chats loaded in
    /// memory (at most eight per account); rows of other chats age out (SPEC §8.2).
    public func messagesDeleted(basePath: String, byChat: [Int64: [Int32]], globalIds: [Int32]) {
        if !self.isAnyOn {
            return
        }
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            let changed = self.qDelete(basePath: basePath, byChat: byChat, globalIds: globalIds)
            if changed.isEmpty {
                return
            }
            Queue.mainQueue().async { [weak self] in
                guard let self else {
                    return
                }
                for session in self.liveSessions() where session.basePath == basePath && changed.contains(session.chatId) {
                    session.requestRedecide()
                }
            }
        }
    }

    /// 「最近 7 天已收合 N 則」: units of the chat the engine folds whose message date is within 7 days. 0 when the chat
    /// was not opened with the feature on in this run, when nothing is stored, or in trial run. Call on the main
    /// thread; the count is computed on the AdShield queue (cached per store version, settings and hour).
    public func foldedCountLast7Days(basePath: String, chatId: Int64) -> Signal<Int, NoError> {
        guard let settings = self.settings, settings.luminaAdShieldAnyOn, !settings.adShieldDryRun else {
            return .single(0)
        }
        let engineSettings = settings.luminaAdShieldEngineSettings
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putNext(0)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            self.queue.async { [weak self] in
                let count = self?.qFoldedCount(basePath: basePath, chatId: chatId, settings: engineSettings) ?? 0
                subscriber.putNext(count)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    // MARK: Main thread: sessions

    func register(_ session: LuminaAdShieldChatSession) {
        self.sessions.removeAll(where: { $0.value == nil })
        self.sessions.append(LuminaAdShieldWeakSession(session))
    }

    private func liveSessions() -> [LuminaAdShieldChatSession] {
        self.sessions.removeAll(where: { $0.value == nil })
        return self.sessions.compactMap { $0.value }
    }

    /// Once per chat per app run (product spec D).
    func claimAllFoldedToast(basePath: String, chatId: Int64) -> Bool {
        let key = basePath + "|" + String(chatId)
        if self.toastShown.contains(key) {
            return false
        }
        self.toastShown.insert(key)
        return true
    }

    func submit(_ batch: LuminaAdShieldBatch, completion: @escaping ([Int32: LuminaAdShield.Decision]?) -> Void) {
        self.queue.async { [weak self] in
            let result = self?.qProcess(batch)
            Queue.mainQueue().async {
                completion(result)
            }
        }
    }

    // MARK: AdShield queue

    private func qLoadKey() -> [UInt8]? {
        if let key = self.state.key {
            return key
        }
        if let keyProvider = self.keyProvider {
            self.state.key = keyProvider()
            return self.state.key
        }
        var key: [UInt8]?
        switch LuminaKeychain.getData(LuminaKeychainKey.adShieldKey) {
        case let .found(data):
            if data.count == 16 {
                key = [UInt8](data)
            } else {
                // A damaged item is a lost key: replace it; files of the old key are purged as orphans.
                LuminaKeychain.delete(LuminaKeychainKey.adShieldKey)
                key = self.qCreateKey()
            }
        case .notFound:
            key = self.qCreateKey()
        case .unavailable:
            // Before the first unlock: never generate a new key here (it would orphan every file). Retry later.
            key = nil
        }
        self.state.key = key
        return key
    }

    private func qCreateKey() -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        if status != errSecSuccess {
            return nil
        }
        let added = LuminaKeychain.addData(Data(bytes), forKey: LuminaKeychainKey.adShieldKey)
        if added == errSecSuccess {
            return bytes
        }
        if added == errSecDuplicateItem, case let .found(data) = LuminaKeychain.getData(LuminaKeychainKey.adShieldKey), data.count == 16 {
            return [UInt8](data)
        }
        return nil
    }

    private func qApplyEnvironment(accounts: [String: Int64]?, policy: LuminaAdShieldPolicy?, settingsKnown: Bool) {
        let s = self.state
        if let policy {
            s.policy = policy
        }
        if settingsKnown {
            s.settingsKnown = true
        }
        if let accounts {
            s.accountsKnown = true
            let removed = s.accounts.keys.filter { accounts[$0] == nil || accounts[$0] != s.accounts[$0]?.userId }
            for basePath in removed {
                if let account = s.accounts[basePath] {
                    // Logout / account removal: ForgetAll (timers first). Telegram deletes account-<id> itself.
                    self.qCancelTimers(account)
                    account.store?.forgetAll()
                    account.store = nil
                }
                s.accounts.removeValue(forKey: basePath)
            }
            for (basePath, userId) in accounts where s.accounts[basePath] == nil {
                s.accounts[basePath] = LuminaAdShieldQueueState.Account(userId: userId, basePath: basePath)
            }
        }
        if !s.settingsKnown || !s.accountsKnown {
            return
        }
        for basePath in s.accounts.keys.sorted() {
            guard let account = s.accounts[basePath] else {
                continue
            }
            if s.policy.anyOn {
                self.qActivate(account)
                self.qApplyPolicy(account)
            } else {
                self.qDeactivate(account)
            }
        }
        self.qEnforceCap(force: false)
    }

    /// Creates the account's store while the feature is effectively on (creating it touches no file); the first
    /// time in this run also purges orphans (files of a lost or replaced key, temp files).
    private func qActivate(_ account: LuminaAdShieldQueueState.Account) {
        if account.store != nil {
            return
        }
        guard let key = self.qLoadKey() else {
            return
        }
        account.store = LuminaAdShield.AccountStore(userId: account.userId, key: key, root: account.root, fs: self.fs)
        account.appliedPolicy = nil
        if !account.startupDone {
            account.startupDone = true
            LuminaAdShield.purgeOrphans(root: account.root, key: key, fs: self.fs)
        }
    }

    /// The feature is fully inactive (global off and no group on): ForgetAll and remove the whole AdShield
    /// directory of the account, including leftovers of an earlier run.
    private func qDeactivate(_ account: LuminaAdShieldQueueState.Account) {
        self.qCancelTimers(account)
        if let store = account.store {
            store.forgetAll(panic: true)
            account.store = nil
        } else if self.fs.isDirectory(account.root) {
            LuminaAdShield.wipeRoot(account.root, fs: self.fs)
        }
        account.startupDone = true
        self.qResetMemory(account)
    }

    private func qResetMemory(_ account: LuminaAdShieldQueueState.Account) {
        account.lru.removeAll()
        account.dirty.removeAll()
        account.images.removeAll()
        account.contexts.removeAll()
        account.foldedCounts.removeAll()
        account.appliedPolicy = nil
    }

    private func qCancelTimers(_ account: LuminaAdShieldQueueState.Account) {
        for (_, timer) in account.flushTimers {
            timer.invalidate()
        }
        account.flushTimers.removeAll()
    }

    private func qImageFileName(_ store: LuminaAdShield.AccountStore, _ chatId: Int64) -> String {
        return AdShieldTables.hex64(LuminaAdShield.khash(store.key, "chat", LuminaAdShield.dec(chatId))) + ".img.bin"
    }

    /// Chats that are not allowed any more (group switched off, or global off with other groups on): unload them
    /// and delete their files.
    private func qApplyPolicy(_ account: LuminaAdShieldQueueState.Account) {
        let policy = self.state.policy
        guard let store = account.store, account.appliedPolicy != policy else {
            return
        }
        account.appliedPolicy = policy
        for chatId in store.loadedChatIds where !policy.allows(chatId) {
            self.qDropChat(account, chatId)
        }
        let dir = LuminaAdShield.joinPath(account.root, store.dirName)
        guard let names = self.fs.contentsOfDirectory(dir) else {
            return
        }
        if policy.globalOn {
            var drop = Set<String>()
            for chatId in policy.offChats {
                drop.insert(store.chatFileName(chatId))
                drop.insert(self.qImageFileName(store, chatId))
            }
            for name in names where drop.contains(name) {
                self.fs.removeItem(LuminaAdShield.joinPath(dir, name))
            }
        } else {
            var keep = Set<String>()
            for chatId in policy.onChats {
                keep.insert(store.chatFileName(chatId))
                keep.insert(self.qImageFileName(store, chatId))
            }
            for name in names where !keep.contains(name) {
                self.fs.removeItem(LuminaAdShield.joinPath(dir, name))
            }
        }
    }

    private func qDropChat(_ account: LuminaAdShieldQueueState.Account, _ chatId: Int64) {
        account.flushTimers.removeValue(forKey: chatId)?.invalidate()
        account.dirty.remove(chatId)
        account.images.removeValue(forKey: chatId)
        account.contexts.removeValue(forKey: chatId)
        account.foldedCounts.removeValue(forKey: chatId)
        account.lru.removeAll(where: { $0 == chatId })
        guard let store = account.store else {
            return
        }
        store.unload(chatId)
        let dir = LuminaAdShield.joinPath(account.root, store.dirName)
        for name in [store.chatFileName(chatId), self.qImageFileName(store, chatId)] {
            let path = LuminaAdShield.joinPath(dir, name)
            if self.fs.fileExists(path) {
                self.fs.removeItem(path)
            }
        }
    }

    private func qChatFileExists(_ account: LuminaAdShieldQueueState.Account, _ chatId: Int64) -> Bool {
        guard let store = account.store else {
            return false
        }
        if store.loadedChatIds.contains(chatId) {
            return true
        }
        return self.fs.fileExists(LuminaAdShield.joinPath(LuminaAdShield.joinPath(account.root, store.dirName), store.chatFileName(chatId)))
    }

    /// Loads (or creates in memory) the chat, keeping at most `maxLoadedChats` chats per account in memory.
    private func qLoadChat(_ account: LuminaAdShieldQueueState.Account, _ chatId: Int64) -> LuminaAdShield.ChatStore? {
        guard let store = account.store else {
            return nil
        }
        let chat: LuminaAdShield.ChatStore
        do {
            chat = try store.chat(chatId)
        } catch {
            return nil
        }
        account.lru.removeAll(where: { $0 == chatId })
        account.lru.append(chatId)
        if account.images[chatId] == nil {
            var table: LuminaAdShieldImageTable?
            let path = LuminaAdShield.joinPath(LuminaAdShield.joinPath(account.root, store.dirName), self.qImageFileName(store, chatId))
            if self.fs.fileExists(path), let data = self.fs.readFile(path) {
                table = LuminaAdShieldImageTable.deserialize(data, key: store.key, chatId: chatId)
            }
            account.images[chatId] = table ?? LuminaAdShieldImageTable()
        }
        while account.lru.count > LuminaAdShield.maxLoadedChats {
            let victim = account.lru.removeFirst()
            self.qFlushChat(account, victim)
            store.unload(victim)
            account.images.removeValue(forKey: victim)
        }
        return chat
    }

    private func qScheduleFlush(_ account: LuminaAdShieldQueueState.Account, _ chatId: Int64) {
        account.dirty.insert(chatId)
        account.flushTimers.removeValue(forKey: chatId)?.invalidate()
        let basePath = account.basePath
        let timer = SwiftSignalKit.Timer(timeout: LuminaAdShieldService.flushDelay, repeat: false, completion: { [weak self] in
            guard let self, let account = self.state.accounts[basePath] else {
                return
            }
            self.qFlushChat(account, chatId)
            self.qEnforceCap(force: false)
        }, queue: self.queue)
        account.flushTimers[chatId] = timer
        timer.start()
    }

    private func qFlushChat(_ account: LuminaAdShieldQueueState.Account, _ chatId: Int64) {
        account.flushTimers.removeValue(forKey: chatId)?.invalidate()
        guard account.dirty.contains(chatId), let store = account.store else {
            return
        }
        account.dirty.remove(chatId)
        if !store.flush(chatId: chatId) {
            return
        }
        if let table = account.images[chatId], table.dirty {
            let path = LuminaAdShield.joinPath(LuminaAdShield.joinPath(account.root, store.dirName), self.qImageFileName(store, chatId))
            if self.fs.writeFileAtomically(path, bytes: table.serialize(key: store.key, chatId: chatId)) {
                table.dirty = false
            }
        }
    }

    private func qFlushAll() {
        for basePath in self.state.accounts.keys.sorted() {
            guard let account = self.state.accounts[basePath] else {
                continue
            }
            for chatId in account.dirty.sorted() {
                self.qFlushChat(account, chatId)
            }
        }
        self.qEnforceCap(force: false)
    }

    private func qWipeAll(reactivate: Bool) {
        for basePath in self.state.accounts.keys.sorted() {
            guard let account = self.state.accounts[basePath] else {
                continue
            }
            self.qCancelTimers(account)
            if let store = account.store {
                store.forgetAll(panic: true)
                account.store = nil
            } else if self.fs.isDirectory(account.root) {
                LuminaAdShield.wipeRoot(account.root, fs: self.fs)
            }
            account.startupDone = true
            self.qResetMemory(account)
        }
        if reactivate {
            self.qApplyEnvironment(accounts: nil, policy: nil, settingsKnown: false)
        }
    }

    /// SPEC §8.2 total cap over every account's AdShield directory (chat files and image tables), oldest file
    /// mtime first. A deleted file of a loaded chat unloads that chat.
    private func qEnforceCap(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force && now - self.state.lastCapCheck < LuminaAdShieldService.capCheckInterval {
            return
        }
        self.state.lastCapCheck = now
        var files: [(mtime: Int64, path: String, size: Int64)] = []
        var loaded: [String: (String, Int64)] = [:]
        for basePath in self.state.accounts.keys.sorted() {
            guard let account = self.state.accounts[basePath], let store = account.store else {
                continue
            }
            let dir = LuminaAdShield.joinPath(account.root, store.dirName)
            for chatId in store.loadedChatIds {
                loaded[LuminaAdShield.joinPath(dir, store.chatFileName(chatId))] = (basePath, chatId)
                loaded[LuminaAdShield.joinPath(dir, self.qImageFileName(store, chatId))] = (basePath, chatId)
            }
            guard let dirs = self.fs.contentsOfDirectory(account.root) else {
                continue
            }
            for d in dirs {
                let p = LuminaAdShield.joinPath(account.root, d)
                guard let names = self.fs.contentsOfDirectory(p) else {
                    continue
                }
                for name in names where LuminaAdShield.hasBinSuffix(name) {
                    let fp = LuminaAdShield.joinPath(p, name)
                    if let st = self.fs.fileSizeAndMtime(fp) {
                        files.append((st.mtimeNanos, fp, st.size))
                    }
                }
            }
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        if total <= LuminaAdShield.totalCapBytes {
            return
        }
        files.sort { a, b in
            if a.mtime != b.mtime {
                return a.mtime < b.mtime
            }
            return Array(a.path.utf8).lexicographicallyPrecedes(Array(b.path.utf8))
        }
        for f in files {
            if total <= LuminaAdShield.totalCapBytes {
                break
            }
            self.fs.removeItem(f.path)
            total -= f.size
            if let owner = loaded[f.path], let account = self.state.accounts[owner.0] {
                self.qDropChat(account, owner.1)
            }
        }
    }

    private func qProcess(_ batch: LuminaAdShieldBatch) -> [Int32: LuminaAdShield.Decision]? {
        let s = self.state
        if !s.settingsKnown || !s.policy.allows(batch.chatId) {
            return nil
        }
        var account = s.accounts[batch.basePath]
        if account == nil && !s.accountsKnown {
            let created = LuminaAdShieldQueueState.Account(userId: batch.userId, basePath: batch.basePath)
            s.accounts[batch.basePath] = created
            account = created
        }
        guard let account, account.userId == batch.userId else {
            return nil
        }
        self.qActivate(account)
        self.qApplyPolicy(account)
        guard let store = account.store, let chat = self.qLoadChat(account, batch.chatId) else {
            return nil
        }
        account.contexts[batch.chatId] = batch.context
        let now = Int64(Date().timeIntervalSince1970)
        var wrote = false
        let items = batch.prepare()
        if !items.isEmpty {
            let table = account.images[batch.chatId]
            for var item in items {
                if let thumbnail = item.photoThumbnail, let table, let hasher = s.thumbnailHasher, let media = item.input.media, media.kind == .photo, let idString = media.id, let photoId = Int64(idString), let dhash = hasher(thumbnail) {
                    let sender = LuminaAdShield.khash(store.key, "sender", LuminaAdShield.dec(item.input.sender.id))
                    let mapped = table.resolve(sender: sender, dhash: dhash, aspect: item.photoAspect, photoId: photoId, date: item.input.date, now: now)
                    if mapped != photoId {
                        item.input.media?.id = String(mapped)
                    }
                }
                do {
                    try chat.observe(item.input, context: batch.context, now: now)
                    wrote = true
                } catch {
                    return nil
                }
            }
        }
        if !batch.deletes.isEmpty {
            let tracked = batch.deletes.filter { chat.byMsg[$0] != nil }
            if !tracked.isEmpty {
                do {
                    try chat.delete(tracked, now: now)
                    wrote = true
                } catch {
                    return nil
                }
            }
        }
        if let notAd = batch.notAd {
            do {
                if try chat.markNotAd(notAd, context: batch.context, now: now) {
                    wrote = true
                }
            } catch {
                return nil
            }
        }
        if wrote {
            self.qScheduleFlush(account, batch.chatId)
        }
        var decisions: [Int32: LuminaAdShield.Decision] = [:]
        for id in batch.decideIds {
            decisions[id] = chat.decide(id, context: batch.context, settings: batch.settings, now: now)
        }
        return decisions
    }

    private func qDelete(basePath: String, byChat: [Int64: [Int32]], globalIds: [Int32]) -> Set<Int64> {
        guard let account = self.state.accounts[basePath], let store = account.store else {
            return []
        }
        let now = Int64(Date().timeIntervalSince1970)
        var changed = Set<Int64>()
        for chatId in store.loadedChatIds {
            var ids = byChat[chatId] ?? []
            // Basic groups (bot-API id -1 … -999999999999) number messages per account, as deletions report them.
            if chatId < 0 && chatId > -1_000_000_000_000 {
                ids.append(contentsOf: globalIds)
            }
            if ids.isEmpty {
                continue
            }
            guard let chat = try? store.chat(chatId) else {
                continue
            }
            let tracked = ids.filter { chat.byMsg[$0] != nil }
            if tracked.isEmpty {
                continue
            }
            do {
                try chat.delete(tracked, now: now)
            } catch {
                continue
            }
            changed.insert(chatId)
            self.qScheduleFlush(account, chatId)
        }
        return changed
    }

    private func qFoldedCount(basePath: String, chatId: Int64, settings: LuminaAdShield.Settings) -> Int {
        guard let account = self.state.accounts[basePath], account.store != nil, self.state.policy.allows(chatId), let context = account.contexts[chatId], self.qChatFileExists(account, chatId), let chat = self.qLoadChat(account, chatId) else {
            return 0
        }
        let now = Int64(Date().timeIntervalSince1970)
        let hour = now / 3600
        if let cached = account.foldedCounts[chatId], cached.version == chat.version, cached.settings == settings, cached.hour == hour {
            return cached.count
        }
        var units = Set<Int64>()
        for row in chat.rows where row.live && now <= row.date + LuminaAdShieldService.countWindow {
            if chat.decide(row.msgId, context: context, settings: settings, now: now).fold {
                units.insert(row.album != 0 ? row.album : -Int64(row.msgId))
            }
        }
        account.foldedCounts[chatId] = (chat.version, settings, hour, units.count)
        return units.count
    }
}

// MARK: - Chat session

/// One open chat (main thread only). Fed by the platform observer; read by the chat list (ChatHistoryEntriesForView)
/// through the UI API below. Exists only while the chat is open; everything in it is runtime state.
///
/// NOTHING VANISHES UNDER THE READER (product spec D). A message the chat list renders as a normal message is
/// "pinned" (it stays unfolded until the chat is opened again) when it is on screen and
///  - it has a settled decision (anything but `pending`) that does not fold it, or
///  - it has no settled decision yet and no grace.
/// Grace lets a message fold although it was drawn for a moment before its decision arrived: messages of a history
/// load (opening the chat, scrolling to older or newer history, a jump) for `historyGrace` seconds after they are
/// first observed, and every message during the opening phase (until the first decision pass without `pending`
/// decisions, at most `openingGrace` seconds; a supergroup's admin list may take that long). A message that arrives
/// while the chat is open gets no grace: if it was drawn before its decision, it stays unfolded until the next
/// opening. Messages off screen fold whenever their decision says so.
public final class LuminaAdShieldChatSession {
    public let userId: Int64
    public let basePath: String
    /// Bot-API chat id (`-100<id>` supergroups, `-<id>` basic groups).
    public let chatId: Int64
    /// Postbox raw peer id (`PeerId.toInt64()`), the key of the per-group mode.
    public let peerId: Int64

    /// The feature is in effect in this chat (and the chat is eligible).
    public private(set) var isActive = false
    /// 試運行: nothing is hidden; would-be folds are labelled.
    public private(set) var isTrialRun = false
    /// Published decisions for the loaded messages.
    public private(set) var decisions: [Int32: LuminaAdShield.Decision] = [:]
    /// The first decision pass after activation has arrived.
    public private(set) var hasDecided = false

    /// Pinned: rendered unfolded while on screen, never folded again in this session.
    private var shownUnfolded = Set<Int32>()
    private var expanded = Set<Int32>()
    /// The message ids the chat list renders on screen now (noteDisplayed).
    private var displayed = Set<Int32>()
    /// History-load grace deadlines (absolute time), and the messages that arrived while the chat was open.
    private var graceUntil: [Int32: Double] = [:]
    private var arrivals = Set<Int32>()
    private var openingUntil: Double = 0
    private var openingEnded = true
    /// Unread incoming messages when the chat was opened (nil = not captured), for the all-folded toast.
    private var openingUnread: [Int32]?
    private var openingUnreadChecked = false
    private var generation = 0
    private var versionCounter = 0
    private let versionValue = ValuePromise<Int>(0, ignoreRepeated: true)
    private var lastContext: LuminaAdShield.ChatContext?
    private var lastDecideIds: [Int32] = []
    private let service: LuminaAdShieldService

    /// Set by the observer: observe every loaded message again (local data was cleared).
    public var reobserveAll: (() -> Void)?
    /// Set by the observer: decide the loaded messages again (the store changed outside a batch).
    public var redecide: (() -> Void)?
    /// Set by the chat list: on the first settled decision pass after opening, when every new (unread incoming)
    /// message folds. It shows the toast once it can (the chat on screen), after `claimAllNewFoldedToast` (once per
    /// chat per app run, and re-checked then).
    public var allNewFolded: ((_ newMessageIds: [Int32]) -> Void)?

    static let historyGrace: Double = 3.0
    static let openingGrace: Double = 8.0
    /// Clock of the grace rules (absolute time); replaceable for tests.
    var clock: () -> Double = { return Date().timeIntervalSinceReferenceDate }

    public convenience init(userId: Int64, basePath: String, chatId: Int64, peerId: Int64) {
        self.init(userId: userId, basePath: basePath, chatId: chatId, peerId: peerId, service: .shared)
    }

    init(userId: Int64, basePath: String, chatId: Int64, peerId: Int64, service: LuminaAdShieldService) {
        self.userId = userId
        self.basePath = basePath
        self.chatId = chatId
        self.peerId = peerId
        self.service = service
        service.register(self)
    }

    // MARK: UI API (main thread)

    /// Bumps whenever anything the chat list renders from changes (a fold / label / fold-row text, expansion,
    /// activity, trial run); a new decision that changes nothing drawn does not bump it. The chat history combine
    /// carries it inside an existing slot (no 27th signal).
    public var version: Signal<Int, NoError> {
        return self.versionValue.get()
    }

    public var currentVersion: Int {
        return self.versionCounter
    }

    public func decision(_ messageId: Int32) -> LuminaAdShield.Decision? {
        return self.decisions[messageId]
    }

    /// The message is to be folded (feature on, not trial run, engine says fold, and it was not already shown
    /// unfolded in this session). Whether its segment is expanded is a segment property (`foldSegments`).
    public func isFoldCandidate(_ messageId: Int32) -> Bool {
        if !self.isActive || self.isTrialRun || self.shownUnfolded.contains(messageId) {
            return false
        }
        return self.decisions[messageId]?.fold ?? false
    }

    /// Trial run: label the message 「疑似重複廣告」.
    public func isSuspected(_ messageId: Int32) -> Bool {
        if !self.isActive || !self.isTrialRun {
            return false
        }
        return self.decisions[messageId]?.fold ?? false
    }

    /// Segments of consecutive folded units. `units` are the rendered message entries in display order, one array
    /// of message ids per entry (an album entry lists all its messages; a non-message entry passes [] and breaks a
    /// segment). Empty in trial run or while inactive.
    public func foldSegments(units: [[Int32]]) -> [LuminaAdShieldFoldSegment] {
        if !self.isActive || self.isTrialRun || self.decisions.isEmpty {
            return []
        }
        var result: [LuminaAdShieldFoldSegment] = []
        var i = 0
        while i < units.count {
            if !self.unitFolds(units[i]) {
                i += 1
                continue
            }
            var j = i
            var ids: [Int32] = []
            while j < units.count && self.unitFolds(units[j]) {
                ids.append(contentsOf: units[j])
                j += 1
            }
            let unitCount = j - i
            var occurrence = 0
            if unitCount == 1 {
                for id in units[i] {
                    if let d = self.decisions[id], d.fold {
                        occurrence = d.occurrence
                        break
                    }
                }
            }
            result.append(LuminaAdShieldFoldSegment(
                unitRange: i ..< j,
                messageIds: ids,
                unitCount: unitCount,
                containsReplyToMe: ids.contains(where: { self.decisions[$0]?.replyToMe ?? false }),
                occurrence: occurrence,
                isExpanded: ids.contains(where: { self.expanded.contains($0) })
            ))
            i = j
        }
        return result
    }

    private func unitFolds(_ ids: [Int32]) -> Bool {
        if ids.isEmpty {
            return false
        }
        var any = false
        for id in ids {
            if self.isFoldCandidate(id) {
                any = true
            } else if self.decisions[id] != nil || self.shownUnfolded.contains(id) {
                return false
            }
        }
        return any
    }

    public func isExpanded(_ messageIds: [Int32]) -> Bool {
        return messageIds.contains(where: { self.expanded.contains($0) })
    }

    /// Tap on the fold row, or a jump / reply to a member: show the whole segment (runtime only).
    public func expand(_ messageIds: [Int32]) {
        let before = self.expanded.count
        self.expanded.formUnion(messageIds)
        if self.expanded.count != before {
            self.bump()
        }
    }

    /// 「收合」 on the expanded header: fold the segment again.
    public func collapse(_ messageIds: [Int32]) {
        let before = self.expanded.count
        self.expanded.subtract(messageIds)
        if self.expanded.count != before {
            self.bump()
        }
    }

    /// 「不是廣告」: remember the cluster of `messageId` for 90 days (SPEC §6.4) and unfold the segment at once.
    public func markNotAd(_ messageId: Int32, segmentIds: [Int32]) {
        self.expand(segmentIds + [messageId])
        guard self.isActive, let context = self.lastContext else {
            return
        }
        self.submit(context: context, prepare: { return [] }, notAd: messageId, decideIds: self.lastDecideIds)
    }

    /// The chat list reports the message ids it renders on screen now (message rows only, never the hidden members of
    /// a folded segment). Pins what must not vanish (see the class comment). No version bump: these messages already
    /// render unfolded; this only keeps later decisions from folding them while the chat stays open.
    public func noteDisplayed(_ messageIds: [Int32]) {
        self.displayed = Set(messageIds)
        if !self.isActive {
            return
        }
        let now = self.clock()
        for id in messageIds where !self.shownUnfolded.contains(id) && !self.isFoldCandidate(id) {
            if self.isSettled(id) || !self.hasGrace(id, now: now) {
                self.shownUnfolded.insert(id)
            }
        }
    }

    /// The message has a decision other than `pending` (the admin list is known for it).
    public func isSettled(_ messageId: Int32) -> Bool {
        guard let decision = self.decisions[messageId] else {
            return false
        }
        return decision.state != .pending
    }

    private func hasGrace(_ messageId: Int32, now: Double) -> Bool {
        if self.arrivals.contains(messageId) {
            return false
        }
        if !self.openingEnded && now < self.openingUntil {
            return true
        }
        if let until = self.graceUntil[messageId] {
            return now < until
        }
        return false
    }

    /// 「這次的新訊息都是重複廣告，已收合」: true at most once per chat per app run, when every new message is folded.
    public func claimAllNewFoldedToast(newMessageIds: [Int32]) -> Bool {
        if !self.isActive || self.isTrialRun || newMessageIds.isEmpty {
            return false
        }
        if !newMessageIds.allSatisfy({ self.isFoldCandidate($0) }) {
            return false
        }
        return self.service.claimAllFoldedToast(basePath: self.basePath, chatId: self.chatId)
    }

    // MARK: Observer API (main thread)

    /// Messages observed for the first time: `historyIds` came with a history load (they get the history grace),
    /// `arrivalIds` arrived while the chat was open (no grace).
    public func noteObserved(historyIds: [Int32], arrivalIds: [Int32]) {
        if !self.isActive {
            return
        }
        let until = self.clock() + LuminaAdShieldChatSession.historyGrace
        for id in historyIds where self.graceUntil[id] == nil {
            self.graceUntil[id] = until
        }
        self.arrivals.formUnion(arrivalIds)
        if self.graceUntil.count > 4000 {
            let now = self.clock()
            self.graceUntil = self.graceUntil.filter { $0.value > now }
        }
    }

    /// The unread incoming messages of the chat when it was opened (keyword-filtered), once per activation. `complete`
    /// is false when the opening view does not reach the newest message: then there is no all-folded toast.
    public func setOpeningUnread(_ messageIds: [Int32], complete: Bool) {
        if !self.isActive || self.openingUnread != nil {
            return
        }
        self.openingUnread = complete ? messageIds : []
        self.checkOpeningToast()
    }

    /// The feature became (in)effective in this chat. Deactivation drops every decision and runtime state.
    public func setActive(_ active: Bool, trialRun: Bool) {
        if active == self.isActive && trialRun == self.isTrialRun {
            return
        }
        if !active {
            self.generation += 1
            self.decisions.removeAll()
            self.shownUnfolded.removeAll()
            self.expanded.removeAll()
            self.graceUntil.removeAll()
            self.arrivals.removeAll()
            self.openingUnread = nil
            self.openingUnreadChecked = false
            self.openingEnded = true
            self.hasDecided = false
            self.lastContext = nil
            self.lastDecideIds = []
        } else if !self.isActive {
            // Becoming effective: the opening phase starts (every message on screen may still fold for a moment).
            self.openingUntil = self.clock() + LuminaAdShieldChatSession.openingGrace
            self.openingEnded = false
        }
        self.isActive = active
        self.isTrialRun = trialRun
        self.bump()
    }

    /// Hands one batch to the AdShield queue: `prepare` (run there) maps the messages to observe; `decideIds` are
    /// all loaded message ids, re-decided after the writes.
    public func submit(context: LuminaAdShield.ChatContext, prepare: @escaping () -> [LuminaAdShieldObserveItem], deletes: [Int32] = [], notAd: Int32? = nil, decideIds: [Int32]) {
        guard self.isActive, let settings = self.service.settings else {
            return
        }
        self.lastContext = context
        self.lastDecideIds = decideIds
        let generation = self.generation
        let batch = LuminaAdShieldBatch(
            userId: self.userId,
            basePath: self.basePath,
            chatId: self.chatId,
            context: context,
            settings: settings.luminaAdShieldEngineSettings,
            prepare: prepare,
            deletes: deletes,
            notAd: notAd,
            decideIds: decideIds
        )
        self.service.submit(batch, completion: { [weak self] decisions in
            guard let self, let decisions, generation == self.generation, self.isActive else {
                return
            }
            self.apply(decisions)
        })
    }

    func apply(_ decisions: [Int32: LuminaAdShield.Decision]) {
        let now = self.clock()
        var changed = false
        var anyPending = false
        for (id, decision) in decisions {
            if decision.state == .pending {
                anyPending = true
            }
            if self.decisions[id] == decision {
                continue
            }
            let before = self.renderKey(id)
            // On screen as a normal message and about to fold: it stays unless it is still in its grace.
            if decision.fold && !self.isTrialRun && self.displayed.contains(id) && !self.shownUnfolded.contains(id) && !self.isFoldCandidate(id) {
                if self.isSettled(id) || !self.hasGrace(id, now: now) {
                    self.shownUnfolded.insert(id)
                }
            }
            self.decisions[id] = decision
            if self.renderKey(id) != before {
                changed = true
            }
        }
        self.hasDecided = true
        if !anyPending {
            self.openingEnded = true
        }
        if changed {
            self.bump()
        }
        self.checkOpeningToast()
    }

    private struct RenderKey: Equatable {
        var folds: Bool
        var suspected: Bool
        var occurrence: Int
        var replyToMe: Bool
    }

    /// What the chat list draws from a message's decision: a new decision that changes none of it (most new messages)
    /// does not bump the version, so it costs the chat list no redraw.
    private func renderKey(_ messageId: Int32) -> RenderKey {
        let folds = self.isFoldCandidate(messageId)
        let decision = self.decisions[messageId]
        return RenderKey(folds: folds, suspected: self.isSuspected(messageId), occurrence: folds ? (decision?.occurrence ?? 0) : 0, replyToMe: folds ? (decision?.replyToMe ?? false) : false)
    }

    /// The all-folded toast, evaluated once: on the first pass where every opening-unread message has a settled
    /// decision (or when the opening phase ends without one).
    private func checkOpeningToast() {
        guard self.isActive, !self.openingUnreadChecked, self.hasDecided, let ids = self.openingUnread else {
            return
        }
        if !ids.allSatisfy({ self.isSettled($0) }) && !(self.openingEnded || self.clock() >= self.openingUntil) {
            return
        }
        self.openingUnreadChecked = true
        if ids.isEmpty || self.isTrialRun || !ids.allSatisfy({ self.isFoldCandidate($0) }) {
            return
        }
        self.allNewFolded?(ids)
    }

    func resetAfterDataCleared() {
        self.generation += 1
        self.decisions.removeAll()
        self.shownUnfolded.removeAll()
        self.expanded.removeAll()
        self.graceUntil.removeAll()
        self.openingUnreadChecked = true
        self.hasDecided = false
        self.bump()
        self.reobserveAll?()
    }

    func requestRedecide() {
        if self.isActive {
            self.redecide?()
        }
    }

    private func bump() {
        self.versionCounter += 1
        self.versionValue.set(self.versionCounter)
    }
}
