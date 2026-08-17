import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

// LuminaGram — translation glossary / do-not-translate list (iOS twin of Android's
// LuminaGlossary.java and desktop's lumina_glossary.{h,cpp}).
//
// Some spans of a message must survive translation byte-for-byte: brand names, product
// models, people's names, @usernames and links. A translation engine happily mangles those
// ("iPhone" -> "i手机", "@durov" reflowed, a URL word-split). This masks every such span with
// a placeholder before the text reaches the engine and swaps the originals back into the
// returned translation.
//
// Protected in every message, always: http(s):// links, @username mentions, plus every
// user-defined term from LuminaSettings.glossaryTerms.
//
// Placeholder scheme: each protected span is replaced by ONE Unicode scalar from the Private
// Use Area (U+E000 + index). PUA scalars carry no linguistic meaning, so engines pass them
// through untouched; one scalar per span (rather than a "{12}" marker) makes restore()
// unambiguous — no digit-boundary collisions, no re-encoding to undo. Ported 1:1 from
// Android's LuminaGlossary (same placeholder base, same longest-first term ordering, same
// ASCII word-boundary rule so CJK terms still match as plain substrings).
//
// Everything here is pure local string processing; nothing leaves the device.
public enum LuminaGlossary {
    private static let tokenBase: UInt32 = 0xE000
    // The BMP PUA runs U+E000..U+F8FF, so at most this many spans can be masked in one
    // message. Far beyond any real message; past it masking simply stops (never crashes).
    private static let tokenMax = 0xF8FF - 0xE000

    // Masked text plus the ordered original spans needed by restore(_:protected:).
    public struct Protected {
        public let masked: String
        fileprivate let originals: [String]

        // True when nothing was masked — the caller can send the original text unchanged.
        public var isEmpty: Bool {
            return self.originals.isEmpty
        }
    }

    // URLs first (most specific). ASCII-only character class so the match stops at CJK/space
    // instead of a greedy match swallowing a whole space-less CJK tail.
    private static let urlRegex = try! NSRegularExpression(pattern: "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", options: [.caseInsensitive])
    // @username: not preceded by a word char or another '@', so it never fires inside an
    // e-mail local part (user@host) or a doubled "@@". Telegram handles are [A-Za-z0-9_].
    private static let mentionRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_@])@[A-Za-z0-9_]+", options: [])

    // Replace every protected span (URLs, @usernames, glossary terms) in `text` with a
    // private-use placeholder. Returns the masked text and the restore table. When nothing
    // matches, `masked` equals `text` and Protected.isEmpty is true (a byte-for-byte no-op
    // path for the caller).
    public static func protect(_ text: String, terms: [String]) -> Protected {
        guard !text.isEmpty else {
            return Protected(masked: text, originals: [])
        }
        var originals: [String] = []
        var s = text
        s = self.mask(s, regex: self.urlRegex, originals: &originals)
        s = self.mask(s, regex: self.mentionRegex, originals: &originals)
        if let termsRegex = self.termsPattern(terms: terms) {
            s = self.mask(s, regex: termsRegex, originals: &originals)
        }
        return Protected(masked: s, originals: originals)
    }

    // Put the original spans back into a translated string. Single forward pass over
    // `translated`'s Unicode scalars: any scalar inside the assigned PUA range is swapped
    // for its original span, everything else is copied verbatim.
    public static func restore(_ translated: String, protected: Protected) -> String {
        guard !protected.originals.isEmpty else {
            return translated
        }
        var out = String.UnicodeScalarView()
        for scalar in translated.unicodeScalars {
            let idx = Int(scalar.value) - Int(self.tokenBase)
            if idx >= 0 && idx < protected.originals.count {
                out.append(contentsOf: protected.originals[idx].unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // Wrap a translation engine so it transparently protects/restores the glossary. Single
    // shared hook: LuminaTranslatorRegistry.current(context:) returns an engine already
    // wrapped this way, so every translation path that goes through the registry
    // (translate-before-send, explain-a-message, the provider test button) inherits glossary
    // protection with no per-call-site change.
    public static func wrap(_ engine: LuminaTranslatorEngine, terms: [String]) -> LuminaTranslatorEngine {
        return LuminaGlossaryEngine(delegate: engine, terms: terms)
    }

    // MARK: - internals

    // Replace every match of `regex` in `s` with a fresh placeholder, recording the original.
    private static func mask(_ s: String, regex: NSRegularExpression, originals: inout [String]) -> String {
        if originals.count >= self.tokenMax {
            return s
        }
        let nsString = s as NSString
        let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: nsString.length))
        if matches.isEmpty {
            return s
        }
        var result = ""
        var lastEnd = 0
        for match in matches {
            if originals.count >= self.tokenMax {
                break
            }
            let range = match.range
            if range.location < lastEnd || range.location > nsString.length {
                continue
            }
            result += nsString.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            let matchedText = nsString.substring(with: range)
            guard let token = UnicodeScalar(self.tokenBase + UInt32(originals.count)) else {
                continue
            }
            originals.append(matchedText)
            result += String(token)
            lastEnd = range.location + range.length
        }
        if lastEnd <= nsString.length {
            result += nsString.substring(from: lastEnd)
        }
        return result
    }

    // Combined, longest-first alternation of every user term, or nil when the list is empty.
    // Longest first: in a regex alternation the first matching branch wins, so a longer
    // multi-word term ("Face ID") must precede a shorter one it contains ("Face"). Boundary:
    // the match may not be flanked by an ASCII word char, giving strict whole-word matching
    // for Latin terms ("AI" ignored inside "SPAIN") while still allowing substring matching
    // for CJK terms, whose neighbours are never ASCII word chars.
    private static func termsPattern(terms: [String]) -> NSRegularExpression? {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return nil
        }
        let sorted = cleaned.sorted { $0.count > $1.count }
        let escaped = sorted.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "(?<![A-Za-z0-9_])(?:" + escaped.joined(separator: "|") + ")(?![A-Za-z0-9_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

private struct LuminaGlossaryEngine: LuminaTranslatorEngine {
    let delegate: LuminaTranslatorEngine
    let terms: [String]

    var id: String { self.delegate.id }
    var displayName: String { self.delegate.displayName }
    var needsKey: Bool { self.delegate.needsKey }
    var needsBaseUrl: Bool { self.delegate.needsBaseUrl }
    var needsModel: Bool { self.delegate.needsModel }

    func translate(text: String, toLang: String, peerId: EnginePeer.Id?, context: AccountContext) -> Signal<LuminaTranslationResult, LuminaTranslateError> {
        let protected = LuminaGlossary.protect(text, terms: self.terms)
        if protected.isEmpty {
            // Nothing to protect: exact passthrough, identical to the un-wrapped engine.
            return self.delegate.translate(text: text, toLang: toLang, peerId: peerId, context: context)
        }
        return self.delegate.translate(text: protected.masked, toLang: toLang, peerId: peerId, context: context)
        |> map { result -> LuminaTranslationResult in
            return LuminaTranslationResult(text: LuminaGlossary.restore(result.text, protected: protected), detectedSourceLang: result.detectedSourceLang)
        }
    }
}
