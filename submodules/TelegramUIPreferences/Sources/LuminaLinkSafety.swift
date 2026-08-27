import Foundation

/// LuminaGram link-safety inspector — local URL analysis before opening.
///
/// Port of Android's link-safety block in `org.telegram.messenger.browser.Browser.openUrl`
/// (gated by `linkSafetyCheck`). Entirely heuristic and offline: no network lookup, no
/// reputation service. When a link is about to open, the caller (the choke point is
/// `ChatController.openUrl` in `submodules/TelegramUI/Sources/ChatController.swift`) shows a
/// confirmation sheet listing the full resolved URL plus any of the warnings below.
public enum LuminaLinkSafety {
    /// Common URL shorteners (registrable host, lower-case, no "www."). Ported from Android's
    /// `LUMINA_URL_SHORTENERS`.
    public static let urlShorteners: Set<String> = [
        "bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "buff.ly",
        "bit.do", "cutt.ly", "rebrand.ly", "rb.gy", "shorturl.at", "tiny.cc",
        "t.ly", "s.id", "v.gd", "clck.ru", "vk.cc", "adf.ly", "shorte.st",
        "lnkd.in", "db.tt", "qr.ae", "u.to", "x.co", "trib.al", "shrtco.de",
    ]

    public enum Warning {
        /// The address hides its real destination behind userinfo, e.g.
        /// `https://paypal.com@evil.example`.
        case userinfoMismatch
        /// The host is punycode / IDN ("xn--").
        case punycode
        /// The host mixes letters from more than one alphabet (Latin + Cyrillic/Greek) — a
        /// classic look-alike / homograph domain.
        case mixedScript
        /// The host is a known URL shortener that hides the real destination.
        case shortener

        /// Hardcoded English, deliberately — see the note in `LuminaGramSettingsController.swift`
        /// about why LuminaGram's own UI text does not route through `PresentationStrings`.
        public var text: String {
            switch self {
            case .userinfoMismatch:
                return LuminaL10n.tr("This link hides its real destination before the \"@\".")
            case .punycode:
                return LuminaL10n.tr("This address uses look-alike international characters (punycode).")
            case .mixedScript:
                return LuminaL10n.tr("This address mixes letters from different alphabets — a common trick to impersonate a trusted site.")
            case .shortener:
                return LuminaL10n.tr("This is a shortened link — its real destination is hidden until you open it.")
            }
        }
    }

    /// Only external http/https web links are worth a safety sheet; `tg://` and other internal
    /// schemes are untouched, and an already-approved URL (the user just tapped "Open" on the
    /// exact same string) is not asked about twice. `isInternalUri` is supplied by the caller —
    /// on iOS that is whatever `ChatController.openUrl`/`openResolved` already knows about
    /// Telegram deep links, so this file stays free of any URL-scheme catalogue of its own.
    public static func shouldConfirm(url: URL, isInternalUri: Bool, alreadyApproved: String?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if isInternalUri {
            return false
        }
        if let alreadyApproved, alreadyApproved == url.absoluteString {
            return false
        }
        return true
    }

    /// The warnings that apply to `url`. Empty when nothing suspicious was found — the caller
    /// still shows the full URL sheet in that case (Android always does, see
    /// `luminaShowLinkSafetySheet`), just with no `⚠` lines.
    public static func warnings(for url: URL) -> [Warning] {
        var warnings: [Warning] = []

        if let user = url.user, !user.isEmpty {
            warnings.append(.userinfoMismatch)
        }

        if let host = url.host?.lowercased() {
            let ascii = punycodeEncodedHost(host) ?? host
            // (c1) punycode / IDN label present (either as literal xn-- or after encoding).
            if host.contains("xn--") || ascii.contains("xn--") {
                warnings.append(.punycode)
            }
            // (c2) mixed-script look-alike.
            if LuminaHomoglyph.isMixedScriptHost(host) {
                warnings.append(.mixedScript)
            }
            // (d) known URL shorteners.
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if urlShorteners.contains(bare) {
                warnings.append(.shortener)
            }
        }

        return warnings
    }

    /// Best-effort Punycode/IDNA encoding of `host`, mirroring Android's `IDN.toASCII`. iOS has
    /// no direct `IDN` equivalent in Foundation, so this goes through `URLComponents`/
    /// `URL(string:)`'s own IDNA handling by round-tripping the host through a scheme-qualified
    /// URL. Returns `nil` (never throws) on anything that fails to round-trip — the plain-host
    /// "xn--" substring check above still catches the common case even if this returns `nil`.
    private static func punycodeEncodedHost(_ host: String) -> String? {
        guard let url = URL(string: "https://\(host)") else {
            return nil
        }
        return url.host
    }
}
