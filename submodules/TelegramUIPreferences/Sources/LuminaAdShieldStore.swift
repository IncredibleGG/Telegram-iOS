import Foundation

// LuminaGram AdShield: per-chat store (SPEC §6, §8), port of `ChatStore` in `adshield/ref/adshield.py`.
//
// THREADING: single-thread confinement by design. A `ChatStore` / `AccountStore` and every value it returns must be
// used from ONE serial queue (the AdShield queue of SPEC §8.4): there are no locks and the classes are not Sendable.
// The UI thread only copies the fields `MessageInput` / `ChatContext` need and hands them to that queue; the
// decision cache the UI reads (chatId, msgId) → Decision is the integration's job.
//
// Nothing here logs. Integration logs may contain counts, cluster counts and timings only — never message text,
// links, usernames or sender ids (SPEC §8.4).

extension LuminaAdShield {
    public enum StoreError: Error {
        /// ForgetAll ran: every write is refused until a new AccountStore is created.
        case forgotten
    }

    /// Shared by an AccountStore and its ChatStores (no reference cycle): once `forgotten`, writes are refused.
    final class WriteGate {
        var forgotten = false
    }

    struct Row {
        var rid: Int
        /// 0 = deleted (anonymous).
        var msgId: Int32
        var album: Int64
        var date: Int64
        var seen: Int64
        /// Keyed hash of the sender, 0 = anonymous.
        var sender: UInt64
        var flags: UInt32
        var keys: [Key]
        var links: [UInt64]
        var pending: [UInt64]

        var live: Bool {
            return self.msgId != 0
        }
    }

    static let recordEndorse: UInt8 = 1
    static let recordNotAd: UInt8 = 2

    struct Record {
        var kind: UInt8
        var stamp: Int64
        /// Endorsement: H("msg", msgId) (upsert key); not-ad: 0.
        var msgKey: UInt64
        var keys: [Key]
        var links: [UInt64]
    }

    struct HandleInfo {
        var first: Int64
        var last: Int64
        var seen: Int64
    }

    /// Order key of a unit: (date, anonymous 0 / live 1, smallest live msgId (0 if anonymous), smallest key hash).
    struct UnitOrder: Comparable {
        let date: Int64
        let live: Int
        let minMsgId: Int32
        let minKeyHash: UInt64

        static func < (a: UnitOrder, b: UnitOrder) -> Bool {
            if a.date != b.date {
                return a.date < b.date
            }
            if a.live != b.live {
                return a.live < b.live
            }
            if a.minMsgId != b.minMsgId {
                return a.minMsgId < b.minMsgId
            }
            return a.minKeyHash < b.minKeyHash
        }
    }

    struct UnitId: Hashable {
        let isAlbum: Bool
        let value: Int64
    }

    struct RuleSpec {
        let window: Int64
        let minHits: Int
        let minSenders: Int
    }

    struct RuleSet {
        let strong: [RuleSpec]
        let weak: [RuleSpec]
        let sameSender: RuleSpec?
        let plain: RuleSpec?
    }

    static func rules(_ s: Sensitivity) -> RuleSet {
        switch s {
        case .loose:
            return RuleSet(strong: [RuleSpec(window: 72 * hour, minHits: 4, minSenders: 1), RuleSpec(window: 72 * hour, minHits: 2, minSenders: 3)], weak: [], sameSender: nil, plain: nil)
        case .standard:
            return RuleSet(strong: [RuleSpec(window: 7 * day, minHits: 3, minSenders: 1), RuleSpec(window: 7 * day, minHits: 2, minSenders: 2)], weak: [RuleSpec(window: 24 * hour, minHits: 4, minSenders: 3)], sameSender: RuleSpec(window: 7 * day, minHits: 3, minSenders: 1), plain: nil)
        case .aggressive:
            return RuleSet(strong: [RuleSpec(window: 7 * day, minHits: 2, minSenders: 1)], weak: [RuleSpec(window: 7 * day, minHits: 3, minSenders: 2)], sameSender: RuleSpec(window: 7 * day, minHits: 3, minSenders: 1), plain: RuleSpec(window: 7 * day, minHits: 3, minSenders: 3))
        }
    }

    /// Exact overlap (any shared exact key) or ≥ 2 shared paragraph keys.
    static func overlap(_ a: Set<Key>, _ b: [Key]) -> Bool {
        var paras = 0
        var seenPara = Set<Key>()
        for k in b where a.contains(k) {
            if k.isExact {
                return true
            }
            if seenPara.insert(k).inserted {
                paras += 1
                if paras >= 2 {
                    return true
                }
            }
        }
        return false
    }

    /// Record keys: deduped, exact keys first then paragraph keys (each keeping its order), at most 64.
    static func orderedRecordKeys(_ seq: [Key]) -> [Key] {
        var seen = Set<Key>()
        var exact: [Key] = []
        var para: [Key] = []
        for k in seq where seen.insert(k).inserted {
            if k.isExact {
                exact.append(k)
            } else {
                para.append(k)
            }
        }
        return Array((exact + para).prefix(maxRecordKeys))
    }

    @inline(__always) static func inDateRange(_ v: Int64) -> Bool {
        return v >= 0 && v <= maxDate
    }

    // ===========================================================================
    // ChatStore
    // ===========================================================================

    public final class ChatStore {
        public let chatId: Int64
        let key: [UInt8]
        let gate: WriteGate?
        /// Sorted by rid (rids only grow).
        var rows: [Row] = []
        var byMsg: [Int32: Int] = [:]
        var nextRid: Int = 1
        var records: [Record] = []
        var handles: [UInt64: HandleInfo] = [:]
        /// Bumped by every change that can change a decision (the integration re-decides visible messages).
        public private(set) var version: Int = 0
        private var cache: UnitsCache?

        /// A store not attached to an AccountStore (tests, or an integration that manages files itself).
        public convenience init(chatId: Int64, key: [UInt8]) {
            self.init(chatId: chatId, key: key, gate: nil)
        }

        init(chatId: Int64, key: [UInt8], gate: WriteGate?) {
            precondition(key.count == 16, "AdShield key must be 16 bytes")
            self.chatId = chatId
            self.key = key
            self.gate = gate
        }

        private func checkWritable() throws {
            if let gate = self.gate, gate.forgotten {
                throw StoreError.forgotten
            }
        }

        private func changed() {
            self.version += 1
            self.cache = nil
        }

        public var rowCount: Int {
            return self.rows.count
        }

        public var recordCount: Int {
            return self.records.count
        }

        public var handleCount: Int {
            return self.handles.count
        }

        func rowIndex(rid: Int) -> Int? {
            var lo = 0
            var hi = self.rows.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = self.rows[mid].rid
                if r < rid {
                    lo = mid + 1
                } else if r > rid {
                    hi = mid - 1
                } else {
                    return mid
                }
            }
            return nil
        }

        // ---- writes ----

        /// New message, history load, re-render or edit (upsert by msgId). Returns nil when the chat / message is
        /// ineligible or out of range (SPEC §6.1).
        @discardableResult
        public func observe(_ msg: MessageInput, context ctx: ChatContext, now: Int64) throws -> Fingerprint? {
            try self.checkWritable()
            if !isEligible(ctx) || !isEligible(msg) || !isValid(msg) {
                return nil
            }
            if !inDateRange(now) {
                return nil
            }
            self.compact(now: now)
            let fp = fingerprint(msg, context: ctx, key: self.key)
            let mid = msg.id
            let date = msg.date
            if let rid = self.byMsg.removeValue(forKey: mid), let idx = self.rowIndex(rid: rid) {
                self.rows.remove(at: idx)
            }
            let username = uname(msg.sender.username)
            if validUsername(username) {
                let h = handleHash(key: self.key, name: username)
                if var hi = self.handles[h] {
                    hi.first = min(hi.first, date)
                    hi.last = max(hi.last, date)
                    hi.seen = max(hi.seen, now)
                    self.handles[h] = hi
                } else {
                    self.handles[h] = HandleInfo(first: date, last: date, seen: now)
                }
            }
            let keys = fp.keys.map { Key(kind: $0.kind.rawValue, hash: $0.hash) }
            if fp.endorsing && !keys.isEmpty {
                var links = fp.linkHashes
                let fixed = Set(fp.linkHashes)
                for h in fp.pending where !fixed.contains(h) {
                    links.append(h)
                }
                self.upsertEndorse(stamp: now, msgKey: khash(self.key, "msg", dec(Int64(mid))), keys: keys, links: links)
            }
            if fp.store {
                let rid = self.nextRid
                self.nextRid += 1
                self.rows.append(Row(rid: rid, msgId: mid, album: msg.album, date: date, seen: now, sender: fp.senderKey, flags: fp.flags, keys: keys, links: fp.linkHashes, pending: fp.pending))
                self.byMsg[mid] = rid
            }
            self.enforceCaps()
            self.changed()
            return fp
        }

        /// Deletion or auto-delete: msgId and sender go immediately; count, date, keys and link hashes (all keyed
        /// hashes) stay as an anonymous row. `now` is clamped to 0…2^40 so the row stays loadable.
        public func delete(_ msgIds: [Int32], now: Int64) throws {
            try self.checkWritable()
            let seen = min(max(now, 0), maxDate)
            for mid in msgIds {
                guard let rid = self.byMsg.removeValue(forKey: mid), let idx = self.rowIndex(rid: rid) else {
                    continue
                }
                self.rows[idx].msgId = 0
                self.rows[idx].sender = 0
                self.rows[idx].flags = (self.rows[idx].flags & Flag.anonKeep) | Flag.anon
                self.rows[idx].seen = seen
            }
            self.changed()
        }

        /// "Not an ad": remember the whole cluster of the message (post-resolve keys and links) for 90 days.
        /// Unit order: m first, the rest by order; keys per unit by (kind, hash unsigned), links by hash unsigned.
        @discardableResult
        public func markNotAd(_ msgId: Int32, context ctx: ChatContext, now: Int64) throws -> Bool {
            try self.checkWritable()
            if !inDateRange(now) {
                return false
            }
            let c = self.units(ctx, now: now)
            guard let mi = self.unitIndex(c, msgId: msgId) else {
                return false
            }
            let others = self.group(c, mi).filter { $0 != mi }
            var keySeq: [Key] = []
            var linkSeq: [UInt64] = []
            for ui in [mi] + others {
                keySeq.append(contentsOf: c.keys[ui].sorted())
                linkSeq.append(contentsOf: c.links[ui].sorted())
            }
            self.addNotAd(stamp: now, keys: orderedRecordKeys(keySeq), links: dedupe(linkSeq, cap: maxRecordLinks))
            self.changed()
            return true
        }

        private func evictRecords(kind: UInt8) {
            let cap = kind == recordEndorse ? maxEndorseRecords : maxNotAdRecords
            while true {
                var count = 0
                var oldest = -1
                for (i, r) in self.records.enumerated() where r.kind == kind {
                    count += 1
                    if oldest < 0 || r.stamp < self.records[oldest].stamp {
                        oldest = i
                    }
                }
                if count <= cap || oldest < 0 {
                    return
                }
                self.records.remove(at: oldest)
            }
        }

        private func upsertEndorse(stamp: Int64, msgKey: UInt64, keys: [Key], links: [UInt64]) {
            let k = orderedRecordKeys(keys)
            let l = Array(links.prefix(maxRecordLinks))
            for i in 0 ..< self.records.count where self.records[i].kind == recordEndorse && self.records[i].msgKey == msgKey {
                self.records[i].keys = k
                self.records[i].links = l
                self.records[i].stamp = max(self.records[i].stamp, stamp)
                return
            }
            self.records.append(Record(kind: recordEndorse, stamp: stamp, msgKey: msgKey, keys: k, links: l))
            self.evictRecords(kind: recordEndorse)
        }

        private func addNotAd(stamp: Int64, keys: [Key], links: [UInt64]) {
            let k = orderedRecordKeys(keys)
            let l = Array(links.prefix(maxRecordLinks))
            for i in 0 ..< self.records.count where self.records[i].kind == recordNotAd && self.records[i].keys == k && self.records[i].links == l {
                self.records[i].stamp = max(self.records[i].stamp, stamp)
                return
            }
            self.records.append(Record(kind: recordNotAd, stamp: stamp, msgKey: 0, keys: k, links: l))
            self.evictRecords(kind: recordNotAd)
        }

        /// Eviction: rows with now − max(date, seen) > 8 days, records older than 90 days, handles idle > 30 days.
        /// Comparisons are written as `now > x + ttl` (x ≤ 2^40), so no `now` can overflow.
        public func compact(now: Int64) {
            let before = (self.rows.count, self.records.count, self.handles.count)
            var kept: [Row] = []
            kept.reserveCapacity(self.rows.count)
            for r in self.rows {
                if now > max(r.date, r.seen) + evictAfter {
                    if r.live {
                        self.byMsg.removeValue(forKey: r.msgId)
                    }
                } else {
                    kept.append(r)
                }
            }
            self.rows = kept
            self.records = self.records.filter { now <= $0.stamp + recordTTL }
            self.handles = self.handles.filter { now <= max($0.value.last, $0.value.seen) + handleTTL }
            if before != (self.rows.count, self.records.count, self.handles.count) {
                self.changed()
            }
        }

        private func enforceCaps() {
            while self.rows.count > maxRows {
                var victim = 0
                for i in 1 ..< self.rows.count {
                    let a = self.rows[i]
                    let b = self.rows[victim]
                    let ka = max(a.date, a.seen)
                    let kb = max(b.date, b.seen)
                    if ka < kb || (ka == kb && a.rid < b.rid) {
                        victim = i
                    }
                }
                let r = self.rows.remove(at: victim)
                if r.live {
                    self.byMsg.removeValue(forKey: r.msgId)
                }
            }
            while self.handles.count > maxHandles {
                var victim: (UInt64, Int64)?
                for (h, hi) in self.handles {
                    let k = max(hi.last, hi.seen)
                    if let v = victim {
                        if k < v.1 || (k == v.1 && h < v.0) {
                            victim = (h, k)
                        }
                    } else {
                        victim = (h, k)
                    }
                }
                if let v = victim {
                    self.handles.removeValue(forKey: v.0)
                }
            }
        }

        // ---- decisions ----

        /// Album-merged counting units of every non-expired row, keys / links / flags resolved against the
        /// known-member table (SPEC §5.5), as parallel arrays. Cached until the store changes or `now` / the
        /// context's member handles change (same result as recomputing on every call, like the reference).
        final class UnitsCache {
            let mutation: Int
            let now: Int64
            let knownHashes: [UInt64]
            var date: [Int64] = []
            var sender: [UInt64] = []
            var flags: [UInt32] = []
            var live: [Bool] = []
            var order: [UnitOrder] = []
            var keys: [Set<Key>] = []
            var links: [Set<UInt64>] = []
            /// Smallest rowId of the unit: total-order tie-breaker. Only ever needed between anonymous units with equal
            /// order keys (live units differ by msgId); the reference leaves that order to Python set iteration.
            var minRid: [Int] = []
            /// Unit indices sorted by (order, minRid), and each unit's position in that sequence.
            var byOrder: [Int] = []
            var rank: [Int] = []
            var byUid: [UnitId: Int] = [:]
            /// key → unit indices (ascending)
            var index: [Key: [Int]] = [:]

            init(mutation: Int, now: Int64, knownHashes: [UInt64]) {
                self.mutation = mutation
                self.now = now
                self.knownHashes = knownHashes
            }

            var count: Int {
                return self.date.count
            }
        }

        private func contextKnown(_ ctx: ChatContext) -> [UInt64] {
            var out = Set<UInt64>()
            for n in ctx.memberHandles where !n.isEmpty {
                out.insert(handleHash(key: self.key, name: n))
            }
            return out.sorted()
        }

        func units(_ ctx: ChatContext, now: Int64) -> UnitsCache {
            let known = self.contextKnown(ctx)
            if let c = self.cache, c.mutation == self.version, c.now == now, c.knownHashes == known {
                return c
            }
            let knownSet = Set(known)
            let handles = self.handles
            let c = UnitsCache(mutation: self.version, now: now, knownHashes: known)
            var liveMinMsg: [Int32] = []
            for r in self.rows {
                if now > max(r.date, r.seen) + evictAfter {
                    continue
                }
                let date = r.date
                let res = resolve(flags: r.flags, keys: r.keys, links: r.links, pending: r.pending, isKnown: { h in
                    if knownSet.contains(h) {
                        return true
                    }
                    if let hi = handles[h] {
                        return hi.first <= date - knownMemberMinAge
                    }
                    return false
                })
                let uid = r.album != 0 ? UnitId(isAlbum: true, value: r.album) : UnitId(isAlbum: false, value: Int64(r.rid))
                let ui: Int
                if let existing = c.byUid[uid] {
                    ui = existing
                    c.date[ui] = min(c.date[ui], r.date)
                    c.flags[ui] |= res.flags
                    c.keys[ui].formUnion(res.keys)
                    c.links[ui].formUnion(res.links)
                    c.minRid[ui] = min(c.minRid[ui], r.rid)
                } else {
                    ui = c.date.count
                    c.byUid[uid] = ui
                    c.date.append(r.date)
                    c.sender.append(0)
                    c.flags.append(res.flags)
                    c.live.append(false)
                    c.keys.append(Set(res.keys))
                    c.links.append(Set(res.links))
                    c.minRid.append(r.rid)
                    liveMinMsg.append(0)
                }
                if r.live && (!c.live[ui] || r.msgId < liveMinMsg[ui]) {
                    c.live[ui] = true
                    liveMinMsg[ui] = r.msgId
                    c.sender[ui] = r.sender
                }
            }
            let n = c.date.count
            c.order.reserveCapacity(n)
            for ui in 0 ..< n {
                if c.live[ui] {
                    c.flags[ui] &= ~Flag.anon
                }
                // Album: any strong feature in any photo makes the unit not "media only".
                if c.flags[ui] & Flag.strongMask != 0 {
                    c.flags[ui] &= ~Flag.mediaOnly
                }
                var minKey: UInt64 = 0
                var first = true
                for k in c.keys[ui] {
                    if first || k.hash < minKey {
                        minKey = k.hash
                        first = false
                    }
                    c.index[k, default: []].append(ui)
                }
                c.order.append(UnitOrder(date: c.date[ui], live: c.live[ui] ? 1 : 0, minMsgId: liveMinMsg[ui], minKeyHash: minKey))
            }
            c.byOrder = Array(0 ..< n)
            c.byOrder.sort { a, b in
                if c.order[a] != c.order[b] {
                    return c.order[a] < c.order[b]
                }
                return c.minRid[a] < c.minRid[b]
            }
            c.rank = [Int](repeating: 0, count: n)
            for (pos, ui) in c.byOrder.enumerated() {
                c.rank[ui] = pos
            }
            self.cache = c
            return c
        }

        func unitIndex(_ c: UnitsCache, msgId: Int32) -> Int? {
            guard let rid = self.byMsg[msgId], let idx = self.rowIndex(rid: rid) else {
                return nil
            }
            let r = self.rows[idx]
            let uid = r.album != 0 ? UnitId(isAlbum: true, value: r.album) : UnitId(isAlbum: false, value: Int64(r.rid))
            return c.byUid[uid]
        }

        /// G(m): units sharing an exact key with m or ≥ 2 paragraph keys (m included), in (order, minRid) sequence,
        /// hence also by date. Only the units indexed under m's keys are visited (O(cluster)).
        func group(_ c: UnitsCache, _ mi: Int) -> [Int] {
            var mark = [UInt8](repeating: 0, count: c.count) // bit 0: in G(m); bits 1-2: shared paragraph keys (≤ 2)
            var members: [Int] = [mi]
            mark[mi] = 1
            for k in c.keys[mi] {
                guard let us = c.index[k] else {
                    continue
                }
                if k.isExact {
                    for u in us where mark[u] & 1 == 0 {
                        mark[u] |= 1
                        members.append(u)
                    }
                } else {
                    for u in us where mark[u] & 1 == 0 {
                        if mark[u] & 2 != 0 {
                            mark[u] |= 1
                            members.append(u)
                        } else {
                            mark[u] |= 2
                        }
                    }
                }
            }
            if members.count > 32 && members.count * 8 > c.count {
                return c.byOrder.filter { mark[$0] & 1 != 0 }
            }
            let rank = c.rank
            return members.sorted { rank[$0] < rank[$1] }
        }

        public func decide(_ msgId: Int32, context ctx: ChatContext, settings: Settings, now: Int64) -> Decision {
            var res = Decision()
            if !isEligible(ctx) {
                res.state = .ineligible
                return res
            }
            let c = self.units(ctx, now: now)
            guard let mi = self.unitIndex(c, msgId: msgId) else {
                res.state = .untracked
                return res
            }
            if !ctx.adminsKnown {
                res.state = .pending
                return res
            }
            let mFlags = c.flags[mi]
            let mKeys = c.keys[mi]
            let mLinks = c.links[mi]
            let mDate = c.date[mi]
            let mSender = c.sender[mi]
            let mOrder = c.order[mi]
            res.replyToMe = mFlags & Flag.replyMe != 0
            if mFlags & Flag.endorsing != 0 {
                res.state = .endorsed
                return res
            }
            let group = self.group(c, mi)

            // Endorsement: overlapping endorsement records ∪ endorsing units still in the pool.
            var endorseLinks = Set<UInt64>()
            var endorsedHit = false
            for r in self.records where r.kind == recordEndorse && now <= r.stamp + recordTTL && overlap(mKeys, r.keys) {
                endorsedHit = true
                endorseLinks.formUnion(r.links)
            }
            for u in group where u != mi && c.flags[u] & Flag.endorsing != 0 {
                endorsedHit = true
                endorseLinks.formUnion(c.links[u])
            }
            var impersonating = false
            if endorsedHit {
                if mLinks.isSubset(of: endorseLinks) {
                    res.state = .endorsed
                    return res
                }
                impersonating = true
            }

            // Not an ad (90 days).
            for r in self.records where r.kind == recordNotAd && now <= r.stamp + recordTTL && overlap(mKeys, r.keys) {
                res.state = .notAd
                return res
            }

            let gc: [Int]
            let cls: Decision.Class
            if impersonating {
                // Other impersonators, including deleted anonymous units (their link hashes are kept).
                gc = group.filter { c.flags[$0] & Flag.endorsing == 0 && !c.links[$0].isSubset(of: endorseLinks) }
                cls = .strong
            } else {
                gc = group
                if mFlags & Flag.strongMask != 0 {
                    cls = .strong
                } else {
                    var sharesMediaFwd = false
                    let mediaFwd = mKeys.filter { $0.kind == KeyKind.media.rawValue || $0.kind == KeyKind.fwd.rawValue }
                    if !mediaFwd.isEmpty {
                        for u in group where u != mi && !c.keys[u].isDisjoint(with: mediaFwd) {
                            sharesMediaFwd = true
                            break
                        }
                    }
                    cls = (mFlags & Flag.weakMask != 0 || sharesMediaFwd) ? .weak : .plain
                }
            }
            res.cls = impersonating ? .impersonation : cls
            let week: Int64 = 7 * day
            var groupSize = 0
            var occurrence = 0
            for u in gc {
                let d = c.date[u]
                if abs(d - mDate) <= week {
                    groupSize += 1
                }
                if mDate - week <= d && c.order[u] <= mOrder {
                    occurrence += 1
                }
            }
            res.groupSize = groupSize
            res.occurrence = occurrence

            let rs = rules(settings.sensitivity)
            var candidates: [(Decision.Rule, RuleSpec, [Int])] = []
            switch cls {
            case .strong, .impersonation:
                for r in rs.strong {
                    candidates.append((.strong, r, gc))
                }
            case .weak:
                for r in rs.weak {
                    candidates.append((.weak, r, gc))
                }
                if let ss = rs.sameSender, mFlags & Flag.mediaOnly != 0 {
                    let mediaKeys = mKeys.filter { $0.kind == KeyKind.media.rawValue }
                    let same = gc.filter { c.live[$0] && c.sender[$0] == mSender && !c.keys[$0].isDisjoint(with: mediaKeys) }
                    candidates.append((.mediaSameSender, RuleSpec(window: ss.window, minHits: ss.minHits, minSenders: 1), same))
                }
                let fwdKeys = mKeys.filter { $0.kind == KeyKind.fwd.rawValue }
                if let ss = rs.sameSender, !fwdKeys.isEmpty {
                    let same = gc.filter { c.live[$0] && c.sender[$0] == mSender && !c.keys[$0].isDisjoint(with: fwdKeys) }
                    candidates.append((.fwdSameSender, RuleSpec(window: ss.window, minHits: ss.minHits, minSenders: 1), same))
                }
            case .plain:
                if let pr = rs.plain, mFlags & Flag.pureText != 0, mFlags & Flag.ack == 0 {
                    candidates.append((.plain, pr, gc.filter { c.flags[$0] & Flag.ack == 0 }))
                }
            }

            var triggered: Decision.Rule?
            var protectedOriginal = false
            for (name, spec, pool) in candidates {
                if !self.windowSatisfied(c, pool, mi, spec) {
                    continue
                }
                // First-message protection (a copied original is not folded); impersonation clusters are copies.
                if !impersonating && self.isFirst(c, pool, mi, spec.window) && !self.repostedBySelf(c, pool, mi, spec.window) {
                    protectedOriginal = true
                    continue
                }
                triggered = name
                break
            }
            guard let rule = triggered else {
                res.state = protectedOriginal ? .original : .notTriggered
                return res
            }
            res.rule = rule

            // Single-message exemptions (still counted).
            let f = mFlags
            if f & Flag.selfSender != 0 {
                res.state = .endorsed
                return res
            }
            if f & Flag.contact != 0 && settings.exemptContacts {
                res.state = .exempt
                return res
            }
            if f & Flag.bot != 0 && settings.exemptBots {
                res.state = .exempt
                return res
            }
            if f & (Flag.replyMe | Flag.mentionMe) != 0 && settings.exemptReplies && f & Flag.strongMask == 0 && !impersonating && f & Flag.weakMassMention == 0 {
                res.state = .exempt
                return res
            }
            res.state = .fold
            res.fold = true
            return res
        }

        /// ∃ t (a pool unit date in [m.date − W, m.date]) with ≥ minHits units dated in [t, t + W] and ≥ minSenders
        /// distinct live senders there. Two pointers over the date-ordered pool (pools come from `group`, which is
        /// already in date order), O(n).
        private func windowSatisfied(_ c: UnitsCache, _ pool: [Int], _ mi: Int, _ spec: RuleSpec) -> Bool {
            var ds = pool
            var sorted = true
            var hasM = false
            for (i, u) in ds.enumerated() {
                if u == mi {
                    hasM = true
                }
                if i > 0 && c.date[ds[i - 1]] > c.date[u] {
                    sorted = false
                }
            }
            if !hasM {
                ds.append(mi)
                sorted = false
            }
            if !sorted {
                ds.sort { c.date[$0] < c.date[$1] }
            }
            let n = ds.count
            let mDate = c.date[mi]
            var counts: [UInt64: Int] = [:]
            var distinct = 0
            var j = 0
            for i in 0 ..< n {
                let t0 = c.date[ds[i]]
                while j < n && c.date[ds[j]] <= t0 + spec.window {
                    let u = ds[j]
                    if c.live[u] && c.sender[u] != 0 {
                        let cnt = (counts[c.sender[u]] ?? 0) + 1
                        counts[c.sender[u]] = cnt
                        if cnt == 1 {
                            distinct += 1
                        }
                    }
                    j += 1
                }
                if (i == 0 || c.date[ds[i - 1]] < t0) && mDate - spec.window <= t0 && t0 <= mDate {
                    if j - i >= spec.minHits && distinct >= spec.minSenders {
                        return true
                    }
                }
                let u = ds[i]
                if c.live[u] && c.sender[u] != 0 {
                    let cnt = (counts[c.sender[u]] ?? 0) - 1
                    counts[c.sender[u]] = cnt
                    if cnt == 0 {
                        distinct -= 1
                    }
                }
            }
            return false
        }

        private func isFirst(_ c: UnitsCache, _ pool: [Int], _ mi: Int, _ window: Int64) -> Bool {
            let mDate = c.date[mi]
            let mOrder = c.order[mi]
            for u in pool where u != mi && mDate - window <= c.date[u] && c.order[u] < mOrder {
                return false
            }
            return true
        }

        private func repostedBySelf(_ c: UnitsCache, _ pool: [Int], _ mi: Int, _ window: Int64) -> Bool {
            let mDate = c.date[mi]
            let mOrder = c.order[mi]
            let mSender = c.sender[mi]
            for u in pool where u != mi && c.live[u] && c.sender[u] == mSender && mOrder < c.order[u] && c.date[u] <= mDate + window {
                return true
            }
            return false
        }

        // ---- serialization (SPEC §8.3, little endian) ----

        static let headerSize = 56

        func body() -> [UInt8] {
            var w = ByteWriter()
            for r in self.rows {
                w.u32(UInt32(bitPattern: r.msgId))
                w.i64(r.album)
                w.i64(r.date)
                w.i64(r.seen)
                w.u64(r.sender)
                w.u32(r.flags)
                w.u8(UInt8(truncatingIfNeeded: r.keys.count))
                for k in r.keys {
                    w.u8(k.kind)
                    w.u64(k.hash)
                }
                w.u8(UInt8(truncatingIfNeeded: r.links.count))
                for h in r.links {
                    w.u64(h)
                }
                w.u8(UInt8(truncatingIfNeeded: r.pending.count))
                for h in r.pending {
                    w.u64(h)
                }
            }
            for rec in self.records {
                w.u8(rec.kind)
                w.i64(rec.stamp)
                w.u64(rec.msgKey)
                w.u8(UInt8(truncatingIfNeeded: rec.keys.count))
                for k in rec.keys {
                    w.u8(k.kind)
                    w.u64(k.hash)
                }
                w.u8(UInt8(truncatingIfNeeded: rec.links.count))
                for h in rec.links {
                    w.u64(h)
                }
            }
            for h in self.handles.keys.sorted() {
                if let hi = self.handles[h] {
                    w.u64(h)
                    w.i64(hi.first)
                    w.i64(hi.last)
                    w.i64(hi.seen)
                }
            }
            return w.bytes
        }

        /// The file image: header + body. Contains only hashes, ids, dates and flags (no text, links, usernames or
        /// sender ids in clear).
        public func serialize() -> [UInt8] {
            let body = self.body()
            var w = ByteWriter()
            w.bytes.append(contentsOf: W.lgas.map { UInt8($0) })
            w.u16(formatVersion)
            w.u16(algoVersion)
            w.u32(AdShieldTables.tablesVersionU32)
            w.u32(0)
            w.u64(AdShieldTables.keyedHash(key16: self.key, tag: "check", payload: "LGAS"))
            w.u64(khash(self.key, "chat", dec(self.chatId)))
            w.u32(UInt32(truncatingIfNeeded: self.rows.count))
            w.u32(UInt32(truncatingIfNeeded: self.records.count))
            w.u32(UInt32(truncatingIfNeeded: self.handles.count))
            w.u32(UInt32(truncatingIfNeeded: self.nextRid))
            w.u64(AdShieldTables.keyedHashBytes(key16: self.key, tag: "body", payload: body))
            w.bytes.append(contentsOf: body)
            return w.bytes
        }

        /// nil when the format / algorithm / tables version, key, chat or body hash do not match, any value is out of
        /// range, or the data is truncated / has trailing bytes: the caller discards the file and starts over.
        public static func deserialize(_ data: [UInt8], chatId: Int64, key: [UInt8]) -> ChatStore? {
            return self.deserialize(data, chatId: chatId, key: key, gate: nil)
        }

        static func deserialize(_ data: [UInt8], chatId: Int64, key: [UInt8], gate: WriteGate?) -> ChatStore? {
            if key.count != 16 || data.count < headerSize {
                return nil
            }
            var h = ByteReader(data)
            guard let magic = h.take(4), magic == W.lgas.map({ UInt8($0) }),
                  let fv = h.u16(), let av = h.u16(), let tv = h.u32(), let _ = h.u32(),
                  let check = h.u64(), let chatTag = h.u64(),
                  let nRows = h.u32(), let nRec = h.u32(), let nHandles = h.u32(), let nextRid = h.u32(),
                  let bodyHash = h.u64() else {
                return nil
            }
            if fv != formatVersion || av != algoVersion || tv != AdShieldTables.tablesVersionU32 {
                return nil
            }
            if check != AdShieldTables.keyedHash(key16: key, tag: "check", payload: "LGAS") || chatTag != khash(key, "chat", dec(chatId)) {
                return nil
            }
            if bodyHash != AdShieldTables.keyedHashBytes(key16: key, tag: "body", payload: Array(data[headerSize...])) {
                return nil
            }
            if Int(nRows) > maxRows || Int(nRec) > maxEndorseRecords + maxNotAdRecords || Int(nHandles) > maxHandles {
                return nil
            }
            let cs = ChatStore(chatId: chatId, key: key, gate: gate)
            var r = h
            var rid = 0
            for _ in 0 ..< Int(nRows) {
                guard let msgId = r.u32(), let album = r.i64(), let date = r.i64(), let seen = r.i64(), let sender = r.u64(), let flags = r.u32() else {
                    return nil
                }
                if Int64(msgId) > maxMsgId || !inDateRange(date) || !inDateRange(seen) || flags & ~Flag.storedMask != 0 {
                    return nil
                }
                if (msgId == 0) != (flags & Flag.anon != 0) || (msgId == 0 && sender != 0) {
                    return nil
                }
                guard let nk = r.u8(), Int(nk) <= maxRowKeys else {
                    return nil
                }
                var keys: [Key] = []
                for _ in 0 ..< Int(nk) {
                    guard let kind = r.u8(), let hash = r.u64(), kind >= 1 && kind <= 7 else {
                        return nil
                    }
                    keys.append(Key(kind: kind, hash: hash))
                }
                guard let nl = r.u8(), Int(nl) <= maxLinksPerRow, let links = r.u64s(Int(nl)) else {
                    return nil
                }
                guard let np = r.u8(), Int(np) <= maxPendingPerRow, let pending = r.u64s(Int(np)) else {
                    return nil
                }
                rid += 1
                let mid = Int32(msgId)
                cs.rows.append(Row(rid: rid, msgId: mid, album: album, date: date, seen: seen, sender: sender, flags: flags, keys: keys, links: links, pending: pending))
                if mid != 0 {
                    if cs.byMsg[mid] != nil {
                        return nil
                    }
                    cs.byMsg[mid] = rid
                }
            }
            cs.nextRid = max(Int(nextRid), rid + 1)
            var endorse = 0
            var notAd = 0
            for _ in 0 ..< Int(nRec) {
                guard let kind = r.u8(), let stamp = r.i64(), let msgKey = r.u64() else {
                    return nil
                }
                if (kind != recordEndorse && kind != recordNotAd) || !inDateRange(stamp) {
                    return nil
                }
                if kind == recordEndorse {
                    endorse += 1
                } else {
                    notAd += 1
                }
                guard let nk = r.u8(), Int(nk) <= maxRecordKeys else {
                    return nil
                }
                var keys: [Key] = []
                for _ in 0 ..< Int(nk) {
                    guard let k = r.u8(), let hash = r.u64(), k >= 1 && k <= 7 else {
                        return nil
                    }
                    keys.append(Key(kind: k, hash: hash))
                }
                guard let nl = r.u8(), Int(nl) <= maxRecordLinks, let links = r.u64s(Int(nl)) else {
                    return nil
                }
                cs.records.append(Record(kind: kind, stamp: stamp, msgKey: msgKey, keys: keys, links: links))
            }
            if endorse > maxEndorseRecords || notAd > maxNotAdRecords {
                return nil
            }
            for _ in 0 ..< Int(nHandles) {
                guard let hash = r.u64(), let first = r.i64(), let last = r.i64(), let seen = r.i64() else {
                    return nil
                }
                if !inDateRange(first) || !inDateRange(last) || !inDateRange(seen) || first > last || cs.handles[hash] != nil {
                    return nil
                }
                cs.handles[hash] = HandleInfo(first: first, last: last, seen: seen)
            }
            if !r.atEnd {
                return nil
            }
            return cs
        }
    }

    struct ByteWriter {
        var bytes: [UInt8] = []

        mutating func u8(_ v: UInt8) {
            self.bytes.append(v)
        }

        mutating func u16(_ v: UInt16) {
            self.bytes.append(UInt8(truncatingIfNeeded: v))
            self.bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        }

        mutating func u32(_ v: UInt32) {
            for i in 0 ..< 4 {
                self.bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))))
            }
        }

        mutating func u64(_ v: UInt64) {
            for i in 0 ..< 8 {
                self.bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))))
            }
        }

        mutating func i64(_ v: Int64) {
            self.u64(UInt64(bitPattern: v))
        }
    }

    /// Bounds-checked little-endian reader: every read returns nil past the end (= truncated file).
    struct ByteReader {
        let data: [UInt8]
        var off = 0

        init(_ data: [UInt8]) {
            self.data = data
        }

        var atEnd: Bool {
            return self.off == self.data.count
        }

        mutating func take(_ n: Int) -> [UInt8]? {
            if n < 0 || self.off + n > self.data.count {
                return nil
            }
            let out = Array(self.data[self.off ..< (self.off + n)])
            self.off += n
            return out
        }

        mutating func u8() -> UInt8? {
            if self.off + 1 > self.data.count {
                return nil
            }
            let v = self.data[self.off]
            self.off += 1
            return v
        }

        mutating func u16() -> UInt16? {
            if self.off + 2 > self.data.count {
                return nil
            }
            let v = UInt16(self.data[self.off]) | (UInt16(self.data[self.off + 1]) << 8)
            self.off += 2
            return v
        }

        mutating func u32() -> UInt32? {
            if self.off + 4 > self.data.count {
                return nil
            }
            var v: UInt32 = 0
            for i in 0 ..< 4 {
                v |= UInt32(self.data[self.off + i]) << (8 * UInt32(i))
            }
            self.off += 4
            return v
        }

        mutating func u64() -> UInt64? {
            if self.off + 8 > self.data.count {
                return nil
            }
            var v: UInt64 = 0
            for i in 0 ..< 8 {
                v |= UInt64(self.data[self.off + i]) << (8 * UInt64(i))
            }
            self.off += 8
            return v
        }

        mutating func i64() -> Int64? {
            guard let v = self.u64() else {
                return nil
            }
            return Int64(bitPattern: v)
        }

        mutating func u64s(_ n: Int) -> [UInt64]? {
            if self.off + 8 * n > self.data.count {
                return nil
            }
            var out: [UInt64] = []
            out.reserveCapacity(n)
            for _ in 0 ..< n {
                guard let v = self.u64() else {
                    return nil
                }
                out.append(v)
            }
            return out
        }
    }
}
