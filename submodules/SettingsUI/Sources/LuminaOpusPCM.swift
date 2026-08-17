import Foundation
import OpusBinding
import AudioWaveform

// Lives in SettingsUI (not TelegramUI, where OpusBinding is more commonly used) because the
// reverse-voice pipeline + its settings-screen composer (LuminaReverseVoice.swift,
// LuminaReverseVoiceController.swift) are also here, and TelegramUI already depends on
// SettingsUI (one-way) - not the other way round - so this is the module both the transcription
// side (TelegramUI/Sources/LuminaVoiceTranscription.swift) and the reverse-voice side can reach.
//
// LuminaGram: shared PCM <-> OGG/Opus helpers used by both voice-to-text (decode a received
// voice note to PCM for Speech framework) and reverse-voice (encode synthesized PCM back to a
// real Telegram voice note). Reuses the SAME native Opus binding the microphone recorder uses
// (see ManagedAudioRecorder.swift) so encoded files are indistinguishable from a real recording,
// and the SAME opusfile-based reader Telegram already ships for other Opus decode paths -
// nothing new is linked in.
//
// Both directions use mono, 16-bit signed PCM at 48 kHz:
//  - Decode: opusfile's op_read always outputs at 48 kHz internally (fixed by the Opus spec),
//    regardless of the stream's original encode rate, so OggOpusReader's output is always
//    48 kHz. Telegram voice notes are always encoded mono; this reader is written assuming a
//    mono source (a stereo Opus file would be misread as interleaved mono - not a real-world
//    case for voice notes).
//  - Encode: TGOggOpusWriter's beginWithDataItem: path hardcodes `rate = 48000` (see
//    OpusBinding/Sources/opusenc/opusenc.m), so writeFrame: must be fed 48 kHz mono PCM16.
public enum LuminaOpusPCM {
    /// Decodes an OGG/Opus file (a Telegram voice note already on disk) to mono PCM16 @ 48kHz.
    /// Returns nil if the file cannot be opened or contains no audio.
    public static func decodeToPCM16Mono48k(path: String) -> [Int16]? {
        guard let reader = OggOpusReader(path: path) else {
            return nil
        }
        var samples: [Int16] = []
        // opusfile recommends buffering at least 120ms @ 48kHz per read call.
        let chunkSamples = 5760
        var buffer = [Int16](repeating: 0, count: chunkSamples)
        while true {
            let readCount: Int32 = buffer.withUnsafeMutableBytes { rawBuf -> Int32 in
                guard let base = rawBuf.baseAddress else {
                    return 0
                }
                return reader.read(base, bufSize: Int32(chunkSamples))
            }
            if readCount <= 0 {
                break
            }
            samples.append(contentsOf: buffer[0 ..< Int(readCount)])
        }
        return samples.isEmpty ? nil : samples
    }

    /// Encodes mono PCM16 @ 48kHz into a Telegram-compatible OGG/Opus voice note, using the
    /// exact same native writer + 60ms packet size ManagedAudioRecorder.swift uses for real
    /// microphone recordings.
    public static func encodeFromPCM16Mono48k(_ samples: [Int16]) -> (data: Data, duration: Double)? {
        guard !samples.isEmpty else {
            return nil
        }
        let writer = TGOggOpusWriter()
        let dataItem = TGDataItem()
        guard writer.begin(with: dataItem) else {
            return nil
        }

        let samplesPerPacket = 48000 / 1000 * 60 // 60ms @ 48kHz = 2880 samples
        var ok = true
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else {
                return
            }
            var offset = 0
            while offset < samples.count {
                let count = min(samplesPerPacket, samples.count - offset)
                let byteCount = count * MemoryLayout<Int16>.size
                let framePtr = UnsafeMutableRawPointer(mutating: base.advanced(by: offset)).assumingMemoryBound(to: UInt8.self)
                if !writer.writeFrame(framePtr, frameByteCount: UInt(byteCount)) {
                    ok = false
                    break
                }
                offset += count
            }
        }
        guard ok, writer.writeFrame(nil, frameByteCount: 0) else {
            return nil
        }
        let duration = writer.encodedDuration()
        return (dataItem.data(), duration)
    }

    /// Linear resample of mono PCM16 from an arbitrary source rate to 48kHz. Good enough for
    /// speech; mirrors the Android LuminaTts.resampleTo48k algorithm.
    public static func resampleMono16(_ input: [Int16], fromRate: Double, toRate: Double = 48000) -> [Int16] {
        guard !input.isEmpty, fromRate > 0, abs(fromRate - toRate) > 0.5 else {
            return input
        }
        let outCount = Int(Double(input.count) * toRate / fromRate)
        guard outCount > 0 else {
            return []
        }
        var out = [Int16](repeating: 0, count: outCount)
        let ratio = fromRate / toRate
        for i in 0 ..< outCount {
            let srcPos = Double(i) * ratio
            let i0 = Int(srcPos)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = srcPos - Double(i0)
            let s0 = Double(input[min(i0, input.count - 1)])
            let s1 = Double(input[i1])
            let v = s0 * (1.0 - frac) + s1 * frac
            out[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), v)))
        }
        return out
    }

    /// Builds the compact 5-bit waveform bitstream Telegram stores on TL_documentAttributeAudio
    /// (`attr.waveform`), from raw mono PCM16 samples. Simplified vs. ManagedAudioRecorder's
    /// streaming version (which has to compress incrementally as the mic feeds it) since here
    /// the whole clip is already in memory: split into 100 buckets, take the peak absolute
    /// amplitude per bucket, normalize to a 5-bit (0-31) range and hand it to AudioWaveform,
    /// which already knows how to pack that into the same bitstream format the app renders.
    public static func computeWaveformBitstream(_ samples: [Int16]) -> Data {
        guard !samples.isEmpty else {
            return Data()
        }
        let bucketCount = 100
        var peaks = [Int16](repeating: 0, count: bucketCount)
        let samplesPerBucket = max(1, samples.count / bucketCount)
        for bucket in 0 ..< bucketCount {
            let start = bucket * samplesPerBucket
            if start >= samples.count {
                break
            }
            let end = (bucket == bucketCount - 1) ? samples.count : min(samples.count, start + samplesPerBucket)
            var maxAbs: Int32 = 0
            for i in start ..< end {
                let s = samples[i]
                let a = (s == Int16.min) ? Int32(Int16.max) : abs(Int32(s))
                if a > maxAbs {
                    maxAbs = a
                }
            }
            peaks[bucket] = Int16(clamping: maxAbs)
        }

        let overallPeak = peaks.max() ?? 0
        let normalizer = max(Int32(overallPeak), 2500) // matches Telegram's own floor, avoids a near-silent clip reading as full-scale noise
        var scaled = [Int16](repeating: 0, count: bucketCount)
        for i in 0 ..< bucketCount {
            let v = min(Int32(31), Int32(peaks[i]) * 31 / normalizer)
            scaled[i] = Int16(clamping: v)
        }

        var samplesData = Data(count: bucketCount * 2)
        samplesData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0 ..< bucketCount {
                dst[i] = scaled[i]
            }
        }

        let resultWaveform = AudioWaveform(samples: samplesData, peak: 31)
        return resultWaveform.makeBitstream()
    }
}
