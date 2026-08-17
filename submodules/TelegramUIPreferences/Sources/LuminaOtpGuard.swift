import Foundation

/// LuminaGram OTP Guard — warn before a Telegram login code leaves the composer.
///
/// The single most damaging step in a Telegram account takeover is the victim typing the
/// 5-6 digit login code into a chat because a scammer posing as "official support" asked
/// for it. Port of Android's `LuminaOtpGuard.java` (`org.telegram.messenger.LuminaOtpGuard`),
/// kept as pure `Foundation` text matching so it needs no `AccountContext` and can be called
/// from anywhere, including unit tests.
///
/// Trigger = both of:
///   1. the outgoing text contains a standalone run of 5-6 digits that survives the
///      false-positive filters below, and
///   2. the Telegram service account (`serviceUserId`) delivered a message to this account
///      within the last `recentWindowSeconds` — i.e. a login code really is in flight.
///
/// Design constraints (deliberate, mirrors Android, do not relax):
///   - Pure local string matching. No ML, no model, no network.
///   - Read-only advisory. Nothing here mutates, blocks or inspects incoming messages; it only
///     lets the composer ask a question before the user's own text is dispatched.
///   - Fail-open by construction: every function here is a total function over its inputs and
///     returns `false`/`nil` for anything ambiguous, so a bug in this file can never itself
///     throw and stop a normal send. Callers should still wrap the call site defensively.
///
/// This file only covers rule (1), the pure text scan. Rule (2) — "did 777000 message us
/// recently" — needs a live `AccountContext` (`TelegramEngine.EngineData.Item.Messages.TopMessage`)
/// that this module does not have; the caller (the send-path hook in
/// `submodules/TelegramUI/Sources/ChatController.swift`, `sendMessages(_:)`) reads that
/// timestamp itself and calls `LuminaOtpGuard.isRecent(serviceMessageTimestamp:now:)` to combine
/// the two.
public enum LuminaOtpGuard {
    /// Telegram's own service account. Login codes are always delivered from this id.
    public static let serviceUserId: Int64 = 777000

    /// A code is only "in flight" for a short while after Telegram sent it.
    public static let recentWindowSeconds: Int32 = 10 * 60

    /// Tolerance for a service message dated slightly ahead of us (clock skew).
    public static let futureSkewSeconds: Int32 = 60

    /// Never scan an unbounded paste; a login code is always near the start anyway.
    private static let maxScanChars = 4096

    /// True when `serviceMessageTimestamp` (the date of the most recent message from
    /// `serviceUserId`) is recent enough that a login code could plausibly still be "in
    /// flight". Pure arithmetic; the caller supplies both timestamps (mirrors Android's
    /// `ConnectionsManager.getCurrentTime()` network-clock read plus dialog last-message-date).
    public static func isRecent(serviceMessageTimestamp: Int32, now: Int32) -> Bool {
        guard serviceMessageTimestamp > 0 else {
            return false
        }
        let age = now - serviceMessageTimestamp
        return age <= recentWindowSeconds && age >= -futureSkewSeconds
    }

    /// True when `text` holds at least one *maximal* run of 5-6 ASCII digits that still looks
    /// like a login code after the false-positive filters below. A run of 4 or of 7+ digits is
    /// never a Telegram code, so years, card numbers and full phone numbers drop out here.
    public static func containsLoginCode(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(maxScanChars))
        let n = scalars.count
        var i = 0
        while i < n {
            if !isAsciiDigit(scalars[i]) {
                i += 1
                continue
            }
            let start = i
            while i < n && isAsciiDigit(scalars[i]) {
                i += 1
            }
            let length = i - start
            if length >= 5 && length <= 6 && looksLikeLoginCode(scalars, start: start, end: i, n: n) {
                return true
            }
        }
        return false
    }

    // MARK: - false-positive filters (ported 1:1 from Android's looksLikeLoginCode)

    /// The rule of thumb is "rather miss a code than nag on every price": every ambiguous
    /// shape below is rejected.
    private static func looksLikeLoginCode(_ s: [Unicode.Scalar], start: Int, end: Int, n: Int) -> Bool {
        let before: Unicode.Scalar = start > 0 ? s[start - 1] : "\0"
        let after: Unicode.Scalar = end < n ? s[end] : "\0"
        let beforeSpaced = previousNonSpace(s, from: start - 1)
        let afterSpaced = nextNonSpace(s, from: end, n: n)

        // Glued to Latin letters/underscore => an identifier, hash, filename or password
        // fragment ("abc123456", "123456th"), not something a user reads out as a code.
        if isAsciiLetter(before) || before == "_" {
            return false
        }
        if isAsciiLetter(after) || after == "_" {
            return false
        }

        // Money ("$12345", "12345元", "45678 元") and percentages.
        if isCurrencyPrefix(beforeSpaced) || isCurrencySuffix(afterSpaced) || afterSpaced == "%" {
            return false
        }

        // Part of a longer structured number: a separator with digits on the far side means
        // decimal / thousands group / phone group / date / version / order id.
        if isNumberSeparator(before), start - 2 >= 0, isAsciiDigit(s[start - 2]) {
            return false
        }
        if isNumberSeparator(after), end + 1 < n, isAsciiDigit(s[end + 1]) {
            return false
        }
        if before == " ", isAsciiDigit(beforeSpaced) {
            return false
        }
        if after == " ", isAsciiDigit(afterSpaced) {
            return false
        }

        // Inside a URL, path, query string, e-mail or file name.
        return !insideUrlLikeToken(s, start: start, end: end, n: n)
    }

    /// True when the run sits inside a token that looks like a URL / path / e-mail / filename.
    /// Token boundaries are whitespace *and* CJK (U+2E80 and above), so a Chinese sentence
    /// written without spaces still isolates the digits instead of swallowing the whole message.
    private static func insideUrlLikeToken(_ s: [Unicode.Scalar], start: Int, end: Int, n: Int) -> Bool {
        var tokenStart = start
        while tokenStart > 0 && !isTokenBreak(s[tokenStart - 1]) {
            tokenStart -= 1
        }
        var tokenEnd = end
        while tokenEnd < n && !isTokenBreak(s[tokenEnd]) {
            tokenEnd += 1
        }
        var i = tokenStart
        while i < tokenEnd {
            let c = s[i]
            if c == "/" || c == "\\" || c == "@" || c == "?" || c == "&" || c == "=" || c == "%" || c == "#" {
                return true
            }
            // "example.com", "photo.jpg", "v1.2" — a dot glued to a Latin letter.
            if c == ".", i + 1 < tokenEnd, isAsciiLetter(s[i + 1]) {
                return true
            }
            i += 1
        }
        return false
    }

    private static func previousNonSpace(_ s: [Unicode.Scalar], from: Int) -> Unicode.Scalar {
        var i = from
        while i >= 0 && s[i] == " " {
            i -= 1
        }
        return i >= 0 ? s[i] : "\0"
    }

    private static func nextNonSpace(_ s: [Unicode.Scalar], from: Int, n: Int) -> Unicode.Scalar {
        var i = from
        while i < n && s[i] == " " {
            i += 1
        }
        return i < n ? s[i] : "\0"
    }

    private static func isTokenBreak(_ c: Unicode.Scalar) -> Bool {
        return CharacterSet.whitespacesAndNewlines.contains(c) || c.value >= 0x2E80
    }

    private static func isAsciiDigit(_ c: Unicode.Scalar) -> Bool {
        return c.value >= 48 && c.value <= 57 // '0'...'9'
    }

    private static func isAsciiLetter(_ c: Unicode.Scalar) -> Bool {
        return (c.value >= 97 && c.value <= 122) || (c.value >= 65 && c.value <= 90) // a-z, A-Z
    }

    private static func isNumberSeparator(_ c: Unicode.Scalar) -> Bool {
        return c == "." || c == "," || c == "-" || c == "/" || c == "+" || c == ":" || c == "'"
    }

    /// Symbols that, glued in front of a number, make it an amount of money.
    private static let currencyPrefixes: Set<Unicode.Scalar> = Set("$＄¥￥€£￡₹₽₩￦฿₫₴".unicodeScalars)
    /// Characters that, glued after a number, make it an amount of money or a count.
    private static let currencySuffixes: Set<Unicode.Scalar> = Set("元塊块圓円币幣원$¥€".unicodeScalars)

    private static func isCurrencyPrefix(_ c: Unicode.Scalar) -> Bool {
        return c != "\0" && currencyPrefixes.contains(c)
    }

    private static func isCurrencySuffix(_ c: Unicode.Scalar) -> Bool {
        return c != "\0" && currencySuffixes.contains(c)
    }
}
