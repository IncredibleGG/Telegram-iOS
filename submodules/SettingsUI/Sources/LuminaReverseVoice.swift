import Foundation
import UIKit
import AVFoundation
import Display
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

// LuminaGram: "reverse voice" - type text, (optionally translated by the caller into the
// recipient's language), speak it with the on-device AVSpeechSynthesizer, encode the result to
// OGG/Opus with the SAME native writer the microphone recorder uses (LuminaOpusPCM, backed by
// OpusBinding/TGOggOpusWriter), and send it as a REAL Telegram voice message - so the other side
// receives an ordinary voice bubble, exactly mirroring the Android port (LuminaTts.java).
// Fully on-device except for the optional translation step (which reuses Telegram's own existing
// translate call, same as LuminaVoiceTranscription's transcribe-then-translate). No voice
// cloning, no cloud TTS, no entitlement - AVSpeechSynthesisVoice is a generic system voice.
// Experimental, default OFF (LuminaSettings.reverseVoice).
public enum LuminaReverseVoiceError {
    case emptyText
    case synthesisFailed
    case encodeFailed
}

public enum LuminaReverseVoice {
    /// Speaks `spokenText` (already translated by the caller, if desired) in `languageCode` and
    /// sends the result as a real voice message to `peerId`. Mirrors Android's LuminaTts.speakAndSend:
    /// the caller is responsible for translating first so the text and the TTS voice locale agree.
    public static func speakAndSend(context: AccountContext, peerId: EnginePeer.Id, spokenText: String, languageCode: String?, completion: @escaping (Result<Void, LuminaReverseVoiceError>) -> Void) {
        let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.emptyText))
            return
        }

        synthesize(text: trimmed, languageCode: languageCode) { result in
            switch result {
            case let .success((pcm, sampleRate)):
                let resampled = LuminaOpusPCM.resampleMono16(pcm, fromRate: sampleRate)
                guard let encoded = LuminaOpusPCM.encodeFromPCM16Mono48k(resampled), encoded.duration > 0 else {
                    DispatchQueue.main.async {
                        completion(.failure(.encodeFailed))
                    }
                    return
                }
                let waveform = LuminaOpusPCM.computeWaveformBitstream(resampled)
                DispatchQueue.main.async {
                    sendVoiceMessage(context: context, peerId: peerId, oggData: encoded.data, duration: encoded.duration, waveform: waveform)
                    completion(.success(()))
                }
            case .failure:
                DispatchQueue.main.async {
                    completion(.failure(.synthesisFailed))
                }
            }
        }
    }

    // MARK: - AVSpeechSynthesizer -> PCM

    /// AVSpeechSynthesizer.write(_:toBufferCallback:) delivers PCM chunks asynchronously and
    /// signals completion with a zero-length final buffer (Apple's documented pattern). The
    /// synthesizer is captured by its own callback closure to keep it alive for the duration of
    /// synthesis - matching the retain pattern Apple's own sample code for this API uses; not
    /// verifiable on-device from this sandbox, flagged in the port report.
    private static func synthesize(text: String, languageCode: String?, completion: @escaping (Result<(pcm: [Int16], sampleRate: Double), LuminaReverseVoiceError>) -> Void) {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        if let languageCode, !languageCode.isEmpty, let voice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = voice
        } else if let detected = NSLinguisticTagger.dominantLanguage(for: text), let voice = AVSpeechSynthesisVoice(language: detected) {
            utterance.voice = voice
        }

        var pcm: [Int16] = []
        var sampleRate: Double = 0
        let lock = NSLock()
        var finished = false

        synthesizer.write(utterance) { [synthesizer] buffer in
            _ = synthesizer // keep the synthesizer alive until the final (zero-length) buffer
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                return
            }
            lock.lock()
            defer { lock.unlock() }
            if finished {
                return
            }
            if pcmBuffer.frameLength == 0 {
                finished = true
                if pcm.isEmpty {
                    completion(.failure(.synthesisFailed))
                } else {
                    completion(.success((pcm, sampleRate)))
                }
                return
            }
            sampleRate = pcmBuffer.format.sampleRate
            let frameCount = Int(pcmBuffer.frameLength)
            let channelCount = max(1, Int(pcmBuffer.format.channelCount))
            if let int16Data = pcmBuffer.int16ChannelData {
                if channelCount == 1 {
                    pcm.append(contentsOf: UnsafeBufferPointer(start: int16Data[0], count: frameCount))
                } else {
                    for i in 0 ..< frameCount {
                        var sum: Int32 = 0
                        for ch in 0 ..< channelCount {
                            sum += Int32(int16Data[ch][i])
                        }
                        pcm.append(Int16(clamping: sum / Int32(channelCount)))
                    }
                }
            } else if let floatData = pcmBuffer.floatChannelData {
                if channelCount == 1 {
                    for i in 0 ..< frameCount {
                        pcm.append(floatToInt16(floatData[0][i]))
                    }
                } else {
                    for i in 0 ..< frameCount {
                        var sum: Float = 0
                        for ch in 0 ..< channelCount {
                            sum += floatData[ch][i]
                        }
                        pcm.append(floatToInt16(sum / Float(channelCount)))
                    }
                }
            }
        }
    }

    private static func floatToInt16(_ f: Float) -> Int16 {
        let clamped = max(Float(-1.0), min(Float(1.0), f))
        return Int16(clamping: Int32(clamped * Float(Int16.max)))
    }

    // MARK: - Send as a real voice message

    /// Builds the same TL_document-style voice attachment Telegram's own microphone-recording
    /// send path builds (ChatControllerMediaRecording.swift) and hands it to the ordinary
    /// enqueueMessages pipeline, so it renders as a normal voice bubble on every client.
    private static func sendVoiceMessage(context: AccountContext, peerId: EnginePeer.Id, oggData: Data, duration: Double, waveform: Data) {
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileMediaResource(fileId: randomId)
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: oggData)

        let file = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: randomId),
            partialReference: nil,
            resource: resource,
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/ogg",
            size: Int64(oggData.count),
            attributes: [.Audio(isVoice: true, duration: Int(duration), title: nil, performer: nil, waveform: waveform)],
            alternativeRepresentations: []
        )

        let message: EnqueueMessage = .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [message]).start()
    }
}
