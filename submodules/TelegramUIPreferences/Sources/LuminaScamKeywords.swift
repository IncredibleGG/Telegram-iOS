import Foundation

/// LuminaGram scam-keyword warning — local incoming-message keyword scan.
///
/// Port of the `LUMINA_SCAM_KEYWORDS` list and matching rule from Android's
/// `ChatActivity.luminaCheckScamKeywordWarning` (`org.telegram.ui.ChatActivity`), gated by
/// `LuminaSettings.scamKeywordWarning`. Pure `String` containment against a bundled +
/// user-editable list (`LuminaSettings.scamKeywords`); no ML, no network.
public enum LuminaScamKeywords {
    /// Ported verbatim from Android's `LUMINA_SCAM_KEYWORDS`. Shown to the user as the
    /// built-in list; `LuminaSettings.scamKeywords` holds any additional user-added phrases.
    public static let defaultKeywords: [String] = [
        "money transfer", "wire transfer", "bank transfer", "western union", "moneygram",
        "send me money", "transfer the money", "gift card", "itunes card", "google play card",
        "steam card", "amazon card", "investment opportunity", "crypto investment",
        "bitcoin investment", "guaranteed profit", "guaranteed return", "double your money",
        "high returns", "trading signal", "mining pool", "verification fee", "processing fee",
        "release fee", "activation fee", "customs fee", "unlock fee", "send the code",
        "send me the code", "verification code", "one-time code", "otp code", "seed phrase",
        "recovery phrase", "private key", "soulmate", "widower", "oil rig", "stranded abroad",
    ]

    /// The first matching keyword (default list + `extraKeywords`) found in `text`, or `nil`.
    /// Case-insensitive plain substring match, exactly like Android's `String.contains` scan —
    /// deliberately not a word-boundary/regex match so short scam phrases like "seed phrase"
    /// are still caught inside a longer sentence.
    public static func matchedKeyword(in text: String, extraKeywords: [String] = []) -> String? {
        guard !text.isEmpty else {
            return nil
        }
        let lower = text.lowercased()
        for keyword in defaultKeywords where lower.contains(keyword) {
            return keyword
        }
        for keyword in extraKeywords {
            let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, lower.contains(normalized) {
                return keyword
            }
        }
        return nil
    }
}
