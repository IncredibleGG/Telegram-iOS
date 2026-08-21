import Foundation
import CryptoKit

// LuminaGram: translation-settings ROAMING (cross-device sync) — crypto + serialization half.
// Serializes the NON-SECRET translation settings into a versioned JSON envelope, AES-256-GCM
// encrypts it with a key derived from a shared app secret + the account id (so two accounts'
// blobs use different keys), and base64-wraps it behind an invisible marker. The encrypted
// carrier is stored as ONE message in the user's own Saved Messages (self chat) by
// LuminaTranslationSyncController (TelegramUI); every logged-in device of the same account
// reads/writes it — the only MTProto primitive all three forks (Android/iOS/desktop) can use
// identically. Two display-layer seams hide the carrier from the user's own UI.
//
// Secrets (provider API keys, chat-lock code) are NEVER included — they live in LuminaKeychain
// and stay device-local. The app secret only OBFUSCATES data the user already fully owns in
// their own cloud; per-account isolation comes from mixing the account id into the key, not the
// secret's secrecy. Same guarantee class as LuminaBackup. Wire format is byte-for-byte the same
// on all platforms: HMAC-SHA256(appSecret, decimal accountId string) -> 32-byte key; AES-256-GCM
// combined = nonce(12)||ciphertext||tag(16).
public enum LuminaTranslationSync {
    // Invisible U+2064 x2 (never in organic text) + a versioned ASCII id. Carrier text =
    // messageMarker + base64(nonce||ciphertext||tag). The UI-hiding seams match this prefix.
    public static let messageMarker = "\u{2064}\u{2064}LG-SYNC1:"

    // 32-byte shared obfuscation secret. MUST be byte-identical to the Android (byte[] in
    // LuminaConfig) and desktop (std::array<uint8_t,32>) copies for cross-device decrypt.
    private static let appSecret = Data([
        0x4c, 0x47, 0x52, 0x6f, 0x61, 0x6d, 0x53, 0x79,
        0x6e, 0x63, 0x31, 0xa7, 0x3e, 0x91, 0xd2, 0x58,
        0x0b, 0xf4, 0x6c, 0x22, 0x9d, 0x71, 0xe8, 0x35,
        0x4a, 0xc9, 0x17, 0x60, 0xbe, 0x83, 0x2f, 0xd1
    ])

    public enum SyncError: Error {
        case notACarrier
        case corrupt
    }

    public struct Payload: Equatable {
        public var ts: Int64
        public var dev: String
        public var body: Body
        public var platform: String
    }

    public struct Body: Codable, Equatable {
        public var trMode: String
        public var trReadLang: String
        public var trSendLang: String
        public var trScopePrivate: Bool
        public var trScopeGroup: Bool
        public var dualLanguageDisplay: Bool
        public var foldOriginalLongMessages: Bool
        public var groupSkipMyLanguages: Bool
        public var myLanguages: [String]
        public var translateBeforeSend: Bool
        public var translateBeforeSendConfirm: Bool
        public var trSendEnabledDialog: [String: Bool]
        public var trSendLangDialog: [String: String]
        public var trRegisterDialog: [String: String]
        public var explainMessage: Bool
        public var glossaryTerms: [String]
        public var translateProvider: String
        public var translateBaseUrl: String
        public var translateModel: String
        public var translatePrompt: String
    }

    private struct Envelope: Codable {
        var v: Int
        var platform: String
        var ts: Int64
        var dev: String
        var settings: Body
    }

    // MARK: Key derivation

    private static func deriveKey(accountId: Int64) -> SymmetricKey {
        let msg = Data(String(accountId).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: self.appSecret))
        return SymmetricKey(data: Data(mac))
    }

    // MARK: Settings <-> wire Body

    public static func makeBody(from settings: LuminaSettings) -> Body {
        var enabled: [String: Bool] = [:]
        for v in settings.trSendEnabledDialog where v.value {
            enabled[String(v.peerId)] = true
        }
        var langs: [String: String] = [:]
        for v in settings.trSendLangDialog where !v.value.isEmpty {
            langs[String(v.peerId)] = v.value
        }
        var registers: [String: String] = [:]
        for v in settings.trRegisterDialog where !v.value.isEmpty {
            registers[String(v.peerId)] = v.value
        }
        // Android's live all-chats value is "all"; iOS's doc-comment "allChats" has no consumer.
        let mode = (settings.trMode == "allChats") ? "all" : settings.trMode
        return Body(
            trMode: mode,
            trReadLang: settings.trReadLang,
            trSendLang: settings.trSendLang,
            trScopePrivate: settings.trScopePrivate,
            trScopeGroup: settings.trScopeGroup,
            dualLanguageDisplay: settings.dualLanguageDisplay,
            foldOriginalLongMessages: settings.foldOriginalLongMessages,
            groupSkipMyLanguages: settings.groupSkipMyLanguages,
            myLanguages: settings.myLanguages,
            translateBeforeSend: settings.translateBeforeSend,
            translateBeforeSendConfirm: settings.translateBeforeSendConfirm,
            trSendEnabledDialog: enabled,
            trSendLangDialog: langs,
            trRegisterDialog: registers,
            explainMessage: settings.explainMessage,
            glossaryTerms: settings.glossaryTerms,
            translateProvider: settings.translateEngine,
            translateBaseUrl: settings.translateBaseUrl,
            translateModel: settings.translateModel,
            translatePrompt: settings.translatePrompt
        )
    }

    public static func apply(_ body: Body, to current: LuminaSettings, platform: String) -> LuminaSettings {
        var s = current
        s.trMode = body.trMode
        s.trReadLang = body.trReadLang
        s.trSendLang = body.trSendLang
        s.trScopePrivate = body.trScopePrivate
        s.trScopeGroup = body.trScopeGroup
        s.dualLanguageDisplay = body.dualLanguageDisplay
        s.foldOriginalLongMessages = body.foldOriginalLongMessages
        s.groupSkipMyLanguages = body.groupSkipMyLanguages
        s.myLanguages = body.myLanguages
        s.translateBeforeSend = body.translateBeforeSend
        s.translateBeforeSendConfirm = body.translateBeforeSendConfirm
        // Per-chat maps roam WITHIN a platform only (peer-id encodings differ across platforms);
        // applying another platform's per-dialog entries would write dead ids AND clobber this
        // device's own. Global settings above still roam everywhere.
        if platform == "ios" {
            s.trSendEnabledDialog = body.trSendEnabledDialog.compactMap { key, value in
                guard let pid = Int64(key) else { return nil }
                return LuminaSettings.DialogBoolValue(peerId: pid, value: value)
            }
            s.trSendLangDialog = body.trSendLangDialog.compactMap { key, value in
                guard let pid = Int64(key) else { return nil }
                return LuminaSettings.DialogTextValue(peerId: pid, value: value)
            }
            s.trRegisterDialog = body.trRegisterDialog.compactMap { key, value in
                guard let pid = Int64(key) else { return nil }
                return LuminaSettings.DialogTextValue(peerId: pid, value: value)
            }
        }
        s.explainMessage = body.explainMessage
        s.glossaryTerms = body.glossaryTerms
        s.translateEngine = body.translateProvider
        s.translateBaseUrl = body.translateBaseUrl
        s.translateModel = body.translateModel
        s.translatePrompt = body.translatePrompt
        return s
    }

    // MARK: Carrier encode/decode

    public static func isCarrier(_ text: String) -> Bool {
        return text.hasPrefix(self.messageMarker)
    }

    public static func encodeCarrier(settings: LuminaSettings, accountId: Int64, dev: String, ts: Int64) throws -> String {
        let envelope = Envelope(v: 1, platform: "ios", ts: ts, dev: dev, settings: self.makeBody(from: settings))
        let json = try JSONEncoder().encode(envelope)
        let key = self.deriveKey(accountId: accountId)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else {
            throw SyncError.corrupt
        }
        return self.messageMarker + combined.base64EncodedString()
    }

    public static func decodeCarrier(text: String, accountId: Int64) throws -> Payload {
        guard text.hasPrefix(self.messageMarker) else {
            throw SyncError.notACarrier
        }
        let b64 = String(text.dropFirst(self.messageMarker.count))
        guard let combined = Data(base64Encoded: b64) else {
            throw SyncError.corrupt
        }
        let key = self.deriveKey(accountId: accountId)
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let json = try AES.GCM.open(sealed, using: key)
            let envelope = try JSONDecoder().decode(Envelope.self, from: json)
            return Payload(ts: envelope.ts, dev: envelope.dev, body: envelope.settings, platform: envelope.platform)
        } catch {
            throw SyncError.corrupt
        }
    }
}
