// AdShield (隱藏重複廣告) conformance checker for the iOS Swift port.
//
// NOT part of any Bazel target: `run.sh` compiles it together with the engine sources from
// submodules/TelegramUIPreferences/Sources (AdShieldTables.swift + LuminaAdShield*.swift, which import only
// Foundation) into one executable, so the checker can also reach `internal` state to forge corrupted files.
//
// Checks (definition of done, SPEC §10): normalize 55, fingerprint 57 (every expect field), SipHash 77,
// all 97 scenarios exactly as README "情境" / ref/test_adshield.py run_scenario, shuffled-load-order invariance,
// serialize → deserialize round trip, every SPEC §8.3 rejection rule on crafted blobs, no plaintext in blobs,
// ForgetAll refusing writes, plus the remaining storage tests of test_adshield.py and a 3000-row timing.
import Foundation

typealias AS = LuminaAdShield

let testKey: [UInt8] = Array(0 ..< 16)

// MARK: - tiny test harness

final class Tally: @unchecked Sendable {
    var sections: [(String, Int, Int)] = []
    var ok = 0
    var bad = 0
    var name = ""
    var failures: [String] = []

    func begin(_ n: String) {
        self.name = n
        self.ok = 0
        self.bad = 0
    }

    func check(_ cond: Bool, _ what: @autoclosure () -> String) {
        if cond {
            self.ok += 1
        } else {
            self.bad += 1
            let msg = "FAIL [\(self.name)] \(what())"
            if self.failures.count < 400 {
                self.failures.append(msg)
            }
            print(msg)
        }
    }

    func end() {
        self.sections.append((self.name, self.ok, self.bad))
        print(String(format: "%-44@ %6d ok %4d failed", self.name as NSString, self.ok, self.bad))
    }
}

let T = Tally()

// MARK: - JSON helpers

typealias J = [String: Any]

func loadJSON(_ path: String) -> J {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? J else {
        print("cannot read \(path)")
        exit(2)
    }
    return obj
}

func i64(_ v: Any?) -> Int64 {
    if let n = v as? NSNumber {
        return n.int64Value
    }
    return 0
}

func str(_ v: Any?) -> String? {
    return v as? String
}

func bool(_ v: Any?) -> Bool {
    if let n = v as? NSNumber {
        return n.boolValue
    }
    return false
}

func scal(_ s: String) -> [UInt32] {
    return s.unicodeScalars.map { $0.value }
}

func string(_ s: [UInt32]) -> String {
    return AdShieldTables.string(s)
}

func hex(_ v: UInt64) -> String {
    return AdShieldTables.hex64(v)
}

func bytesFromHex(_ h: String) -> [UInt8] {
    var out: [UInt8] = []
    let u = Array(h.utf8)
    var i = 0
    while i + 1 < u.count {
        out.append(UInt8(String(decoding: u[i ..< i + 2], as: UTF8.self), radix: 16)!)
        i += 2
    }
    return out
}

func message(_ m: J) -> AS.MessageInput {
    let s = (m["sender"] as? J) ?? [:]
    let sender = AS.Sender(id: i64(s["id"]), role: AS.Role(rawValue: str(s["role"]) ?? "member") ?? .member, username: str(s["username"]))
    var entities: [AS.Entity] = []
    for e in (m["entities"] as? [J]) ?? [] {
        switch str(e["type"]) {
        case "text_url":
            entities.append(.textUrl(str(e["url"]) ?? ""))
        case "mention_name":
            if e["userId"] != nil {
                entities.append(.mentionName(userId: i64(e["userId"])))
            }
        default:
            break
        }
    }
    var media: AS.Media?
    if let md = m["media"] as? J, let kind = AS.MediaKind(rawValue: str(md["kind"]) ?? "") {
        var id: String?
        if let s = md["id"] as? String {
            id = s
        } else if let n = md["id"] as? NSNumber {
            id = String(n.int64Value)
        }
        media = AS.Media(kind: kind, id: id, userId: i64(md["userId"]), phone: str(md["phone"]))
    }
    var forward: AS.Forward?
    if let f = m["forward"] as? J {
        forward = AS.Forward(fromKind: AS.ForwardKind(rawValue: str(f["fromKind"]) ?? "hidden") ?? .hidden, fromId: i64(f["fromId"]), postId: Int32(truncatingIfNeeded: i64(f["postId"])), fromName: str(f["fromName"]), username: str(f["username"]), date: i64(f["date"]))
    }
    let replyTo = m["replyTo"] != nil ? Int32(truncatingIfNeeded: i64(m["replyTo"])) : nil
    return AS.MessageInput(
        id: Int32(truncatingIfNeeded: i64(m["id"])), date: i64(m["date"]), sender: sender, text: str(m["text"]) ?? "",
        entities: entities, media: media, album: i64(m["album"]), forward: forward, buttons: (m["buttons"] as? [String]) ?? [],
        viaBot: bool(m["viaBot"]), replyToMe: bool(m["replyToMe"]), mentionsMe: bool(m["mentionsMe"]), pinned: bool(m["pinned"]),
        autoForward: bool(m["autoForward"]), service: bool(m["service"]), sponsored: bool(m["sponsored"]), scheduled: bool(m["scheduled"]),
        replyTo: replyTo
    )
}

func context(_ d: J) -> AS.ChatContext {
    let lc = (d["linkedChannel"] as? J) ?? [:]
    return AS.ChatContext(
        chatId: i64(d["chatId"]), type: AS.ChatType(rawValue: str(d["type"]) ?? "supergroup") ?? .other,
        username: str(d["username"]), linkedChannelId: i64(lc["id"]), linkedChannelUsername: str(lc["username"]),
        description: str(d["description"]) ?? "", pinnedTexts: (d["pinnedTexts"] as? [String]) ?? [],
        adminsKnown: d["adminsKnown"] == nil ? true : bool(d["adminsKnown"]),
        memberHandles: (d["memberHandles"] as? [String]) ?? [], selfUsername: str(d["selfUsername"])
    )
}

func settings(_ d: J?, _ sens: AS.Sensitivity) -> AS.Settings {
    var s = AS.Settings(sensitivity: sens)
    if let d {
        if d["exemptContacts"] != nil { s.exemptContacts = bool(d["exemptContacts"]) }
        if d["exemptBots"] != nil { s.exemptBots = bool(d["exemptBots"]) }
        if d["exemptReplies"] != nil { s.exemptReplies = bool(d["exemptReplies"]) }
        if d["dryRun"] != nil { s.dryRun = bool(d["dryRun"]) }
    }
    return s
}

func flagNames(_ flags: UInt32) -> [String] {
    var names: [String] = []
    for (bit, n) in AS.Flag.strongNames where flags & bit != 0 {
        names.append("S_" + n)
    }
    for (bit, n) in AS.Flag.weakNames where flags & bit != 0 {
        names.append("W_" + n)
    }
    let rest: [(String, UInt32)] = [
        ("F_HAS_TEXT", AS.Flag.hasText), ("F_MEDIA_ONLY", AS.Flag.mediaOnly), ("F_PURE_TEXT", AS.Flag.pureText),
        ("F_ACK", AS.Flag.ack), ("F_REPLY_ME", AS.Flag.replyMe), ("F_MENTION_ME", AS.Flag.mentionMe),
        ("F_IS_REPLY", AS.Flag.isReply), ("F_ENDORSING", AS.Flag.endorsing), ("F_BOT", AS.Flag.bot),
        ("F_CONTACT", AS.Flag.contact), ("F_SELF", AS.Flag.selfSender), ("F_HAS_MEDIA_KEY", AS.Flag.hasMediaKey),
        ("F_HAS_FWD_KEY", AS.Flag.hasFwdKey), ("F_ANON", AS.Flag.anon), ("F_TMPL_COND", AS.Flag.tmplCond)
    ]
    for (n, bit) in rest where flags & bit != 0 {
        names.append(n)
    }
    return names
}

// MARK: - in-memory file system (tests run without the app)

final class MemoryFS: LuminaAdShieldFileSystem {
    struct Node {
        var isDir: Bool
        var bytes: [UInt8]
        var mtime: Int64
    }

    var nodes: [String: Node] = ["/mem": Node(isDir: true, bytes: [], mtime: 0)]
    var clock: Int64 = 1_000

    static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else {
            return ""
        }
        return String(p[p.startIndex ..< i])
    }

    func contentsOfDirectory(_ path: String) -> [String]? {
        guard let n = self.nodes[path], n.isDir else {
            return nil
        }
        let prefix = path + "/"
        var out: [String] = []
        for k in self.nodes.keys where k.hasPrefix(prefix) {
            let rest = k.dropFirst(prefix.count)
            if !rest.contains("/") {
                out.append(String(rest))
            }
        }
        return out.sorted()
    }

    func isDirectory(_ path: String) -> Bool {
        return self.nodes[path]?.isDir ?? false
    }

    func fileExists(_ path: String) -> Bool {
        return self.nodes[path] != nil
    }

    func readFile(_ path: String) -> [UInt8]? {
        guard let n = self.nodes[path], !n.isDir else {
            return nil
        }
        return n.bytes
    }

    func readFilePrefix(_ path: String, count: Int) -> [UInt8]? {
        guard let b = self.readFile(path) else {
            return nil
        }
        return Array(b.prefix(count))
    }

    func writeFileAtomically(_ path: String, bytes: [UInt8]) -> Bool {
        guard self.isDirectory(MemoryFS.parent(path)) else {
            return false
        }
        self.clock += 1
        self.nodes[path + ".tmp"] = Node(isDir: false, bytes: bytes, mtime: self.clock)
        self.nodes[path] = self.nodes.removeValue(forKey: path + ".tmp")
        return true
    }

    func createDirectory(_ path: String) -> Bool {
        if self.isDirectory(path) {
            return true
        }
        if self.nodes[path] != nil || !self.isDirectory(MemoryFS.parent(path)) {
            return false
        }
        self.nodes[path] = Node(isDir: true, bytes: [], mtime: self.clock)
        return true
    }

    @discardableResult
    func removeItem(_ path: String) -> Bool {
        guard self.nodes[path] != nil else {
            return false
        }
        let prefix = path + "/"
        for k in Array(self.nodes.keys) where k == path || k.hasPrefix(prefix) {
            self.nodes.removeValue(forKey: k)
        }
        return true
    }

    func fileSizeAndMtime(_ path: String) -> (size: Int64, mtimeNanos: Int64)? {
        guard let n = self.nodes[path], !n.isDir else {
            return nil
        }
        return (Int64(n.bytes.count), n.mtime)
    }

    func put(_ path: String, _ bytes: [UInt8]) {
        self.clock += 1
        self.nodes[path] = Node(isDir: false, bytes: bytes, mtime: self.clock)
    }
}

// MARK: - scenario runner (= ref/test_adshield.py run_scenario)

struct ExpectResult {
    let index: Int
    let sens: AS.Sensitivity
    let want: [Int32]
    let got: [Int32]
    let badStates: [(Int32, String, String)]
    let decisions: [Int32: AS.Decision]
}

func runScenario(_ sc: J, events: [J]? = nil) -> [ExpectResult] {
    return runScenarioFull(sc, events: events).0
}

/// README "情境" runner; also returns the chat store (for the byte-exact blob comparison of extra corpora).
func runScenarioFull(_ sc: J, events: [J]? = nil) -> ([ExpectResult], AS.ChatStore) {
    let acct = AS.AccountStore(userId: 424242, key: testKey, root: nil, fs: MemoryFS())
    var ctx = context(sc["context"] as! J)
    let chat = try! acct.chat(ctx.chatId)
    var seen: [Int32] = []
    var now: Int64 = 0
    var results: [ExpectResult] = []
    let evs = events ?? (sc["events"] as! [J])
    for (idx, ev) in evs.enumerated() {
        switch str(ev["op"]) ?? "" {
        case "observe":
            let m = ev["message"] as! J
            let msg = message(m)
            now = ev["now"] != nil ? i64(ev["now"]) : max(now, msg.date)
            _ = try! chat.observe(msg, context: ctx, now: now)
            if !seen.contains(msg.id) {
                seen.append(msg.id)
            }
        case "delete":
            now = ev["now"] != nil ? i64(ev["now"]) : now
            let ids = ((ev["ids"] as? [NSNumber]) ?? []).map { Int32(truncatingIfNeeded: $0.int64Value) }
            try! chat.delete(ids, now: now)
        case "notAd":
            now = ev["now"] != nil ? i64(ev["now"]) : now
            _ = try! chat.markNotAd(Int32(truncatingIfNeeded: i64(ev["id"])), context: ctx, now: now)
        case "context":
            ctx = context(ev["context"] as! J)
        case "expect":
            now = ev["now"] != nil ? i64(ev["now"]) : now
            for sens in AS.Sensitivity.allCases {
                let st = settings(sc["settings"] as? J, sens)
                var decisions: [Int32: AS.Decision] = [:]
                for i in seen {
                    decisions[i] = chat.decide(i, context: ctx, settings: st, now: now)
                }
                let got = seen.filter { decisions[$0]!.fold }.sorted()
                let want = (((ev["fold"] as? J)?[sens.rawValue] as? [NSNumber]) ?? []).map { Int32(truncatingIfNeeded: $0.int64Value) }.sorted()
                var bad: [(Int32, String, String)] = []
                if let states = (ev["states"] as? J)?[sens.rawValue] as? J {
                    for (sid, stv) in states.sorted(by: { $0.key < $1.key }) {
                        let id = Int32(sid)!
                        let wantState = stv as! String
                        let gotState = decisions[id]?.state.rawValue ?? "missing"
                        if gotState != wantState {
                            bad.append((id, wantState, gotState))
                        }
                    }
                }
                results.append(ExpectResult(index: idx, sens: sens, want: want, got: got, badStates: bad, decisions: decisions))
            }
        default:
            break
        }
    }
    return (results, chat)
}

/// SplitMix64: deterministic shuffles (any permutation must give the same result).
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        self.state = self.state &+ 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func shuffle<E>(_ a: inout [E]) {
        if a.count < 2 {
            return
        }
        var i = a.count - 1
        while i > 0 {
            let j = Int(self.next() % UInt64(i + 1))
            a.swapAt(i, j)
            i -= 1
        }
    }
}

// MARK: - blob forging helpers

func rehash(_ blob: [UInt8], key: [UInt8] = testKey) -> [UInt8] {
    var b = blob
    let h = AdShieldTables.keyedHashBytes(key16: key, tag: "body", payload: Array(b[56...]))
    for i in 0 ..< 8 {
        b[48 + i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i)))
    }
    return b
}

func putLE(_ b: inout [UInt8], _ off: Int, _ v: UInt64, _ n: Int) {
    for i in 0 ..< n {
        b[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))
    }
}

func readLE(_ b: [UInt8], _ off: Int, _ n: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0 ..< n {
        v |= UInt64(b[off + i]) << (8 * UInt64(i))
    }
    return v
}

/// Byte offsets of every field of a valid blob (walks the format of SPEC §8.3).
struct Layout {
    struct RowL {
        var msgId = 0, album = 0, date = 0, seen = 0, sender = 0, flags = 0, nKeys = 0, firstKeyKind = -1, nLinks = 0, nPend = 0, end = 0
    }
    struct RecL {
        var kind = 0, stamp = 0, nKeys = 0, firstKeyKind = -1, nLinks = 0, end = 0
    }
    struct HandleL {
        var hash = 0, first = 0, last = 0, seen = 0
    }
    var rows: [RowL] = []
    var records: [RecL] = []
    var handles: [HandleL] = []

    init(_ b: [UInt8]) {
        let nRows = Int(readLE(b, 32, 4)), nRec = Int(readLE(b, 36, 4)), nH = Int(readLE(b, 40, 4))
        var off = 56
        for _ in 0 ..< nRows {
            var r = RowL()
            r.msgId = off; r.album = off + 4; r.date = off + 12; r.seen = off + 20; r.sender = off + 28; r.flags = off + 36
            off += 40
            r.nKeys = off
            let nk = Int(b[off]); off += 1
            if nk > 0 { r.firstKeyKind = off }
            off += 9 * nk
            r.nLinks = off
            let nl = Int(b[off]); off += 1 + 8 * nl
            r.nPend = off
            let np = Int(b[off]); off += 1 + 8 * np
            r.end = off
            self.rows.append(r)
        }
        for _ in 0 ..< nRec {
            var r = RecL()
            r.kind = off; r.stamp = off + 1
            off += 17
            r.nKeys = off
            let nk = Int(b[off]); off += 1
            if nk > 0 { r.firstKeyKind = off }
            off += 9 * nk
            r.nLinks = off
            let nl = Int(b[off]); off += 1 + 8 * nl
            r.end = off
            self.records.append(r)
        }
        for _ in 0 ..< nH {
            self.handles.append(HandleL(hash: off, first: off + 8, last: off + 16, seen: off + 24))
            off += 32
        }
    }
}

let chatIdForge: Int64 = -1001000000777

/// A store with live rows, an anonymous row, both record kinds and known-member handles.
func forgeBase() -> AS.ChatStore {
    let ctx = AS.ChatContext(chatId: chatIdForge)
    let cs = AS.ChatStore(chatId: chatIdForge, key: testKey)
    let base: Int64 = 1_794_268_800
    _ = try! cs.observe(AS.MessageInput(id: 1, date: base, sender: AS.Sender(id: 9, role: .admin, username: "admin_one"), text: "今晚八點語音聊天室開放，歡迎大家來玩，報名 t.me/+AdminRoom1"), context: ctx, now: base)
    for i in 2 ... 6 {
        _ = try! cs.observe(AS.MessageInput(id: Int32(i), date: base + Int64(i) * 60, sender: AS.Sender(id: Int64(100 + i), username: "user_\(i)"), text: "私聊我領取高額返利 第\(i)號 t.me/+VipRoomX 加V：deal_aa\(i)"), context: ctx, now: base + Int64(i) * 60)
    }
    _ = try! cs.markNotAd(3, context: ctx, now: base + 400)
    try! cs.delete([2], now: base + 500)
    return cs
}

// MARK: - checks

func checkNormalize(_ dir: String) {
    T.begin("normalize vectors (JSON)")
    let v = loadJSON(dir + "/vectors/normalize_vectors.json")
    T.check(str(v["tablesVersion"]) == AdShieldTables.tablesVersion, "tablesVersion \(str(v["tablesVersion"]) ?? "") != \(AdShieldTables.tablesVersion)")
    var n = 0
    var substituted: [String] = []
    for c in v["cases"] as! [J] {
        let id = str(c["id"]) ?? "?"
        var input: String
        if let s = c["input"] as? String {
            input = s
        } else {
            // Lone surrogate: Swift cannot represent it; decoding the UTF-16 gives U+FFFD (in DROP) – SPEC §10.1.
            let units = ((c["inputUtf16"] as? [NSNumber]) ?? []).map { UInt16(truncatingIfNeeded: $0.intValue) }
            input = String(decoding: units, as: UTF16.self)
            substituted.append(id)
        }
        let f = AdShieldTables.fold(input)
        let t = AdShieldTables.textForm(f)
        let cjk = AdShieldTables.cjkForm(t)
        let (cc, oc) = AS.letterCounts(t)
        let paras = AS.paragraphs(AS.extractLinks(f).fNoLinks)
        let foldScalars = f.map { String(format: "%04x", $0) }
        var ok = true
        ok = ok && f == scal(str(c["fold"]) ?? "")
        ok = ok && foldScalars == ((c["foldScalars"] as? [String]) ?? [])
        ok = ok && t == scal(str(c["text"]) ?? "")
        ok = ok && cjk == scal(str(c["cjk"]) ?? "")
        ok = ok && AdShieldTables.wlen(t) == Int(i64(c["wlen"]))
        ok = ok && cc == Int(i64(c["cjkCount"])) && oc == Int(i64(c["otherLetterCount"]))
        ok = ok && paras == ((c["paragraphs"] as? [String]) ?? []).map(scal)
        T.check(ok, "\(id): fold=\(foldScalars.joined(separator: " ")) text=\(string(t)) paras=\(paras.map(string))")
        n += 1
    }
    T.check(n == 55, "expected 55 normalize cases, got \(n)")
    if !substituted.isEmpty {
        print("  (\(substituted.joined(separator: ",")): built from inputUtf16; Swift turns the lone surrogate into U+FFFD, which is in DROP)")
    }
    T.end()

    T.begin("normalize + siphash vectors (TSV)")
    func lines(_ path: String) -> [[UInt8]] {
        let data = [UInt8](FileManager.default.contents(atPath: path) ?? Data()).filter { $0 != 0x0D }
        return data.split(separator: 0x0A).map { Array($0) }
    }
    func fields(_ l: [UInt8]) -> [String] {
        return l.split(separator: 0x09, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }
    func hexBytes(_ s: String) -> [UInt8] {
        return s == "-" ? [] : bytesFromHex(s)
    }
    for l in lines(dir + "/vectors/normalize_vectors.tsv") where l.first != 0x23 {
        let f = fields(l)
        let folded = AdShieldTables.fold(String(decoding: hexBytes(f[1]), as: UTF8.self))
        let text = AdShieldTables.textForm(folded)
        let ok = AS.utf8(folded) == hexBytes(f[2]) && AS.utf8(text) == hexBytes(f[3]) && AS.utf8(AdShieldTables.cjkForm(text)) == hexBytes(f[4]) && String(AdShieldTables.wlen(text)) == f[5]
        T.check(ok, "tsv normalize \(f[0])")
    }
    let key = testKey
    for l in lines(dir + "/vectors/siphash_vectors.tsv") where l.first != 0x23 {
        let f = fields(l)
        let got: String
        if f[0] == "raw" {
            got = hex(sip(hexBytes(f[2])))
        } else {
            got = hex(AdShieldTables.keyedHashBytes(key16: key, tag: String(decoding: hexBytes(f[1]), as: UTF8.self), payload: hexBytes(f[2])))
        }
        T.check(got == f[3], "tsv siphash \(f[0]) \(f[1]) \(f[2]) got \(got)")
    }
    T.end()
}

func sip(_ m: [UInt8]) -> UInt64 {
    var k0: UInt64 = 0
    var k1: UInt64 = 0
    for j in stride(from: 7, through: 0, by: -1) { k0 = (k0 << 8) | UInt64(testKey[j]) }
    for j in stride(from: 15, through: 8, by: -1) { k1 = (k1 << 8) | UInt64(testKey[j]) }
    return AdShieldTables.sipHash24(k0: k0, k1: k1, m)
}

func checkSipHash(_ dir: String) {
    T.begin("siphash vectors (JSON)")
    let v = loadJSON(dir + "/vectors/siphash_vectors.json")
    let key = bytesFromHex(str(v["key"]) ?? "")
    T.check(key == testKey, "key")
    var n = 0
    for r in v["raw"] as! [J] {
        let got = hex(sip(bytesFromHex(str(r["messageHex"]) ?? "")))
        T.check(got == str(r["hash"]), "raw \(str(r["messageHex"]) ?? "") got \(got)")
        n += 1
    }
    for r in v["tagged"] as! [J] {
        let got = hex(AdShieldTables.keyedHash(key16: key, tag: str(r["tag"]) ?? "", payload: str(r["payload"]) ?? ""))
        T.check(got == str(r["hash"]), "tagged \(str(r["tag"]) ?? "") got \(got)")
        // the scalar path used by the engine must agree with the String path
        T.check(AS.khash(key, str(r["tag"]) ?? "", scal(str(r["payload"]) ?? "")) == AdShieldTables.keyedHash(key16: key, tag: str(r["tag"]) ?? "", payload: str(r["payload"]) ?? ""), "khash scalar path \(str(r["tag"]) ?? "")")
        n += 1
    }
    T.check(n == 77, "expected 77 siphash vectors, got \(n)")
    T.check(hex(sip([])) == "726fdb47dd0e0e31" && hex(sip(Array(0 ..< 15))) == "a129ca6149be45e5", "paper vectors")
    T.end()
}

func checkFingerprints(_ dir: String) {
    checkFingerprintFile(dir + "/vectors/fingerprint_vectors.json", title: "fingerprint vectors (all expect fields)", expectedCount: 57)
}

func checkFingerprintFile(_ path: String, title: String, expectedCount: Int?) {
    T.begin(title)
    let v = loadJSON(path)
    let key = bytesFromHex(str(v["key"]) ?? "")
    let ctx = context(v["context"] as! J)
    T.check(str(v["tablesVersion"]) == AdShieldTables.tablesVersion, "tablesVersion")
    var n = 0
    var fieldChecks = 0
    for c in v["cases"] as! [J] {
        let id = str(c["id"]) ?? "?"
        let e = c["expect"] as! J
        let fp = AS.fingerprint(message(c["message"] as! J), context: ctx, key: key, knownHandles: [])
        func eq(_ field: String, _ ok: Bool, _ got: @autoclosure () -> String) {
            fieldChecks += 1
            T.check(ok, "\(id).\(field): got \(got())")
        }
        eq("fold", fp.f == scal(str(e["fold"]) ?? ""), string(fp.f))
        eq("foldNoLinks", fp.fNoLinks == scal(str(e["foldNoLinks"]) ?? ""), string(fp.fNoLinks))
        eq("text", fp.t == scal(str(e["text"]) ?? ""), string(fp.t))
        eq("cjk", fp.tCjk == scal(str(e["cjk"]) ?? ""), string(fp.tCjk))
        eq("wlen", fp.wlen == Int(i64(e["wlen"])), "\(fp.wlen)")
        eq("cjkCount", fp.cjkCount == Int(i64(e["cjkCount"])), "\(fp.cjkCount)")
        eq("otherLetterCount", fp.letterCount == Int(i64(e["otherLetterCount"])), "\(fp.letterCount)")
        eq("paragraphs", fp.paragraphs == ((e["paragraphs"] as? [String]) ?? []).map(scal), "\(fp.paragraphs.map(string))")
        let gotLinks = zip(fp.links, fp.linkFeatures).map { l, f in
            [string(l.token), string(l.type), l.kind.rawValue, l.source.rawValue, f.rawValue, hex(AS.khash(key, "link", l.token))]
        }
        let wantLinks = ((e["links"] as? [J]) ?? []).map { l in
            [str(l["token"]) ?? "", str(l["type"]) ?? "", str(l["kind"]) ?? "", str(l["source"]) ?? "", str(l["feature"]) ?? "", str(l["hash"]) ?? ""]
        }
        // token / type compared as scalars (not String ==, which uses canonical equivalence)
        let linksOk = gotLinks.count == wantLinks.count && zip(gotLinks, wantLinks).allSatisfy { g, w in
            zip(g, w).allSatisfy { scal($0) == scal($1) }
        }
        eq("links", linksOk, "\(gotLinks)")
        eq("strong", fp.strong == ((e["strong"] as? [String]) ?? []), "\(fp.strong)")
        eq("weak", fp.weak == ((e["weak"] as? [String]) ?? []), "\(fp.weak)")
        eq("mentionCount", fp.mentionCount == Int(i64(e["mentionCount"])), "\(fp.mentionCount)")
        let gotKeys = fp.keys.map { [$0.kind.name, $0.kind.tag, string($0.payload), hex($0.hash)] }
        let wantKeys = ((e["keys"] as? [J]) ?? []).map { [str($0["kind"]) ?? "", str($0["tag"]) ?? "", str($0["payload"]) ?? "", str($0["hash"]) ?? ""] }
        let keysOk = gotKeys.count == wantKeys.count && zip(gotKeys, wantKeys).allSatisfy { g, w in zip(g, w).allSatisfy { scal($0) == scal($1) } }
        eq("keys", keysOk, "\(gotKeys)")
        eq("flags", Int64(fp.flags) == i64(e["flags"]), "\(fp.flags)")
        eq("flagNames", flagNames(fp.flags) == ((e["flagNames"] as? [String]) ?? []), "\(flagNames(fp.flags))")
        eq("subsetLinks", fp.linkHashes.map(hex) == ((e["subsetLinks"] as? [String]) ?? []), "\(fp.linkHashes.map(hex))")
        eq("pending", fp.pending.map(hex) == ((e["pending"] as? [String]) ?? []), "\(fp.pending.map(hex))")
        eq("resolvedStrong", fp.resolvedStrong == ((e["resolvedStrong"] as? [String]) ?? []), "\(fp.resolvedStrong)")
        eq("resolvedWeak", fp.resolvedWeak == ((e["resolvedWeak"] as? [String]) ?? []), "\(fp.resolvedWeak)")
        eq("resolvedFlags", Int64(fp.resolvedFlags) == i64(e["resolvedFlags"]), "\(fp.resolvedFlags)")
        eq("resolvedFlagNames", flagNames(fp.resolvedFlags) == ((e["resolvedFlagNames"] as? [String]) ?? []), "\(flagNames(fp.resolvedFlags))")
        eq("senderKey", hex(fp.senderKey) == str(e["senderKey"]), hex(fp.senderKey))
        eq("store", fp.store == bool(e["store"]), "\(fp.store)")
        eq("endorsing", fp.endorsing == bool(e["endorsing"]), "\(fp.endorsing)")
        n += 1
    }
    if let expectedCount {
        T.check(n == expectedCount, "expected \(expectedCount) fingerprint cases, got \(n)")
    }
    print("  \(n) cases × \(n > 0 ? fieldChecks / n : 0) fields = \(fieldChecks) field comparisons")
    T.end()
}

func checkScenarios(_ dir: String) -> [J] {
    T.begin("scenarios (97, every expect × 3 sensitivities)")
    let data = loadJSON(dir + "/corpus/scenarios.json")
    let scenarios = data["scenarios"] as! [J]
    var scenarioPass = 0
    var expectChecks = 0
    var stateChecks = 0
    for sc in scenarios {
        let id = str(sc["id"]) ?? "?"
        var allOk = true
        for r in runScenario(sc) {
            expectChecks += 1
            T.check(r.got == r.want, "\(id) event#\(r.index) \(r.sens.rawValue): want fold \(r.want), got \(r.got)")
            T.check(r.badStates.isEmpty, "\(id) event#\(r.index) \(r.sens.rawValue): states (id, want, got) \(r.badStates)")
            if r.got != r.want || !r.badStates.isEmpty {
                allOk = false
            }
        }
        if let evs = sc["events"] as? [J] {
            for ev in evs where str(ev["op"]) == "expect" {
                for sens in AS.Sensitivity.allCases {
                    stateChecks += (((ev["states"] as? J)?[sens.rawValue] as? J)?.count ?? 0)
                }
            }
        }
        if allOk {
            scenarioPass += 1
        }
    }
    T.check(scenarios.count == 97, "expected 97 scenarios, got \(scenarios.count)")
    print("  \(scenarioPass)/\(scenarios.count) scenarios pass; \(expectChecks) fold-set comparisons, \(stateChecks) state comparisons")
    // required lists (test_required_lists_present)
    for sc in scenarios {
        let cat = str(sc["category"]) ?? ""
        let expects = ((sc["events"] as? [J]) ?? []).filter { str($0["op"]) == "expect" }
        if cat == "must_not_trigger" {
            for ev in expects {
                let f = ev["fold"] as? J
                T.check(AS.Sensitivity.allCases.allSatisfy { ((f?[$0.rawValue] as? [Any]) ?? [1]).isEmpty }, "\(str(sc["id"]) ?? "") must_not_trigger has folds")
            }
        }
        if cat == "must_trigger", let last = expects.last {
            T.check(!(((last["fold"] as? J)?["standard"] as? [Any]) ?? []).isEmpty, "\(str(sc["id"]) ?? "") must_trigger: standard must fold")
        }
    }
    T.end()
    return scenarios
}

func checkShuffle(_ scenarios: [J]) {
    T.begin("shuffled load order invariance")
    var rng = SplitMix64(state: 20261117)
    var covered = Set<String>()
    var runs = 0
    for sc in scenarios {
        let evs = sc["events"] as! [J]
        if evs.contains(where: { ["delete", "notAd", "context"].contains(str($0["op"]) ?? "") }) {
            continue
        }
        let obs = evs.filter { str($0["op"]) == "observe" }
        let ids = obs.map { i64(($0["message"] as! J)["id"]) }
        if Set(ids).count != ids.count {
            continue // edits: order matters by design
        }
        guard var probe = evs.last(where: { str($0["op"]) == "expect" }) else {
            continue
        }
        let maxNow = obs.map { $0["now"] != nil ? i64($0["now"]) : i64(($0["message"] as! J)["date"]) }.max() ?? 0
        probe["now"] = NSNumber(value: maxNow)
        probe["states"] = [String: Any]()
        func withNow(_ list: [J]) -> [J] {
            return list.map { e in
                var e = e
                e["now"] = NSNumber(value: maxNow)
                return e
            }
        }
        let id = str(sc["id"]) ?? "?"
        let baseline = runScenario(sc, events: withNow(obs) + [probe]).map { "\($0.sens.rawValue):\($0.got)" }
        covered.insert(id)
        var orders: [[J]] = [Array(obs.reversed())]
        for _ in 0 ..< 5 {
            var s = obs
            rng.shuffle(&s)
            orders.append(s)
        }
        for order in orders {
            let got = runScenario(sc, events: withNow(order) + [probe]).map { "\($0.sens.rawValue):\($0.got)" }
            runs += 1
            T.check(got == baseline, "\(id): shuffled order gives \(got) vs baseline \(baseline)")
        }
    }
    for need in ["FP-20a", "FP-20b", "RG-01", "RG-02", "EV-25"] {
        T.check(covered.contains(need), "shuffle coverage must include \(need)")
    }
    // FP-20a / FP-20b: the same messages in opposite load orders give the same result (test_reverse_order_learning)
    let byId = Dictionary(scenarios.map { (str($0["id"]) ?? "", $0) }, uniquingKeysWith: { $1 })
    if let a = byId["FP-20a"], let b = byId["FP-20b"] {
        let ra = runScenario(a).map { "\($0.sens.rawValue):\($0.got)" }
        let rb = runScenario(b).map { "\($0.sens.rawValue):\($0.got)" }
        T.check(ra == rb, "FP-20a vs FP-20b: \(ra) vs \(rb)")
    }
    print("  \(covered.count) shuffle-eligible scenarios × 6 orders (reverse + 5 shuffles) = \(runs) runs")
    T.end()
}

func filledTR03(_ scenarios: [J], acct: AS.AccountStore) -> (J, AS.ChatContext, AS.ChatStore, Int64) {
    let sc = scenarios.first { str($0["id"]) == "TR-03" }!
    let ctx = context(sc["context"] as! J)
    let chat = try! acct.chat(ctx.chatId)
    var now: Int64 = 0
    for ev in sc["events"] as! [J] where str(ev["op"]) == "observe" {
        let m = message(ev["message"] as! J)
        now = max(now, m.date)
        _ = try! chat.observe(m, context: ctx, now: now)
    }
    return (sc, ctx, chat, now)
}

func checkStorage(_ scenarios: [J]) {
    T.begin("storage: round trip, privacy, upsert, determinism")
    do {
        let acct = AS.AccountStore(userId: 1, key: testKey, root: nil, fs: MemoryFS())
        let (_, ctx, chat, now) = filledTR03(scenarios, acct: acct)
        let blob = chat.serialize()
        let back = AS.ChatStore.deserialize(blob, chatId: ctx.chatId, key: testKey)
        T.check(back != nil, "round trip: deserialize")
        T.check(back?.serialize() == blob, "round trip: serialize(deserialize(blob)) == blob")
        for mid: Int32 in 1 ... 4 {
            for sens in AS.Sensitivity.allCases {
                let st = AS.Settings(sensitivity: sens)
                T.check(chat.decide(mid, context: ctx, settings: st, now: now) == back?.decide(mid, context: ctx, settings: st, now: now), "round trip: same decision mid \(mid) \(sens)")
            }
        }
        // round trip of a store with every element type (anonymous row, both record kinds, handles)
        let f = forgeBase()
        let fb = f.serialize()
        let fback = AS.ChatStore.deserialize(fb, chatId: chatIdForge, key: testKey)
        T.check(fback?.serialize() == fb, "round trip (rows + anon + records + handles)")
        T.check(f.rowCount == 6 && f.recordCount == 2 && f.handleCount == 6, "forge base shape rows=\(f.rowCount) records=\(f.recordCount) handles=\(f.handleCount)")

        // wrong key / chat / truncated
        T.check(AS.ChatStore.deserialize(blob, chatId: ctx.chatId, key: [UInt8](repeating: 0, count: 16)) == nil, "wrong key rejected")
        T.check(AS.ChatStore.deserialize(blob, chatId: ctx.chatId + 1, key: testKey) == nil, "wrong chat rejected")
        T.check(AS.ChatStore.deserialize(Array(blob.dropLast()), chatId: ctx.chatId, key: testKey) == nil, "truncated rejected")

        // no plaintext in blob (test_no_plaintext_in_blob)
        let sc = scenarios.first { str($0["id"]) == "TR-03" }!
        for ev in sc["events"] as! [J] where str(ev["op"]) == "observe" {
            let m = ev["message"] as! J
            let senderId = i64((m["sender"] as! J)["id"])
            let frags = [string(Array(AdShieldTables.fold(str(m["text"]) ?? "").prefix(6))), "viproom9", "VipRoom9", String(senderId), "本群提供"]
            for frag in frags {
                T.check(!contains(blob, Array(frag.utf8)), "plaintext '\(frag)' found in blob")
            }
            T.check(!contains(blob, (0 ..< 8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: senderId) >> (8 * UInt64($0))) }), "sender id LE64 found in blob")
        }
    }
    do {
        // no plaintext in any scenario's final blob (long fragments only, so random hash bytes cannot collide)
        var checked = 0
        for sc in scenarios {
            let acct = AS.AccountStore(userId: 424242, key: testKey, root: nil, fs: MemoryFS())
            let ctx = context(sc["context"] as! J)
            let chat = try! acct.chat(ctx.chatId)
            var now: Int64 = 0
            var frags: [[UInt8]] = []
            for ev in sc["events"] as! [J] where str(ev["op"]) == "observe" {
                let mj = ev["message"] as! J
                let m = message(mj)
                now = ev["now"] != nil ? i64(ev["now"]) : max(now, m.date)
                _ = try! chat.observe(m, context: ctx, now: now)
                let folded = AS.utf8(Array(AdShieldTables.fold(m.text).prefix(8)))
                if folded.count >= 8 { frags.append(folded) }
                if let u = m.sender.username, u.utf8.count >= 5 { frags.append(Array(u.utf8)); frags.append(AS.utf8(AS.uname(u))) }
                if String(m.sender.id).utf8.count >= 6 { frags.append(Array(String(m.sender.id).utf8)) }
                for b in m.buttons where b.utf8.count >= 8 { frags.append(Array(b.utf8)) }
            }
            let blob = chat.serialize()
            for frag in frags {
                checked += 1
                T.check(!contains(blob, frag), "\(str(sc["id"]) ?? ""): plaintext fragment found in blob")
            }
        }
        print("  no-plaintext: TR-03 exact test + \(checked) fragments over all 97 scenario blobs")
    }
    do {
        // delete anonymizes (test_delete_anonymizes)
        let acct = AS.AccountStore(userId: 1, key: testKey, root: nil, fs: MemoryFS())
        let (_, ctx, chat, now) = filledTR03(scenarios, acct: acct)
        let before = chat.rows.first { $0.msgId == 1 }!
        try! chat.delete([1], now: now + 1)
        let anon = chat.rows.filter { !$0.live }
        T.check(anon.count == 1 && anon[0].msgId == 0 && anon[0].sender == 0, "delete: anonymous row")
        T.check(anon.first.map { $0.flags & AS.Flag.anon != 0 && $0.flags & ~(AS.Flag.anonKeep | AS.Flag.anon) == 0 } ?? false, "delete: flags keep only ACK|HAS_MEDIA_KEY|HAS_FWD_KEY|HAS_TEXT|TMPL_COND + ANON")
        T.check(anon.first?.links == before.links && anon.first?.keys == before.keys && anon.first?.date == before.date, "delete: keys / links / date kept")
        T.check(chat.decide(1, context: ctx, settings: AS.Settings(), now: now + 1).state == .untracked, "delete: decide → untracked")
        T.check(AS.ChatStore.deserialize(chat.serialize(), chatId: ctx.chatId, key: testKey) != nil, "delete: blob still valid")
    }
    do {
        // endorsement record upsert (test_endorse_record_upsert)
        let chat = AS.ChatStore(chatId: -1, key: testKey)
        let ctx = AS.ChatContext(chatId: -1)
        let m = AS.MessageInput(id: 5, date: 1000, sender: AS.Sender(id: 9, role: .admin), text: "今晚八點語音聊天室開放，歡迎大家來玩")
        for k in 0 ..< 300 {
            _ = try! chat.observe(m, context: ctx, now: 2000 + Int64(k))
        }
        T.check(chat.records.filter { $0.kind == AS.recordEndorse }.count == 1, "upsert: one endorsement record after 300 observes")
        T.check(chat.records.first?.stamp == 2299, "upsert: stamp = max")
        var edited = m
        edited.text = "改過的公告：今晚九點語音聊天室開放"
        _ = try! chat.observe(edited, context: ctx, now: 3000)
        T.check(chat.records.count == 1, "upsert: edit keeps one record")
        _ = try! chat.markNotAd(5, context: ctx, now: 3001)
        _ = try! chat.markNotAd(5, context: ctx, now: 3002)
        T.check(chat.records.filter { $0.kind == AS.recordNotAd }.count == 1, "not-ad: same content only refreshes stamp")
    }
    do {
        // not-ad record deterministic with > 64 keys (test_not_ad_record_deterministic)
        let common = ["一", "二"].map { "共用段落第\($0)段的內容要超過十六個中文字才會被當成段落鍵喔" }
        var msgs: [AS.MessageInput] = []
        let nums = Array("一二三四五")
        let stems = Array("甲乙丙丁戊己庚辛壬癸子丑寅卯")
        for i in 0 ..< 5 {
            let own = (0 ..< 14).map { j in "第\(nums[i])則訊息自己的段落之\(stems[j])，內容同樣要超過十六個中文字才算" }
            msgs.append(AS.MessageInput(id: Int32(i + 1), date: 1000 + Int64(i), sender: AS.Sender(id: Int64(100 + i)), text: (common + own).joined(separator: "\n")))
        }
        let ctx = AS.ChatContext(chatId: -1)
        var rng = SplitMix64(state: 7)
        var results = Set<String>()
        var firstKeys: [AS.Key] = []
        for _ in 0 ..< 6 {
            var order = msgs
            rng.shuffle(&order)
            let chat = AS.ChatStore(chatId: -1, key: testKey)
            for m in order {
                _ = try! chat.observe(m, context: ctx, now: 5000)
            }
            T.check((try? chat.markNotAd(3, context: ctx, now: 5001)) == true, "not-ad: mark")
            let rec = chat.records.first { $0.kind == AS.recordNotAd }!
            results.insert(rec.keys.map { "\($0.kind):\(hex($0.hash))" }.joined(separator: ",") + "|" + rec.links.map(hex).joined(separator: ","))
            firstKeys = rec.keys
        }
        T.check(results.count == 1, "not-ad: record independent of load order (\(results.count) variants)")
        T.check(firstKeys.count == 64, "not-ad: 64 keys")
        let kinds = firstKeys.map { $0.isExact ? 0 : 1 }
        T.check(kinds == kinds.sorted(), "not-ad: exact keys before paragraph keys")
        let fp3 = AS.fingerprint(msgs[2], context: ctx, key: testKey)
        let own = Set(fp3.keys.filter { $0.kind == .para }.map { AS.Key(kind: $0.kind.rawValue, hash: $0.hash) })
        T.check(own.isSubset(of: Set(firstKeys)), "not-ad: m's own paragraph keys kept")
    }
    do {
        // handles serialized sorted unsigned (test_handles_serialized_sorted_unsigned)
        let chat = AS.ChatStore(chatId: -1, key: testKey)
        let ctx = AS.ChatContext(chatId: -1)
        for i in 0 ..< 40 {
            _ = try! chat.observe(AS.MessageInput(id: Int32(i + 1), date: 1000 + Int64(i), sender: AS.Sender(id: Int64(i), username: String(format: "user_%03d", i)), text: "私聊我 t.me/+x\(i)"), context: ctx, now: 2000)
        }
        let blob = chat.serialize()
        let nH = Int(readLE(blob, 40, 4))
        let hs = (0 ..< nH).map { readLE(blob, blob.count - 32 * (nH - $0), 8) }
        T.check(hs == hs.sorted() && nH == 40, "handles sorted by unsigned hash")
        T.check(hs.contains { $0 >= 1 << 63 } && hs.contains { $0 < 1 << 63 }, "handles span both halves of u64")
    }
    do {
        // observe rejects out-of-range input (test_observe_rejects_out_of_range)
        let chat = AS.ChatStore(chatId: -1, key: testKey)
        let ctx = AS.ChatContext(chatId: -1)
        let base = AS.MessageInput(id: 1, date: 1000, sender: AS.Sender(id: 1), text: "私聊我 t.me/+abc")
        var bads: [AS.MessageInput] = []
        for id: Int32 in [0, -5, Int32.min] {
            var m = base
            m.id = id
            bads.append(m)
        }
        for d: Int64 in [-1, (1 << 40) + 1, Int64.max, Int64.min] {
            var m = base
            m.date = d
            bads.append(m)
        }
        for m in bads {
            T.check(observeIsNil(chat, m, ctx, 2000), "observe rejects id \(m.id) date \(m.date)")
        }
        T.check(observeIsNil(chat, base, ctx, -1), "observe rejects now -1")
        T.check(observeIsNil(chat, base, ctx, Int64.max), "observe rejects now Int64.max")
        T.check(chat.rowCount == 0, "nothing stored")
        // decide / compact with extreme `now` must not trap (overflow-free comparisons)
        _ = try? chat.observe(base, context: ctx, now: 2000)
        _ = chat.decide(1, context: ctx, settings: AS.Settings(), now: Int64.max)
        _ = chat.decide(1, context: ctx, settings: AS.Settings(), now: Int64.min)
        chat.compact(now: Int64.min)
        T.check(chat.rowCount == 1, "compact(Int64.min) keeps rows")
        chat.compact(now: Int64.max)
        T.check(chat.rowCount == 0, "compact(Int64.max) expires rows")
        // ineligible chats and messages
        let priv = AS.ChatContext(chatId: 5, type: .other)
        T.check(observeIsNil(chat, base, priv, 2000), "observe in ineligible chat")
        T.check(chat.decide(1, context: priv, settings: AS.Settings(), now: 2000).state == .ineligible, "decide in ineligible chat")
        for flag in 0 ..< 3 {
            var m = base
            m.service = flag == 0
            m.sponsored = flag == 1
            m.scheduled = flag == 2
            T.check(observeIsNil(chat, m, ctx, 2000), "service/sponsored/scheduled not observed")
        }
    }
    do {
        // eviction by max(date, seen) (test_eviction_by_max_date_seen)
        let chat = AS.ChatStore(chatId: -1, key: testKey)
        let ctx = AS.ChatContext(chatId: -1)
        _ = try! chat.observe(AS.MessageInput(id: 1, date: 0, sender: AS.Sender(id: 1), text: "私聊我領取 t.me/+abc"), context: ctx, now: 100 * AS.day)
        chat.compact(now: 108 * AS.day)
        T.check(chat.rowCount == 1, "eviction: kept at exactly 8 days")
        chat.compact(now: 108 * AS.day + 1)
        T.check(chat.rowCount == 0, "eviction: gone after 8 days")
    }
    do {
        // row cap 3000 (test_row_cap with the real cap): evicts min (max(date, seen), rowId)
        let chat = AS.ChatStore(chatId: -1, key: testKey)
        let ctx = AS.ChatContext(chatId: -1)
        for i in 1 ... 3005 {
            _ = try! chat.observe(AS.MessageInput(id: Int32(i), date: 1000 + Int64(i), sender: AS.Sender(id: Int64(i)), text: "私聊我 第\(i)號 t.me/+x\(i)"), context: ctx, now: 5000)
        }
        T.check(chat.rowCount == 3000, "row cap: 3000 rows (\(chat.rowCount))")
        T.check(Set(chat.rows.map { $0.msgId }) == Set((6 ... 3005).map { Int32($0) }), "row cap: msgIds 1…5 evicted")
        let blob = chat.serialize()
        T.check(AS.ChatStore.deserialize(blob, chatId: -1, key: testKey)?.rowCount == 3000, "row cap: 3000-row blob loads")
        print("  3000-row blob: \(blob.count) bytes")
    }
    T.end()
}

func observeIsNil(_ chat: AS.ChatStore, _ m: AS.MessageInput, _ ctx: AS.ChatContext, _ now: Int64) -> Bool {
    do {
        return try chat.observe(m, context: ctx, now: now) == nil
    } catch {
        return false
    }
}

func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty || needle.count > hay.count {
        return false
    }
    let first = needle[0]
    var i = 0
    while i <= hay.count - needle.count {
        if hay[i] == first && Array(hay[i ..< i + needle.count]) == needle {
            return true
        }
        i += 1
    }
    return false
}

func checkRejections() {
    T.begin("SPEC 8.3 rejection rules (crafted blobs)")
    let key = testKey
    let base = forgeBase()
    let good = base.serialize()
    let L = Layout(good)
    func load(_ b: [UInt8], chat: Int64 = chatIdForge, key k: [UInt8] = key) -> Bool {
        return AS.ChatStore.deserialize(b, chatId: chat, key: k) != nil
    }
    func patched(_ off: Int, _ v: UInt64, _ n: Int, rehashBody: Bool = true) -> [UInt8] {
        var b = good
        putLE(&b, off, v, n)
        return rehashBody ? rehash(b) : b
    }
    func reject(_ what: String, _ b: [UInt8], chat: Int64 = chatIdForge, key k: [UInt8] = key) {
        T.check(!load(b, chat: chat, key: k), "must reject: \(what)")
    }
    func accept(_ what: String, _ b: [UInt8]) {
        T.check(load(b), "must accept (control): \(what)")
    }
    // forge through internal state, re-serialized (bodyHash recomputed)
    func forged(_ mutate: (AS.ChatStore) -> Void) -> [UInt8] {
        let cs = forgeBase()
        mutate(cs)
        return cs.serialize()
    }
    let anonIdx = L.rows.firstIndex { readLE(good, $0.msgId, 4) == 0 }!
    let liveIdx = L.rows.firstIndex { readLE(good, $0.msgId, 4) != 0 }!
    let live = L.rows[liveIdx]
    let anon = L.rows[anonIdx]
    let rec = L.records[0]
    let hnd = L.handles[0]
    let maxDate = UInt64(1 << 40)

    accept("unmodified", good)
    accept("unmodified, rehashed", rehash(good))
    // header
    reject("empty", [])
    reject("length 55 (< 56)", Array(good.prefix(55)))
    reject("header only (56 bytes)", Array(good.prefix(56)))
    reject("magic", patched(0, 0x5341474D, 4))
    reject("formatVersion 1", patched(4, 1, 2))
    reject("formatVersion 3", patched(4, 3, 2))
    reject("algoVersion 1", patched(6, 1, 2))
    reject("algoVersion 3", patched(6, 3, 2))
    reject("tablesVersion", patched(8, UInt64(AdShieldTables.tablesVersionU32 ^ 1), 4))
    accept("reserved u32 is not checked (as the reference)", patched(12, 7, 4))
    reject("keyCheck field", patched(16, readLE(good, 16, 8) ^ 1, 8))
    reject("other key", good, key: [UInt8](repeating: 1, count: 16))
    reject("chatTag field", patched(24, readLE(good, 24, 8) ^ 1, 8))
    reject("other chat", good, chat: chatIdForge + 1)
    reject("bodyHash field", patched(48, readLE(good, 48, 8) ^ 1, 8, rehashBody: false))
    for pos in [56, 60, good.count / 2, good.count - 3] {
        var b = good
        b[pos] ^= 0x40
        reject("body byte \(pos) flipped (bodyHash)", b)
    }
    // counts (header, not covered by bodyHash)
    reject("rowCount 3001", patched(32, 3001, 4, rehashBody: false))
    reject("recordCount 401", patched(36, 401, 4, rehashBody: false))
    reject("handleCount 2001", patched(40, 2001, 4, rehashBody: false))
    reject("rowCount + 1 (structure mismatch)", patched(32, readLE(good, 32, 4) + 1, 4, rehashBody: false))
    reject("rowCount - 1 (trailing data)", patched(32, readLE(good, 32, 4) - 1, 4, rehashBody: false))
    reject("handleCount + 1 (truncated)", patched(40, readLE(good, 40, 4) + 1, 4, rehashBody: false))
    func endorse(_ i: Int) -> AS.Record {
        return AS.Record(kind: AS.recordEndorse, stamp: 5, msgKey: UInt64(i), keys: [], links: [])
    }
    func notAd(_ i: Int) -> AS.Record {
        return AS.Record(kind: AS.recordNotAd, stamp: 5, msgKey: 0, keys: [], links: [])
    }
    accept("200 endorsement records (forged)", forged { cs in cs.records = (0 ..< 200).map(endorse) })
    reject("201 endorsement records", forged { cs in cs.records = (0 ..< 201).map(endorse) })
    accept("200 not-ad records (forged)", forged { cs in cs.records = (0 ..< 200).map(notAd) })
    reject("201 not-ad records", forged { cs in cs.records = (0 ..< 201).map(notAd) })
    accept("200 + 200 records", forged { cs in cs.records = (0 ..< 200).map(endorse) + (0 ..< 200).map(notAd) })
    reject("401 records (200 + 201)", forged { cs in cs.records = (0 ..< 200).map(endorse) + (0 ..< 201).map(notAd) })
    // dates 0…2^40
    for (name, off) in [("row date", live.date), ("row seen", live.seen), ("anon row date", anon.date), ("record stamp", rec.stamp), ("handle first", hnd.first), ("handle last", hnd.last), ("handle seen", hnd.seen)] {
        reject("\(name) = -1", patched(off, UInt64(bitPattern: -1), 8))
        reject("\(name) = 2^40 + 1", patched(off, maxDate + 1, 8))
        reject("\(name) = Int64.min", patched(off, UInt64(bitPattern: Int64.min), 8))
    }
    accept("row seen = 2^40", patched(live.seen, maxDate, 8))
    accept("row date = 0", patched(live.date, 0, 8))
    accept("record stamp = 2^40", patched(rec.stamp, maxDate, 8))
    accept("handle seen = 2^40", patched(hnd.seen, maxDate, 8))
    do {
        let first = readLE(good, hnd.first, 8), last = readLE(good, hnd.last, 8)
        reject("handle first > last", patched(hnd.first, last + 1, 8))
        accept("handle first == last", patched(hnd.first, last, 8))
        _ = first
    }
    // msgId / anonymity
    reject("msgId 2^31", patched(live.msgId, 0x8000_0000, 4))
    reject("msgId 0xFFFFFFFF", patched(live.msgId, 0xFFFF_FFFF, 4))
    accept("msgId 2^31 - 1", patched(live.msgId, 0x7FFF_FFFF, 4))
    reject("msgId 0 without ANON flag", patched(live.msgId, 0, 4))
    reject("ANON flag with msgId != 0", patched(anon.msgId, 999_999, 4))
    reject("anonymous row with sender != 0", patched(anon.sender, 1, 8))
    reject("live row with ANON flag", patched(live.flags, readLE(good, live.flags, 4) | UInt64(AS.Flag.anon), 4))
    do {
        let other = L.rows.first { readLE(good, $0.msgId, 4) != 0 && $0.msgId != live.msgId }!
        reject("duplicate msgId", patched(other.msgId, readLE(good, live.msgId, 4), 4))
        let h2 = L.handles[1]
        reject("duplicate handle", patched(h2.hash, readLE(good, hnd.hash, 8), 8))
    }
    // reserved flag bits
    for bit in [9, 15, 17, 31] {
        reject("row flag bit \(bit)", patched(live.flags, readLE(good, live.flags, 4) | (UInt64(1) << UInt64(bit)), 4))
    }
    accept("row flag bit 30 (TMPL_COND) allowed", patched(live.flags, readLE(good, live.flags, 4) | (UInt64(1) << 30), 4))
    // element counts and kinds
    func keys(_ n: Int, kind: UInt8 = 1) -> [AS.Key] {
        return (0 ..< n).map { AS.Key(kind: kind, hash: UInt64($0) &* 0x9E37_79B9_7F4A_7C15) }
    }
    func hashes(_ n: Int) -> [UInt64] {
        return (0 ..< n).map { UInt64($0) &+ 77 }
    }
    accept("row with 22 keys", forged { cs in cs.rows[0].keys = keys(22) })
    reject("row with 23 keys", forged { cs in cs.rows[0].keys = keys(23) })
    accept("row with 16 links", forged { cs in cs.rows[0].links = hashes(16) })
    reject("row with 17 links", forged { cs in cs.rows[0].links = hashes(17) })
    accept("row with 16 pending", forged { cs in cs.rows[0].pending = hashes(16) })
    reject("row with 17 pending", forged { cs in cs.rows[0].pending = hashes(17) })
    accept("record with 64 keys", forged { cs in cs.records[0].keys = keys(64) })
    reject("record with 65 keys", forged { cs in cs.records[0].keys = keys(65) })
    accept("record with 64 links", forged { cs in cs.records[0].links = hashes(64) })
    reject("record with 65 links", forged { cs in cs.records[0].links = hashes(65) })
    for kind: UInt8 in [0, 8, 255] {
        reject("row key kind \(kind)", forged { cs in cs.rows[0].keys = keys(1, kind: kind) })
        reject("record key kind \(kind)", forged { cs in cs.records[0].keys = keys(1, kind: kind) })
    }
    for kind: UInt8 in 1 ... 7 {
        accept("row key kind \(kind)", forged { cs in cs.rows[0].keys = keys(1, kind: kind) })
    }
    for kind: UInt64 in [0, 3, 255] {
        reject("record kind \(kind)", patched(rec.kind, kind, 1))
    }
    T.check(live.firstKeyKind >= 0 && rec.firstKeyKind >= 0, "layout has keys")
    reject("row key kind byte 9 (patched)", patched(live.firstKeyKind, 9, 1))
    reject("record key kind byte 0 (patched)", patched(rec.firstKeyKind, 0, 1))
    reject("row nKeys 23 (patched)", patched(live.nKeys, 23, 1))
    reject("row nLinks 17 (patched)", patched(live.nLinks, 17, 1))
    reject("row nPend 17 (patched)", patched(live.nPend, 17, 1))
    reject("record nKeys 65 (patched)", patched(rec.nKeys, 65, 1))
    reject("record nLinks 65 (patched)", patched(rec.nLinks, 65, 1))
    // truncation and trailing bytes
    var truncRejected = 0
    for cut in 0 ..< good.count {
        let b = Array(good.prefix(cut))
        if !load(b) && !load(cut >= 56 ? rehash(b) : b) {
            truncRejected += 1
        }
    }
    T.check(truncRejected == good.count, "every truncation (with and without rehash) rejected: \(truncRejected)/\(good.count)")
    reject("1 trailing byte (rehashed)", rehash(good + [0]))
    reject("8 trailing bytes (rehashed)", rehash(good + [UInt8](repeating: 0, count: 8)))
    reject("trailing bytes (not rehashed)", good + [0])
    print("  base blob \(good.count) bytes: \(L.rows.count) rows, \(L.records.count) records, \(L.handles.count) handles")
    T.end()
}

func checkAccount(_ scenarios: [J]) {
    T.begin("account: ForgetAll, wipeRoot, purgeOrphans, cap")
    let msg = AS.MessageInput(id: 1, date: 1000, sender: AS.Sender(id: 5), text: "私聊我 t.me/+abc")
    func runForgetAll(_ fs: LuminaAdShieldFileSystem, _ d: String) {
        let acct = AS.AccountStore(userId: 777, key: testKey, root: d, fs: fs)
        let (sc, ctx, chat, now) = filledTR03(scenarios, acct: acct)
        T.check(acct.flush(), "flush writes")
        let acctDir = AS.joinPath(d, acct.dirName)
        T.check(!(fs.contentsOfDirectory(acctDir) ?? []).isEmpty, "account dir has files")
        for name in fs.contentsOfDirectory(acctDir) ?? [] {
            T.check(!name.contains("1001000000001") && !name.contains("777"), "file name reveals no id")
        }
        T.check(!acct.dirName.contains("777"), "dir name reveals no user id")
        // reload from disk (test_reload_from_disk)
        let acct2 = AS.AccountStore(userId: 777, key: testKey, root: d, fs: fs)
        T.check((try? acct2.chat(ctx.chatId))?.serialize() == chat.serialize(), "reload from disk")
        acct.forgetAll()
        T.check(acct.isForgotten, "forgotten flag")
        T.check(!fs.fileExists(acctDir), "account dir deleted")
        T.check(!acct.flush(), "flush refused after forgetAll")
        T.check(!acct.flush(chatId: ctx.chatId), "flush(chatId:) refused after forgetAll")
        T.check(!fs.fileExists(acctDir), "late flush did not recreate files")
        let m0 = message((sc["events"] as! [J])[0]["message"] as! J)
        do {
            _ = try chat.observe(m0, context: ctx, now: now)
            T.check(false, "observe must throw after forgetAll")
        } catch {
            T.check(error as? AS.StoreError == .forgotten, "observe throws .forgotten")
        }
        do {
            try chat.delete([1], now: now)
            T.check(false, "delete must throw after forgetAll")
        } catch {
            T.check(error as? AS.StoreError == .forgotten, "delete throws .forgotten")
        }
        do {
            _ = try chat.markNotAd(1, context: ctx, now: now)
            T.check(false, "markNotAd must throw after forgetAll")
        } catch {
            T.check(error as? AS.StoreError == .forgotten, "markNotAd throws .forgotten")
        }
        do {
            _ = try acct.chat(ctx.chatId)
            T.check(false, "chat() must throw after forgetAll")
        } catch {
            T.check(error as? AS.StoreError == .forgotten, "chat() throws .forgotten")
        }
        T.check(acct.loadedChatIds.isEmpty, "memory cleared")
    }
    let mem = MemoryFS()
    runForgetAll(mem, "/mem/fa")
    let tmpRoot = NSTemporaryDirectory() + "adshield-check-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64(Date().timeIntervalSince1970 * 1000))"
    let disk = LuminaAdShieldDiskFileSystem()
    T.check(disk.createDirectory(tmpRoot), "temp dir")
    runForgetAll(disk, tmpRoot + "/fa")

    for (fs, top) in [(mem as LuminaAdShieldFileSystem, "/mem"), (disk as LuminaAdShieldFileSystem, tmpRoot)] {
        let label = fs === mem ? "memory" : "disk"
        // purge orphans after key change (test_purge_orphans_after_key_change)
        let d = top + "/po"
        T.check(fs.createDirectory(d), "\(label): po dir")
        let old = AS.AccountStore(userId: 777, key: [UInt8](repeating: 1, count: 16), root: d, fs: fs)
        _ = try! old.chat(-1).observe(msg, context: AS.ChatContext(chatId: -1), now: 2000)
        T.check(old.flush(), "\(label): old flush")
        T.check(fs.writeFileAtomically(AS.joinPath(AS.joinPath(d, old.dirName), "junk.tmp.bin.x"), bytes: [0x78]), "\(label): junk")
        let new = AS.AccountStore(userId: 777, key: testKey, root: d, fs: fs)
        let other = AS.AccountStore(userId: 888, key: testKey, root: d, fs: fs)
        _ = try! other.chat(-2).observe(msg, context: AS.ChatContext(chatId: -2), now: 2000)
        T.check(other.flush(), "\(label): other flush")
        T.check(new.dirName != old.dirName, "\(label): new key → new dir name")
        // a stray file in the root and a non-LGAS .bin are orphans too
        T.check(fs.writeFileAtomically(AS.joinPath(d, "stray"), bytes: [1, 2, 3]), "\(label): stray")
        T.check(fs.writeFileAtomically(AS.joinPath(AS.joinPath(d, other.dirName), "bogus.bin"), bytes: [UInt8](repeating: 0x41, count: 40)), "\(label): bogus bin")
        let removed = AS.purgeOrphans(root: d, key: testKey, fs: fs)
        T.check((fs.contentsOfDirectory(d) ?? []) == [other.dirName], "\(label): only the current-key account dir remains: \(fs.contentsOfDirectory(d) ?? [])")
        T.check((fs.contentsOfDirectory(AS.joinPath(d, other.dirName)) ?? []) == [other.chatFileName(-2)], "\(label): only the valid chat file remains")
        T.check(removed == 4, "\(label): purge removed 4 entries (old .bin, junk, stray, bogus): \(removed)")

        // logout purges orphans; panic wipes the root (test_logout_purges_orphans_and_panic_wipes_root)
        let root = top + "/lg/luminagram_adshield"
        T.check(fs.createDirectory(top + "/lg"), "\(label): lg dir")
        let oldA = AS.AccountStore(userId: 1, key: [UInt8](repeating: 2, count: 16), root: root, fs: fs)
        _ = try! oldA.chat(-1).observe(msg, context: AS.ChatContext(chatId: -1), now: 2000)
        T.check(oldA.flush(), "\(label): flush creates root one level")
        let a = AS.AccountStore(userId: 1, key: testKey, root: root, fs: fs)
        let b = AS.AccountStore(userId: 2, key: testKey, root: root, fs: fs)
        for acct in [a, b] {
            _ = try! acct.chat(-1).observe(msg, context: AS.ChatContext(chatId: -1), now: 2000)
            T.check(acct.flush(), "\(label): flush")
        }
        a.forgetAll()
        T.check((fs.contentsOfDirectory(root) ?? []) == [b.dirName], "\(label): logout leaves only the other account")
        b.forgetAll(panic: true)
        T.check(!fs.fileExists(root), "\(label): panic wipes the root")
        T.check(!b.flush(), "\(label): flush refused after panic")
        // never recreate a missing parent (iOS: only under an existing account-<id>/)
        let orphanRoot = top + "/missing-account/lumina-adshield"
        let c = AS.AccountStore(userId: 3, key: testKey, root: orphanRoot, fs: fs)
        _ = try! c.chat(-1).observe(msg, context: AS.ChatContext(chatId: -1), now: 2000)
        T.check(!c.flush(), "\(label): flush refuses to create intermediate directories")
        T.check(!fs.fileExists(top + "/missing-account"), "\(label): missing parent not recreated")

        // disabled feature creates nothing (test_disabled_feature_creates_nothing)
        let dd = top + "/off"
        T.check(fs.createDirectory(dd), "\(label): off dir")
        let off = AS.AccountStore(userId: 5, key: testKey, root: dd, fs: fs)
        T.check((fs.contentsOfDirectory(dd) ?? ["x"]).isEmpty && !off.isForgotten, "\(label): no file before the first flush")
        // wipeRoot
        AS.wipeRoot(dd, fs: fs)
        T.check(!fs.fileExists(dd), "\(label): wipeRoot")
    }

    // total cap LRU by mtime (test_total_cap_lru_by_mtime), memory FS with controlled mtimes
    do {
        let fs = MemoryFS()
        let d = "/mem/cap"
        T.check(fs.createDirectory(d), "cap dir")
        let acct = AS.AccountStore(userId: 1, key: testKey, root: d, fs: fs)
        for i in 0 ..< 4 {
            _ = try! acct.chat(Int64(-i - 1)).observe(AS.MessageInput(id: 1, date: 1000, sender: AS.Sender(id: 5), text: "私聊我 t.me/+abc\(i)"), context: AS.ChatContext(chatId: Int64(-i - 1)), now: 2000)
        }
        T.check(acct.flush(), "cap flush")
        let dir = AS.joinPath(d, acct.dirName)
        let files = (fs.contentsOfDirectory(dir) ?? []).sorted()
        for (k, name) in files.enumerated() {
            fs.nodes[AS.joinPath(dir, name)]?.mtime = 1_000_000_000_000_000_000 + Int64(k)
        }
        let size = Int64(fs.readFile(AS.joinPath(dir, files[0]))?.count ?? 0)
        T.check(AS.enforceTotalCap(root: d, cap: 2 * size, fs: fs) == 2, "cap removed 2")
        T.check((fs.contentsOfDirectory(dir) ?? []).sorted() == Array(files[2...]), "cap removed the 2 oldest")
        T.check(AS.enforceTotalCap(root: d, fs: fs) == 0, "default 10 MiB cap removes nothing")
    }
    // disk: mtime order follows rename order
    do {
        let d = tmpRoot + "/capdisk"
        T.check(disk.createDirectory(d), "capdisk dir")
        let acct = AS.AccountStore(userId: 1, key: testKey, root: d, fs: disk)
        var order: [String] = []
        for i in 0 ..< 3 {
            let cid = Int64(-i - 1)
            _ = try! acct.chat(cid).observe(AS.MessageInput(id: 1, date: 1000, sender: AS.Sender(id: 5), text: "私聊我 t.me/+abc\(i)"), context: AS.ChatContext(chatId: cid), now: 2000)
            T.check(acct.flush(chatId: cid), "capdisk flush \(i)")
            order.append(acct.chatFileName(cid))
            usleep(20_000)
        }
        let dir = AS.joinPath(d, acct.dirName)
        let size = disk.fileSizeAndMtime(AS.joinPath(dir, order[0]))?.size ?? 0
        T.check(AS.enforceTotalCap(root: d, cap: size, fs: disk) == 2, "disk cap removed 2")
        T.check((disk.contentsOfDirectory(dir) ?? []) == [order[2]], "disk cap kept the newest")
    }
    disk.removeItem(tmpRoot)
    T.end()
}

// MARK: - timing

func now() -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds) / 1e6
}

func checkTiming() {
    T.begin("timing (3000-row chat)")
    let ctx = AS.ChatContext(chatId: -1001000000999, username: "perf_grp", memberHandles: ["perf_admin"])
    let chat = AS.ChatStore(chatId: ctx.chatId, key: testKey)
    let base: Int64 = 1_794_268_800
    var msgs: [AS.MessageInput] = []
    let templates = [
        "限時優惠！加V：%@，日賺3000不是夢，名額有限 t.me/+Room%@ 私聊我了解詳情",
        "高收益項目，每天穩定回報，詳情請看簡介，聯繫 @deal_%@ 或 https://bit.ly/x%@",
        "今天的行情分析已經更新，有興趣的朋友可以看看我們的頻道，連結在這裡 t.me/news_%@ 編號%@",
        "大家好，我是新來的，請多指教！這是我第一次在這個群組發言，希望可以認識更多朋友 https://example-%@.com/p%@"
    ]
    for i in 0 ..< 3000 {
        let cluster = i % 1000
        let t = templates[cluster % templates.count]
        let text = String(format: t, "acc\(cluster)x" as NSString, "\(cluster)" as NSString)
        let sender = Int64(10_000 + (i * 7919) % 900)
        let m = AS.MessageInput(id: Int32(i + 1), date: base + Int64(i) * 150, sender: AS.Sender(id: sender, username: "member_\(sender)"), text: text, media: i % 10 == 0 ? AS.Media(kind: .photo, id: String(Int64(cluster) * 1_000_003)) : nil)
        msgs.append(m)
    }
    let t0 = now()
    for m in msgs {
        _ = try! chat.observe(m, context: ctx, now: m.date)
    }
    let t1 = now()
    let lastNow = msgs.last!.date
    T.check(chat.rowCount == 3000, "3000 rows stored (\(chat.rowCount))")
    let st = AS.Settings()
    // cold: first decision after a change rebuilds the resolved units
    var coldTimes: [Double] = []
    for k in 0 ..< 5 {
        try! chat.delete([Int32(3000 - k)], now: lastNow)
        let a = now()
        _ = chat.decide(Int32(1500 + k), context: ctx, settings: st, now: lastNow)
        coldTimes.append(now() - a)
    }
    let a = now()
    var folded = 0
    for i in 1 ... 3000 {
        if chat.decide(Int32(i), context: ctx, settings: st, now: lastNow).fold {
            folded += 1
        }
    }
    let warmAll = now() - a
    var maxOne = 0.0
    for i in stride(from: 1, through: 3000, by: 97) {
        let b = now()
        _ = chat.decide(Int32(i), context: ctx, settings: st, now: lastNow)
        maxOne = max(maxOne, now() - b)
    }
    let blobStart = now()
    let blob = chat.serialize()
    let blobEnd = now()
    let back = AS.ChatStore.deserialize(blob, chatId: ctx.chatId, key: testKey)
    let loadEnd = now()
    T.check(back != nil, "3000-row blob loads")
    T.check(folded > 0, "the synthetic chat has folded messages (\(folded))")
    let coldMedian = coldTimes.sorted()[coldTimes.count / 2]
    print(String(format: "  observe: %.1f ms total for 3000 (%.3f ms each)", t1 - t0, (t1 - t0) / 3000))
    print(String(format: "  decide cold (after a change, rebuilds units): median %.2f ms, max %.2f ms", coldMedian, coldTimes.max() ?? 0))
    print(String(format: "  decide warm: all 3000 messages %.1f ms (%.4f ms each), slowest single %.3f ms; %d folded", warmAll, warmAll / 3000, maxOne, folded))
    print(String(format: "  serialize %.2f ms, deserialize %.2f ms (%d bytes)", blobEnd - blobStart, loadEnd - blobEnd, blob.count))
    T.end()
}

/// Extra generated corpora (e.g. differential fuzzing against ref/adshield.py): same shape as scenarios.json, with
/// optional per-expect "decisions" {sens: {id: [state, fold, class, rule, occurrence, groupSize, replyToMe]}} and a
/// final "blobHex" (the reference's serialize()), both compared exactly.
func checkExtraScenarios(_ path: String) {
    T.begin("extra scenarios: " + (path as NSString).lastPathComponent)
    let data = loadJSON(path)
    let scenarios = data["scenarios"] as! [J]
    var decisionChecks = 0
    var blobChecks = 0
    for sc in scenarios {
        let id = str(sc["id"]) ?? "?"
        let (results, chat) = runScenarioFull(sc)
        let expects = ((sc["events"] as? [J]) ?? []).enumerated().filter { str($0.element["op"]) == "expect" }
        for r in results {
            T.check(r.got == r.want, "\(id) event#\(r.index) \(r.sens.rawValue): want fold \(r.want), got \(r.got)")
            T.check(r.badStates.isEmpty, "\(id) event#\(r.index) \(r.sens.rawValue): states \(r.badStates)")
            guard let ev = expects.first(where: { $0.offset == r.index })?.element,
                  let want = (ev["decisions"] as? J)?[r.sens.rawValue] as? J else {
                continue
            }
            for (sid, tuple) in want {
                let w = tuple as! [Any]
                let d = r.decisions[Int32(sid)!]!
                let got: [String] = [d.state.rawValue, d.fold ? "1" : "0", d.cls?.rawValue ?? "", d.rule?.rawValue ?? "", String(d.occurrence), String(d.groupSize), d.replyToMe ? "1" : "0"]
                let exp: [String] = [w[0] as! String, bool(w[1]) ? "1" : "0", w[2] as! String, w[3] as! String, String(i64(w[4])), String(i64(w[5])), bool(w[6]) ? "1" : "0"]
                decisionChecks += 1
                T.check(got == exp, "\(id) event#\(r.index) \(r.sens.rawValue) id \(sid): want \(exp) got \(got)")
            }
        }
        if let blobHex = str(sc["blobHex"]) {
            blobChecks += 1
            let mine = chat.serialize()
            T.check(mine == bytesFromHex(blobHex), "\(id): serialize() differs from the reference blob (\(mine.count) vs \(blobHex.utf8.count / 2) bytes)")
        }
    }
    print("  \(scenarios.count) scenarios, \(decisionChecks) full decisions, \(blobChecks) byte-exact blobs")
    T.end()
}

// MARK: - main

@main
struct AdShieldCheck {
    static func main() {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let args = CommandLine.arguments
        let skipTiming = args.contains("--no-timing")
        var extraFingerprints: [String] = []
        var extraScenarios: [String] = []
        for (i, a) in args.enumerated() where i + 1 < args.count {
            if a == "--extra-fingerprints" { extraFingerprints.append(args[i + 1]) }
            if a == "--extra-scenarios" { extraScenarios.append(args[i + 1]) }
        }
        print("AdShield iOS checker – tables \(AdShieldTables.tablesVersion), algo \(AS.algoVersion), format \(AS.formatVersion)")
        checkNormalize(dir)
        checkSipHash(dir)
        checkFingerprints(dir)
        let scenarios = checkScenarios(dir)
        checkShuffle(scenarios)
        checkStorage(scenarios)
        checkRejections()
        checkAccount(scenarios)
        for p in extraFingerprints {
            checkFingerprintFile(p, title: "extra fingerprints: " + (p as NSString).lastPathComponent, expectedCount: nil)
        }
        for p in extraScenarios {
            checkExtraScenarios(p)
        }
        if !skipTiming {
            checkTiming()
        }
        var ok = 0
        var bad = 0
        print("\nSummary")
        for (n, o, b) in T.sections {
            print(String(format: "  %-44@ %6d ok %4d failed", n as NSString, o, b))
            ok += o
            bad += b
        }
        print("TOTAL \(ok) ok, \(bad) failed")
        exit(bad == 0 && ok > 0 ? 0 : 1)
    }
}
