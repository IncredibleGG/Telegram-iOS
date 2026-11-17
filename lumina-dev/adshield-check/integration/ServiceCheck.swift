import Foundation
import SwiftSignalKit
import TelegramCore

// Integration checks for LuminaAdShieldService / LuminaAdShieldChatSession (the iOS plumbing around the engine):
// lifecycle (activation only while effectively on, ForgetAll on logout / full deactivation, startup purge of
// leftovers), per-group policy, debounced flush + flush on demand, the similar-image table (SPEC §5.4), deletions,
// "Not an ad", clear-local-data, the 7-day count and the session UI API (segments, expand, shown-unfolded, trial,
// the on-screen grace rules and the opening toast).
//
// Compiled together with the TelegramUIPreferences sources by run.sh in this directory (same module, so the test
// can use the internal init with a temp directory and a fixed key). NOT part of any Bazel target.

let testKey: [UInt8] = Array(0 ..< 16)

final class Tally {
    var ok = 0
    var bad = 0

    func check(_ cond: Bool, _ what: @autoclosure () -> String) {
        if cond {
            self.ok += 1
        } else {
            self.bad += 1
            print("FAIL \(what())")
        }
    }
}

let T = Tally()

/// Runs the main run loop until `cond` holds (completions are delivered on the main queue).
func waitUntil(_ timeout: Double = 5.0, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > deadline {
            return false
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

func drain(_ service: LuminaAdShieldService) {
    // Two hops: the queue runs everything enqueued so far, then the main queue delivers its results.
    service.flushAllSynchronously()
    let _ = waitUntil(0.05, { false })
}

func settings(global: Bool, dialogs: [LuminaSettings.DialogBoolValue] = [], dryRun: Bool = false, sensitivity: String = "standard") -> LuminaSettings {
    var s = LuminaSettings.defaultSettings
    s.adShieldEnabled = global
    s.adShieldDialogs = dialogs
    s.adShieldDryRun = dryRun
    s.adShieldSensitivity = sensitivity
    return s
}

func ad(_ id: Int32, sender: Int64, date: Int64) -> LuminaAdShieldObserveItem {
    return LuminaAdShieldObserveItem(input: LuminaAdShield.MessageInput(id: id, date: date, sender: LuminaAdShield.Sender(id: sender, username: "user_\(sender)"), text: "私聊我領取高額返利 t.me/+VipRoomX 名額有限"))
}

func photo(_ id: Int32, sender: Int64, date: Int64, photoId: Int64, thumb: UInt8, aspect: Int8 = 0) -> LuminaAdShieldObserveItem {
    return LuminaAdShieldObserveItem(input: LuminaAdShield.MessageInput(id: id, date: date, sender: LuminaAdShield.Sender(id: sender), media: LuminaAdShield.Media(kind: .photo, id: String(photoId))), photoThumbnail: Data([thumb]), photoAspect: aspect)
}

func files(_ root: String) -> [String] {
    guard let e = FileManager.default.enumerator(atPath: root) else {
        return []
    }
    var out: [String] = []
    while let p = e.nextObject() as? String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root + "/" + p, isDirectory: &isDir), !isDir.boolValue {
            out.append(p)
        }
    }
    return out.sorted()
}

@main
struct ServiceCheck {
    static func main() {
        let tmp = NSTemporaryDirectory() + "adshield-service-check-\(getpid())"
        try? FileManager.default.removeItem(atPath: tmp)
        let accountDir = tmp + "/account-1"
        try! FileManager.default.createDirectory(atPath: accountDir, withIntermediateDirectories: true)
        let root = accountDir + "/" + LuminaAdShieldService.rootDirectoryName
        let userId: Int64 = 777
        let chatId: Int64 = -1001234567890
        let peerId: Int64 = 0x0000_0002_0000_1234
        let now = Int64(Date().timeIntervalSince1970)

        // dHash stand-in: the first byte of the "thumbnail" picks a hash; 1 and 2 differ by 3 bits, 9 is far.
        let hashes: [UInt8: UInt64] = [1: 0xF0F0_F0F0_0F0F_0F0F, 2: 0xF0F0_F0F0_0F0F_0F08, 9: 0x0123_4567_89AB_CDEF]
        func makeService() -> LuminaAdShieldService {
            let service = LuminaAdShieldService(fs: LuminaAdShieldDiskFileSystem(), keyProvider: { testKey })
            service.start(accountManager: AccountManager<TelegramAccountManagerTypes>(), chatIdForPeer: { raw in
                return raw == peerId ? chatId : nil
            }, thumbnailHasher: { data in
                return data.first.flatMap { hashes[$0] }
            })
            return service
        }

        // ---- 1. Feature off: nothing happens, nothing is created --------------------------------------------
        do {
            let service = makeService()
            service.settingsLoaded(settings(global: false))
            service.updateAccounts([accountDir: userId])
            let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId, peerId: peerId, service: service)
            session.submit(context: LuminaAdShield.ChatContext(chatId: chatId), prepare: { [ad(1, sender: 1, date: now)] }, decideIds: [1])
            drain(service)
            T.check(!session.isActive && session.decisions.isEmpty, "off: inactive session gets no decisions")
            T.check(!FileManager.default.fileExists(atPath: root), "off: no root directory")
        }

        // ---- 2. Global on: observe, decide, debounce, flush -------------------------------------------------
        let ctx = LuminaAdShield.ChatContext(chatId: chatId, type: .supergroup, adminsKnown: true)
        do {
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([accountDir: userId])
            let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId, peerId: peerId, service: service)
            session.setActive(true, trialRun: false)
            session.submit(context: ctx, prepare: { [ad(10, sender: 1, date: now - 300), ad(11, sender: 2, date: now - 200), ad(12, sender: 3, date: now - 100)] }, decideIds: [10, 11, 12])
            T.check(waitUntil { session.hasDecided }, "on: decisions arrive")
            T.check(session.decision(10)?.state == .original, "on: first copy is the protected original (\(String(describing: session.decision(10)?.state)))")
            T.check(session.decision(11)?.fold == true && session.decision(12)?.fold == true, "on: later copies fold")
            T.check(session.isFoldCandidate(11) && !session.isFoldCandidate(10), "on: fold candidates")
            T.check(session.decision(12)?.occurrence == 3, "on: occurrence of the third copy is 3 (\(session.decision(12)?.occurrence ?? -1))")
            T.check(files(root).isEmpty, "on: nothing written before the 5 s debounce")
            T.check(waitUntil(8.0) { files(root).count == 1 }, "on: debounced flush writes one chat file")

            // segments: units in display order, a non-message unit breaks a run
            let segs = session.foldSegments(units: [[10], [11], [12], [], [13]])
            T.check(segs.count == 1 && segs[0].unitRange == 1 ..< 3 && segs[0].unitCount == 2 && segs[0].messageIds == [11, 12] && !segs[0].isExpanded, "segments: one run of two")
            session.expand([12])
            T.check(session.foldSegments(units: [[10], [11], [12]]).first?.isExpanded == true, "segments: expanding a member expands the run")
            session.collapse([11, 12])
            T.check(session.foldSegments(units: [[10], [11], [12]]).first?.isExpanded == false, "segments: collapse")
            let single = session.foldSegments(units: [[12]])
            T.check(single.count == 1 && single[0].occurrence == 3, "segments: single unit carries the occurrence")

            // a message shown unfolded stays unfolded
            session.noteDisplayed([10, 11])
            T.check(!session.isFoldCandidate(10) && session.isFoldCandidate(11), "shown: a fold candidate on screen stays a candidate")
            session.submit(context: ctx, prepare: { [ad(13, sender: 4, date: now - 50)] }, decideIds: [10, 11, 12, 13])
            T.check(waitUntil { session.decision(13) != nil }, "shown: new decision")
            session.noteDisplayed([13])
            T.check(session.decision(13)?.fold == true && session.isFoldCandidate(13), "shown: decided-folded message is still folded when reported")
            session.submit(context: ctx, prepare: { [ad(14, sender: 5, date: now - 40)] }, decideIds: [10, 11, 12, 13, 14])
            session.noteDisplayed([14]) // rendered before its decision arrives
            T.check(waitUntil { session.decision(14) != nil }, "shown: decision for 14")
            T.check(session.decision(14)?.fold == true && !session.isFoldCandidate(14), "shown: rendered before the decision → stays unfolded")

            // toast
            T.check(session.claimAllNewFoldedToast(newMessageIds: [11, 12]), "toast: first time")
            T.check(!session.claimAllNewFoldedToast(newMessageIds: [11, 12]), "toast: once per chat per run")
            T.check(!session.claimAllNewFoldedToast(newMessageIds: [10]), "toast: not when a new message is unfolded")

            // trial run: nothing folds, candidates are labelled
            session.setActive(true, trialRun: true)
            T.check(session.foldSegments(units: [[11], [12]]).isEmpty && session.isSuspected(11) && !session.isFoldCandidate(11), "trial: labels only")
            session.setActive(true, trialRun: false)

            // not an ad
            session.markNotAd(12, segmentIds: [11, 12])
            T.check(waitUntil { session.decision(12)?.state == .notAd }, "not ad: cluster unfolds (\(String(describing: session.decision(12)?.state)))")
            T.check(session.decision(11)?.fold == false, "not ad: whole cluster")

            // 7-day count after "not an ad" is 0
            var count = -1
            let _ = service.foldedCountLast7Days(basePath: accountDir, chatId: chatId).start(next: { count = $0 })
            T.check(waitUntil { count >= 0 } && count == 0, "count: 0 after not-an-ad (\(count))")

            // flush on demand
            service.flushAll()
            drain(service)
            T.check(files(root).count == 1, "flush: one file")

            // deletions of loaded chats
            session.submit(context: ctx, prepare: { [ad(20, sender: 6, date: now - 30)] }, decideIds: [20])
            T.check(waitUntil { session.decision(20) != nil }, "delete: setup")
            service.messagesDeleted(basePath: accountDir, byChat: [chatId: [20]], globalIds: [])
            var redecided = false
            session.redecide = { redecided = true }
            T.check(waitUntil { redecided }, "delete: the session is asked to re-decide")
            session.redecide = nil
            session.submit(context: ctx, prepare: { [] }, decideIds: [20])
            T.check(waitUntil { session.decision(20)?.state == .untracked }, "delete: deleted message is untracked")
        }

        // ---- 2b. Nothing vanishes under the reader (grace for history loads, none for arrivals), opening toast ----
        do {
            let chatId2: Int64 = -1005550001
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([accountDir: userId])
            var clockNow = 1000.0
            func open() -> LuminaAdShieldChatSession {
                let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId2, peerId: peerId + 1, service: service)
                session.clock = { clockNow }
                session.setActive(true, trialRun: false)
                return session
            }
            func post(_ id: Int32, sender: Int64, date: Int64, _ text: String) -> LuminaAdShieldObserveItem {
                return LuminaAdShieldObserveItem(input: LuminaAdShield.MessageInput(id: id, date: date, sender: LuminaAdShield.Sender(id: sender, username: "user_\(sender)"), text: text))
            }
            let textB = "限時優惠 加入 t.me/+DealsChannelZ 每天免費領紅包"
            let ctx2 = LuminaAdShield.ChatContext(chatId: chatId2, type: .supergroup, adminsKnown: true)

            // opening: messages on screen before the first decision pass may still fold; all new ones folded → toast
            let s = open()
            var toast: Bool?
            s.allNewFolded = { ids in toast = s.claimAllNewFoldedToast(newMessageIds: ids) }
            s.setOpeningUnread([101, 102], complete: true)
            s.noteObserved(historyIds: [100, 101, 102], arrivalIds: [])
            s.noteDisplayed([100, 101, 102])
            s.submit(context: ctx2, prepare: { [ad(100, sender: 11, date: now - 300), ad(101, sender: 12, date: now - 200), ad(102, sender: 13, date: now - 100)] }, decideIds: [100, 101, 102])
            T.check(waitUntil { s.hasDecided }, "opening: decisions")
            T.check(s.isFoldCandidate(101) && s.isFoldCandidate(102) && !s.isFoldCandidate(100), "opening: on screen before the first pass, still folds")
            T.check(toast == true, "opening: every new message folded → toast claimed (\(String(describing: toast)))")

            // arrival while the chat is open, drawn before its decision: stays unfolded until the next opening
            clockNow += 1.0
            s.noteObserved(historyIds: [], arrivalIds: [103])
            s.noteDisplayed([100, 103])
            s.submit(context: ctx2, prepare: { [ad(103, sender: 14, date: now - 50)] }, decideIds: [100, 101, 102, 103])
            T.check(waitUntil { s.decision(103) != nil }, "arrival: decision")
            T.check(s.decision(103)?.fold == true && !s.isFoldCandidate(103), "arrival: drawn before its decision → stays unfolded")

            // history load (newer page): drawn before its decision but within the grace → folds
            s.noteObserved(historyIds: [104], arrivalIds: [])
            s.noteDisplayed([100, 104])
            s.submit(context: ctx2, prepare: { [ad(104, sender: 15, date: now - 40)] }, decideIds: [100, 101, 102, 103, 104])
            T.check(waitUntil { s.decision(104) != nil }, "history grace: decision")
            T.check(s.isFoldCandidate(104), "history grace: a just-loaded message may still fold")

            // the grace ends after 3 s
            s.noteObserved(historyIds: [105], arrivalIds: [])
            clockNow += 4.0
            s.noteDisplayed([100, 105])
            s.submit(context: ctx2, prepare: { [ad(105, sender: 16, date: now - 30)] }, decideIds: [100, 101, 102, 103, 104, 105])
            T.check(waitUntil { s.decision(105) != nil }, "history grace end: decision")
            T.check(s.decision(105)?.fold == true && !s.isFoldCandidate(105), "history grace end: stays unfolded")

            // on screen with a settled decision that does not fold: a later fold (same sender re-posts) waits
            s.noteObserved(historyIds: [200], arrivalIds: [])
            s.noteDisplayed([200])
            let versionBefore = s.currentVersion
            s.submit(context: ctx2, prepare: { [post(200, sender: 21, date: now - 20, textB)] }, decideIds: [200])
            T.check(waitUntil { s.decision(200) != nil }, "settled: decision")
            T.check(s.isSettled(200) && s.decision(200)?.fold == false, "settled: a single copy does not fold (\(String(describing: s.decision(200)?.state)))")
            T.check(s.currentVersion == versionBefore, "version: a decision that draws nothing costs no redraw")
            s.submit(context: ctx2, prepare: { [post(201, sender: 22, date: now - 15, textB), post(202, sender: 23, date: now - 12, textB), post(203, sender: 21, date: now - 10, textB)] }, decideIds: [200, 201, 202, 203])
            T.check(waitUntil { s.decision(203) != nil && s.decision(200)?.fold == true }, "settled: the cluster triggers (\(String(describing: s.decision(200)?.state)))")
            T.check(!s.isFoldCandidate(200) && s.isFoldCandidate(201) && s.isFoldCandidate(203), "settled: the one on screen stays, the others fold")
            T.check(s.currentVersion > versionBefore, "version: new folds redraw")

            // a new opening: pending (admin list not loaded) is not settled; folds once it is known; no second toast
            let s2 = open()
            var toast2: Bool?
            s2.allNewFolded = { ids in toast2 = s2.claimAllNewFoldedToast(newMessageIds: ids) }
            s2.setOpeningUnread([101], complete: true)
            s2.noteObserved(historyIds: [100, 101, 102], arrivalIds: [])
            s2.noteDisplayed([100, 101, 102])
            s2.submit(context: LuminaAdShield.ChatContext(chatId: chatId2, type: .supergroup, adminsKnown: false), prepare: { [] }, decideIds: [100, 101, 102])
            T.check(waitUntil { s2.hasDecided }, "pending: decisions")
            T.check(s2.decision(101)?.state == .pending && !s2.isSettled(101) && !s2.isFoldCandidate(101) && toast2 == nil, "pending: not settled, no toast yet")
            s2.noteDisplayed([100, 101, 102])
            s2.submit(context: ctx2, prepare: { [] }, decideIds: [100, 101, 102])
            T.check(waitUntil { s2.decision(101)?.fold == true }, "pending → settled: decision")
            T.check(s2.isFoldCandidate(101) && s2.isFoldCandidate(102), "pending → settled: folds (opening grace)")
            T.check(toast2 == false, "toast: once per chat per app run (\(String(describing: toast2)))")

            // a trial run never pins what it labels... but a labelled message on screen stays when the trial ends
            let s3 = open()
            s3.setActive(true, trialRun: true)
            s3.submit(context: ctx2, prepare: { [] }, decideIds: [101, 102])
            T.check(waitUntil { s3.hasDecided }, "trial: decisions")
            clockNow += 10.0
            s3.noteDisplayed([101])
            s3.setActive(true, trialRun: false)
            T.check(!s3.isFoldCandidate(101) && s3.isFoldCandidate(102), "trial: a labelled message seen on screen stays unfolded after the trial")
        }

        // ---- 3. Reload from disk in a new process: the stored rows count ------------------------------------
        do {
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([accountDir: userId])
            let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId, peerId: peerId, service: service)
            session.setActive(true, trialRun: false)
            session.submit(context: ctx, prepare: { [] }, decideIds: [10, 11, 12, 13])
            T.check(waitUntil { session.hasDecided }, "reload: decisions")
            // 13 belongs to the cluster marked "not an ad" above, so it reloads as not_ad, not as untracked.
            T.check(session.decision(13)?.state == .notAd && session.decision(10)?.state != .untracked, "reload: rows survived the restart (\(String(describing: session.decision(13)?.state)))")
            T.check(session.decision(12)?.state == .notAd, "reload: not-an-ad record survived")

            // ---- similar images (SPEC §5.4) ----
            session.submit(context: ctx, prepare: {
                [photo(30, sender: 50, date: now - 3000, photoId: 9001, thumb: 1), photo(31, sender: 50, date: now - 2000, photoId: 9002, thumb: 2), photo(32, sender: 50, date: now - 1000, photoId: 9003, thumb: 1)]
            }, decideIds: [30, 31, 32])
            T.check(waitUntil { session.decision(32) != nil }, "image: decisions")
            T.check(session.decision(32)?.fold == true && session.decision(32)?.rule == .mediaSameSender, "image: third similar photo of one sender folds (\(String(describing: session.decision(32))))")
            session.submit(context: ctx, prepare: {
                [photo(40, sender: 60, date: now - 3000, photoId: 9101, thumb: 1), photo(41, sender: 61, date: now - 2000, photoId: 9102, thumb: 2), photo(42, sender: 62, date: now - 1000, photoId: 9103, thumb: 1)]
            }, decideIds: [40, 41, 42])
            T.check(waitUntil { session.decision(42) != nil }, "image: other senders decided")
            T.check(session.decision(42)?.fold == false, "image: different senders never match")
            session.submit(context: ctx, prepare: {
                [photo(50, sender: 70, date: now - 3000, photoId: 9201, thumb: 1), photo(51, sender: 70, date: now - 2000, photoId: 9202, thumb: 9), photo(52, sender: 70, date: now - 1000, photoId: 9203, thumb: 1, aspect: 2)]
            }, decideIds: [50, 51, 52])
            T.check(waitUntil { session.decision(52) != nil }, "image: dissimilar decided")
            T.check(session.decision(52)?.fold == false, "image: far hash / other aspect do not match")
            service.flushAll()
            drain(service)
            T.check(files(root).contains(where: { $0.hasSuffix(".img.bin") }), "image: table written next to the chat file")
        }

        // ---- 4. Image table file round trip + rejection ----------------------------------------------------
        do {
            let table = LuminaAdShieldImageTable()
            let a = table.resolve(sender: 1, dhash: 0xFF, aspect: 0, photoId: 5, date: now - 10, now: now)
            let b = table.resolve(sender: 1, dhash: 0xFE, aspect: 0, photoId: 6, date: now - 5, now: now)
            let again = table.resolve(sender: 1, dhash: 0xFE, aspect: 0, photoId: 6, date: now - 5, now: now)
            T.check(a == 5 && b == 5 && again == 5 && table.entries.count == 2, "table: maps to the earlier photo, stable on re-observe")
            let bytes = table.serialize(key: testKey, chatId: chatId)
            let back = LuminaAdShieldImageTable.deserialize(bytes, key: testKey, chatId: chatId)
            T.check(back?.entries == table.entries, "table: round trip")
            var bad = bytes
            bad[bad.count - 1] ^= 1
            T.check(LuminaAdShieldImageTable.deserialize(bad, key: testKey, chatId: chatId) == nil, "table: body hash")
            T.check(LuminaAdShieldImageTable.deserialize(bytes, key: Array(repeating: 1, count: 16), chatId: chatId) == nil, "table: other key")
            T.check(LuminaAdShieldImageTable.deserialize(bytes, key: testKey, chatId: chatId + 1) == nil, "table: other chat")
            T.check(LuminaAdShieldImageTable.deserialize(Array(bytes.dropLast()), key: testKey, chatId: chatId) == nil, "table: truncated")
            let old = LuminaAdShieldImageTable()
            let _ = old.resolve(sender: 1, dhash: 0xFF, aspect: 0, photoId: 5, date: now - 8 * 86400, now: now)
            T.check(old.entries.isEmpty, "table: older than 7 days is not recorded")
            let full = LuminaAdShieldImageTable()
            for i in 0 ..< 520 {
                let _ = full.resolve(sender: UInt64(i), dhash: UInt64(i), aspect: 0, photoId: Int64(i), date: now - 1000 + Int64(i), now: now)
            }
            T.check(full.entries.count == 500 && full.entries.first?.photoId == 20, "table: capped at 500, oldest dropped")
            T.check(luminaAdShieldDifferenceHash(gray9x8: Array(repeating: 7, count: 72)) == 0, "dhash: flat image")
            T.check(luminaAdShieldDifferenceHash(gray9x8: (0 ..< 72).map { UInt8(255 - ($0 % 9) * 10) }) == UInt64.max, "dhash: decreasing rows")
            T.check(luminaAdShieldDifferenceHash(gray9x8: []) == nil, "dhash: size")
            T.check(luminaAdShieldAspectBucket(width: 1000, height: 1000) == 0 && luminaAdShieldAspectBucket(width: 1280, height: 720) == 2 && luminaAdShieldAspectBucket(width: 720, height: 1280) == -2 && luminaAdShieldAspectBucket(width: 0, height: 5) == 0, "aspect buckets")
        }

        // ---- 5. Per-group policy: off in this group deletes its files; global off + group on keeps only it ----
        do {
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([accountDir: userId])
            drain(service)
            T.check(!files(root).isEmpty, "policy: files present")
            service.settingsLoaded(settings(global: true, dialogs: [LuminaSettings.DialogBoolValue(peerId: peerId, value: false)]))
            drain(service)
            T.check(files(root).isEmpty, "policy: 在此群關閉 removes the chat's files (\(files(root)))")
            let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId, peerId: peerId, service: service)
            session.setActive(true, trialRun: false)
            session.submit(context: ctx, prepare: { [ad(1, sender: 1, date: now)] }, decideIds: [1])
            drain(service)
            T.check(!session.hasDecided, "policy: a switched-off group is never observed")

            service.settingsLoaded(settings(global: false, dialogs: [LuminaSettings.DialogBoolValue(peerId: peerId, value: true)]))
            drain(service)
            session.submit(context: ctx, prepare: { [ad(1, sender: 1, date: now - 20), ad(2, sender: 2, date: now - 10)] }, decideIds: [1, 2])
            T.check(waitUntil { session.hasDecided }, "policy: 在此群開啟 with global off observes")
            service.flushAll()
            drain(service)
            T.check(files(root).count == 1, "policy: one file")

            // ---- 6. Fully inactive: ForgetAll + whole directory removed ----
            service.settingsLoaded(settings(global: false))
            drain(service)
            T.check(!FileManager.default.fileExists(atPath: root), "inactive: root removed")
            session.submit(context: ctx, prepare: { [ad(3, sender: 3, date: now)] }, decideIds: [3])
            drain(service)
            T.check(!FileManager.default.fileExists(atPath: root), "inactive: nothing recreated")
        }

        // ---- 7. Clear local data, logout, startup purge -----------------------------------------------------
        do {
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([accountDir: userId])
            let session = LuminaAdShieldChatSession(userId: userId, basePath: accountDir, chatId: chatId, peerId: peerId, service: service)
            session.setActive(true, trialRun: false)
            var reobserved = 0
            session.reobserveAll = { reobserved += 1 }
            session.submit(context: ctx, prepare: { [ad(1, sender: 1, date: now - 20), ad(2, sender: 2, date: now - 10)] }, decideIds: [1, 2])
            T.check(waitUntil { session.hasDecided }, "clear: setup")
            service.flushAll()
            drain(service)
            T.check(files(root).count == 1, "clear: file present")
            service.clearAllLocalData()
            drain(service)
            T.check(!FileManager.default.fileExists(atPath: root), "clear: root wiped")
            T.check(session.decisions.isEmpty && reobserved == 1, "clear: open sessions start over")
            session.submit(context: ctx, prepare: { [ad(1, sender: 1, date: now - 20)] }, decideIds: [1])
            T.check(waitUntil { session.hasDecided }, "clear: still on, a new store works")
            service.flushAll()
            drain(service)
            T.check(files(root).count == 1, "clear: new data written")

            // an orphan of another key and a temp file are purged at startup
            let stray = root + "/0000000000000000"
            try? FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stray + "/abc.bin", contents: Data(repeating: 0, count: 64))
            let acct = files(root).first!.split(separator: "/").first!
            FileManager.default.createFile(atPath: root + "/" + acct + "/x.bin.tmp", contents: Data([1]))
            let restarted = makeService()
            restarted.settingsLoaded(settings(global: true))
            restarted.updateAccounts([accountDir: userId])
            drain(restarted)
            T.check(files(root).count == 1, "startup: orphans and temp files purged (\(files(root)))")

            // logout: the account disappears
            restarted.updateAccounts([:])
            drain(restarted)
            T.check(files(root).isEmpty, "logout: ForgetAll removed the account's files")

            // startup while off removes leftovers of an earlier run
            try? FileManager.default.createDirectory(atPath: root + "/leftover", withIntermediateDirectories: true)
            let offService = makeService()
            offService.settingsLoaded(settings(global: false))
            offService.updateAccounts([accountDir: userId])
            drain(offService)
            T.check(!FileManager.default.fileExists(atPath: root), "startup off: leftovers removed")
            T.check(FileManager.default.fileExists(atPath: accountDir), "account directory itself untouched")
        }

        // ---- 8. Never recreates a missing account directory ------------------------------------------------
        do {
            let missing = tmp + "/account-2"
            let service = makeService()
            service.settingsLoaded(settings(global: true))
            service.updateAccounts([missing: 888])
            let session = LuminaAdShieldChatSession(userId: 888, basePath: missing, chatId: chatId, peerId: peerId, service: service)
            session.setActive(true, trialRun: false)
            session.submit(context: ctx, prepare: { [ad(1, sender: 1, date: now)] }, decideIds: [1])
            T.check(waitUntil { session.hasDecided }, "missing account dir: still decides in memory")
            service.flushAll()
            drain(service)
            T.check(!FileManager.default.fileExists(atPath: missing), "missing account dir: never created")
        }

        // ---- 9. Settings helpers --------------------------------------------------------------------------
        do {
            var s = settings(global: false)
            T.check(s.luminaAdShieldMode(peerId: 5) == .followDefault && !s.luminaAdShieldIsOn(peerId: 5) && !s.luminaAdShieldAnyOn, "mode: default")
            s = s.withLuminaAdShieldMode(.on, peerId: 5)
            T.check(s.luminaAdShieldMode(peerId: 5) == .on && s.luminaAdShieldIsOn(peerId: 5) && s.luminaAdShieldAnyOn, "mode: on")
            s = s.withLuminaAdShieldMode(.off, peerId: 5)
            T.check(s.adShieldDialogs.count == 1 && !s.luminaAdShieldIsOn(peerId: 5) && !s.luminaAdShieldAnyOn, "mode: off replaces")
            s.adShieldEnabled = true
            T.check(!s.luminaAdShieldIsOn(peerId: 5) && s.luminaAdShieldIsOn(peerId: 6), "mode: off beats global on")
            s = s.withLuminaAdShieldMode(.followDefault, peerId: 5)
            T.check(s.adShieldDialogs.isEmpty && s.luminaAdShieldIsOn(peerId: 5), "mode: follow default")
            T.check(LuminaSettings.defaultSettings.luminaAdShieldEngineSettings == LuminaAdShield.Settings(), "defaults match the engine defaults")
            let encoded = try? JSONEncoder().encode(s)
            let decoded = encoded.flatMap { try? JSONDecoder().decode(LuminaSettings.self, from: $0) }
            T.check(decoded == s, "settings: Codable round trip")
            let legacy = try? JSONDecoder().decode(LuminaSettings.self, from: Data("{}".utf8))
            T.check(legacy == LuminaSettings.defaultSettings && legacy?.adShieldEnabled == false, "settings: old blob decodes with the feature off")
        }

        try? FileManager.default.removeItem(atPath: tmp)
        print("SERVICE \(T.ok) ok, \(T.bad) failed")
        exit(T.bad == 0 ? 0 : 1)
    }
}
