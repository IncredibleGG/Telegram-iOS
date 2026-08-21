import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext
import TelegramUIPreferences
import PresentationDataUtils

// LuminaGram — per-chat translate-before-send (iOS twin of Android's ChatActivityEnterView
// translate-before-send hook + LuminaTBS.java, and desktop's lumina_translate_send.{h,cpp}).
// Telegram-iOS has no outgoing-translation plumbing at all — this is the hook. It is called
// from ChatController.sendMessages right before Telegram's own send pipeline runs (see the
// `// LuminaGram: translate-before-send` insertion there): it translates the plain text of
// each outgoing message through LuminaTranslatorRegistry.current(context:) (which already
// carries glossary protection) and swaps the translation in, capturing the original in
// LuminaTranslateBeforeSendStore so it can be revealed later.
public enum LuminaTranslateBeforeSendChoice {
    case sendTranslation
    case sendOriginal
}

// Only plain, untagged text is intercepted — matches desktop's documented behavior
// (lumina_translate_send.cpp): formatted text (bold/mentions/custom entities/…) passes
// through untouched, since the entity ranges would no longer line up after translation.
// Bot commands are left alone too, since translating "/start" defeats the command.
private func luminaShouldTranslateBeforeSend(text: String, attributes: [MessageAttribute]) -> Bool {
    if text.isEmpty || text.hasPrefix("/") {
        return false
    }
    if attributes.contains(where: { $0 is TextEntitiesMessageAttribute }) {
        return false
    }
    return true
}

// The single entry point ChatController.sendMessages calls. A fast no-op path (`.single(messages)`
// with no further work) whenever the feature or this specific dialog is off, so the stock send
// path is unaffected when translate-before-send has never been touched.
public func luminaTranslateMessagesBeforeSend(context: AccountContext, peerId: EnginePeer.Id, present: @escaping (ViewController) -> Void, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError> {
    return luminaCurrentSettings(context: context)
    |> mapToSignal { settings -> Signal<[EnqueueMessage], NoError> in
        guard settings.translateBeforeSend else {
            return .single(messages)
        }
        guard settings.trSendEnabledDialog.first(where: { $0.peerId == peerId.toInt64() })?.value == true else {
            return .single(messages)
        }
        guard messages.contains(where: { message in
            if case let .message(text, attributes, _, _, _, _, _, _, _, _) = message {
                return luminaShouldTranslateBeforeSend(text: text, attributes: attributes)
            }
            return false
        }) else {
            return .single(messages)
        }

        let storedLang = settings.trSendLangDialog.first(where: { $0.peerId == peerId.toInt64() })?.value ?? settings.trSendLang
        let targetLangSignal: Signal<String, NoError>
        if storedLang.isEmpty || storedLang == "auto" {
            // "auto" = the recipient's language, guessed from the same detector dual-language
            // display already relies on: the dominant detected language of this peer's own
            // recent incoming messages (ChatTranslation.swift's chatTranslationState).
            targetLangSignal = chatTranslationState(context: context, peerId: peerId, threadId: nil)
            |> take(1)
            |> map { state -> String in
                if let fromLang = state?.fromLang, !fromLang.isEmpty {
                    return fromLang
                }
                return "en"
            }
        } else {
            targetLangSignal = .single(storedLang)
        }

        return targetLangSignal
        |> mapToSignal { toLang -> Signal<[EnqueueMessage], NoError> in
            return LuminaTranslatorRegistry.current(context: context)
            |> mapToSignal { engine -> Signal<[EnqueueMessage], NoError> in
                let signals: [Signal<EnqueueMessage, NoError>] = messages.map { message -> Signal<EnqueueMessage, NoError> in
                    guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else {
                        return .single(message)
                    }
                    guard luminaShouldTranslateBeforeSend(text: text, attributes: attributes) else {
                        return .single(message)
                    }
                    return engine.translate(text: text, toLang: toLang, peerId: peerId, context: context)
                    |> map { result -> LuminaTranslationResult? in
                        return result
                    }
                    |> `catch` { _ -> Signal<LuminaTranslationResult?, NoError> in
                        // Translation failed (no key, network, rate limit, …): fail open and
                        // send the original as typed rather than blocking the send.
                        return .single(nil)
                    }
                    |> mapToSignal { result -> Signal<EnqueueMessage, NoError> in
                        guard let result, !result.text.isEmpty, result.text != text else {
                            return .single(message)
                        }
                        let resolvedCorrelationId = correlationId ?? Int64.random(in: 1...Int64.max)
                        // LuminaGram (己方): send ONLY the translation to the recipient (对方 sees the
                        // clean translation, never the original). Stash the pre-send original locally,
                        // keyed by correlationId (round-tripped onto the message's
                        // OutgoingMessageInfoAttribute), so the SENDER's OWN bubble renders
                        // original+translation - see the !incoming branch in ChatMessageTextBubbleContentNode.
                        // No "send original vs translation" prompt.
                        let translatedMessage = EnqueueMessage.message(text: result.text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: resolvedCorrelationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
                        LuminaTranslateBeforeSendStore.remember(correlationId: resolvedCorrelationId, original: text)
                        return .single(translatedMessage)
                    }
                }
                return combineLatest(signals)
            }
        }
    }
    |> deliverOnMainQueue
}

// The pre-translation original for a sent message, if translate-before-send fired for it —
// for a "Show Original" context-menu action on own messages. correlationId round-trips onto
// the persisted message via OutgoingMessageInfoAttribute (see LuminaTranslateBeforeSendStore's
// header comment); nil for any message translate-before-send never touched.
public func luminaOriginalText(for message: Message) -> String? {
    guard let attribute = message.attributes.first(where: { $0 is OutgoingMessageInfoAttribute }) as? OutgoingMessageInfoAttribute else {
        return nil
    }
    return LuminaTranslateBeforeSendStore.original(correlationId: attribute.correlationId)
}

private func luminaPresentTranslateBeforeSendConfirm(context: AccountContext, present: @escaping (ViewController) -> Void, original: String, translated: String, completion: @escaping (LuminaTranslateBeforeSendChoice) -> Void) {
    var didComplete = false
    let complete: (LuminaTranslateBeforeSendChoice) -> Void = { choice in
        guard !didComplete else {
            return
        }
        didComplete = true
        completion(choice)
    }
    let text = LuminaL10n.tr("Translation:") + "\n\(translated)\n\n" + LuminaL10n.tr("Original:") + "\n\(original)"
    // dismissOnOutsideTap: false — this signal only completes when one of the two actions
    // fires (see luminaTranslateMessagesBeforeSend); an outside-tap dismissal with neither
    // action firing would otherwise hang that message's send indefinitely.
    let controller = textAlertController(context: context, title: LuminaL10n.tr("Send translation?"), text: text, actions: [
        TextAlertAction(type: .genericAction, title: LuminaL10n.tr("Send Original"), action: {
            complete(.sendOriginal)
        }),
        TextAlertAction(type: .defaultAction, title: LuminaL10n.tr("Send Translation"), action: {
            complete(.sendTranslation)
        })
    ], dismissOnOutsideTap: false)
    present(controller)
}
