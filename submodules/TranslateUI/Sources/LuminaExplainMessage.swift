import Foundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramUIPreferences
import PresentationDataUtils

// LuminaGram — explain-a-message / cultural note (iOS twin of desktop's
// lumina_explain.{h,cpp}). Sends the selected message text to the user's own configured LLM
// engine and shows the result in a sheet. LLM-only — DeepL/Google/Telegram have no channel
// for this kind of open-ended request. Gated by LuminaSettings.explainMessage at the call
// site (ChatInterfaceStateContextMenus.swift's `// LuminaGram: explain-a-message` insertion);
// this function itself is unconditional once called.
//
// Deliberately reuses LuminaLLMEngine's HTTP shape (luminaHTTPRequest, LuminaKeychain,
// LuminaLLMDefaults) but NOT LuminaTranslatorEngine.translate(...) itself: explain is a
// different request (a free-form question, not "translate into {lang}"), so it builds its
// own system prompt rather than routing through the translate-prompt/register pipeline.
//
// Context (same design on every platform): when `message` is given, up to 8 earlier text
// messages from the same chat (or the same thread / topic when `threadId` is set) and the
// message the target replies to are sent along, capped at ~1500 characters with the oldest
// dropped first, so the model can tell what "it" or "that" refers to, or spot slang and irony.
// Speakers are only ever "Me" (the user) and A, B, C... - never names, usernames, phone
// numbers or ids. Secret chats and protected dialogs (Saved Messages, Telegram service and
// verification accounts, BotFather, support accounts; luminaIsExplainContextExcludedChat) get
// no context: only the target is sent, exactly as before.
public func luminaExplainMessage(context: AccountContext, present: @escaping (ViewController) -> Void, text: String, message: Message? = nil, threadId: Int64? = nil) {
    guard !text.isEmpty else {
        return
    }
    guard let rawKey = LuminaKeychain.get(LuminaKeychainKey.translateProviderAPIKey(providerId: "llm")), !rawKey.isEmpty else {
        present(luminaSimpleAlert(context: context, title: LuminaL10n.tr("Explain"), text: LuminaL10n.tr("Add an LLM API key on the Translation settings page to use Explain.")))
        return
    }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

    let _ = (combineLatest(
        luminaCurrentSettings(context: context) |> take(1),
        luminaExplainContext(context: context, message: message, threadId: threadId)
    )
    |> deliverOnMainQueue).start(next: { settings, explainContext in
        let base = LuminaLLMDefaults.resolvedBaseUrl(settings.translateBaseUrl)
        let model = LuminaLLMDefaults.resolvedModel(settings.translateModel)
        let interfaceLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let readLangName = LuminaLang.name(settings.trReadLang.isEmpty ? interfaceLang : settings.trReadLang)

        // Four labelled sections, mirroring desktop's ExplainPrompt: literal meaning, actual
        // tone/intent/subtext, cultural or slang notes (or "None"), then reply suggestions.
        var prompt = "You are explaining a chat message to someone who received it. Reply in "
            + readLangName + ". Structure your reply in exactly four short labelled sections, in "
            + "this order: 1) Literal meaning — a plain, literal explanation of what the message "
            + "says. 2) Actual tone and intent — what the sender most likely means or feels, "
            + "including any subtext. 3) Cultural or slang notes — anything a reader unfamiliar "
            + "with the sender's language or culture might miss; write \"None\" if there is "
            + "nothing notable. 4) How to reply — one or two brief, natural reply suggestions. "
            + "Keep the whole answer concise and write only the four sections, nothing else."

        let userContent: String
        if let explainContext {
            prompt += " The user's message contains the TARGET message and, before it, earlier "
                + "messages from the same conversation as context. Explain only the TARGET "
                + "message. Use the context to work out slang, references, irony, or what words "
                + "like \"it\" or \"that\" refer to; if the context is irrelevant, ignore it. "
                + "Speakers are labelled \"Me\" (the person asking you) and A, B, C for the "
                + "other participants; refer to them only by these labels."
            userContent = explainContext.render(targetText: text)
        } else {
            userContent = text
        }

        guard let url = URL(string: base + "/chat/completions") else {
            present(luminaProviderErrorAlert(context: context, title: LuminaL10n.tr("Explain"), error: .network(nil), usesBaseUrl: true, present: present))
            return
        }
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": userContent]
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        let headers = [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json"
        ]

        let _ = (luminaHTTPRequest(url: url, method: "POST", headers: headers, body: body, model: model)
        |> mapToSignal { data -> Signal<String, LuminaTranslateError> in
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let reply = first["message"] as? [String: Any],
                let content = reply["content"] as? String
            else {
                return .fail(.badResponse)
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .fail(.badResponse)
            }
            return .single(trimmed)
        }
        |> deliverOnMainQueue).start(next: { explanation in
            present(luminaSimpleAlert(context: context, title: LuminaL10n.tr("Explain"), text: explanation))
        }, error: { error in
            present(luminaProviderErrorAlert(context: context, title: LuminaL10n.tr("Explain"), error: error, usesBaseUrl: true, present: present))
        })
    })
}

private func luminaSimpleAlert(context: AccountContext, title: String, text: String) -> ViewController {
    return textAlertController(context: context, title: title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("OK"), action: {})
    ])
}

// MARK: - Conversation context

private let luminaExplainContextMaxMessages = 8
private let luminaExplainContextMaxCharacters = 1500
// One long message must not crowd out everything else.
private let luminaExplainContextMaxCharactersPerMessage = 600
// How far back to look for the 8 text messages (service messages and bare media are skipped).
private let luminaExplainContextScanLimit = 40

private struct LuminaExplainContextLine {
    let speaker: String
    let text: String
    let isReplyTarget: Bool
}

private struct LuminaExplainContext {
    // Oldest first.
    let lines: [LuminaExplainContextLine]
    let targetSpeaker: String

    func render(targetText: String) -> String {
        var result = "Earlier messages in this chat, oldest first (context only):\n"
        for line in self.lines {
            if line.isReplyTarget {
                result += "\(line.speaker) [the TARGET message replies to this one]: \(line.text)\n"
            } else {
                result += "\(line.speaker): \(line.text)\n"
            }
        }
        result += "\nTARGET message (from \(self.targetSpeaker)), explain this one:\n"
        result += targetText
        return result
    }
}

// The user's own message: sent by this account (also as a channel / anonymous admin).
private func luminaExplainIsOwnMessage(_ message: Message, accountPeerId: PeerId) -> Bool {
    if message.author?.id == accountPeerId {
        return true
    }
    return !message.effectivelyIncoming(accountPeerId)
}

// Text or caption of a context message as one line, or nil when it must not / cannot be used:
// service messages, media without a caption, and anything written by or forwarded from an
// official Telegram account (login codes, BotFather tokens).
private func luminaExplainContextText(_ message: Message, accountPeerId: PeerId) -> String? {
    if message.media.contains(where: { $0 is TelegramMediaAction }) {
        return nil
    }
    if luminaIsAutoTranslateExcludedMessage(accountPeerId: accountPeerId, message: message) {
        return nil
    }
    let parts = message.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if parts.isEmpty {
        return nil
    }
    var text = parts.joined(separator: " / ")
    if text.count > luminaExplainContextMaxCharactersPerMessage {
        text = String(text.prefix(luminaExplainContextMaxCharactersPerMessage)) + "…"
    }
    return text
}

private func luminaExplainSpeakerLabel(_ index: Int) -> String {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    if index < letters.count {
        return String(letters[index])
    }
    return "P\(index + 1)"
}

private func luminaExplainContext(context: AccountContext, message: Message?, threadId: Int64?) -> Signal<LuminaExplainContext?, NoError> {
    guard let message else {
        return .single(nil)
    }
    let accountPeerId = context.account.peerId
    let peerId = message.id.peerId
    if luminaIsExplainContextExcludedChat(accountPeerId: accountPeerId, peerId: peerId, peer: message.peers[peerId]) {
        return .single(nil)
    }
    // Scheduled, local (still sending) and other non-cloud messages have no history to anchor to.
    guard message.id.namespace == Namespaces.Message.Cloud else {
        return .single(nil)
    }
    return context.account.postbox.transaction { transaction -> LuminaExplainContext? in
        // Re-check with the stored peer, which carries the support flag even if the message
        // snapshot did not include it.
        if luminaIsExplainContextExcludedChat(accountPeerId: accountPeerId, peerId: peerId, peer: transaction.getPeer(peerId)) {
            return nil
        }
        let lowerBound = MessageIndex.lowerBound(peerId: peerId, namespace: Namespaces.Message.Cloud)
        let fetched: [Message]
        if let threadId {
            fetched = transaction.getMessagesWithThreadId(peerId: peerId, namespace: Namespaces.Message.Cloud, threadId: threadId, from: message.index, includeFrom: false, to: lowerBound, limit: luminaExplainContextScanLimit)
        } else {
            fetched = transaction.getMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, from: message.index, includeFrom: false, to: lowerBound, limit: luminaExplainContextScanLimit)
        }
        // Newest first.
        let preceding = fetched.filter { $0.index < message.index }.sorted(by: { $0.index > $1.index })

        var replyMessage: Message?
        if let replyAttribute = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, replyAttribute.messageId.peerId == peerId, replyAttribute.messageId != message.id {
            replyMessage = transaction.getMessage(replyAttribute.messageId) ?? message.associatedMessages[replyAttribute.messageId]
        }

        var picked: [(message: Message, text: String, isReplyTarget: Bool)] = []
        var pickedIds = Set<MessageId>()
        var budget = luminaExplainContextMaxCharacters

        // The message the target replies to is the most direct context, so it is kept first.
        if let replyMessage, let text = luminaExplainContextText(replyMessage, accountPeerId: accountPeerId) {
            picked.append((message: replyMessage, text: text, isReplyTarget: true))
            pickedIds.insert(replyMessage.id)
            budget -= text.count + 4
        }

        // Then up to 8 earlier messages, newest first; when the budget runs out the rest (the
        // oldest) are dropped.
        var precedingCount = 0
        for candidate in preceding {
            if precedingCount >= luminaExplainContextMaxMessages {
                break
            }
            if pickedIds.contains(candidate.id) {
                precedingCount += 1
                continue
            }
            guard let text = luminaExplainContextText(candidate, accountPeerId: accountPeerId) else {
                continue
            }
            let cost = text.count + 4
            if cost > budget {
                break
            }
            picked.append((message: candidate, text: text, isReplyTarget: false))
            pickedIds.insert(candidate.id)
            budget -= cost
            precedingCount += 1
        }

        if picked.isEmpty {
            return nil
        }
        picked.sort(by: { $0.message.index < $1.message.index })

        // Labels in order of first appearance, consistent within this one request.
        var labels: [PeerId: String] = [:]
        func speaker(for item: Message) -> String {
            if luminaExplainIsOwnMessage(item, accountPeerId: accountPeerId) {
                return "Me"
            }
            let key = item.author?.id ?? item.id.peerId
            if let existing = labels[key] {
                return existing
            }
            let label = luminaExplainSpeakerLabel(labels.count)
            labels[key] = label
            return label
        }
        let lines = picked.map { item -> LuminaExplainContextLine in
            return LuminaExplainContextLine(speaker: speaker(for: item.message), text: item.text, isReplyTarget: item.isReplyTarget)
        }
        return LuminaExplainContext(lines: lines, targetSpeaker: speaker(for: message))
    }
}
