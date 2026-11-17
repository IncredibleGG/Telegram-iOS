import TelegramCore

/// LuminaGram「隱藏重複廣告」(hide repeated ads): what a `ChatHistoryEntry.LuminaAdFoldEntry` row shows.
///
/// These rows exist only in the rendered entries of a group's main chat history (ChatHistoryEntriesForView, after the
/// keyword filter). The messages they stand for stay in the history view untouched; a folded segment's other messages
/// are simply not rendered. Ordering: a row takes the `index` of the entry it is placed at (the segment head), and
/// its `stableId` sorts it right around that entry (see `ChatHistoryEntry.stableId`).
public struct LuminaAdFoldEntryData: Equatable {
    public enum Kind: Int32, Equatable {
        /// The one row standing for a folded segment: 「已收合 N 則重複訊息（疑似廣告）· 點擊顯示」.
        case folded
        /// The slim header above an expanded segment: 「重複訊息（疑似廣告）· 收合 · 不是廣告」.
        case expandedHeader
        /// Trial run (試運行): the small 「疑似重複廣告」 label above a message that would fold.
        case trialLabel
    }

    public let kind: Kind
    /// Stable id of the head entry's first message: the row's identity in the list.
    public let headStableId: UInt32
    /// Every message of the segment (the label's message for a trial label), album members included.
    public let messageIds: [EngineMessage.Id]
    /// The indices of those messages: a fold row on screen reads them (no stuck unread badge).
    public let messageIndices: [EngineMessage.Index]
    /// Those of the messages that carry an unseen mention of me, consumed like the mentions of a shown message.
    public let unseenMentionIds: [EngineMessage.Id]
    /// Folded units (an album counts once): the {n} of the fold row.
    public let unitCount: Int
    /// Decision.occurrence of a one-unit segment (the {k} of 「7 天內第 {k} 次出現」), 0 otherwise.
    public let occurrence: Int
    /// The segment holds a message replying to or mentioning me (the 「回覆你的」 text).
    public let containsReplyToMe: Bool

    public init(kind: Kind, headStableId: UInt32, messageIds: [EngineMessage.Id], messageIndices: [EngineMessage.Index], unseenMentionIds: [EngineMessage.Id], unitCount: Int, occurrence: Int, containsReplyToMe: Bool) {
        self.kind = kind
        self.headStableId = headStableId
        self.messageIds = messageIds
        self.messageIndices = messageIndices
        self.unseenMentionIds = unseenMentionIds
        self.unitCount = unitCount
        self.occurrence = occurrence
        self.containsReplyToMe = containsReplyToMe
    }

    /// The list identity of the row. Message entries use type tags 2...7 in bits 40+ (`ChatHistoryEntry.stableId`);
    /// these use the free values below them, so that at an equal `index` the row sorts like this:
    ///  - a fold row (type 1) replaces its head entry and still sorts before an unread separator at that index;
    ///  - a header or a trial label (below 2^40) sorts before the message entry it sits on top of.
    public var stableId: UInt64 {
        switch self.kind {
        case .folded:
            return UInt64(self.headStableId) | (UInt64(1) << 40)
        case .expandedHeader:
            return UInt64(self.headStableId)
        case .trialLabel:
            return UInt64(self.headStableId) | (UInt64(1) << 39)
        }
    }
}
