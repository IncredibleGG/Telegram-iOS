import Foundation
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import TelegramUIPreferences
import ChatHistoryEntry

// LuminaGram「隱藏重複廣告」(hide repeated ads), stage 2: the rendered chat history entries.
//
// `luminaAdShieldFoldedEntries` is called by ChatHistoryEntriesForView right after the keyword filter. A run of
// consecutive folded messages (a segment; an album is one unit) becomes ONE fold row at the segment head and its other
// messages are left out of the rendered entries; an expanded segment gets a slim header above it; in trial run a small
// label goes above every message that would fold. The history view itself is never changed, and the entries stay
// sorted with unique stable ids (LuminaAdFoldEntryData.stableId), which the list diff relies on.

// MARK: - Entries (ChatHistoryEntriesForView)

/// The message ids an entry renders, as one AdShield unit: a message of the group, or every message of an album.
/// Anything else (service rows, sponsored messages, local or scheduled messages) is [] and breaks a segment.
private func luminaAdShieldUnit(_ entry: ChatHistoryEntry, peerId: PeerId) -> [Int32] {
    switch entry {
    case let .MessageEntry(message, _, _, _, _, _):
        if message.id.peerId == peerId && message.id.namespace == Namespaces.Message.Cloud && message.adAttribute == nil {
            return [message.id.id]
        }
        return []
    case let .MessageGroupEntry(_, messages, _):
        var ids: [Int32] = []
        for (message, _, _, _, _) in messages {
            if message.id.peerId != peerId || message.id.namespace != Namespaces.Message.Cloud || message.adAttribute != nil {
                return []
            }
            ids.append(message.id.id)
        }
        return ids
    default:
        return []
    }
}

private func luminaAdShieldEntryMessages(_ entry: ChatHistoryEntry) -> [Message] {
    switch entry {
    case let .MessageEntry(message, _, _, _, _, _):
        return [message]
    case let .MessageGroupEntry(_, messages, _):
        return messages.map { $0.0 }
    default:
        return []
    }
}

/// The test ChatHistoryListNode applies to a shown message before consuming its mention.
private func luminaAdShieldHasUnseenMention(_ message: Message) -> Bool {
    if !message.tags.contains(.unseenPersonalMessage) {
        return false
    }
    var hasMention = false
    for attribute in message.attributes {
        if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute, !attribute.pending {
            hasMention = true
        } else if let attribute = attribute as? ConsumableContentMessageAttribute, !attribute.consumed {
            return false
        }
    }
    return hasMention
}

private func luminaAdShieldRowData(kind: LuminaAdFoldEntryData.Kind, entries: ArraySlice<ChatHistoryEntry>, unitCount: Int, occurrence: Int, containsReplyToMe: Bool) -> LuminaAdFoldEntryData? {
    var headStableId: UInt32?
    var ids: [EngineMessage.Id] = []
    var indices: [EngineMessage.Index] = []
    var mentions: [EngineMessage.Id] = []
    for entry in entries {
        for message in luminaAdShieldEntryMessages(entry) {
            if headStableId == nil {
                headStableId = message.stableId
            }
            ids.append(message.id)
            indices.append(message.index)
            if kind == .folded && luminaAdShieldHasUnseenMention(message) {
                mentions.append(message.id)
            }
        }
    }
    guard let headStableId else {
        return nil
    }
    return LuminaAdFoldEntryData(kind: kind, headStableId: headStableId, messageIds: ids, messageIndices: indices, unseenMentionIds: mentions, unitCount: unitCount, occurrence: occurrence, containsReplyToMe: containsReplyToMe)
}

/// ChatHistoryEntriesForView, right after the keyword filter (entries in ascending order). Display only: returns the
/// entries to render; the messages of a folded segment other than its head are left out here and nowhere else.
func luminaAdShieldFoldedEntries(_ entries: [ChatHistoryEntry], session: LuminaAdShieldChatSession, peerId: PeerId, presentationData: ChatPresentationData) -> [ChatHistoryEntry] {
    if !session.isActive || entries.isEmpty {
        return entries
    }
    let units = entries.map { luminaAdShieldUnit($0, peerId: peerId) }

    if session.isTrialRun {
        // 試運行: nothing is hidden; a label goes on top of every message (album) that would fold.
        var result: [ChatHistoryEntry] = []
        result.reserveCapacity(entries.count + 8)
        for i in 0 ..< entries.count {
            if units[i].contains(where: { session.isSuspected($0) }), let data = luminaAdShieldRowData(kind: .trialLabel, entries: entries[i ... i], unitCount: 1, occurrence: 0, containsReplyToMe: false) {
                result.append(.LuminaAdFoldEntry(entries[i].index, data, presentationData))
            }
            result.append(entries[i])
        }
        return result
    }

    let segments = session.foldSegments(units: units)
    if segments.isEmpty {
        return entries
    }
    var result: [ChatHistoryEntry] = []
    result.reserveCapacity(entries.count)
    var next = 0
    for segment in segments {
        let range = segment.unitRange
        if range.isEmpty || range.lowerBound < next || range.upperBound > entries.count {
            continue
        }
        guard let data = luminaAdShieldRowData(kind: segment.isExpanded ? .expandedHeader : .folded, entries: entries[range], unitCount: segment.unitCount, occurrence: segment.occurrence, containsReplyToMe: segment.containsReplyToMe) else {
            continue
        }
        result.append(contentsOf: entries[next ..< range.lowerBound])
        // The row takes the head's index: a fold row stands in its place, a header sorts right before it.
        result.append(.LuminaAdFoldEntry(entries[range.lowerBound].index, data, presentationData))
        if segment.isExpanded {
            result.append(contentsOf: entries[range])
        }
        next = range.upperBound
    }
    result.append(contentsOf: entries[next...])
    return result
}

/// The message a jump (reply quote, search result, link, pinned bar) is going to, if the location is one.
func luminaAdShieldJumpTarget(_ location: ChatHistoryLocationInput?) -> EngineMessage.Id? {
    guard let location else {
        return nil
    }
    switch location.content {
    case let .Scroll(subject, _, _, _, _, highlight, setupReply):
        if highlight || setupReply, case let .message(index) = subject.index {
            return index.id
        }
        return nil
    case let .InitialSearch(subject, _, _, _, _):
        if case let .id(id) = subject.location {
            return id
        }
        return nil
    default:
        return nil
    }
}
