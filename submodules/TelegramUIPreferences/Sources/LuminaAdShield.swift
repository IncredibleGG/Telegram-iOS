import Foundation

// LuminaGram AdShield ("隱藏重複廣告" / hide repeated ads): the pure-logic core, ported function by function
// from the shared reference engine `adshield/ref/adshield.py` (algoVersion 2, formatVersion 2). The rules are
// normative in `adshield/SPEC.md`; this file and `LuminaAdShieldStore.swift` must reproduce the shared vectors
// and scenarios byte for byte (checker: `lumina-dev/adshield-check/`, not part of any BUILD target).
//
// What lives here: the data model the platform fills in (`MessageInput`, `ChatContext`, `Settings`, `Decision`),
// link extraction (SPEC §4), `fingerprint` (SPEC §3, §5) and `resolve` (SPEC §5.5). Normalization, SipHash and
// the word lists are the generated `AdShieldTables.swift` (do not hand-edit; regenerate with gen_tables.py).
//
// SPEC §1 rules this port follows everywhere:
//  - after `AdShieldTables.fold` everything is `[UInt32]` (Unicode scalars): no String / Character / Foundation
//    comparison, search, split or sort (they use canonical equivalence / grapheme clusters);
//  - "all digits" means ASCII 0-9 only; usernames go through `fold`; ordering is code-point order on `[UInt32]`;
//  - hashes are UInt64 and compared unsigned; no result depends on Dictionary / Set iteration order;
//  - the URL-query dictionary is built with `Dictionary(_:uniquingKeysWith:)` (last key wins, never traps).
// The regular expressions of SPEC §4.2 are implemented as hand-written scanners over `[UInt32]` with exactly the
// backtracking semantics of the reference patterns (each scanner documents why it is equivalent), so indices are
// scalar indices by construction and there is no NSRegularExpression / UTF-16 conversion or ICU stack limit.
//
// Pure logic: no UI, no logging, no Postbox / TelegramCore types. Not thread-safe by design: see
// `LuminaAdShieldStore.swift` for the single-queue confinement rule.
public enum LuminaAdShield {
    public static let algoVersion: UInt16 = 2
    public static let formatVersion: UInt16 = 2

    // ---- Length thresholds (SPEC §3) ----
    static let minTextWlen = 12
    static let minTmplWlen = 4
    static let minCjkCount = 8
    static let paraMinWlen = 32
    static let maxPara = 16
    static let pureTextMinCjk = 12
    static let pureTextMinLetters = 24
    static let ackRemainderMax = 2
    static let massMention = 3
    static let gapMax = 4
    static let numCtxWindow = 12
    static let pointerNegWindow = 4

    // ---- Time (Unix seconds) ----
    public static let minute: Int64 = 60
    public static let hour: Int64 = 3600
    public static let day: Int64 = 86400
    static let knownMemberMinAge: Int64 = 86400

    // ---- Storage limits (SPEC §8.2) ----
    static let evictAfter: Int64 = 8 * 86400
    static let recordTTL: Int64 = 90 * 86400
    static let handleTTL: Int64 = 30 * 86400
    public static let maxRows = 3000
    static let maxEndorseRecords = 200
    static let maxNotAdRecords = 200
    static let maxHandles = 2000
    static let maxLinksPerRow = 16
    static let maxPendingPerRow = 16
    static let maxRowKeys = 22
    static let maxRecordKeys = 64
    static let maxRecordLinks = 64
    public static let totalCapBytes: Int64 = 10 * 1024 * 1024
    public static let maxLoadedChats = 8
    public static let maxDate: Int64 = 1 << 40
    static let maxMsgId: Int64 = 0x7FFFFFFF

    // ---- Fingerprint key kinds (1-byte storage code, hash tag) ----
    public enum KeyKind: UInt8, CaseIterable, Sendable {
        case fwd = 1
        case media = 2
        case text = 3
        case cjk = 4
        case tmpl = 5
        case para = 6
        case contact = 7

        public var tag: String {
            switch self {
            case .fwd: return "fwd"
            case .media: return "media"
            case .text: return "text"
            case .cjk: return "cjk"
            case .tmpl: return "tmpl"
            case .para: return "para"
            case .contact: return "contact"
            }
        }

        public var name: String {
            switch self {
            case .fwd: return "FWD"
            case .media: return "MEDIA"
            case .text: return "TEXT"
            case .cjk: return "CJK"
            case .tmpl: return "TMPL"
            case .para: return "PARA"
            case .contact: return "CONTACT"
            }
        }

        /// Every kind except PARA is an exact key (one shared exact key is enough to cluster).
        public var isExact: Bool {
            return self != .para
        }
    }

    /// A stored fingerprint key: (kind, H(tag, payload)). Ordered by (kind, hash unsigned).
    public struct Key: Hashable, Comparable, Sendable {
        public let kind: UInt8
        public let hash: UInt64

        public init(kind: UInt8, hash: UInt64) {
            self.kind = kind
            self.hash = hash
        }

        public static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.kind != rhs.kind {
                return lhs.kind < rhs.kind
            }
            return lhs.hash < rhs.hash
        }

        var isExact: Bool {
            return self.kind != KeyKind.para.rawValue
        }
    }

    // ---- Feature and flag bits (stored row flags, SPEC §5.2) ----
    public enum Flag {
        public static let strongInvite: UInt32 = 1 << 0
        public static let strongHandle: UInt32 = 1 << 1
        public static let strongShortener: UInt32 = 1 << 2
        public static let strongButton: UInt32 = 1 << 3
        public static let strongViaBot: UInt32 = 1 << 4
        public static let strongContactCard: UInt32 = 1 << 5
        public static let strongPhone: UInt32 = 1 << 6
        public static let strongAccount: UInt32 = 1 << 7
        public static let strongPointer: UInt32 = 1 << 8
        public static let weakUrl: UInt32 = 1 << 10
        public static let weakMemberMention: UInt32 = 1 << 11
        public static let weakLongNumber: UInt32 = 1 << 12
        public static let weakMassMention: UInt32 = 1 << 13
        public static let weakEmail: UInt32 = 1 << 14
        public static let hasText: UInt32 = 1 << 16
        /// Never stored; computed by `resolve` at decision time.
        public static let mediaOnly: UInt32 = 1 << 17
        public static let pureText: UInt32 = 1 << 18
        public static let ack: UInt32 = 1 << 19
        public static let replyMe: UInt32 = 1 << 20
        public static let mentionMe: UInt32 = 1 << 21
        public static let isReply: UInt32 = 1 << 22
        public static let endorsing: UInt32 = 1 << 23
        public static let bot: UInt32 = 1 << 24
        public static let contact: UInt32 = 1 << 25
        public static let selfSender: UInt32 = 1 << 26
        public static let hasMediaKey: UInt32 = 1 << 27
        public static let hasFwdKey: UInt32 = 1 << 28
        public static let anon: UInt32 = 1 << 29
        public static let tmplCond: UInt32 = 1 << 30

        public static let strongMask: UInt32 = 0x1FF
        public static let weakMask: UInt32 = 0x7C00
        static let anonKeep: UInt32 = ack | hasMediaKey | hasFwdKey | hasText | tmplCond
        /// Every bit a stored row may carry (bits 9, 15, 17 and 31 are reserved and rejected on load).
        static let storedMask: UInt32 = strongMask | weakMask | hasText | pureText | ack | replyMe | mentionMe
            | isReply | endorsing | bot | contact | selfSender | hasMediaKey | hasFwdKey | anon | tmplCond

        /// Names in SPEC order (bit, name) for tests and debugging.
        public static let strongNames: [(UInt32, String)] = [
            (strongInvite, "invite"), (strongHandle, "handle"), (strongShortener, "shortener"),
            (strongButton, "button"), (strongViaBot, "via_bot"), (strongContactCard, "contact_card"),
            (strongPhone, "phone"), (strongAccount, "account"), (strongPointer, "pointer")
        ]
        public static let weakNames: [(UInt32, String)] = [
            (weakUrl, "url"), (weakMemberMention, "member_mention"), (weakLongNumber, "long_number"),
            (weakMassMention, "mass_mention"), (weakEmail, "email")
        ]
    }

    // ===========================================================================
    // Data model (SPEC §9.1). The integration maps native messages to these.
    // ===========================================================================

    public enum ChatType: String, Sendable {
        case group
        case supergroup
        case forum
        case gigagroup
        /// Private chats, secret chats, Saved Messages, broadcast channels, bots: always `ineligible`.
        case other
    }

    public enum Role: String, Sendable {
        case member
        case admin
        case creator
        case anonAdmin = "anon_admin"
        case bot
        case contact
        case selfUser = "self"
        case channel
    }

    public struct Sender: Sendable {
        /// Bot API style id (users `<id>`, channels `-100<id>`); an anonymous admin uses the group id. 0 if unknown.
        public var id: Int64
        public var role: Role
        public var username: String?

        public init(id: Int64, role: Role = .member, username: String? = nil) {
            self.id = id
            self.role = role
            self.username = username
        }
    }

    public enum Entity: Sendable {
        /// Hidden link (`text_url`).
        case textUrl(String)
        /// `mention_name` (a mention of a user without a username).
        case mentionName(userId: Int64)
    }

    public enum MediaKind: String, Sendable {
        case photo
        case video
        case document
        case audio
        case contact
        case sticker
        case gif
        case voice
        case round
        case dice
        case location
        case venue
        case poll
        case webpage
        case game
        case story
        case invoice
        case giveaway
        case paid
    }

    public struct Media: Sendable {
        public var kind: MediaKind
        /// Photo / document id as the decimal string of the SIGNED Int64 (iOS `MediaId.id` directly).
        public var id: String?
        /// Contact card: user id (0 if none).
        public var userId: Int64
        /// Contact card: phone number as entered.
        public var phone: String?

        public init(kind: MediaKind, id: String? = nil, userId: Int64 = 0, phone: String? = nil) {
            self.kind = kind
            self.id = id
            self.userId = userId
            self.phone = phone
        }
    }

    public enum ForwardKind: String, Sendable {
        case channel
        case user
        case hidden
    }

    public struct Forward: Sendable {
        public var fromKind: ForwardKind
        public var fromId: Int64
        public var postId: Int32
        public var fromName: String?
        public var username: String?
        public var date: Int64

        public init(fromKind: ForwardKind, fromId: Int64 = 0, postId: Int32 = 0, fromName: String? = nil, username: String? = nil, date: Int64 = 0) {
            self.fromKind = fromKind
            self.fromId = fromId
            self.postId = postId
            self.fromName = fromName
            self.username = username
            self.date = date
        }
    }

    public struct MessageInput: Sendable {
        public var id: Int32
        public var date: Int64
        public var sender: Sender
        /// Message text, or the caption when there is media.
        public var text: String
        /// In the original entity order; only `text_url` and `mention_name` matter.
        public var entities: [Entity]
        /// Directly attached media only (never a web-page preview's photo; SPEC §3 whitelist).
        public var media: Media?
        /// grouped_id, 0 = not an album.
        public var album: Int64
        public var forward: Forward?
        /// URL buttons of the reply markup.
        public var buttons: [String]
        public var viaBot: Bool
        public var replyToMe: Bool
        public var mentionsMe: Bool
        public var pinned: Bool
        public var autoForward: Bool
        public var service: Bool
        public var sponsored: Bool
        public var scheduled: Bool
        /// Replied-to message id; nil or 0 = not a reply.
        public var replyTo: Int32?

        public init(
            id: Int32,
            date: Int64,
            sender: Sender,
            text: String = "",
            entities: [Entity] = [],
            media: Media? = nil,
            album: Int64 = 0,
            forward: Forward? = nil,
            buttons: [String] = [],
            viaBot: Bool = false,
            replyToMe: Bool = false,
            mentionsMe: Bool = false,
            pinned: Bool = false,
            autoForward: Bool = false,
            service: Bool = false,
            sponsored: Bool = false,
            scheduled: Bool = false,
            replyTo: Int32? = nil
        ) {
            self.id = id
            self.date = date
            self.sender = sender
            self.text = text
            self.entities = entities
            self.media = media
            self.album = album
            self.forward = forward
            self.buttons = buttons
            self.viaBot = viaBot
            self.replyToMe = replyToMe
            self.mentionsMe = mentionsMe
            self.pinned = pinned
            self.autoForward = autoForward
            self.service = service
            self.sponsored = sponsored
            self.scheduled = scheduled
            self.replyTo = replyTo
        }
    }

    /// Per-chat context. Usernames are folded once here; the trusted tokens / domains of the chat (its own
    /// username, the linked channel, every link in the description and in pinned messages) are extracted eagerly
    /// so the value is immutable and cheap to pass to every call.
    public struct ChatContext: Sendable {
        public let chatId: Int64
        public let type: ChatType
        /// Folded, leading "@" removed.
        public let username: [UInt32]
        public let linkedChannelId: Int64
        public let linkedChannelUsername: [UInt32]
        public let description: String
        public let pinnedTexts: [String]
        /// false while the admin list is not loaded: every decision is `pending`.
        public let adminsKnown: Bool
        /// Folded usernames always treated as known members (at least the loaded admins and the bots in the chat).
        public let memberHandles: [[UInt32]]
        /// My own folded username ("@me" is never a feature).
        public let selfUsername: [UInt32]
        let trustedTokens: Set<[UInt32]>
        let trustedDomains: Set<[UInt32]>

        public init(
            chatId: Int64,
            type: ChatType = .supergroup,
            username: String? = nil,
            linkedChannelId: Int64 = 0,
            linkedChannelUsername: String? = nil,
            description: String = "",
            pinnedTexts: [String] = [],
            adminsKnown: Bool = true,
            memberHandles: [String] = [],
            selfUsername: String? = nil
        ) {
            self.chatId = chatId
            self.type = type
            self.username = LuminaAdShield.uname(username)
            self.linkedChannelId = linkedChannelId
            self.linkedChannelUsername = LuminaAdShield.uname(linkedChannelUsername)
            self.description = description
            self.pinnedTexts = pinnedTexts
            self.adminsKnown = adminsKnown
            self.memberHandles = memberHandles.map { LuminaAdShield.uname($0) }
            self.selfUsername = LuminaAdShield.uname(selfUsername)

            var tokens = Set<[UInt32]>()
            var domains = Set<[UInt32]>()
            for h in [self.username, self.linkedChannelUsername] where !h.isEmpty {
                tokens.insert([0x40] + h)
            }
            for text in [description] + pinnedTexts {
                let ex = LuminaAdShield.extractLinks(AdShieldTables.fold(text))
                for var link in ex.links {
                    LuminaAdShield.normalizePhoneToken(&link)
                    tokens.insert(link.token)
                    if (link.kind == .url || link.kind == .mail) && !link.shortener && !link.domain.isEmpty {
                        domains.insert(link.domain)
                    }
                }
            }
            self.trustedTokens = tokens
            self.trustedDomains = domains
        }
    }

    public enum Sensitivity: String, CaseIterable, Sendable {
        case loose
        case standard
        case aggressive
    }

    public struct Settings: Equatable, Sendable {
        public var sensitivity: Sensitivity
        public var exemptContacts: Bool
        public var exemptBots: Bool
        public var exemptReplies: Bool
        /// Changes only the UI ("suspected repeated ad" mark instead of folding); never the Decision.
        public var dryRun: Bool

        public init(sensitivity: Sensitivity = .standard, exemptContacts: Bool = true, exemptBots: Bool = true, exemptReplies: Bool = true, dryRun: Bool = false) {
            self.sensitivity = sensitivity
            self.exemptContacts = exemptContacts
            self.exemptBots = exemptBots
            self.exemptReplies = exemptReplies
            self.dryRun = dryRun
        }
    }

    public struct Decision: Equatable, Sendable {
        public enum State: String, Sendable {
            case ineligible
            case untracked
            case pending
            case endorsed
            case notAd = "not_ad"
            /// SPEC name "none": no rule triggered.
            case notTriggered = "none"
            case original
            case exempt
            case fold
        }

        public enum Class: String, Sendable {
            case strong
            case weak
            case plain
            case impersonation
        }

        public enum Rule: String, Sendable {
            case strong
            case weak
            case mediaSameSender = "media_same_sender"
            case fwdSameSender = "fwd_same_sender"
            case plain
        }

        public var state: State
        public var fold: Bool
        public var cls: Class?
        public var rule: Rule?
        /// "N-th occurrence within 7 days" for the folded row's label.
        public var occurrence: Int
        public var groupSize: Int
        /// The folded message replies to / mentions me (label "1 repeated message replying to you").
        public var replyToMe: Bool

        public init(state: State = .notTriggered, fold: Bool = false, cls: Class? = nil, rule: Rule? = nil, occurrence: Int = 0, groupSize: Int = 0, replyToMe: Bool = false) {
            self.state = state
            self.fold = fold
            self.cls = cls
            self.rule = rule
            self.occurrence = occurrence
            self.groupSize = groupSize
            self.replyToMe = replyToMe
        }
    }

    // ---- Links ----

    public enum LinkKind: String, Sendable {
        case invite
        case handle
        case url
        case phone
        case acct
        case mail
    }

    public enum LinkSource: String, Sendable {
        case text
        case hidden
        case button
        case media
    }

    public enum LinkFeature: String, Sendable {
        case strong
        case weak
        case member
        case pending
        /// SPEC name "none": trusted or not a feature.
        case notCounted = "none"
    }

    public struct Link: Sendable {
        /// Normalized token, e.g. "@abc", "invite:xyz", "url:example.com/a", "uid:123", "tel:8613812345678".
        public var token: [UInt32]
        public var kind: LinkKind
        /// Template type: INVITE / HANDLE / SHORT / URL:<registrable domain> / PHONE / ACCT:<class> / MAIL.
        public var type: [UInt32]
        /// Registrable domain of url / mail links (empty otherwise).
        public var domain: [UInt32]
        public var shortener: Bool
        public var source: LinkSource

        init(_ token: [UInt32], _ kind: LinkKind, _ type: [UInt32], domain: [UInt32] = [], shortener: Bool = false, source: LinkSource = .text) {
            self.token = token
            self.kind = kind
            self.type = type
            self.domain = domain
            self.shortener = shortener
            self.source = source
        }
    }

    public struct Extraction: Sendable {
        /// F′: F with every extracted range replaced by one U+0020.
        public var fNoLinks: [UInt32]
        public var links: [Link]
        /// Text @handles (incl. "@ handle"), without the "@".
        public var mentions: [[UInt32]]
        public var pointer: Bool
        /// Long numbers that are not dates, prices or order numbers.
        public var longNumbers: [[UInt32]]
    }

    public struct FingerprintKey: Sendable {
        public var kind: KeyKind
        public var payload: [UInt32]
        public var hash: UInt64
    }

    public struct Fingerprint: Sendable {
        public var f: [UInt32]
        public var fNoLinks: [UInt32]
        public var t: [UInt32]
        public var tCjk: [UInt32]
        public var wlen: Int
        public var cjkCount: Int
        public var letterCount: Int
        public var paragraphs: [[UInt32]]
        public var links: [Link]
        public var linkFeatures: [LinkFeature]
        /// Fixed strong / weak features as bits (pending handles not included).
        public var strongFlags: UInt32
        public var weakFlags: UInt32
        /// FWD → MEDIA → TEXT → CJK → TMPL → CONTACT → PARA….
        public var keys: [FingerprintKey]
        /// Subset links H("link", token) for the endorsement subset check (fixed part).
        public var linkHashes: [UInt64]
        /// Pending handles H("link", "@name"), decided at decision time.
        public var pending: [UInt64]
        /// Stored flags (no pending-handle contribution, no MEDIA_ONLY).
        public var flags: UInt32
        public var senderKey: UInt64
        public var store: Bool
        public var endorsing: Bool
        public var mentionCount: Int
        /// Resolved with `knownHandles` ∪ context.memberHandles (vectors only).
        public var resolvedFlags: UInt32

        public var strong: [String] {
            return LuminaAdShield.sortedNames(self.strongFlags, Flag.strongNames)
        }

        public var weak: [String] {
            return LuminaAdShield.sortedNames(self.weakFlags, Flag.weakNames)
        }

        public var resolvedStrong: [String] {
            return LuminaAdShield.sortedNames(self.resolvedFlags, Flag.strongNames)
        }

        public var resolvedWeak: [String] {
            return LuminaAdShield.sortedNames(self.resolvedFlags, Flag.weakNames)
        }
    }

    static func sortedNames(_ flags: UInt32, _ names: [(UInt32, String)]) -> [String] {
        var out: [[UInt8]] = []
        for (bit, name) in names where flags & bit != 0 {
            out.append(Array(name.utf8))
        }
        out.sort { $0.lexicographicallyPrecedes($1) }
        return out.map { String(decoding: $0, as: UTF8.self) }
    }
}

// ===========================================================================
// Scalar helpers (everything after fold is [UInt32]; SPEC §1 rule 2)
// ===========================================================================

extension LuminaAdShield {
    @inline(__always) static func sc(_ s: String) -> [UInt32] {
        return s.unicodeScalars.map { $0.value }
    }

    @inline(__always) static func isLower(_ c: UInt32) -> Bool {
        return c >= 0x61 && c <= 0x7A
    }

    @inline(__always) static func isDigit(_ c: UInt32) -> Bool {
        return c >= 0x30 && c <= 0x39
    }

    /// [a-z0-9]
    @inline(__always) static func isAlnum(_ c: UInt32) -> Bool {
        return (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
    }

    /// [a-z0-9_]
    @inline(__always) static func isWordChar(_ c: UInt32) -> Bool {
        return isAlnum(c) || c == 0x5F
    }

    /// [a-z0-9\-]
    @inline(__always) static func isLabelChar(_ c: UInt32) -> Bool {
        return isAlnum(c) || c == 0x2D
    }

    /// URL body class [a-z0-9\-._~:/?#@!$&*+,;=%]
    @inline(__always) static func isUrlChar(_ c: UInt32) -> Bool {
        if isAlnum(c) {
            return true
        }
        switch c {
        case 0x2D, 0x2E, 0x5F, 0x7E, 0x3A, 0x2F, 0x3F, 0x23, 0x40, 0x21, 0x24, 0x26, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D, 0x25:
            return true
        default:
            return false
        }
    }

    /// Look-behind class of rounds 2, 3 and 5: [a-z0-9_\-.@/]
    @inline(__always) static func isNotBefore(_ c: UInt32) -> Bool {
        return isAlnum(c) || c == 0x5F || c == 0x2D || c == 0x2E || c == 0x40 || c == 0x2F
    }

    /// Email local part [a-z0-9._%+\-]
    @inline(__always) static func isEmailLocal(_ c: UInt32) -> Bool {
        return isAlnum(c) || c == 0x2E || c == 0x5F || c == 0x25 || c == 0x2B || c == 0x2D
    }

    /// Account body [a-z0-9_\-.]
    @inline(__always) static func isAcctChar(_ c: UInt32) -> Bool {
        return isAlnum(c) || c == 0x5F || c == 0x2D || c == 0x2E
    }

    /// Phone separator [ \-.]
    @inline(__always) static func isPhoneSep(_ c: UInt32) -> Bool {
        return c == 0x20 || c == 0x2D || c == 0x2E
    }

    /// Trailing characters trimmed from URL matches: . , ; : ! ? *
    @inline(__always) static func isTrim(_ c: UInt32) -> Bool {
        switch c {
        case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x2A:
            return true
        default:
            return false
        }
    }

    /// Python `str.isspace()` (used only by `str.strip()` in canonicalize; after fold only U+0020 / U+000A remain).
    @inline(__always) static func isPyWhitespace(_ c: UInt32) -> Bool {
        switch c {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    @inline(__always) static func startsWith(_ s: [UInt32], _ at: Int, _ lit: [UInt32]) -> Bool {
        if at < 0 || at + lit.count > s.count {
            return false
        }
        var k = 0
        while k < lit.count {
            if s[at + k] != lit[k] {
                return false
            }
            k += 1
        }
        return true
    }

    static func hasPrefix(_ s: [UInt32], _ p: [UInt32]) -> Bool {
        return startsWith(s, 0, p)
    }

    static func hasSuffix(_ s: [UInt32], _ p: [UInt32]) -> Bool {
        return startsWith(s, s.count - p.count, p)
    }

    /// First occurrence of `w` in `s` at or after `from` (Python `str.find`).
    static func find(_ s: [UInt32], _ w: [UInt32], from: Int = 0) -> Int? {
        if w.isEmpty {
            return from <= s.count ? from : nil
        }
        if s.count < w.count {
            return nil
        }
        let first = w[0]
        var i = max(from, 0)
        let last = s.count - w.count
        while i <= last {
            if s[i] == first && startsWith(s, i, w) {
                return i
            }
            i += 1
        }
        return nil
    }

    static func contains(_ s: [UInt32], _ w: [UInt32]) -> Bool {
        return find(s, w) != nil
    }

    /// Python `s.replace(w, "")`: non-overlapping, left to right.
    static func removeAll(_ s: [UInt32], _ w: [UInt32]) -> [UInt32] {
        if w.isEmpty || s.count < w.count {
            return s
        }
        var out: [UInt32] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if s[i] == w[0] && startsWith(s, i, w) {
                i += w.count
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    /// Python `s.split(sep)` (keeps empty pieces).
    static func split(_ s: [UInt32], _ sep: UInt32) -> [[UInt32]] {
        var out: [[UInt32]] = []
        var cur: [UInt32] = []
        for c in s {
            if c == sep {
                out.append(cur)
                cur = []
            } else {
                cur.append(c)
            }
        }
        out.append(cur)
        return out
    }

    /// Python `s.partition(sep)` → (head, tail) without the separator; tail empty if absent.
    static func partition(_ s: [UInt32], _ sep: UInt32) -> ([UInt32], [UInt32]) {
        if let i = s.firstIndex(of: sep) {
            return (Array(s[0 ..< i]), Array(s[(i + 1)...]))
        }
        return (s, [])
    }

    static func strip(_ s: [UInt32], _ ch: UInt32) -> [UInt32] {
        var a = 0
        var b = s.count
        while a < b && s[a] == ch {
            a += 1
        }
        while b > a && s[b - 1] == ch {
            b -= 1
        }
        return Array(s[a ..< b])
    }

    static func rstrip(_ s: [UInt32], _ ch: UInt32) -> [UInt32] {
        var b = s.count
        while b > 0 && s[b - 1] == ch {
            b -= 1
        }
        return Array(s[0 ..< b])
    }

    static func digitsOnly(_ s: [UInt32]) -> [UInt32] {
        return s.filter { isDigit($0) }
    }

    static func digitsOnly(_ s: ArraySlice<UInt32>) -> [UInt32] {
        return s.filter { isDigit($0) }
    }

    /// SPEC §1 rule 4: non-empty and every scalar is ASCII 0-9.
    static func isAllDigits(_ s: [UInt32]) -> Bool {
        if s.isEmpty {
            return false
        }
        for c in s where !isDigit(c) {
            return false
        }
        return true
    }

    /// `[a-z][a-z0-9_]{3,31}` full match.
    static func validUsername(_ s: [UInt32]) -> Bool {
        if s.count < 4 || s.count > 32 || !isLower(s[0]) {
            return false
        }
        for c in s.dropFirst() where !isWordChar(c) {
            return false
        }
        return true
    }

    static func join(_ parts: [[UInt32]], _ sep: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        for (i, p) in parts.enumerated() {
            if i > 0 {
                out.append(sep)
            }
            out.append(contentsOf: p)
        }
        return out
    }

    /// Code-point order (= UTF-8 byte order).
    @inline(__always) static func cpLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        return a.lexicographicallyPrecedes(b)
    }

    /// UTF-8 bytes of a scalar array (scalars come from `unicodeScalars`, so they are valid by construction).
    static func utf8(_ s: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        for c in s {
            if c < 0x80 {
                out.append(UInt8(c))
            } else if c < 0x800 {
                out.append(UInt8(0xC0 | (c >> 6)))
                out.append(UInt8(0x80 | (c & 0x3F)))
            } else if c < 0x10000 {
                out.append(UInt8(0xE0 | (c >> 12)))
                out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (c & 0x3F)))
            } else {
                out.append(UInt8(0xF0 | (c >> 18)))
                out.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (c & 0x3F)))
            }
        }
        return out
    }

    /// H(tag, payload) with a scalar payload.
    @inline(__always) static func khash(_ key: [UInt8], _ tag: String, _ payload: [UInt32]) -> UInt64 {
        return AdShieldTables.keyedHashBytes(key16: key, tag: tag, payload: utf8(payload))
    }

    /// Decimal with sign, no padding (SPEC §3).
    @inline(__always) static func dec(_ v: Int64) -> [UInt32] {
        return sc(String(v))
    }

    /// username → fold, leading "@"s removed (SPEC §1 rule 6).
    static func uname(_ s: String?) -> [UInt32] {
        let f = AdShieldTables.fold(s ?? "")
        var a = 0
        while a < f.count && f[a] == 0x40 {
            a += 1
        }
        return Array(f[a...])
    }

    /// H("link", "@" + folded username): shared by the known-member table and pending handles.
    public static func handleHash(key: [UInt8], name: [UInt32]) -> UInt64 {
        return khash(key, "link", [0x40] + name)
    }

    public static func letterCounts(_ t: [UInt32]) -> (cjk: Int, other: Int) {
        var cjk = 0
        var other = 0
        for c in t where c != 0x23 {
            if AdShieldTables.isCjk(c) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return (cjk, other)
    }

    /// SPEC §2.6: split F′ at \n . ! ? ;, keep pieces whose text form has wlen ≥ 32, dedupe (scalar equality), ≤ 16.
    public static func paragraphs(_ fNoLinks: [UInt32]) -> [[UInt32]] {
        var out: [[UInt32]] = []
        var seen = Set<[UInt32]>()
        var piece: [UInt32] = []
        var i = 0
        while i <= fNoLinks.count {
            let atEnd = i == fNoLinks.count
            let c: UInt32 = atEnd ? 0 : fNoLinks[i]
            if atEnd || c == 0x0A || c == 0x2E || c == 0x21 || c == 0x3F || c == 0x3B {
                let tp = AdShieldTables.textForm(piece)
                if AdShieldTables.wlen(tp) >= paraMinWlen && !seen.contains(tp) {
                    seen.insert(tp)
                    out.append(tp)
                    if out.count == maxPara {
                        break
                    }
                }
                piece.removeAll(keepingCapacity: true)
            } else {
                piece.append(c)
            }
            i += 1
        }
        return out
    }
}

// ===========================================================================
// Word tables, converted once from the generated AdShieldTables (immutable, Sendable)
// ===========================================================================

extension LuminaAdShield {
    enum KeywordKind: Sendable {
        case standaloneCjk
        case standaloneAscii
        case standaloneStrict
        case prefixed
        case phoneCjk
        case phoneAscii

        init(_ s: String) {
            switch s {
            case "standalone_ascii": self = .standaloneAscii
            case "standalone_strict": self = .standaloneStrict
            case "prefixed": self = .prefixed
            case "phone_cjk": self = .phoneCjk
            case "phone_ascii": self = .phoneAscii
            default: self = .standaloneCjk
            }
        }

        var isPhone: Bool {
            return self == .phoneCjk || self == .phoneAscii
        }
    }

    struct Keyword: Sendable {
        let word: [UInt32]
        let cls: [UInt32]
        let kind: KeywordKind
        let ascii: Bool
    }

    struct Currency: Sendable {
        let word: [UInt32]
        /// All of it is [a-z]: then the neighbouring character must not be [a-z].
        let asciiWord: Bool
    }

    enum W {
        static let keywords: [Keyword] = {
            var out: [Keyword] = []
            let n = min(AdShieldTables.keywordWords.count, AdShieldTables.keywordClasses.count, AdShieldTables.keywordKinds.count)
            for i in 0 ..< n {
                let w = sc(AdShieldTables.keywordWords[i])
                out.append(Keyword(word: w, cls: sc(AdShieldTables.keywordClasses[i]), kind: KeywordKind(AdShieldTables.keywordKinds[i]), ascii: w.allSatisfy { $0 < 0x80 }))
            }
            return out
        }()
        static let pointerCjk: [[UInt32]] = AdShieldTables.pointerCjk.map { sc($0) }
        static let pointerAscii: [[UInt32]] = AdShieldTables.pointerAscii.map { [0x20] + sc($0) + [0x20] }
        static let pointerNotAfter: [[UInt32]: [UInt32]] = Dictionary(zip(AdShieldTables.pointerNotAfterPhrase.map { sc($0) }, AdShieldTables.pointerNotAfterChars.map { sc($0) }), uniquingKeysWith: { $1 })
        static let pointerNotBefore: [[UInt32]: [UInt32]] = Dictionary(zip(AdShieldTables.pointerNotBeforePhrase.map { sc($0) }, AdShieldTables.pointerNotBeforeChars.map { sc($0) }), uniquingKeysWith: { $1 })
        static let pointerBeforeOk: [[UInt32]] = AdShieldTables.pointerBeforeOk.map { sc($0) }
        static let pointerNegation: [[UInt32]] = AdShieldTables.pointerNegation.map { sc($0) }
        static let pointerNegationBreak: [[UInt32]] = AdShieldTables.pointerNegationBreak.map { sc($0) }
        static let ack: [[UInt32]] = AdShieldTables.ackPhrases.map { sc($0) }
        static let ackFillers: [[UInt32]] = AdShieldTables.ackFillers.map { sc($0) }
        static let orderCjk: [[UInt32]] = AdShieldTables.orderContextCjk.map { sc($0) }
        static let phoneOrderCjk: [[UInt32]] = AdShieldTables.phoneOrderContextCjk.map { sc($0) }
        static let orderAscii: [[UInt32]] = AdShieldTables.orderContextAscii.map { sc($0) }
        static let currencyAfter: [Currency] = AdShieldTables.currencyAfter.map { s in
            let w = sc(s)
            return Currency(word: w, asciiWord: w.allSatisfy { isLower($0) })
        }
        static let currencyBefore: [Currency] = AdShieldTables.currencyBefore.map { s in
            let w = sc(s)
            return Currency(word: w, asciiWord: w.allSatisfy { isLower($0) })
        }
        static let shorteners: Set<[UInt32]> = Set(AdShieldTables.shorteners.map { sc($0) })
        static let domainAlias: [[UInt32]: [UInt32]] = Dictionary(zip(AdShieldTables.domainAliasFrom.map { sc($0) }, AdShieldTables.domainAliasTo.map { sc($0) }), uniquingKeysWith: { $1 })
        static let trackingParams: Set<[UInt32]> = Set(AdShieldTables.trackingParams.map { sc($0) })
        static let trackingPrefixes: [[UInt32]] = AdShieldTables.trackingPrefixes.map { sc($0) }
        static let multiSuffix: Set<[UInt32]> = Set(AdShieldTables.multiSuffix.map { sc($0) })
        static let tlds: Set<[UInt32]> = Set(AdShieldTables.tlds.map { sc($0) })
        static let tldMaxLen: Int = AdShieldTables.tlds.map { $0.unicodeScalars.count }.max() ?? 0
        static let tmeReserved: Set<[UInt32]> = Set(AdShieldTables.tmeReserved.map { sc($0) })

        static let http = sc("http")
        static let ftp = sc("ftp")
        static let tg = sc("tg")
        static let colonSlashSlash = sc("://")
        static let wwwDot = sc("www.")
        static let telegram = sc("telegram")
        static let me = sc("me")
        static let dog = sc("dog")
        static let dotTDotMe = sc(".t.me")
        static let tme = sc("t.me")
        static let urlPrefix = sc("url:")
        static let urlTgPrefix = sc("url:tg/")
        static let urlTme = sc("url:t.me")
        static let urlTmeSlash = sc("url:t.me/")
        static let typeUrl = sc("URL")
        static let typeUrlColon = sc("URL:")
        static let typeUrlTg = sc("URL:tg")
        static let typeUrlTme = sc("URL:t.me")
        static let typeShort = sc("SHORT")
        static let typeHandle = sc("HANDLE")
        static let typeInvite = sc("INVITE")
        static let typePhone = sc("PHONE")
        static let typeMail = sc("MAIL")
        static let typeAcct = sc("ACCT:")
        static let typeButton = sc("BUTTON")
        static let typeViaBot = sc("VIABOT")
        static let typeContact = sc("CONTACT")
        static let invitePrefix = sc("invite:")
        static let inviteAddlist = sc("invite:addlist/")
        static let telPrefix = sc("tel:")
        static let uidPrefix = sc("uid:")
        static let tgcPrefix = sc("tgc:")
        static let mailPrefix = sc("mail:")
        static let acctPrefix = sc("acct:")
        static let joinchat = sc("joinchat")
        static let addlist = sc("addlist")
        static let user = sc("user")
        static let openmessage = sc("openmessage")
        static let resolve = sc("resolve")
        static let join = sc("join")
        static let id = sc("id")
        static let userId = sc("user_id")
        static let domain = sc("domain")
        static let invite = sc("invite")
        static let phone = sc("phone")
        static let tgScheme = sc("tg")
        static let youtuBe = sc("youtu.be")
        static let youtubeCom = sc("youtube.com")
        static let watch = sc("/watch")
        static let vEq = sc("v=")
        static let waMe = sc("wa.me")
        static let apiWhatsapp = sc("api.whatsapp.com")
        static let whatsapp = sc("whatsapp.com")
        static let send = sc("/send")
        static let ptr = sc("ptr:")
        static let via = sc("via:")
        static let fwdChannel = sc("c|")
        static let fwdUser = sc("u|")
        static let fwdName = sc("n:")
        static let fwdText = sc("t:")
        static let fwdMedia = sc("m:")
        static let fwdEmpty = sc("e")
        static let mediaPhoto = sc("p:")
        static let mediaDoc = sc("d:")
        static let mediaUser = sc("u:")
        static let lgas = sc("LGAS")
    }
}

// ===========================================================================
// SPEC §4: link extraction. Each scanner reproduces the reference regex exactly.
// ===========================================================================

extension LuminaAdShield {
    /// Python `re.finditer` over a scanner that returns the match end at position i (or nil):
    /// leftmost match, then continue at the match end (all patterns here are non-empty).
    static func findAll(_ s: [UInt32], _ match: ([UInt32], Int) -> Int?) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var pos = 0
        let n = s.count
        while pos < n {
            if let e = match(s, pos) {
                out.append((pos, e))
                pos = e > pos ? e : pos + 1
            } else {
                pos += 1
            }
        }
        return out
    }

    /// Round 1: `(?:https?|ftp|tg)://[URLC]+` (no look-behind). The alternatives start with different letters and
    /// `s?` can only backtrack onto "s://" vs "://", so a single forward pass is exact.
    static func matchScheme(_ s: [UInt32], _ i: Int) -> Int? {
        let n = s.count
        var p: Int
        switch s[i] {
        case 0x68: // h
            guard startsWith(s, i, W.http) else {
                return nil
            }
            p = i + 4
            if p < n && s[p] == 0x73 { // "https" needs "://" after the s; "http" + "s" without it cannot match
                p += 1
            }
        case 0x66: // f
            guard startsWith(s, i, W.ftp) else {
                return nil
            }
            p = i + 3
        case 0x74: // t
            guard startsWith(s, i, W.tg) else {
                return nil
            }
            p = i + 2
        default:
            return nil
        }
        guard startsWith(s, p, W.colonSlashSlash) else {
            return nil
        }
        p += 3
        let start = p
        while p < n && isUrlChar(s[p]) {
            p += 1
        }
        return p > start ? p : nil
    }

    /// Round 2: `(?<![a-z0-9_\-.@/])(?:www\.)?(?:t|telegram) ?\. ?(?:me|dog) ?/[URLC]*`.
    /// Every optional space is followed by a mandatory non-space literal, so backtracking over it can never
    /// succeed; "t" vs "telegram" is the only real alternative.
    static func matchTme(_ s: [UInt32], _ i: Int) -> Int? {
        if i > 0 && isNotBefore(s[i - 1]) {
            return nil
        }
        var q = i
        if startsWith(s, i, W.wwwDot) {
            q = i + 4
        }
        guard q < s.count && s[q] == 0x74 else {
            return nil
        }
        if let e = tmeTail(s, q + 1) {
            return e
        }
        if startsWith(s, q, W.telegram), let e = tmeTail(s, q + 8) {
            return e
        }
        return nil
    }

    private static func tmeTail(_ s: [UInt32], _ r: Int) -> Int? {
        let n = s.count
        var p = r
        if p < n && s[p] == 0x20 {
            p += 1
        }
        guard p < n && s[p] == 0x2E else {
            return nil
        }
        p += 1
        if p < n && s[p] == 0x20 {
            p += 1
        }
        if startsWith(s, p, W.me) {
            p += 2
        } else if startsWith(s, p, W.dog) {
            p += 3
        } else {
            return nil
        }
        if p < n && s[p] == 0x20 {
            p += 1
        }
        guard p < n && s[p] == 0x2F else {
            return nil
        }
        p += 1
        while p < n && isUrlChar(s[p]) {
            p += 1
        }
        return p
    }

    /// Round 3: `(?<![a-z0-9_\-.@/])[a-z][a-z0-9_]{3,31}\.t\.me(?![a-z0-9\-])(?:/[URLC]*)?`.
    /// The name class excludes ".", so the name is the whole [a-z0-9_] run (4…32 scalars).
    static func matchTmeSub(_ s: [UInt32], _ i: Int) -> Int? {
        if i > 0 && isNotBefore(s[i - 1]) {
            return nil
        }
        let n = s.count
        guard isLower(s[i]) else {
            return nil
        }
        var p = i + 1
        while p < n && isWordChar(s[p]) {
            p += 1
        }
        let len = p - i
        guard len >= 4 && len <= 32 && startsWith(s, p, W.dotTDotMe) else {
            return nil
        }
        p += 5
        if p < n && isLabelChar(s[p]) {
            return nil
        }
        if p < n && s[p] == 0x2F {
            p += 1
            while p < n && isUrlChar(s[p]) {
                p += 1
            }
        }
        return p
    }

    /// Round 4: `(?<![a-z0-9._%+\-])[a-z0-9._%+\-]+@[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,24}(?![a-z0-9\-])`.
    /// Labels are always maximal [a-z0-9-] runs (giving characters back would need a "." where a label character
    /// is), so the regex ends at the LAST label L_j (j ≥ 2) that is 2…24 letters [a-z].
    static func matchEmail(_ s: [UInt32], _ i: Int) -> Int? {
        if i > 0 && isEmailLocal(s[i - 1]) {
            return nil
        }
        let n = s.count
        guard isEmailLocal(s[i]) else {
            return nil
        }
        var p = i
        while p < n && isEmailLocal(s[p]) {
            p += 1
        }
        guard p < n && s[p] == 0x40 else {
            return nil
        }
        p += 1
        var q = p
        while q < n && isLabelChar(s[q]) {
            q += 1
        }
        guard q > p else {
            return nil
        }
        var best: Int?
        var pos = q
        while pos < n && s[pos] == 0x2E {
            var r = pos + 1
            var allLetters = true
            while r < n && isLabelChar(s[r]) {
                if !isLower(s[r]) {
                    allLetters = false
                }
                r += 1
            }
            let len = r - pos - 1
            if len == 0 {
                break
            }
            if allLetters && len >= 2 && len <= 24 {
                best = r
            }
            pos = r
        }
        return best
    }

    /// Round 5: `(?<![a-z0-9_\-.@/])(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:<TLDS>)(?![a-z0-9\-])
    /// (?::[0-9]{1,5})?(?:/[URLC]*)?`. Each label must be a whole [a-z0-9-] run (1…63, alnum at both ends) followed
    /// by "."; the TLD must be the whole [a-z0-9-] run after a dot (the look-ahead forbids a longer run). The
    /// greedy `+` tries the most labels first, so the match uses the LAST dot whose following run is a TLD.
    static func matchDomain(_ s: [UInt32], _ i: Int) -> Int? {
        if i > 0 && isNotBefore(s[i - 1]) {
            return nil
        }
        guard isAlnum(s[i]) else {
            return nil
        }
        let n = s.count
        var tldStarts: [Int] = []
        var pos = i
        while true {
            var r = pos
            while r < n && isLabelChar(s[r]) {
                r += 1
            }
            let len = r - pos
            if len < 1 || len > 63 || !isAlnum(s[pos]) || !isAlnum(s[r - 1]) || r >= n || s[r] != 0x2E {
                break
            }
            pos = r + 1
            tldStarts.append(pos)
        }
        if tldStarts.isEmpty {
            return nil
        }
        for t in tldStarts.reversed() {
            var r = t
            while r < n && isLabelChar(s[r]) {
                r += 1
            }
            let len = r - t
            if len < 1 || len > W.tldMaxLen || !W.tlds.contains(Array(s[t ..< r])) {
                continue
            }
            var e = r
            if e < n && s[e] == 0x3A {
                var d = e + 1
                while d < n && isDigit(s[d]) && d - (e + 1) < 5 {
                    d += 1
                }
                if d > e + 1 {
                    e = d
                }
            }
            if e < n && s[e] == 0x2F {
                e += 1
                while e < n && isUrlChar(s[e]) {
                    e += 1
                }
            }
            return e
        }
        return nil
    }

    /// Rounds 6 / 6b: `(?<![a-z0-9_])@( ?)([a-z][a-z0-9_]{3,31})(?![a-z0-9_])` – the name is the whole run.
    static func matchMention(_ s: [UInt32], _ i: Int, spaced: Bool) -> Int? {
        let n = s.count
        guard s[i] == 0x40 else {
            return nil
        }
        if i > 0 && isWordChar(s[i - 1]) {
            return nil
        }
        var p = i + 1
        if spaced {
            guard p < n && s[p] == 0x20 else {
                return nil
            }
            p += 1
        }
        let start = p
        guard p < n && isLower(s[p]) else {
            return nil
        }
        p += 1
        while p < n && isWordChar(s[p]) {
            p += 1
        }
        let len = p - start
        return (len >= 4 && len <= 32) ? p : nil
    }

    /// `(?:[ \-.]?[0-9]){min,max}(?![0-9])` starting at `p`: greedy count, then give iterations back until the
    /// look-ahead holds (an iteration ending before a separator is the only way back). Returns the end.
    private static func sepDigits(_ s: [UInt32], _ p0: Int, min minCount: Int, max maxCount: Int) -> Int? {
        let n = s.count
        var p = p0
        var ends: [Int] = []
        ends.reserveCapacity(maxCount)
        while ends.count < maxCount {
            if p + 1 < n && isPhoneSep(s[p]) && isDigit(s[p + 1]) {
                p += 2
            } else if p < n && isDigit(s[p]) {
                p += 1
            } else {
                break
            }
            ends.append(p)
        }
        if ends.count < minCount {
            return nil
        }
        var k = ends.count - 1
        while k >= minCount - 1 {
            let e = ends[k]
            if e >= n || !isDigit(s[e]) {
                return e
            }
            k -= 1
        }
        return nil
    }

    /// Round 7a: `(?<![0-9a-z+])\+[0-9](?:[ \-.]?[0-9]){6,14}(?![0-9])`.
    static func matchPhoneIntl(_ s: [UInt32], _ i: Int) -> Int? {
        guard s[i] == 0x2B else {
            return nil
        }
        if i > 0 {
            let c = s[i - 1]
            if isDigit(c) || isLower(c) || c == 0x2B {
                return nil
            }
        }
        guard i + 1 < s.count && isDigit(s[i + 1]) else {
            return nil
        }
        return sepDigits(s, i + 2, min: 6, max: 14)
    }

    /// `(?:[ \-.]?[0-9]){count}` exactly (no alternative positions exist), then `(?![0-9])`.
    private static func fixedSepDigits(_ s: [UInt32], _ p0: Int, count: Int) -> Int? {
        let n = s.count
        var p = p0
        for _ in 0 ..< count {
            if p + 1 < n && isPhoneSep(s[p]) && isDigit(s[p + 1]) {
                p += 2
            } else if p < n && isDigit(s[p]) {
                p += 1
            } else {
                return nil
            }
        }
        if p < n && isDigit(s[p]) {
            return nil
        }
        return p
    }

    /// Round 7b: `(?<![0-9])1[ \-.]?[3-9](?:[ \-.]?[0-9]){9}(?![0-9])`.
    static func matchPhoneCn(_ s: [UInt32], _ i: Int) -> Int? {
        let n = s.count
        guard s[i] == 0x31 else {
            return nil
        }
        if i > 0 && isDigit(s[i - 1]) {
            return nil
        }
        var p = i + 1
        if p + 1 < n && isPhoneSep(s[p]) && s[p + 1] >= 0x33 && s[p + 1] <= 0x39 {
            p += 2
        } else if p < n && s[p] >= 0x33 && s[p] <= 0x39 {
            p += 1
        } else {
            return nil
        }
        return fixedSepDigits(s, p, count: 9)
    }

    /// Round 7c: `(?<![0-9])09[0-9](?:[ \-.]?[0-9]){7}(?![0-9])`.
    static func matchPhoneTw(_ s: [UInt32], _ i: Int) -> Int? {
        let n = s.count
        guard s[i] == 0x30 else {
            return nil
        }
        if i > 0 && isDigit(s[i - 1]) {
            return nil
        }
        guard i + 2 < n && s[i + 1] == 0x39 && isDigit(s[i + 2]) else {
            return nil
        }
        return fixedSepDigits(s, i + 3, count: 7)
    }

    /// `[0-9](?:[ \-.]?[0-9]){6,14}(?![0-9])` anchored at g (phone keyword + number).
    static func matchDigitsSep(_ s: [UInt32], _ g: Int) -> Int? {
        guard g < s.count && isDigit(s[g]) else {
            return nil
        }
        return sepDigits(s, g + 1, min: 6, max: 14)
    }

    /// `[a-z0-9][a-z0-9_\-.]{3,29}` anchored at g (greedy, ≤ 30 scalars).
    static func matchAccount(_ s: [UInt32], _ g: Int) -> Int? {
        let n = s.count
        guard g < n && isAlnum(s[g]) else {
            return nil
        }
        var p = g + 1
        while p < n && p - g < 30 && isAcctChar(s[p]) {
            p += 1
        }
        return p - g >= 4 ? p : nil
    }

    /// Replace each span with one U+0020 (spans sorted; overlapping ones skipped, as `_remove_spans`).
    static func removeSpans(_ s: [UInt32], _ spans: [(Int, Int)]) -> [UInt32] {
        if spans.isEmpty {
            return s
        }
        let sorted = spans.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
        var out: [UInt32] = []
        out.reserveCapacity(s.count)
        var pos = 0
        for (a, b) in sorted {
            if a < pos {
                continue
            }
            out.append(contentsOf: s[pos ..< a])
            out.append(0x20)
            pos = b
        }
        if pos < s.count {
            out.append(contentsOf: s[pos...])
        }
        return out
    }

    static func regdomain(_ host: [UInt32]) -> [UInt32] {
        if !host.isEmpty && host.allSatisfy({ isDigit($0) || $0 == 0x2E }) {
            return host
        }
        let labels = split(host, 0x2E).filter { !$0.isEmpty }
        if labels.count <= 2 {
            return join(labels, 0x2E)
        }
        let last2 = join(Array(labels.suffix(2)), 0x2E)
        if W.multiSuffix.contains(last2) {
            return join(Array(labels.suffix(3)), 0x2E)
        }
        return last2
    }

    private static func parseQuery(_ q: [UInt32]) -> [([UInt32], [UInt32])] {
        var out: [([UInt32], [UInt32])] = []
        for part in split(q, 0x26) where !part.isEmpty {
            out.append(partition(part, 0x3D))
        }
        return out
    }

    /// Duplicate keys: the last one wins (never `uniqueKeysWithValues`, which traps on duplicates).
    static func queryDict(_ q: [UInt32]) -> [[UInt32]: [UInt32]] {
        return Dictionary(parseQuery(q), uniquingKeysWith: { $1 })
    }

    static func cleanQuery(_ q: [UInt32]) -> [UInt32] {
        var keep: [([UInt32], [UInt32])] = []
        for (k, v) in parseQuery(q) {
            if W.trackingParams.contains(k) || W.trackingPrefixes.contains(where: { hasPrefix(k, $0) }) {
                continue
            }
            keep.append((k, v))
        }
        keep.sort { a, b in
            if a.0 != b.0 {
                return cpLess(a.0, b.0)
            }
            return cpLess(a.1, b.1)
        }
        var parts: [[UInt32]] = []
        for (k, v) in keep {
            parts.append(v.isEmpty ? k : k + [0x3D] + v)
        }
        return join(parts, 0x26)
    }

    static func phoneLink(_ digits: [UInt32], _ source: LinkSource) -> Link? {
        if digits.count >= 7 && digits.count <= 15 {
            return Link(W.telPrefix + digits, .phone, W.typePhone, source: source)
        }
        return nil
    }

    static func tmeLink(_ path: [UInt32], _ source: LinkSource) -> Link? {
        let segs = split(path, 0x2F).filter { !$0.isEmpty }
        if segs.isEmpty {
            return Link(W.urlTme, .url, W.typeUrlTme, domain: W.tme, source: source)
        }
        let s0 = segs[0]
        if s0.first == 0x2B {
            let h = Array(s0.dropFirst())
            if isAllDigits(h) {
                return phoneLink(h, source)
            }
            if !h.isEmpty {
                return Link(W.invitePrefix + h, .invite, W.typeInvite, source: source)
            }
        }
        if s0 == W.joinchat && segs.count > 1 {
            return Link(W.invitePrefix + segs[1], .invite, W.typeInvite, source: source)
        }
        if s0 == W.addlist && segs.count > 1 {
            return Link(W.inviteAddlist + segs[1], .invite, W.typeInvite, source: source)
        }
        if s0 == [0x63] && segs.count > 1 && isAllDigits(segs[1]) {
            return Link(W.tgcPrefix + segs[1], .handle, W.typeHandle, source: source)
        }
        if s0 == [0x73] && segs.count > 1 && validUsername(segs[1]) {
            return Link([0x40] + segs[1], .handle, W.typeHandle, source: source)
        }
        if W.tmeReserved.contains(s0) {
            return Link(W.urlTmeSlash + s0, .url, W.typeUrlTme, domain: W.tme, source: source)
        }
        if validUsername(s0) {
            return Link([0x40] + s0, .handle, W.typeHandle, source: source)
        }
        return Link(W.urlTmeSlash + join(segs, 0x2F), .url, W.typeUrlTme, domain: W.tme, source: source)
    }

    /// SPEC §4.3. The input must already be folded.
    public static func canonicalizeUrl(_ raw: [UInt32], source: LinkSource = .text) -> Link? {
        var a = 0
        var b = raw.count
        while a < b && isPyWhitespace(raw[a]) {
            a += 1
        }
        while b > a && isPyWhitespace(raw[b - 1]) {
            b -= 1
        }
        var u = raw[a ..< b].filter { $0 != 0x20 }
        while let last = u.last, isTrim(last) {
            u.removeLast()
        }
        var scheme: [UInt32] = []
        if let f = u.first, isLower(f) {
            var p = 1
            while p < u.count && (isAlnum(u[p]) || u[p] == 0x2B || u[p] == 0x2E || u[p] == 0x2D) {
                p += 1
            }
            if startsWith(u, p, W.colonSlashSlash) {
                scheme = Array(u[0 ..< p])
                u = Array(u[(p + 3)...])
            }
        }
        if scheme == W.tgScheme {
            let (host0, rest) = partition(u, 0x3F)
            let host = strip(host0, 0x2F)
            let q = queryDict(rest)
            if host == W.user || host == W.openmessage {
                let uid = host == W.user ? q[W.id] : q[W.userId]
                if let uid, isAllDigits(uid) {
                    return Link(W.uidPrefix + uid, .handle, W.typeHandle, source: source)
                }
            }
            if host == W.resolve, let d = q[W.domain], validUsername(d) {
                return Link([0x40] + d, .handle, W.typeHandle, source: source)
            }
            if host == W.join, let inv = q[W.invite], !inv.isEmpty {
                return Link(W.invitePrefix + inv, .invite, W.typeInvite, source: source)
            }
            return Link(W.urlTgPrefix + host, .url, W.typeUrlTg, domain: W.tg, source: source)
        }
        var cut = u.count
        for (idx, c) in u.enumerated() where c == 0x2F || c == 0x3F || c == 0x23 {
            cut = idx
            break
        }
        var hostport = Array(u[0 ..< cut])
        var rest = Array(u[cut...])
        if let at = hostport.lastIndex(of: 0x40) {
            hostport = Array(hostport[(at + 1)...])
        }
        var host = strip(partition(hostport, 0x3A).0, 0x2E)
        if host.isEmpty {
            return nil
        }
        if hasPrefix(host, W.wwwDot) {
            host = Array(host[4...])
        }
        if let alias = W.domainAlias[host] {
            host = alias
        }
        rest = partition(rest, 0x23).0
        let (path0, query0) = partition(rest, 0x3F)
        var path = rstrip(path0, 0x2F)
        var query = query0
        if host == W.tme {
            return tmeLink(path, source)
        }
        if hasSuffix(host, W.dotTDotMe) {
            let name = Array(host[0 ..< (host.count - 5)])
            if validUsername(name) {
                return Link([0x40] + name, .handle, W.typeHandle, source: source)
            }
        }
        if host == W.youtuBe {
            let vid = split(strip(path, 0x2F), 0x2F)[0]
            host = W.youtubeCom
            path = W.watch
            query = W.vEq + vid + (query.isEmpty ? [] : [0x26] + query)
        }
        if host == W.waMe {
            let d = strip(path, 0x2F)
            if isAllDigits(d) {
                return phoneLink(d, source)
            }
        }
        if (host == W.apiWhatsapp || host == W.whatsapp) && path == W.send {
            let d = digitsOnly(queryDict(query)[W.phone] ?? [])
            if !d.isEmpty {
                return phoneLink(d, source)
            }
        }
        let q = cleanQuery(query)
        let token = W.urlPrefix + host + path + (q.isEmpty ? [] : [0x3F] + q)
        if W.shorteners.contains(host) {
            return Link(token, .url, W.typeShort, domain: host, shortener: true, source: source)
        }
        let rd = regdomain(host)
        return Link(token, .url, W.typeUrlColon + rd, domain: rd, source: source)
    }

    /// SPEC §4.6: contact keyword + account / phone keyword + number. Returns (links, spans to remove).
    static func contactAccounts(_ s: [UInt32]) -> ([Link], [(Int, Int)]) {
        struct Span: Hashable {
            let a: Int
            let b: Int
        }
        let n = s.count
        var found: [Span: Link] = [:]
        for kw in W.keywords {
            var start = 0
            while let i = find(s, kw.word, from: start) {
                start = i + 1
                let j = i + kw.word.count
                if kw.ascii {
                    if i > 0 && isAlnum(s[i - 1]) {
                        continue
                    }
                    if j < n && isLower(s[j]) {
                        continue
                    }
                }
                if kw.kind == .prefixed {
                    var k = i - 1
                    while k >= 0 && s[k] == 0x20 {
                        k -= 1
                    }
                    if k >= 0 && (s[k] == 0x6211 || s[k] == 0x4E2A) { // 我 个
                        k -= 1
                        while k >= 0 && s[k] == 0x20 {
                            k -= 1
                        }
                    }
                    if k < 0 || !(s[k] == 0x52A0 || s[k] == 0x2B) { // 加 +
                        continue
                    }
                }
                var g = j
                var gapHasMarker = false
                var gapLen = 0
                while g < n && gapLen < gapMax && s[g] != 0x0A && !isAlnum(s[g]) {
                    if s[g] == 0x3A || s[g] == 0x3D || s[g] == 0x40 { // : = @
                        gapHasMarker = true
                    }
                    gapLen += 1
                    g += 1
                }
                if kw.kind.isPhone {
                    guard let e = matchDigitsSep(s, g) else {
                        continue
                    }
                    let span = Span(a: g, b: e)
                    if found[span] == nil {
                        found[span] = Link(W.telPrefix + digitsOnly(s[g ..< e]), .phone, W.typePhone)
                    }
                    continue
                }
                guard let e = matchAccount(s, g) else {
                    continue
                }
                if e < n && isAlnum(s[e]) {
                    continue
                }
                var acct = Array(s[g ..< e])
                while let last = acct.last, last == 0x2E || last == 0x2D {
                    acct.removeLast()
                }
                let allDigits = isAllDigits(acct)
                if acct.count < 4 || (allDigits && acct.count < 5) {
                    continue
                }
                let hasAlpha = acct.contains { isLower($0) }
                let hasUnderscore = acct.contains(0x5F)
                if !allDigits && !hasAlpha && !hasUnderscore {
                    continue
                }
                if kw.kind == .standaloneAscii {
                    let hasDigit = acct.contains { isDigit($0) }
                    let ok = gapHasMarker || hasUnderscore || (hasAlpha && hasDigit) || (allDigits && acct.count >= 7)
                    if !ok {
                        continue
                    }
                }
                if kw.kind == .standaloneStrict {
                    if !(gapHasMarker || hasUnderscore) || !hasAlpha {
                        continue
                    }
                }
                let span = Span(a: g, b: g + acct.count)
                if found[span] == nil {
                    found[span] = Link(W.acctPrefix + kw.cls + [0x3A] + acct, .acct, W.typeAcct + kw.cls)
                }
            }
        }
        let order = found.keys.sorted { x, y in x.a != y.a ? x.a < y.a : x.b > y.b }
        var links: [Link] = []
        var spans: [(Int, Int)] = []
        var lastEnd = -1
        for span in order {
            if span.a < lastEnd {
                continue
            }
            spans.append((span.a, span.b))
            if let link = found[span] {
                links.append(link)
            }
            lastEnd = span.b
        }
        return (links, spans)
    }

    /// " " + words of [a-z0-9] joined by one space + " " (Python `" " + " ".join(...split()) + " "`).
    static func wordForm(_ s: [UInt32]) -> [UInt32] {
        var out: [UInt32] = [0x20]
        var pendingSpace = false
        var any = false
        for c in s {
            if isAlnum(c) {
                if pendingSpace && any {
                    out.append(0x20)
                }
                pendingSpace = false
                any = true
                out.append(c)
            } else {
                pendingSpace = true
            }
        }
        out.append(0x20)
        return out
    }

    /// SPEC §4.7: is the hit of pointer phrase p at index i of Tcjk real?
    static func pointerHitOk(_ tc: [UInt32], _ p: [UInt32], _ i: Int) -> Bool {
        if let na = W.pointerNotAfter[p], i > 0, na.contains(tc[i - 1]) {
            return false
        }
        if let nb = W.pointerNotBefore[p] {
            let a = i + p.count
            if a < tc.count && nb.contains(tc[a]) && !W.pointerBeforeOk.contains(where: { startsWith(tc, a, $0) }) {
                return false
            }
        }
        let pre = Array(tc[max(0, i - pointerNegWindow) ..< i])
        for neg in W.pointerNegation {
            var k = find(pre, neg)
            while let kk = k {
                let between = Array(pre[(kk + neg.count)...])
                if !W.pointerNegationBreak.contains(where: { contains(between, $0) }) {
                    return false
                }
                k = find(pre, neg, from: kk + 1)
            }
        }
        return true
    }

    static func hasPointer(_ fNoLinks: [UInt32]) -> Bool {
        let tc = AdShieldTables.cjkForm(AdShieldTables.textForm(fNoLinks))
        for p in W.pointerCjk {
            var start = 0
            while let i = find(tc, p, from: start) {
                start = i + 1
                if pointerHitOk(tc, p, i) {
                    return true
                }
            }
        }
        let w = wordForm(fNoLinks)
        for p in W.pointerAscii where contains(w, p) {
            return true
        }
        return false
    }

    /// Number [a, b) followed (after ≤ 1 space) by currencyAfter, or preceded (after ≤ 1 space) by currencyBefore.
    static func priceContext(_ s: [UInt32], _ a: Int, _ b: Int) -> Bool {
        let n = s.count
        var p = b
        if p < n && s[p] == 0x20 {
            p += 1
        }
        for c in W.currencyAfter where startsWith(s, p, c.word) {
            let e = p + c.word.count
            if c.asciiWord && e < n && isLower(s[e]) {
                continue
            }
            return true
        }
        var q = a
        if q > 0 && s[q - 1] == 0x20 {
            q -= 1
        }
        for c in W.currencyBefore where q >= c.word.count && startsWith(s, q - c.word.count, c.word) {
            let st = q - c.word.count
            if c.asciiWord && st > 0 && isLower(s[st - 1]) {
                continue
            }
            return true
        }
        return false
    }

    /// The 12 scalars before index a, as an independent substring (its edges are string edges).
    static func windowBefore(_ s: [UInt32], _ a: Int) -> [UInt32] {
        return Array(s[max(0, a - numCtxWindow) ..< a])
    }

    /// `(?<![a-z])w(?![a-z])` searched inside the window.
    static func asciiWordIn(_ window: [UInt32], _ w: [UInt32]) -> Bool {
        var start = 0
        while let k = find(window, w, from: start) {
            start = k + 1
            let before = k == 0 || !isLower(window[k - 1])
            let e = k + w.count
            let after = e >= window.count || !isLower(window[e])
            if before && after {
                return true
            }
        }
        return false
    }

    static func isDate8(_ r: ArraySlice<UInt32>) -> Bool {
        let d = Array(r)
        if d.count != 8 {
            return false
        }
        let c0 = d[0], c1 = d[1], m0 = d[4], m1 = d[5], x0 = d[6], x1 = d[7]
        let year = (c0 == 0x31 && c1 == 0x39) || (c0 == 0x32 && c1 == 0x30)
        let month = (m0 == 0x30 && m1 >= 0x31 && m1 <= 0x39) || (m0 == 0x31 && m1 >= 0x30 && m1 <= 0x32)
        let dayOk = (x0 == 0x30 && x1 >= 0x31 && x1 <= 0x39) || ((x0 == 0x31 || x0 == 0x32) && isDigit(x1)) || (x0 == 0x33 && (x1 == 0x30 || x1 == 0x31))
        return year && month && dayOk
    }

    static func longNumbers(_ s: [UInt32]) -> [[UInt32]] {
        var out: [[UInt32]] = []
        let n = s.count
        var i = 0
        while i < n {
            if !isDigit(s[i]) {
                i += 1
                continue
            }
            var j = i
            while j < n && isDigit(s[j]) {
                j += 1
            }
            if j - i >= 6 {
                let run = s[i ..< j]
                var exempt = (j - i == 8 && isDate8(run)) || priceContext(s, i, j)
                if !exempt {
                    let window = windowBefore(s, i)
                    exempt = W.orderCjk.contains(where: { contains(window, $0) })
                        || W.orderAscii.contains(where: { asciiWordIn(window, $0) })
                }
                if !exempt {
                    out.append(Array(run))
                }
            }
            i = j
        }
        return out
    }

    /// A bare phone number (no phone keyword) inside a price or order context is not a phone.
    static func phoneExempt(_ s: [UInt32], _ a: Int, _ b: Int) -> Bool {
        if priceContext(s, a, b) {
            return true
        }
        let window = windowBefore(s, a)
        return W.phoneOrderCjk.contains(where: { contains(window, $0) })
    }

    /// SPEC §4: scheme URL → t.me → *.t.me → email → bare domain → @mention → "@ handle" → phones → contact
    /// accounts; every round replaces what it extracted with one U+0020 before the next round runs.
    public static func extractLinks(_ f: [UInt32]) -> Extraction {
        var s = f
        var links: [Link] = []
        var mentions: [[UInt32]] = []

        let urlRounds: [([UInt32], Int) -> Int?] = [matchScheme, matchTme, matchTmeSub, matchEmail, matchDomain]
        for (round, matcher) in urlRounds.enumerated() {
            var spans: [(Int, Int)] = []
            for (a0, b0) in findAll(s, matcher) {
                var b = b0
                while b > a0 && isTrim(s[b - 1]) {
                    b -= 1
                }
                if b <= a0 {
                    continue
                }
                let raw = Array(s[a0 ..< b])
                if round == 3 {
                    let domainPart = partition(raw, 0x40).1
                    links.append(Link(W.mailPrefix + raw, .mail, W.typeMail, domain: regdomain(domainPart)))
                } else {
                    guard let link = canonicalizeUrl(raw) else {
                        continue
                    }
                    links.append(link)
                }
                spans.append((a0, b))
            }
            s = removeSpans(s, spans)
        }

        for spaced in [false, true] {
            var spans: [(Int, Int)] = []
            for (a, e) in findAll(s, { matchMention($0, $1, spaced: spaced) }) {
                let name = Array(s[(a + (spaced ? 2 : 1)) ..< e])
                if spaced && !name.contains(where: { $0 == 0x5F || isDigit($0) }) {
                    continue
                }
                mentions.append(name)
                links.append(Link([0x40] + name, .handle, W.typeHandle))
                spans.append((a, e))
            }
            s = removeSpans(s, spans)
        }

        let phoneRounds: [([UInt32], Int) -> Int?] = [matchPhoneIntl, matchPhoneCn, matchPhoneTw]
        for (round, matcher) in phoneRounds.enumerated() {
            var spans: [(Int, Int)] = []
            for (a, e) in findAll(s, matcher) {
                if phoneExempt(s, a, e) {
                    continue
                }
                var d = digitsOnly(s[a ..< e])
                if round == 1 {
                    d = [0x38, 0x36] + d
                } else if round == 2 {
                    d = [0x38, 0x38, 0x36] + d.dropFirst()
                }
                links.append(Link(W.telPrefix + d, .phone, W.typePhone))
                spans.append((a, e))
            }
            s = removeSpans(s, spans)
        }

        let (acctLinks, acctSpans) = contactAccounts(s)
        links.append(contentsOf: acctLinks)
        s = removeSpans(s, acctSpans)
        return Extraction(fNoLinks: s, links: links, mentions: mentions, pointer: hasPointer(s), longNumbers: longNumbers(s))
    }

    /// Chinese mobiles always get 86, Taiwanese 09… become 8869… ("+86 138…" and "138…" give one token).
    static func normalizePhoneToken(_ link: inout Link) {
        if link.kind != .phone {
            return
        }
        let d = Array(link.token.dropFirst(4))
        if d.count == 11 && d[0] == 0x31 && d[1] >= 0x33 && d[1] <= 0x39 {
            link.token = W.telPrefix + [0x38, 0x36] + d
        } else if d.count == 10 && d[0] == 0x30 && d[1] == 0x39 {
            link.token = W.telPrefix + [0x38, 0x38, 0x36] + d.dropFirst()
        }
    }

    /// Leading @handles (addressing someone): `[ \n]*(?:@[a-z][a-z0-9_]{3,31}(?![a-z0-9_])[ \n,:]*)+` at F's start.
    static func leadingHandles(_ f: [UInt32]) -> Set<[UInt32]> {
        var out = Set<[UInt32]>()
        let n = f.count
        var p = 0
        while p < n && (f[p] == 0x20 || f[p] == 0x0A) {
            p += 1
        }
        while p < n && f[p] == 0x40 {
            let st = p + 1
            guard st < n && isLower(f[st]) else {
                break
            }
            var e = st + 1
            while e < n && isWordChar(f[e]) {
                e += 1
            }
            let len = e - st
            if len < 4 || len > 32 {
                break
            }
            out.insert(Array(f[st ..< e]))
            p = e
            while p < n && (f[p] == 0x20 || f[p] == 0x0A || f[p] == 0x2C || f[p] == 0x3A) {
                p += 1
            }
        }
        return out
    }
}

// ===========================================================================
// SPEC §3, §5: fingerprint and resolve
// ===========================================================================

extension LuminaAdShield {
    static func isEligible(_ ctx: ChatContext) -> Bool {
        switch ctx.type {
        case .group, .supergroup, .forum, .gigagroup:
            return true
        case .other:
            return false
        }
    }

    static func isEligible(_ msg: MessageInput) -> Bool {
        return !(msg.service || msg.sponsored || msg.scheduled)
    }

    /// observe only accepts 0 < msgId ≤ 2^31−1 and 0 ≤ date ≤ 2^40.
    static func isValid(_ msg: MessageInput) -> Bool {
        return msg.id > 0 && msg.date >= 0 && msg.date <= maxDate
    }

    static func isAck(_ t: [UInt32]) -> Bool {
        if t.isEmpty || t.contains(0x23) {
            return false
        }
        var r = t
        var hit = false
        for p in W.ack where contains(r, p) {
            hit = true
            r = removeAll(r, p)
        }
        if !hit {
            return false
        }
        for p in W.ackFillers {
            r = removeAll(r, p)
        }
        return AdShieldTables.wlen(r) <= ackRemainderMax
    }

    static func dedupe(_ xs: [UInt64], cap: Int) -> [UInt64] {
        var out: [UInt64] = []
        var seen = Set<UInt64>()
        for x in xs where !seen.contains(x) {
            seen.insert(x)
            out.append(x)
            if out.count == cap {
                break
            }
        }
        return out
    }

    /// SPEC §5.5: unknown pending handles → strong `handle` (and they count as new links); known ones → weak
    /// `member_mention`. A conditional TMPL key is dropped when no pending handle is unknown. MEDIA_ONLY = media
    /// key and no strong feature.
    public static func resolve(flags: UInt32, keys: [Key], links: [UInt64], pending: [UInt64], isKnown: (UInt64) -> Bool) -> (flags: UInt32, keys: [Key], links: [UInt64]) {
        var unknown: [UInt64] = []
        for h in pending where !isKnown(h) {
            unknown.append(h)
        }
        var f = flags & ~Flag.mediaOnly
        if !unknown.isEmpty {
            f |= Flag.strongHandle
        }
        if unknown.count < pending.count {
            f |= Flag.weakMemberMention
        }
        var outKeys = keys
        if flags & Flag.tmplCond != 0 && unknown.isEmpty {
            outKeys = keys.filter { $0.kind != KeyKind.tmpl.rawValue }
        }
        var outLinks = links
        if !unknown.isEmpty {
            let original = Set(links)
            for h in unknown where !original.contains(h) {
                outLinks.append(h)
            }
        }
        if f & Flag.hasMediaKey != 0 && f & Flag.strongMask == 0 {
            f |= Flag.mediaOnly
        }
        return (f, outKeys, outLinks)
    }

    /// One message → normalized text, links, features and fingerprint keys (SPEC §3–§5).
    /// The stored part (keys / flags / linkHashes / pending) depends only on (msg, context, key);
    /// `knownHandles` (folded usernames, no "@") only affects `resolvedFlags`.
    public static func fingerprint(_ msg: MessageInput, context ctx: ChatContext, key: [UInt8], knownHandles: Set<[UInt32]> = []) -> Fingerprint {
        let role = msg.sender.role
        let senderUsername = uname(msg.sender.username)
        let fwd = msg.forward
        let chanFwd = fwd?.fromKind == .channel
        let media = msg.media

        let f = AdShieldTables.fold(msg.text)
        let ex = extractLinks(f)
        var links = ex.links
        for ent in msg.entities {
            switch ent {
            case let .mentionName(userId):
                if userId == msg.sender.id {
                    links.append(Link(W.uidPrefix + dec(userId), .handle, W.typeHandle, source: .hidden))
                }
            case let .textUrl(url):
                if !url.isEmpty, let l = canonicalizeUrl(AdShieldTables.fold(url), source: .hidden) {
                    links.append(l)
                }
            }
        }
        let buttons = msg.buttons.filter { !$0.isEmpty }
        for b in buttons {
            if let l = canonicalizeUrl(AdShieldTables.fold(b), source: .button) {
                links.append(l)
            }
        }
        if let media, media.kind == .contact, let phone = media.phone, !phone.isEmpty {
            if let l = phoneLink(digitsOnly(AdShieldTables.fold(phone)), .media) {
                links.append(l)
            }
        }
        for i in 0 ..< links.count {
            normalizePhoneToken(&links[i])
        }

        let t = AdShieldTables.textForm(ex.fNoLinks)
        let tc = AdShieldTables.cjkForm(t)
        let wl = AdShieldTables.wlen(t)
        let (cjkCount, letterCount) = letterCounts(t)
        let paras = paragraphs(ex.fNoLinks)

        // ---- features ----
        let fwdUsername = uname(fwd?.username)
        let addressed = leadingHandles(f)
        var strong: UInt32 = 0
        var weak: UInt32 = 0
        var features: [LinkFeature] = []
        features.reserveCapacity(links.count)
        for l in links {
            var feat = LinkFeature.notCounted
            if ctx.trustedTokens.contains(l.token) {
                feat = .notCounted
            } else {
                switch l.kind {
                case .invite:
                    feat = chanFwd ? .weak : .strong
                case .handle:
                    let h: [UInt32] = l.token.first == 0x40 ? Array(l.token.dropFirst()) : []
                    if !h.isEmpty && h == fwdUsername {
                        feat = .notCounted
                    } else if !h.isEmpty && h == ctx.selfUsername {
                        feat = .notCounted
                    } else if chanFwd {
                        feat = .weak
                    } else if !h.isEmpty && h == senderUsername {
                        feat = .strong
                    } else if h.isEmpty {
                        feat = .strong
                    } else if addressed.contains(h) {
                        feat = .member
                    } else {
                        feat = .pending
                    }
                case .url:
                    if l.shortener {
                        feat = chanFwd ? .weak : .strong
                    } else if ctx.trustedDomains.contains(l.domain) {
                        feat = .notCounted
                    } else {
                        feat = .weak
                    }
                case .phone, .acct:
                    feat = .strong
                case .mail:
                    feat = ctx.trustedDomains.contains(l.domain) ? .notCounted : .weak
                }
            }
            features.append(feat)
            switch feat {
            case .strong:
                switch l.kind {
                case .invite: strong |= Flag.strongInvite
                case .handle: strong |= Flag.strongHandle
                case .url: strong |= Flag.strongShortener
                case .phone: strong |= Flag.strongPhone
                case .acct: strong |= Flag.strongAccount
                case .mail: break
                }
            case .weak:
                weak |= l.kind == .mail ? Flag.weakEmail : Flag.weakUrl
            case .member:
                weak |= Flag.weakMemberMention
            case .pending, .notCounted:
                break
            }
        }
        if ex.pointer {
            strong |= Flag.strongPointer
        }
        if !buttons.isEmpty {
            if chanFwd {
                weak |= Flag.weakUrl
            } else {
                strong |= Flag.strongButton
            }
        }
        if msg.viaBot {
            if chanFwd {
                weak |= Flag.weakUrl
            } else {
                strong |= Flag.strongViaBot
            }
        }
        if media?.kind == .contact {
            strong |= Flag.strongContactCard
        }
        if !ex.longNumbers.isEmpty {
            weak |= Flag.weakLongNumber
        }
        let mentionNames = Set(ex.mentions)
        var mentionIds = Set<Int64>()
        for ent in msg.entities {
            if case let .mentionName(userId) = ent {
                mentionIds.insert(userId)
            }
        }
        let mentionCount = mentionNames.count + mentionIds.count
        if mentionCount >= massMention {
            weak |= Flag.weakMassMention
        }
        var pendingTokens: [[UInt32]] = []
        for (l, feat) in zip(links, features) where feat == .pending {
            pendingTokens.append(l.token)
        }

        // ---- keys: FWD MEDIA TEXT CJK TMPL CONTACT PARA… ----
        var keys: [(KeyKind, [UInt32])] = []
        var mediaPayload: [UInt32] = []
        if let media {
            switch media.kind {
            case .photo:
                if let id = media.id, !id.isEmpty {
                    mediaPayload = W.mediaPhoto + sc(id)
                }
            case .video, .document, .audio:
                if let id = media.id, !id.isEmpty {
                    mediaPayload = W.mediaDoc + sc(id)
                }
            case .contact:
                if media.userId != 0 {
                    mediaPayload = W.mediaUser + dec(media.userId)
                } else if let phone = media.phone, !phone.isEmpty {
                    mediaPayload = W.telPrefix + digitsOnly(AdShieldTables.fold(phone))
                }
            default:
                break
            }
        }
        if let fwd {
            if chanFwd && fwd.fromId != 0 && fwd.postId != 0 {
                keys.append((.fwd, W.fwdChannel + dec(fwd.fromId) + [0x7C] + dec(Int64(fwd.postId))))
            } else {
                let who: [UInt32] = fwd.fromId != 0 ? dec(fwd.fromId) : W.fwdName + AdShieldTables.textForm(AdShieldTables.fold(fwd.fromName ?? ""))
                let content: [UInt32] = !t.isEmpty ? W.fwdText + t : (!mediaPayload.isEmpty ? W.fwdMedia + mediaPayload : W.fwdEmpty)
                keys.append((.fwd, W.fwdUser + who + [0x7C] + dec(fwd.date) + [0x7C] + content))
            }
        }
        if !mediaPayload.isEmpty {
            keys.append((.media, mediaPayload))
        }
        if wl >= minTextWlen {
            keys.append((.text, t))
        }
        if cjkCount >= minCjkCount {
            keys.append((.cjk, tc))
        }
        var tmplCond = false
        if (strong != 0 || !pendingTokens.isEmpty) && wl >= minTmplWlen {
            var types = Set<[UInt32]>()
            for l in links {
                types.insert(hasPrefix(l.type, W.typeUrlColon) ? W.typeUrl : l.type)
            }
            if !buttons.isEmpty {
                types.insert(W.typeButton)
            }
            if msg.viaBot {
                types.insert(W.typeViaBot)
            }
            if media?.kind == .contact {
                types.insert(W.typeContact)
            }
            let sortedTypes = types.sorted(by: cpLess)
            keys.append((.tmpl, t + [0x1E] + join(sortedTypes, 0x2C)))
            tmplCond = strong == 0
        }
        var contactSet = Set<[UInt32]>()
        for (l, feat) in zip(links, features) where feat == .strong && (l.kind == .invite || l.kind == .phone || l.kind == .acct) {
            contactSet.insert(l.token)
        }
        if !contactSet.isEmpty {
            keys.append((.contact, join(contactSet.sorted(by: cpLess), 0x2C)))
        }
        for p in paras {
            keys.append((.para, p))
        }
        let hashed: [FingerprintKey] = keys.map { FingerprintKey(kind: $0.0, payload: $0.1, hash: khash(key, $0.0.tag, $0.1)) }

        var subsetTokens: [[UInt32]] = []
        for (l, feat) in zip(links, features) where feat == .strong || feat == .weak {
            subsetTokens.append(l.token)
        }
        if ex.pointer {
            subsetTokens.append(W.ptr)
        }
        if msg.viaBot {
            subsetTokens.append(W.via)
        }
        let linkHashes = dedupe(subsetTokens.map { khash(key, "link", $0) }, cap: maxLinksPerRow)
        let pending = dedupe(pendingTokens.map { khash(key, "link", $0) }, cap: maxPendingPerRow)

        // ---- flags ----
        let fwdIsOthers = fwd != nil && !chanFwd
        var endorsing = (role == .admin || role == .creator || role == .anonAdmin || role == .selfUser) && !fwdIsOthers
        endorsing = endorsing || msg.pinned || msg.autoForward
        if let fwd, ctx.linkedChannelId != 0 && fwd.fromId == ctx.linkedChannelId {
            endorsing = true
        }
        if role == .channel && ctx.linkedChannelId != 0 && msg.sender.id == ctx.linkedChannelId {
            endorsing = true
        }
        var flags: UInt32 = strong | weak
        if wl >= minTextWlen {
            flags |= Flag.hasText
        }
        if keys.contains(where: { $0.0 == .media }) {
            flags |= Flag.hasMediaKey
        }
        if keys.contains(where: { $0.0 == .fwd }) {
            flags |= Flag.hasFwdKey
        }
        if tmplCond {
            flags |= Flag.tmplCond
        }
        if (cjkCount >= pureTextMinCjk || letterCount >= pureTextMinLetters) && !t.contains(0x23) {
            flags |= Flag.pureText
        }
        if let replyTo = msg.replyTo, replyTo != 0 {
            flags |= Flag.isReply
            if isAck(t) {
                flags |= Flag.ack
            }
        }
        if msg.replyToMe {
            flags |= Flag.replyMe
        }
        if msg.mentionsMe {
            flags |= Flag.mentionMe
        }
        if endorsing {
            flags |= Flag.endorsing
        }
        if role == .bot {
            flags |= Flag.bot
        }
        if role == .contact {
            flags |= Flag.contact
        }
        if role == .selfUser {
            flags |= Flag.selfSender
        }

        let store = !hashed.isEmpty && (strong != 0 || weak != 0 || !pending.isEmpty || flags & (Flag.hasMediaKey | Flag.hasFwdKey | Flag.pureText) != 0 || endorsing)
        let senderKey = khash(key, "sender", dec(msg.sender.id))

        var known = Set<UInt64>()
        for n in knownHandles {
            known.insert(handleHash(key: key, name: n))
        }
        for n in ctx.memberHandles {
            known.insert(handleHash(key: key, name: n))
        }
        let resolved = resolve(flags: flags, keys: hashed.map { Key(kind: $0.kind.rawValue, hash: $0.hash) }, links: linkHashes, pending: pending, isKnown: { known.contains($0) })

        return Fingerprint(
            f: f, fNoLinks: ex.fNoLinks, t: t, tCjk: tc, wlen: wl, cjkCount: cjkCount, letterCount: letterCount,
            paragraphs: paras, links: links, linkFeatures: features, strongFlags: strong, weakFlags: weak,
            keys: hashed, linkHashes: linkHashes, pending: pending, flags: flags, senderKey: senderKey, store: store,
            endorsing: endorsing, mentionCount: mentionCount, resolvedFlags: resolved.flags
        )
    }
}
