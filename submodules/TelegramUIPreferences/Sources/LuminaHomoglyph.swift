import Foundation

/// LuminaGram homoglyph / look-alike impersonation detector.
///
/// A purely LOCAL, on-device heuristic that flags display names, usernames and link hosts
/// built from characters that merely *look* like Latin letters but are not — the classic
/// trick used to pass a fake account or domain off as a trusted brand or person ("аpple" with
/// a Cyrillic а, "micr0soft", fullwidth "google"). Port of Android's `LuminaHomoglyph.java`
/// (`org.telegram.messenger.LuminaHomoglyph`) onto `Unicode.Scalar`; no third-party library,
/// no network, no upload — see `IOS-PORT-PLAN.md`'s Security & anti-scam section.
///
/// Signals (any one is enough to mark a name/host as suspicious):
///   1. Mixed script inside a single word — Latin letters sitting next to Cyrillic or Greek.
///   2. A known confusable letter (Cyrillic / Greek look-alike of a Latin letter) appearing in
///      a name that also contains ordinary ASCII Latin letters.
///   3. Fullwidth digits / fullwidth Latin letters (U+FF10.., U+FF21..).
///   4. The digits 0 / 1 used *as letters* — sandwiched between letters inside a word
///      (e.g. "micr0soft", "g00gle", "l0l").
///
/// Shared by the profile-row warning (`PeerInfoProfileItems.swift`) and by
/// `LuminaLinkSafety.swift`'s mixed-script-host check, so the two features can never disagree
/// on what "looks Cyrillic-Latin mixed" means.
public enum LuminaHomoglyph {
    private enum Script {
        case other, latin, cyrillic, greek
    }

    /// Confusable table: look-alike Cyrillic / Greek letters that imitate a plain ASCII Latin
    /// letter. Used only for membership tests. A few dozen of the most-abused pairs, ported
    /// from Android's `CONFUSABLES` map (lower + upper case, Cyrillic then Greek).
    private static let confusables: Set<Unicode.Scalar> = Set(
        (
            "аеорсхуіјѕԛԝкһԁ" + "АВЕКМНОРСТУХІЈ" +
            "οαρνυτκειχγ" + "ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ"
        ).unicodeScalars
    )

    /// True when `name` contains at least one visually-deceptive character.
    public static func containsSuspiciousChars(_ name: String) -> Bool {
        return !suspiciousIndices(in: name).isEmpty
    }

    /// Index set (into `Array(name.unicodeScalars)`) of every suspicious character. Empty when
    /// `name` is empty or has nothing suspicious. Shared by `containsSuspiciousChars` and any
    /// future highlight-the-offending-characters UI so the two can never disagree.
    public static func suspiciousIndices(in name: String) -> IndexSet {
        let scalars = Array(name.unicodeScalars)
        let n = scalars.count
        guard n > 0 else {
            return IndexSet()
        }

        // Does the whole string contain any ordinary ASCII Latin letter? Gates the "lone
        // confusable" rule so a legitimately all-Cyrillic or all-Greek name is never flagged —
        // only mixed / disguised-into-Latin names are of interest.
        let hasAsciiLatin = scalars.contains { isAsciiLetter($0) }

        var result = IndexSet()
        var i = 0
        while i < n {
            if !isWordChar(scalars[i]) {
                i += 1
                continue
            }
            let start = i
            var sawLatin = false, sawCyrillic = false, sawGreek = false
            while i < n && isWordChar(scalars[i]) {
                switch script(of: scalars[i]) {
                case .latin: sawLatin = true
                case .cyrillic: sawCyrillic = true
                case .greek: sawGreek = true
                case .other: break
                }
                i += 1
            }
            let end = i
            let distinctScripts = (sawLatin ? 1 : 0) + (sawCyrillic ? 1 : 0) + (sawGreek ? 1 : 0)
            let mixedScript = distinctScripts >= 2

            var k = start
            while k < end {
                let w = scalars[k]
                // (1) Fullwidth digit / fullwidth Latin letter — always deceptive.
                if isFullwidthLookalike(w) {
                    result.insert(k)
                    k += 1
                    continue
                }
                // (2) Mixed-script word: the Cyrillic / Greek letters are the disguise.
                let sc = script(of: w)
                if mixedScript && (sc == .cyrillic || sc == .greek) {
                    result.insert(k)
                    k += 1
                    continue
                }
                // (3) A known confusable letter in a name that also has ASCII Latin.
                if hasAsciiLatin && confusables.contains(w) {
                    result.insert(k)
                    k += 1
                    continue
                }
                // (4) 0 / 1 used as a letter: a real letter both before and after it inside the
                //     same word (catches micr0soft, g00gle, l0l; leaves "user1" alone).
                if isConfusableDigit(w), hasLetter(scalars, from: start, to: k), hasLetter(scalars, from: k + 1, to: end) {
                    result.insert(k)
                }
                k += 1
            }
        }
        return result
    }

    /// Mixed-script check scoped to just Latin/Cyrillic/Greek presence anywhere in `s` (no word
    /// tokenisation) — used by `LuminaLinkSafety` on a URL host, which has no spaces to split on.
    public static func isMixedScriptHost(_ s: String) -> Bool {
        var latin = false, cyrillic = false, greek = false
        for scalar in s.unicodeScalars {
            switch script(of: scalar) {
            case .latin: latin = true
            case .cyrillic: cyrillic = true
            case .greek: greek = true
            case .other: break
            }
        }
        return (latin && cyrillic) || (latin && greek) || (cyrillic && greek)
    }

    // MARK: - internals

    private static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        return CharacterSet.alphanumerics.contains(c) || CharacterSet.nonBaseCharacters.contains(c)
    }

    private static func hasLetter(_ s: [Unicode.Scalar], from: Int, to: Int) -> Bool {
        guard from >= 0, to <= s.count, from < to else {
            return false
        }
        return s[from..<to].contains { CharacterSet.letters.contains($0) }
    }

    private static func isConfusableDigit(_ c: Unicode.Scalar) -> Bool {
        return c == "0" || c == "1"
    }

    private static func isFullwidthLookalike(_ c: Unicode.Scalar) -> Bool {
        return (c.value >= 0xFF10 && c.value <= 0xFF19) // fullwidth 0-9
            || (c.value >= 0xFF21 && c.value <= 0xFF3A) // fullwidth A-Z
            || (c.value >= 0xFF41 && c.value <= 0xFF5A) // fullwidth a-z
    }

    private static func isAsciiLetter(_ c: Unicode.Scalar) -> Bool {
        return (c.value >= 97 && c.value <= 122) || (c.value >= 65 && c.value <= 90)
    }

    private static func script(of c: Unicode.Scalar) -> Script {
        if isAsciiLetter(c) {
            return .latin
        }
        if isFullwidthLookalike(c) {
            return .latin
        }
        switch c.value {
        case 0x0400...0x04FF: // Cyrillic + Cyrillic Supplement neighbourhood
            return .cyrillic
        case 0x0370...0x03FF: // Greek and Coptic
            return .greek
        case 0x00C0...0x024F: // Latin-1 Supplement / Extended-A / Extended-B
            return .latin
        default:
            return .other
        }
    }
}
