import Foundation
import TelegramCore
import SwiftSignalKit

// LuminaGram's own preferences store - the iOS twin of Android's LuminaConfig and
// desktop's Lumina::Settings. Everything in here is LuminaGram-specific, lives only in
// this app's local SharedData (ApplicationSpecificSharedDataKeys.luminaSettings, see
// PostboxKeys.swift), and is never part of a Telegram cloud sync: it follows the exact
// storage pattern Telegram-iOS itself uses for its own local-only preferences (compare
// TranslationSettings.swift and ExperimentalUISettings.swift in this same module) - a
// Codable struct written through updateSharedData via updateLuminaSettingsInteractively
// below, and read back with `sharedData.entries[...]?.get(LuminaSettings.self)`.
//
// Secrets do NOT belong here. Translation-provider API keys and the chat-lock code go
// through LuminaKeychain.swift instead (Keychain, kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
// so a LuminaSettings export/backup or a stray log of this struct can never leak them.
//
// Field names mirror the roadmap's key names (IOS-PORT-PLAN.md) and, where the same
// feature exists on Android/desktop, their key names too - trMode, trReadLang, trSendLang,
// dualLanguageDisplay, foldOriginalLongMessages, otpGuardEnabled, homoglyphWarn,
// stripPhotoMetadata, stickerScale, etc. - so a value can be compared across platforms
// without re-deriving what it means. This commit only adds the storage: every field is
// read/written by nothing yet. The feature waves that land on top of this wire the actual
// behavior.
//
// Dictionaries keyed by peer/dialog id are deliberately NOT stored as Swift Dictionary
// fields: WatchPresetSettings.swift in this module has already hit that a directly-encoded
// Dictionary does not round-trip through this preferences pipeline, and works around it by
// storing two parallel arrays instead. To avoid the same trap, every per-dialog map here is
// an array of a tiny Codable(peerId, value) struct, which is exactly how
// ExperimentalUISettings.AccountReactionOverrides already stores its per-account data in
// this module - a proven-safe shape, not a new one.
public struct LuminaSettings: Codable, Equatable {
    public struct DialogBoolValue: Equatable, Codable {
        public var peerId: Int64
        public var value: Bool

        public init(peerId: Int64, value: Bool) {
            self.peerId = peerId
            self.value = value
        }
    }

    public struct DialogTextValue: Equatable, Codable {
        public var peerId: Int64
        public var value: String

        public init(peerId: Int64, value: String) {
            self.peerId = peerId
            self.value = value
        }
    }

    public struct ContactNote: Equatable, Codable {
        public var peerId: Int64
        public var note: String
        public var tags: [String]

        public init(peerId: Int64, note: String, tags: [String]) {
            self.peerId = peerId
            self.note = note
            self.tags = tags
        }
    }

    public struct Bookmark: Equatable, Codable {
        public var peerId: Int64
        public var messageId: Int32
        public var messageNamespace: Int32
        public var snippet: String
        public var timestamp: Int32

        public init(peerId: Int64, messageId: Int32, messageNamespace: Int32, snippet: String, timestamp: Int32) {
            self.peerId = peerId
            self.messageId = messageId
            self.messageNamespace = messageNamespace
            self.snippet = snippet
            self.timestamp = timestamp
        }
    }

    public struct QuickReplyTemplate: Equatable, Codable {
        public var id: String
        public var title: String
        public var text: String

        public init(id: String, title: String, text: String) {
            self.id = id
            self.title = title
            self.text = text
        }
    }

    // MARK: Translation & AI

    // "manual" (translate chats one at a time via the per-chat toggle) or "allChats"
    // (translate everywhere trScopePrivate/trScopeGroup allow). Governs #1/#2/#6 in the
    // roadmap's Translation & AI section.
    public var trMode: String
    // Empty means "follow the interface language". Feeds dual-language display and the
    // group-skip-my-languages filter.
    public var trReadLang: String
    // "auto" means "the recipient's language", resolved per chat.
    public var trSendLang: String
    public var trScopePrivate: Bool
    public var trScopeGroup: Bool
    public var dualLanguageDisplay: Bool
    public var foldOriginalLongMessages: Bool
    public var groupSkipMyLanguages: Bool
    public var myLanguages: [String]
    // Global capability gate. Per-dialog outgoing translation itself is
    // trSendEnabledDialog; this only makes the feature available at all.
    public var translateBeforeSend: Bool
    public var translateBeforeSendConfirm: Bool
    public var trSendEnabledDialog: [DialogBoolValue]
    public var trSendLangDialog: [DialogTextValue]
    // Per-dialog tone/register preset code (Android LuminaRegister: none/client/colleague/
    // friend/family/elder/flirting/custom:<text>). Only consumed by the LLM engine.
    public var trRegisterDialog: [DialogTextValue]
    public var explainMessage: Bool
    // @usernames and links are always protected by the translate pipeline in addition to
    // this list; that behavior is not a setting.
    public var glossaryTerms: [String]
    // "google" (keyless web endpoint, Telegram-iOS's existing default), "deepl", "llm"
    // (OpenAI-compatible), or "telegram" (reuse MTProto). API keys for deepl/llm live in
    // LuminaKeychain, keyed per provider id - never here.
    public var translateEngine: String
    public var translateBaseUrl: String
    public var translateModel: String
    public var translatePrompt: String

    // MARK: Voice & Media

    public var sttAutoPipeline: Bool
    public var autoTranslateTranscript: Bool
    public var reverseVoice: Bool
    public var ocrTranslate: Bool
    public var keepOriginalFilename: Bool
    public var autoPauseBackgroundVideo: Bool
    // iOS has no folder-rename equivalent (Photos has no filesystem folders); this instead
    // gates saving into a "LuminaGram" PHAssetCollection album alongside the camera roll.
    public var saveMediaToLuminaAlbum: Bool

    // MARK: Security & anti-scam

    public var otpGuardEnabled: Bool
    public var sessionGuardEnabled: Bool
    // Baseline authorization hashes (TelegramEngine requestRecentAccounts) the session
    // guard diffs against on foreground/launch. iOS has no persistent background socket,
    // so this is polled, not pushed - see the roadmap's Security & anti-scam section.
    public var sessionGuardKnownHashes: [Int64]
    public var cryptoClipboardGuard: Bool
    public var linkSafetyCheck: Bool
    public var scamKeywordWarning: Bool
    public var scamKeywords: [String]
    public var homoglyphWarn: Bool
    public var fileGuardEnabled: Bool

    // MARK: Privacy & disguise

    public var hideOwnPhone: Bool
    public var stripPhotoMetadata: Bool
    public var showRegistrationDate: Bool
    // Dialog ids hidden from the chat list until unlocked. The unlock gate itself is
    // LocalAuthentication (Face ID/passcode), not a stored code - see LuminaKeychain.swift
    // for chatLockCode, used only as a LocalAuthentication fallback.
    public var lockedChats: [Int64]

    // MARK: Utility & interface

    public var showBookmarks: Bool
    public var bookmarks: [Bookmark]
    public var quickReplyTemplates: [QuickReplyTemplate]
    public var contactNotes: [ContactNote]
    public var storiesFullyOff: Bool
    public var storiesHidePostEntry: Bool
    public var unreadDigest: Bool
    public var disableNumberRounding: Bool
    // Percent: 75/100/125, matching Android's KEY_STICKER_SCALE.
    public var stickerScale: Int32
    public var timeWithSeconds: Bool
    public var hideInputAiButton: Bool

    public static var defaultSettings: LuminaSettings {
        return LuminaSettings(
            trMode: "manual",
            trReadLang: "",
            trSendLang: "auto",
            trScopePrivate: true,
            trScopeGroup: true,
            dualLanguageDisplay: false,
            foldOriginalLongMessages: true,
            groupSkipMyLanguages: true,
            myLanguages: [],
            translateBeforeSend: false,
            translateBeforeSendConfirm: true,
            trSendEnabledDialog: [],
            trSendLangDialog: [],
            trRegisterDialog: [],
            explainMessage: true,
            glossaryTerms: [],
            translateEngine: "google",
            translateBaseUrl: "",
            translateModel: "",
            translatePrompt: "",
            sttAutoPipeline: false,
            autoTranslateTranscript: true,
            reverseVoice: false,
            ocrTranslate: true,
            keepOriginalFilename: false,
            autoPauseBackgroundVideo: true,
            saveMediaToLuminaAlbum: false,
            otpGuardEnabled: true,
            sessionGuardEnabled: true,
            sessionGuardKnownHashes: [],
            cryptoClipboardGuard: true,
            linkSafetyCheck: true,
            scamKeywordWarning: true,
            scamKeywords: [],
            homoglyphWarn: true,
            fileGuardEnabled: true,
            hideOwnPhone: false,
            stripPhotoMetadata: true,
            showRegistrationDate: true,
            lockedChats: [],
            showBookmarks: true,
            bookmarks: [],
            quickReplyTemplates: [],
            contactNotes: [],
            storiesFullyOff: false,
            storiesHidePostEntry: false,
            unreadDigest: true,
            disableNumberRounding: false,
            stickerScale: 100,
            timeWithSeconds: false,
            hideInputAiButton: false
        )
    }

    public init(
        trMode: String,
        trReadLang: String,
        trSendLang: String,
        trScopePrivate: Bool,
        trScopeGroup: Bool,
        dualLanguageDisplay: Bool,
        foldOriginalLongMessages: Bool,
        groupSkipMyLanguages: Bool,
        myLanguages: [String],
        translateBeforeSend: Bool,
        translateBeforeSendConfirm: Bool,
        trSendEnabledDialog: [DialogBoolValue],
        trSendLangDialog: [DialogTextValue],
        trRegisterDialog: [DialogTextValue],
        explainMessage: Bool,
        glossaryTerms: [String],
        translateEngine: String,
        translateBaseUrl: String,
        translateModel: String,
        translatePrompt: String,
        sttAutoPipeline: Bool,
        autoTranslateTranscript: Bool,
        reverseVoice: Bool,
        ocrTranslate: Bool,
        keepOriginalFilename: Bool,
        autoPauseBackgroundVideo: Bool,
        saveMediaToLuminaAlbum: Bool,
        otpGuardEnabled: Bool,
        sessionGuardEnabled: Bool,
        sessionGuardKnownHashes: [Int64],
        cryptoClipboardGuard: Bool,
        linkSafetyCheck: Bool,
        scamKeywordWarning: Bool,
        scamKeywords: [String],
        homoglyphWarn: Bool,
        fileGuardEnabled: Bool,
        hideOwnPhone: Bool,
        stripPhotoMetadata: Bool,
        showRegistrationDate: Bool,
        lockedChats: [Int64],
        showBookmarks: Bool,
        bookmarks: [Bookmark],
        quickReplyTemplates: [QuickReplyTemplate],
        contactNotes: [ContactNote],
        storiesFullyOff: Bool,
        storiesHidePostEntry: Bool,
        unreadDigest: Bool,
        disableNumberRounding: Bool,
        stickerScale: Int32,
        timeWithSeconds: Bool,
        hideInputAiButton: Bool
    ) {
        self.trMode = trMode
        self.trReadLang = trReadLang
        self.trSendLang = trSendLang
        self.trScopePrivate = trScopePrivate
        self.trScopeGroup = trScopeGroup
        self.dualLanguageDisplay = dualLanguageDisplay
        self.foldOriginalLongMessages = foldOriginalLongMessages
        self.groupSkipMyLanguages = groupSkipMyLanguages
        self.myLanguages = myLanguages
        self.translateBeforeSend = translateBeforeSend
        self.translateBeforeSendConfirm = translateBeforeSendConfirm
        self.trSendEnabledDialog = trSendEnabledDialog
        self.trSendLangDialog = trSendLangDialog
        self.trRegisterDialog = trRegisterDialog
        self.explainMessage = explainMessage
        self.glossaryTerms = glossaryTerms
        self.translateEngine = translateEngine
        self.translateBaseUrl = translateBaseUrl
        self.translateModel = translateModel
        self.translatePrompt = translatePrompt
        self.sttAutoPipeline = sttAutoPipeline
        self.autoTranslateTranscript = autoTranslateTranscript
        self.reverseVoice = reverseVoice
        self.ocrTranslate = ocrTranslate
        self.keepOriginalFilename = keepOriginalFilename
        self.autoPauseBackgroundVideo = autoPauseBackgroundVideo
        self.saveMediaToLuminaAlbum = saveMediaToLuminaAlbum
        self.otpGuardEnabled = otpGuardEnabled
        self.sessionGuardEnabled = sessionGuardEnabled
        self.sessionGuardKnownHashes = sessionGuardKnownHashes
        self.cryptoClipboardGuard = cryptoClipboardGuard
        self.linkSafetyCheck = linkSafetyCheck
        self.scamKeywordWarning = scamKeywordWarning
        self.scamKeywords = scamKeywords
        self.homoglyphWarn = homoglyphWarn
        self.fileGuardEnabled = fileGuardEnabled
        self.hideOwnPhone = hideOwnPhone
        self.stripPhotoMetadata = stripPhotoMetadata
        self.showRegistrationDate = showRegistrationDate
        self.lockedChats = lockedChats
        self.showBookmarks = showBookmarks
        self.bookmarks = bookmarks
        self.quickReplyTemplates = quickReplyTemplates
        self.contactNotes = contactNotes
        self.storiesFullyOff = storiesFullyOff
        self.storiesHidePostEntry = storiesHidePostEntry
        self.unreadDigest = unreadDigest
        self.disableNumberRounding = disableNumberRounding
        self.stickerScale = stickerScale
        self.timeWithSeconds = timeWithSeconds
        self.hideInputAiButton = hideInputAiButton
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let defaults = LuminaSettings.defaultSettings

        self.trMode = try container.decodeIfPresent(String.self, forKey: "trMode") ?? defaults.trMode
        self.trReadLang = try container.decodeIfPresent(String.self, forKey: "trReadLang") ?? defaults.trReadLang
        self.trSendLang = try container.decodeIfPresent(String.self, forKey: "trSendLang") ?? defaults.trSendLang
        self.trScopePrivate = try container.decodeIfPresent(Bool.self, forKey: "trScopePrivate") ?? defaults.trScopePrivate
        self.trScopeGroup = try container.decodeIfPresent(Bool.self, forKey: "trScopeGroup") ?? defaults.trScopeGroup
        self.dualLanguageDisplay = try container.decodeIfPresent(Bool.self, forKey: "dualLanguageDisplay") ?? defaults.dualLanguageDisplay
        self.foldOriginalLongMessages = try container.decodeIfPresent(Bool.self, forKey: "foldOriginalLongMessages") ?? defaults.foldOriginalLongMessages
        self.groupSkipMyLanguages = try container.decodeIfPresent(Bool.self, forKey: "groupSkipMyLanguages") ?? defaults.groupSkipMyLanguages
        self.myLanguages = try container.decodeIfPresent([String].self, forKey: "myLanguages") ?? defaults.myLanguages
        self.translateBeforeSend = try container.decodeIfPresent(Bool.self, forKey: "translateBeforeSend") ?? defaults.translateBeforeSend
        self.translateBeforeSendConfirm = try container.decodeIfPresent(Bool.self, forKey: "translateBeforeSendConfirm") ?? defaults.translateBeforeSendConfirm
        self.trSendEnabledDialog = try container.decodeIfPresent([DialogBoolValue].self, forKey: "trSendEnabledDialog") ?? defaults.trSendEnabledDialog
        self.trSendLangDialog = try container.decodeIfPresent([DialogTextValue].self, forKey: "trSendLangDialog") ?? defaults.trSendLangDialog
        self.trRegisterDialog = try container.decodeIfPresent([DialogTextValue].self, forKey: "trRegisterDialog") ?? defaults.trRegisterDialog
        self.explainMessage = try container.decodeIfPresent(Bool.self, forKey: "explainMessage") ?? defaults.explainMessage
        self.glossaryTerms = try container.decodeIfPresent([String].self, forKey: "glossaryTerms") ?? defaults.glossaryTerms
        self.translateEngine = try container.decodeIfPresent(String.self, forKey: "translateEngine") ?? defaults.translateEngine
        self.translateBaseUrl = try container.decodeIfPresent(String.self, forKey: "translateBaseUrl") ?? defaults.translateBaseUrl
        self.translateModel = try container.decodeIfPresent(String.self, forKey: "translateModel") ?? defaults.translateModel
        self.translatePrompt = try container.decodeIfPresent(String.self, forKey: "translatePrompt") ?? defaults.translatePrompt

        self.sttAutoPipeline = try container.decodeIfPresent(Bool.self, forKey: "sttAutoPipeline") ?? defaults.sttAutoPipeline
        self.autoTranslateTranscript = try container.decodeIfPresent(Bool.self, forKey: "autoTranslateTranscript") ?? defaults.autoTranslateTranscript
        self.reverseVoice = try container.decodeIfPresent(Bool.self, forKey: "reverseVoice") ?? defaults.reverseVoice
        self.ocrTranslate = try container.decodeIfPresent(Bool.self, forKey: "ocrTranslate") ?? defaults.ocrTranslate
        self.keepOriginalFilename = try container.decodeIfPresent(Bool.self, forKey: "keepOriginalFilename") ?? defaults.keepOriginalFilename
        self.autoPauseBackgroundVideo = try container.decodeIfPresent(Bool.self, forKey: "autoPauseBackgroundVideo") ?? defaults.autoPauseBackgroundVideo
        self.saveMediaToLuminaAlbum = try container.decodeIfPresent(Bool.self, forKey: "saveMediaToLuminaAlbum") ?? defaults.saveMediaToLuminaAlbum

        self.otpGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: "otpGuardEnabled") ?? defaults.otpGuardEnabled
        self.sessionGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: "sessionGuardEnabled") ?? defaults.sessionGuardEnabled
        self.sessionGuardKnownHashes = try container.decodeIfPresent([Int64].self, forKey: "sessionGuardKnownHashes") ?? defaults.sessionGuardKnownHashes
        self.cryptoClipboardGuard = try container.decodeIfPresent(Bool.self, forKey: "cryptoClipboardGuard") ?? defaults.cryptoClipboardGuard
        self.linkSafetyCheck = try container.decodeIfPresent(Bool.self, forKey: "linkSafetyCheck") ?? defaults.linkSafetyCheck
        self.scamKeywordWarning = try container.decodeIfPresent(Bool.self, forKey: "scamKeywordWarning") ?? defaults.scamKeywordWarning
        self.scamKeywords = try container.decodeIfPresent([String].self, forKey: "scamKeywords") ?? defaults.scamKeywords
        self.homoglyphWarn = try container.decodeIfPresent(Bool.self, forKey: "homoglyphWarn") ?? defaults.homoglyphWarn
        self.fileGuardEnabled = try container.decodeIfPresent(Bool.self, forKey: "fileGuardEnabled") ?? defaults.fileGuardEnabled

        self.hideOwnPhone = try container.decodeIfPresent(Bool.self, forKey: "hideOwnPhone") ?? defaults.hideOwnPhone
        self.stripPhotoMetadata = try container.decodeIfPresent(Bool.self, forKey: "stripPhotoMetadata") ?? defaults.stripPhotoMetadata
        self.showRegistrationDate = try container.decodeIfPresent(Bool.self, forKey: "showRegistrationDate") ?? defaults.showRegistrationDate
        self.lockedChats = try container.decodeIfPresent([Int64].self, forKey: "lockedChats") ?? defaults.lockedChats

        self.showBookmarks = try container.decodeIfPresent(Bool.self, forKey: "showBookmarks") ?? defaults.showBookmarks
        self.bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: "bookmarks") ?? defaults.bookmarks
        self.quickReplyTemplates = try container.decodeIfPresent([QuickReplyTemplate].self, forKey: "quickReplyTemplates") ?? defaults.quickReplyTemplates
        self.contactNotes = try container.decodeIfPresent([ContactNote].self, forKey: "contactNotes") ?? defaults.contactNotes
        self.storiesFullyOff = try container.decodeIfPresent(Bool.self, forKey: "storiesFullyOff") ?? defaults.storiesFullyOff
        self.storiesHidePostEntry = try container.decodeIfPresent(Bool.self, forKey: "storiesHidePostEntry") ?? defaults.storiesHidePostEntry
        self.unreadDigest = try container.decodeIfPresent(Bool.self, forKey: "unreadDigest") ?? defaults.unreadDigest
        self.disableNumberRounding = try container.decodeIfPresent(Bool.self, forKey: "disableNumberRounding") ?? defaults.disableNumberRounding
        self.stickerScale = try container.decodeIfPresent(Int32.self, forKey: "stickerScale") ?? defaults.stickerScale
        self.timeWithSeconds = try container.decodeIfPresent(Bool.self, forKey: "timeWithSeconds") ?? defaults.timeWithSeconds
        self.hideInputAiButton = try container.decodeIfPresent(Bool.self, forKey: "hideInputAiButton") ?? defaults.hideInputAiButton
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.trMode, forKey: "trMode")
        try container.encode(self.trReadLang, forKey: "trReadLang")
        try container.encode(self.trSendLang, forKey: "trSendLang")
        try container.encode(self.trScopePrivate, forKey: "trScopePrivate")
        try container.encode(self.trScopeGroup, forKey: "trScopeGroup")
        try container.encode(self.dualLanguageDisplay, forKey: "dualLanguageDisplay")
        try container.encode(self.foldOriginalLongMessages, forKey: "foldOriginalLongMessages")
        try container.encode(self.groupSkipMyLanguages, forKey: "groupSkipMyLanguages")
        try container.encode(self.myLanguages, forKey: "myLanguages")
        try container.encode(self.translateBeforeSend, forKey: "translateBeforeSend")
        try container.encode(self.translateBeforeSendConfirm, forKey: "translateBeforeSendConfirm")
        try container.encode(self.trSendEnabledDialog, forKey: "trSendEnabledDialog")
        try container.encode(self.trSendLangDialog, forKey: "trSendLangDialog")
        try container.encode(self.trRegisterDialog, forKey: "trRegisterDialog")
        try container.encode(self.explainMessage, forKey: "explainMessage")
        try container.encode(self.glossaryTerms, forKey: "glossaryTerms")
        try container.encode(self.translateEngine, forKey: "translateEngine")
        try container.encode(self.translateBaseUrl, forKey: "translateBaseUrl")
        try container.encode(self.translateModel, forKey: "translateModel")
        try container.encode(self.translatePrompt, forKey: "translatePrompt")

        try container.encode(self.sttAutoPipeline, forKey: "sttAutoPipeline")
        try container.encode(self.autoTranslateTranscript, forKey: "autoTranslateTranscript")
        try container.encode(self.reverseVoice, forKey: "reverseVoice")
        try container.encode(self.ocrTranslate, forKey: "ocrTranslate")
        try container.encode(self.keepOriginalFilename, forKey: "keepOriginalFilename")
        try container.encode(self.autoPauseBackgroundVideo, forKey: "autoPauseBackgroundVideo")
        try container.encode(self.saveMediaToLuminaAlbum, forKey: "saveMediaToLuminaAlbum")

        try container.encode(self.otpGuardEnabled, forKey: "otpGuardEnabled")
        try container.encode(self.sessionGuardEnabled, forKey: "sessionGuardEnabled")
        try container.encode(self.sessionGuardKnownHashes, forKey: "sessionGuardKnownHashes")
        try container.encode(self.cryptoClipboardGuard, forKey: "cryptoClipboardGuard")
        try container.encode(self.linkSafetyCheck, forKey: "linkSafetyCheck")
        try container.encode(self.scamKeywordWarning, forKey: "scamKeywordWarning")
        try container.encode(self.scamKeywords, forKey: "scamKeywords")
        try container.encode(self.homoglyphWarn, forKey: "homoglyphWarn")
        try container.encode(self.fileGuardEnabled, forKey: "fileGuardEnabled")

        try container.encode(self.hideOwnPhone, forKey: "hideOwnPhone")
        try container.encode(self.stripPhotoMetadata, forKey: "stripPhotoMetadata")
        try container.encode(self.showRegistrationDate, forKey: "showRegistrationDate")
        try container.encode(self.lockedChats, forKey: "lockedChats")

        try container.encode(self.showBookmarks, forKey: "showBookmarks")
        try container.encode(self.bookmarks, forKey: "bookmarks")
        try container.encode(self.quickReplyTemplates, forKey: "quickReplyTemplates")
        try container.encode(self.contactNotes, forKey: "contactNotes")
        try container.encode(self.storiesFullyOff, forKey: "storiesFullyOff")
        try container.encode(self.storiesHidePostEntry, forKey: "storiesHidePostEntry")
        try container.encode(self.unreadDigest, forKey: "unreadDigest")
        try container.encode(self.disableNumberRounding, forKey: "disableNumberRounding")
        try container.encode(self.stickerScale, forKey: "stickerScale")
        try container.encode(self.timeWithSeconds, forKey: "timeWithSeconds")
        try container.encode(self.hideInputAiButton, forKey: "hideInputAiButton")
    }
}

// Same shape as updateTranslationSettingsInteractively / updateExperimentalUISettingsInteractively
// in this module: read-modify-write against SharedData, main-thread-safe via the account
// manager transaction queue.
public func updateLuminaSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (LuminaSettings) -> LuminaSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.luminaSettings, { entry in
            let currentSettings: LuminaSettings
            if let entry = entry?.get(LuminaSettings.self) {
                currentSettings = entry
            } else {
                currentSettings = LuminaSettings.defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
