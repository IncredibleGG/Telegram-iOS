import Foundation
import Speech
import AVFoundation
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData
import AccountContext
import UndoUI
import TranslateUI
// LuminaOpusPCM (the OGG/Opus decode helper reused below) lives in SettingsUI, alongside the
// rest of the reverse-voice pipeline that also needs it - see LuminaReverseVoice.swift's file
// header for why. TelegramUI already depends on SettingsUI, so this is a same-direction import.
import SettingsUI

// LuminaGram: voice-to-text. Transcribes a received voice note / round-video ENTIRELY ON DEVICE
// using Apple's Speech framework, and displays the result through Telegram's OWN existing
// transcription UI (the same AudioTranscriptionMessageAttribute that ChatMessageInteractiveFileNode
// / ChatMessageInteractiveInstantVideoNode already know how to render) - by writing the attribute
// directly into the local Postbox, the SAME way TelegramCore's _internal_transcribeAudio does
// (see TelegramCore/Sources/TelegramEngine/Messages/Transcription.swift) MINUS the
// `messages.transcribeAudio` server RPC that function issues. No server call is made, so this
// never touches Telegram's premium transcription trial/quota.
//
// CRITICAL ToS/privacy requirement (see IOS-PORT-PLAN.md "Voice & Media" + risk #4): this MUST
// stay on-device. SFSpeechRecognizer.supportsOnDeviceRecognition is checked and recognition is
// hard-gated with requiresOnDeviceRecognition = true; if on-device recognition is unavailable for
// the resolved locale we bail out with an error rather than silently letting iOS route the audio
// to Apple's servers.
//
// Scope note: this targets SFSpeechRecognizer (iOS 13+), which is correct and available on every
// OS version this app supports. The roadmap also mentions iOS 26's newer SpeechAnalyzer /
// SpeechTranscriber API as a possible upgrade path; that API was intentionally NOT adopted here -
// it is very new, its exact Swift signatures could not be verified against real SDK headers from
// this sandbox, and a wrong guess would risk breaking compilation for every OS version rather than
// just failing to upgrade gracefully. SFSpeechRecognizer already works fine on iOS 26.
public enum LuminaVoiceTranscription {
    public enum FailureReason {
        case noAudio
        case authorizationDenied
        case onDeviceUnavailable
        case decodeFailed
        case emptyResult
        case recognitionFailed
    }

    /// True when `message` carries a voice note or round-video that this feature can act on.
    public static func isApplicable(to message: Message) -> Bool {
        return voiceFile(in: message) != nil
    }

    /// Entry point wired from the voice-message context menu. `displayUndo` is expected to be
    /// `ChatControllerInteraction.displayUndo` - the same bulletin surface Translate/Speak and
    /// every other context-menu action already use for feedback.
    public static func transcribe(context: AccountContext, message: Message, displayUndo: @escaping (UndoOverlayContent) -> Void) {
        guard let file = voiceFile(in: message) else {
            return
        }
        guard let path = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(file.resource.id), pathExtension: "ogg"), !path.isEmpty else {
            presentError(.noAudio, displayUndo: displayUndo)
            return
        }

        presentInfo("Transcribing…", displayUndo: displayUndo)

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    presentError(.authorizationDenied, displayUndo: displayUndo)
                    return
                }
                runRecognition(context: context, message: message, path: path, displayUndo: displayUndo)
            }
        }
    }

    // MARK: - Recognition

    private final class DeliveryGuard {
        var delivered = false
    }

    private static func runRecognition(context: AccountContext, message: Message, path: String, displayUndo: @escaping (UndoOverlayContent) -> Void) {
        guard let pcm = LuminaOpusPCM.decodeToPCM16Mono48k(path: path), !pcm.isEmpty else {
            presentError(.decodeFailed, displayUndo: displayUndo)
            return
        }

        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            presentError(.recognitionFailed, displayUndo: displayUndo)
            return
        }
        // CRITICAL: never fall back to server-side recognition - see file header.
        guard recognizer.supportsOnDeviceRecognition else {
            presentError(.onDeviceUnavailable, displayUndo: displayUndo)
            return
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let channelData = buffer.int16ChannelData else {
            presentError(.decodeFailed, displayUndo: displayUndo)
            return
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelData[0].update(from: base, count: pcm.count)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        request.append(buffer)
        request.endAudio()

        let guardBox = DeliveryGuard()
        recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                if guardBox.delivered {
                    return
                }
                guardBox.delivered = true
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    deliver(context: context, message: message, transcript: text, displayUndo: displayUndo)
                }
            } else if let error {
                if guardBox.delivered {
                    return
                }
                guardBox.delivered = true
                _ = error
                DispatchQueue.main.async {
                    presentError(.recognitionFailed, displayUndo: displayUndo)
                }
            }
        }
    }

    // MARK: - Delivery (local-only, no server RPC)

    private static func deliver(context: AccountContext, message: Message, transcript: String, displayUndo: @escaping (UndoOverlayContent) -> Void) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentError(.emptyResult, displayUndo: displayUndo)
            return
        }

        writeTranscript(context: context, messageId: message.id, text: trimmed)

        let _ = (luminaSettings(context: context)
        |> take(1)
        |> deliverOnMainQueue).start(next: { settings in
            guard settings.autoTranslateTranscript else {
                return
            }
            resolveReadingLanguage(context: context, peerId: message.id.peerId, settings: settings, completion: { targetLang in
                guard let targetLang, !targetLang.isEmpty else {
                    return
                }
                let _ = (context.engine.messages.translate(text: trimmed, toLang: targetLang)
                |> deliverOnMainQueue).start(next: { result in
                    guard let (translated, _) = result else {
                        return
                    }
                    let translatedTrimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !translatedTrimmed.isEmpty, translatedTrimmed.caseInsensitiveCompare(trimmed) != .orderedSame else {
                        return
                    }
                    // Same two-segment-in-one-string shape as the Android port (LuminaVoiceToText):
                    // the transcription slot is a plain String, so a styled sub-line can't survive
                    // persistence - a blank line separates transcript from translation instead.
                    writeTranscript(context: context, messageId: message.id, text: trimmed + "\n\n" + translatedTrimmed)
                }, error: { _ in
                    // Fail-safe: the plain transcript is already on screen.
                })
            })
        })
    }

    private static func writeTranscript(context: AccountContext, messageId: MessageId, text: String) {
        let _ = context.account.postbox.transaction { transaction -> Void in
            transaction.updateMessage(messageId, update: { currentMessage in
                let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                var attributes = currentMessage.attributes.filter { !($0 is AudioTranscriptionMessageAttribute) }
                attributes.append(AudioTranscriptionMessageAttribute(id: Int64.random(in: Int64.min ... Int64.max), text: text, isPending: false, didRate: false, error: nil))
                return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
            })
        }.start()
    }

    // MARK: - Reading-language resolution (mirrors Android LuminaVoiceToText.readLanguage order:
    // explicit Lumina read-language setting, then the dialog's own live translation target, then
    // the device's language as a last resort)

    private static func resolveReadingLanguage(context: AccountContext, peerId: EnginePeer.Id, settings: LuminaSettings, completion: @escaping (String?) -> Void) {
        if !settings.trReadLang.isEmpty {
            completion(settings.trReadLang)
            return
        }
        let _ = (chatTranslationState(context: context, peerId: peerId, threadId: nil)
        |> take(1)
        |> deliverOnMainQueue).start(next: { state in
            if let state, state.isEnabled, let toLang = state.toLang, !toLang.isEmpty {
                completion(toLang)
            } else {
                completion(Locale.current.languageCode)
            }
        })
    }

    private static func luminaSettings(context: AccountContext) -> Signal<LuminaSettings, NoError> {
        return context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.luminaSettings])
        |> map { sharedData -> LuminaSettings in
            return sharedData.entries[ApplicationSpecificSharedDataKeys.luminaSettings]?.get(LuminaSettings.self) ?? .defaultSettings
        }
    }

    // MARK: - Helpers

    private static func voiceFile(in message: Message) -> TelegramMediaFile? {
        for media in message.media {
            if let file = media as? TelegramMediaFile, file.isVoice || file.isInstantVideo {
                return file
            }
        }
        return nil
    }

    // LuminaGram's UI strings are hardcoded English rather than routed through PresentationStrings
    // - same rationale as LuminaGramSettingsController.swift: a fork-invented strings key has no
    // cloud translation and would silently read English for non-English users regardless of their
    // language.
    private static func presentError(_ reason: FailureReason, displayUndo: @escaping (UndoOverlayContent) -> Void) {
        let text: String
        switch reason {
        case .noAudio:
            text = "Voice message isn't downloaded yet."
        case .authorizationDenied:
            text = "Speech recognition permission is required. Enable it in Settings."
        case .onDeviceUnavailable:
            text = "On-device transcription isn't available for this language."
        case .decodeFailed:
            text = "Couldn't read this voice message."
        case .emptyResult:
            text = "No speech was recognized."
        case .recognitionFailed:
            text = "Transcription failed."
        }
        presentInfo(text, displayUndo: displayUndo)
    }

    private static func presentInfo(_ text: String, displayUndo: @escaping (UndoOverlayContent) -> Void) {
        displayUndo(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
    }
}
