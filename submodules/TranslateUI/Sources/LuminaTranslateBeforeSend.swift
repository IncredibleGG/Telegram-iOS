import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext
import TelegramUIPreferences
import PresentationDataUtils
import OverlayStatusController

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
//
// `translatingIndicator` shows the "Translating…" hint while a translation is pending and returns
// the disposable that hides it (ChatControllerImpl.luminaPresentTranslatingIndicator: a small
// bubble over the send button that takes no touches). nil, or a call that returns nil, falls back
// to the full-screen spinner presented through `present`.
public func luminaTranslateMessagesBeforeSend(context: AccountContext, peerId: EnginePeer.Id, present: @escaping (ViewController) -> Void, translatingIndicator: (() -> Disposable?)? = nil, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError> {
    let translated: Signal<[EnqueueMessage], NoError> = luminaCurrentSettings(context: context)
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
            // LuminaGram: read the ungated state here - this only picks the target language for
            // the user's own outgoing text, so it must keep working in the chats the automatic
            // translation gate excludes (official/support accounts, BotFather, ...).
            targetLangSignal = luminaChatTranslationStateUnchecked(context: context, peerId: peerId, threadId: nil)
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
                    |> `catch` { error -> Signal<LuminaTranslationResult?, NoError> in
                        // Translation failed (no key, network, rate limit, …): fail open and
                        // send the original as typed rather than blocking the send. A missing
                        // LLM model or a rejected key is also reported once as a toast
                        // (LuminaTranslateFailureNotice.swift); that never delays the send.
                        luminaReportTranslateFailure(context: context, engineId: engine.id, error: error)
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
                // LuminaGram: "Translating…" while the translate round-trip runs, so a send with
                // translate-before-send never looks stuck. The 0.15s delay means fast or cached
                // translates never flash it; placed here (after all gates) so it appears ONLY when
                // translation actually runs, and it goes away when the work finishes. The chat's
                // indicator leaves the input usable, so the user can keep typing and even send the
                // next message - LuminaTranslateBeforeSendOrder below keeps those sends in order.
                // Without an indicator this is the old full-screen spinner.
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let progressDisposable = (Signal<Never, NoError> { _ in
                    if let indicator = translatingIndicator?() {
                        return indicator
                    }
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                    present(controller)
                    return ActionDisposable { [weak controller] in
                        Queue.mainQueue().async {
                            controller?.dismiss()
                        }
                    }
                }
                |> runOn(Queue.mainQueue())
                |> delay(0.15, queue: Queue.mainQueue())).startStrict()
                return combineLatest(signals)
                |> afterDisposed {
                    Queue.mainQueue().async {
                        progressDisposable.dispose()
                    }
                }
            }
        }
    }
    |> deliverOnMainQueue

    // Only chats with translate-before-send on are ordered, read from the synchronous settings
    // cache (the async read above cannot decide this before the caller subscribes). Every other
    // chat keeps the stock path untouched.
    let cachedSettings = LuminaSettingsCache.settings
    if cachedSettings.translateBeforeSend, cachedSettings.trSendEnabledDialog.first(where: { $0.peerId == peerId.toInt64() })?.value == true {
        return LuminaTranslateBeforeSendOrder.ordered(peerId: peerId, translated)
    }
    return translated
}

// LuminaGram: keep a chat's sends in order while translate-before-send is on for it. The
// "Translating…" indicator no longer covers the screen, so a second message (or a sticker) can be
// sent before the first one's translation has come back; without this the faster one would reach
// enqueueMessages first and land above the other. A send that comes through
// luminaTranslateMessagesBeforeSend for such a chat is handed on only after every earlier one from
// that chat has been handed on (or has finished without a result). The wait for earlier sends is
// capped at maxWait, so a request that never finishes cannot hold the chat's sends back.
//
// Main queue only: both callers in ChatController subscribe on the main queue, the translated
// signal is delivered there, and the slots are released there.
private enum LuminaTranslateBeforeSendOrder {
    private static var tails: [EnginePeer.Id: (id: Int, done: Signal<Never, NoError>)] = [:]
    private static var nextId: Int = 0
    private static let maxWait: Double = 20.0

    static func ordered(peerId: EnginePeer.Id, _ signal: Signal<[EnqueueMessage], NoError>) -> Signal<[EnqueueMessage], NoError> {
        return Signal<[EnqueueMessage], NoError> { subscriber in
            LuminaTranslateBeforeSendOrder.nextId += 1
            let id = LuminaTranslateBeforeSendOrder.nextId
            // Completes once every earlier send of this chat has been handed on.
            let previous: Signal<Never, NoError> = LuminaTranslateBeforeSendOrder.tails[peerId]?.done ?? .complete()
            let released = ValuePromise<Bool>(false, ignoreRepeated: true)
            let ownDone: Signal<Never, NoError> = released.get()
            |> filter { $0 }
            |> take(1)
            |> ignoreValues
            LuminaTranslateBeforeSendOrder.tails[peerId] = (id: id, done: previous |> then(ownDone))

            var isReleased = false
            let release: () -> Void = {
                if isReleased {
                    return
                }
                isReleased = true
                released.set(true)
                if let tail = LuminaTranslateBeforeSendOrder.tails[peerId], tail.id == id {
                    LuminaTranslateBeforeSendOrder.tails.removeValue(forKey: peerId)
                }
            }

            var result: [EnqueueMessage]?
            var previousDone = false
            var sourceDone = false
            var finished = false
            let finishIfReady: () -> Void = {
                if finished || !previousDone {
                    return
                }
                if let value = result {
                    finished = true
                    result = nil
                    // The caller enqueues synchronously from putNext, so this send is in the
                    // queue before the next one is released.
                    subscriber.putNext(value)
                    release()
                    subscriber.putCompletion()
                } else if sourceDone {
                    finished = true
                    release()
                    subscriber.putCompletion()
                }
            }

            let previousDisposable = (previous
            |> timeout(LuminaTranslateBeforeSendOrder.maxWait, queue: Queue.mainQueue(), alternate: .complete())).start(completed: {
                previousDone = true
                finishIfReady()
            })
            let sourceDisposable = signal.start(next: { value in
                result = value
                finishIfReady()
            }, completed: {
                sourceDone = true
                finishIfReady()
            })

            return ActionDisposable {
                previousDisposable.dispose()
                sourceDisposable.dispose()
                // A cancelled send must not hold up the ones after it.
                Queue.mainQueue().async {
                    release()
                }
            }
        }
        |> runOn(Queue.mainQueue())
    }
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
