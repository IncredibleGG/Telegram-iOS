import Foundation

/// LuminaGram crypto-address paste guard — pattern match only, ported from Android's
/// `LUMINA_CRYPTO_ADDRESS_PATTERN` in `ChatActivityEnterView.java`.
///
/// Clipboard-hijacking malware can silently swap a copied wallet address for a scammer's. When
/// `LuminaSettings.cryptoClipboardGuard` is on, a paste into the composer whose *entire*
/// clipboard text looks like a crypto wallet address is intercepted and the full address is
/// shown for the user to verify before it lands in the message — see the paste hook in
/// `ChatTextInputPanelNode.chatInputTextNodeShouldPaste()`
/// (`submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift`).
public enum LuminaCryptoAddress {
    /// Matches (whole string only, mirrors Android's `^...$` anchoring):
    ///   - `0x` + 40 hex chars (ETH/EVM-compatible chains)
    ///   - Base58Check, leading `1`/`3` + 25-34 chars (BTC legacy/P2SH)
    ///   - `T` + 33 base58 chars (TRON)
    ///   - `bc1` + 25-90 bech32 chars (BTC segwit)
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(0x[a-fA-F0-9]{40}|[13][a-km-zA-HJ-NP-Z1-9]{25,34}|T[a-zA-Z0-9]{33}|bc1[a-z0-9]{25,90})$"
    )

    /// True when `text`, trimmed of surrounding whitespace, is entirely a recognisable wallet
    /// address. A message that merely *contains* an address alongside other prose does not
    /// match — mirrors Android's "whole clipboard text" check, which only fires on a clean
    /// copy-paste of an address by itself.
    public static func isWalletAddress(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, let pattern else {
            return false
        }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return pattern.firstMatch(in: candidate, options: [], range: range) != nil
    }
}
