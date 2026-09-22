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
    // Whether the session guard has already taken its one-time baseline of existing
    // authorizations. Distinguishes "first run for this account — adopt whatever sessions
    // already exist as known" from "baseline taken — alert on anything new". Without it, an
    // account that had zero other sessions at first run and later gains exactly one would seed
    // silently instead of alerting (see LuminaSessionGuard.swift).
    public var sessionGuardBaselineSeeded: Bool
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

    // MARK: Display gates (LuminaGram)
    //
    // hideReactions: hide the reaction chips under messages (skips both draw AND
    //   measure/layout, so no empty gap is left behind). Default false = stock behavior.
    public var hideReactions: Bool

    // MARK: Chat list (LuminaGram)
    //
    // chatListPreviewLines: number of message-preview lines each chat-list row shows.
    //   0 = follow stock behavior (2 lines for private chats, 1 alongside an author line);
    //   1/2/3 = force that many preview lines and grow/shrink the row height to match.
    // chatListDisableSwipe: disable the chat-list row swipe gesture entirely.
    // chatListHideDeleteSwipe: hide only the destructive delete action from the swipe.
    public var chatListPreviewLines: Int32
    public var chatListDisableSwipe: Bool
    public var chatListHideDeleteSwipe: Bool

    // MARK: Input row (LuminaGram)
    //
    // Composer input-row detail toggles. Every default below is the stock behavior, so an
    // untouched install is byte-identical to upstream.
    //
    // hideVoiceRecordButton: hide the voice/video-message record button in the composer.
    //   Default false = the mic button shows as usual.
    // hideSendAsButton: hide the "send as" (post-as-channel) avatar button in the composer.
    //   Default false = the button shows whenever send-as peers are available.
    // disableThanosDeleteEffect: turn off the "thanos snap" dust delete animation in the
    //   chat history; deletions fall back to the standard list-removal animation. Default
    //   false = the dust effect plays (stock behavior; mirrors the existing app-config
    //   ios_killswitch_disable_dust_effect graceful path).
    // sendWithReturnKey: make the on-screen keyboard Return key send the message instead of
    //   inserting a newline. Default false = Return inserts a newline (stock behavior).
    // formattingToolbar: show a small bar of quick formatting buttons (bold / italic / link)
    //   above the composer input, reusing the existing formatting actions. Default false.
    public var hideVoiceRecordButton: Bool
    public var hideSendAsButton: Bool
    public var disableThanosDeleteEffect: Bool
    public var sendWithReturnKey: Bool
    public var formattingToolbar: Bool

    // MARK: Chat & interaction (LuminaGram, Batch 4)
    //
    // Every default below is the stock behavior, so an untouched install is byte-identical to
    // upstream.
    //
    // doubleTapToEdit: double-tapping your OWN message enters edit mode (reusing the standard
    //   edit-message path) instead of adding a quick reaction. Default false = double-tap adds a
    //   reaction (stock behavior).
    // ctxMenuShow*: show/hide individual long-press message-menu actions. Default true for each =
    //   the action is shown (stock behavior); an untouched install shows every action.
    // messageFilterKeywords: pure client-side display filter. Messages whose text contains any of
    //   these keywords are hidden from the visible message list (the user's own choice - nothing
    //   is deleted or hidden on the server). Default [] = nothing is filtered.
    // confirmBeforeCall: show a confirmation dialog before starting a voice/video call. Default
    //   false = a call starts immediately (stock behavior).
    public var doubleTapToEdit: Bool
    public var ctxMenuShowReply: Bool
    public var ctxMenuShowCopy: Bool
    public var ctxMenuShowForward: Bool
    public var ctxMenuShowPin: Bool
    public var ctxMenuShowReport: Bool
    public var ctxMenuShowSave: Bool
    public var ctxMenuShowSelect: Bool
    public var messageFilterKeywords: [String]
    public var confirmBeforeCall: Bool
    // Notification fine control (LuminaGram #18). Both default false = stock behavior:
    // when true, mutePinnedNotifications suppresses the OS notification for
    // "X pinned a message" service messages; muteMentionReplyNotifications suppresses
    // the OS notification for messages that @mention you or reply to your message.
    // These only skip presenting the notification - nothing is marked read or deleted.
    public var mutePinnedNotifications: Bool
    public var muteMentionReplyNotifications: Bool

    // MARK: Navigation & folders (LuminaGram, Batch 7)
    //
    // Every default below is the stock behavior, so an untouched install is byte-identical to
    // upstream.
    //
    // hideAllChatsFolder: hide the "All Chats" tab from the folder strip. Default false.
    // compactFolderTabs: tighten the spacing between folder tabs. Default false.
    // wideFolderTabs: stretch the folder tab strip to fill the full width evenly when the tabs
    //   already fit. Default false.
    // rememberLastFolder: reopen the chat list to the last-used folder instead of always "All
    //   Chats". Default false. lastSelectedFolderId persists that folder id (0 = All Chats).
    // hideTabBar: hide the main bottom tab bar. Default false. When on, a Settings entry is
    //   surfaced in the chat list so the user is never stranded.
    // tabBarHideLabels: hide the text labels under the bottom tab-bar items. Default false.
    // tabBarHideContacts: hide the Contacts tab from the bottom tab bar. Default false.
    // tabBarHideCalls: hide the Calls tab from the bottom tab bar even when the account setting
    //   would show it. Default false.
    public var hideAllChatsFolder: Bool
    public var compactFolderTabs: Bool
    public var wideFolderTabs: Bool
    public var rememberLastFolder: Bool
    public var lastSelectedFolderId: Int32
    public var hideTabBar: Bool
    public var tabBarHideLabels: Bool
    public var tabBarHideContacts: Bool
    public var tabBarHideCalls: Bool

    // MARK: Media send (LuminaGram, Batch 8)
    //
    // #20 outgoing photo quality + resolution. Both defaults are the stock behavior, so an
    // untouched install sends byte-identical bytes to upstream: the photo goes through the
    // exact same Telegram upload pipeline, only the JPEG compression quality and the maximum
    // pixel dimension differ, and only when the user changes them.
    //
    // outgoingPhotoQuality: JPEG quality percent (1-100) applied when recompressing an outgoing
    //   photo. 0 = follow stock (compressImageToJPEG's built-in 0.6 / fetchPhotoLibraryResource's
    //   0.6). Any value 1-100 overrides that single quality parameter; nothing else in the send
    //   path changes.
    // sendLargePhotos: cap outgoing photos at the larger 2560px side instead of the stock 1280px
    //   (this reuses Telegram's own existing "HD" sizing, the same forceHd path the app already
    //   uses). Default false = the stock 1280px cap.
    public var outgoingPhotoQuality: Int32
    public var sendLargePhotos: Bool

    // #19 swipe-down-to-PiP on a fullscreen video. Default false = stock behavior (a swipe down
    // dismisses the gallery; a swipe up already enters PiP upstream). When true, a swipe down on
    // a fullscreen video enters picture-in-picture instead of dismissing. Mobile/touch only.
    public var swipeVideoPip: Bool

    public static var defaultSettings: LuminaSettings {
        return LuminaSettings(
            trMode: "manual",
            trReadLang: "",
            trSendLang: "auto",
            trScopePrivate: true,
            trScopeGroup: true,
            dualLanguageDisplay: true,
            foldOriginalLongMessages: true,
            groupSkipMyLanguages: true,
            myLanguages: [],
            translateBeforeSend: true,
            translateBeforeSendConfirm: true,
            trSendEnabledDialog: [],
            trSendLangDialog: [],
            trRegisterDialog: [],
            explainMessage: true,
            glossaryTerms: [],
            translateEngine: "google_web",
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
            sessionGuardBaselineSeeded: false,
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
            hideInputAiButton: false,
            hideReactions: false,
            chatListPreviewLines: 0,
            chatListDisableSwipe: false,
            chatListHideDeleteSwipe: false,
            hideVoiceRecordButton: false,
            hideSendAsButton: false,
            disableThanosDeleteEffect: false,
            sendWithReturnKey: false,
            formattingToolbar: false,
            doubleTapToEdit: false,
            ctxMenuShowReply: true,
            ctxMenuShowCopy: true,
            ctxMenuShowForward: true,
            ctxMenuShowPin: true,
            ctxMenuShowReport: true,
            ctxMenuShowSave: true,
            ctxMenuShowSelect: true,
            messageFilterKeywords: [],
            confirmBeforeCall: false,
            mutePinnedNotifications: false,
            muteMentionReplyNotifications: false,
            hideAllChatsFolder: false,
            compactFolderTabs: false,
            wideFolderTabs: false,
            rememberLastFolder: false,
            lastSelectedFolderId: 0,
            hideTabBar: false,
            tabBarHideLabels: false,
            tabBarHideContacts: false,
            tabBarHideCalls: false,
            outgoingPhotoQuality: 0,
            sendLargePhotos: false,
            swipeVideoPip: false
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
        sessionGuardBaselineSeeded: Bool,
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
        hideInputAiButton: Bool,
        hideReactions: Bool,
        chatListPreviewLines: Int32,
        chatListDisableSwipe: Bool,
        chatListHideDeleteSwipe: Bool,
        hideVoiceRecordButton: Bool,
        hideSendAsButton: Bool,
        disableThanosDeleteEffect: Bool,
        sendWithReturnKey: Bool,
        formattingToolbar: Bool,
        doubleTapToEdit: Bool,
        ctxMenuShowReply: Bool,
        ctxMenuShowCopy: Bool,
        ctxMenuShowForward: Bool,
        ctxMenuShowPin: Bool,
        ctxMenuShowReport: Bool,
        ctxMenuShowSave: Bool,
        ctxMenuShowSelect: Bool,
        messageFilterKeywords: [String],
        confirmBeforeCall: Bool,
        mutePinnedNotifications: Bool,
        muteMentionReplyNotifications: Bool,
        hideAllChatsFolder: Bool,
        compactFolderTabs: Bool,
        wideFolderTabs: Bool,
        rememberLastFolder: Bool,
        lastSelectedFolderId: Int32,
        hideTabBar: Bool,
        tabBarHideLabels: Bool,
        tabBarHideContacts: Bool,
        tabBarHideCalls: Bool,
        outgoingPhotoQuality: Int32,
        sendLargePhotos: Bool,
        swipeVideoPip: Bool
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
        self.sessionGuardBaselineSeeded = sessionGuardBaselineSeeded
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
        self.hideReactions = hideReactions
        self.chatListPreviewLines = chatListPreviewLines
        self.chatListDisableSwipe = chatListDisableSwipe
        self.chatListHideDeleteSwipe = chatListHideDeleteSwipe
        self.hideVoiceRecordButton = hideVoiceRecordButton
        self.hideSendAsButton = hideSendAsButton
        self.disableThanosDeleteEffect = disableThanosDeleteEffect
        self.sendWithReturnKey = sendWithReturnKey
        self.formattingToolbar = formattingToolbar
        self.doubleTapToEdit = doubleTapToEdit
        self.ctxMenuShowReply = ctxMenuShowReply
        self.ctxMenuShowCopy = ctxMenuShowCopy
        self.ctxMenuShowForward = ctxMenuShowForward
        self.ctxMenuShowPin = ctxMenuShowPin
        self.ctxMenuShowReport = ctxMenuShowReport
        self.ctxMenuShowSave = ctxMenuShowSave
        self.ctxMenuShowSelect = ctxMenuShowSelect
        self.messageFilterKeywords = messageFilterKeywords
        self.confirmBeforeCall = confirmBeforeCall
        self.mutePinnedNotifications = mutePinnedNotifications
        self.muteMentionReplyNotifications = muteMentionReplyNotifications
        self.hideAllChatsFolder = hideAllChatsFolder
        self.compactFolderTabs = compactFolderTabs
        self.wideFolderTabs = wideFolderTabs
        self.rememberLastFolder = rememberLastFolder
        self.lastSelectedFolderId = lastSelectedFolderId
        self.hideTabBar = hideTabBar
        self.tabBarHideLabels = tabBarHideLabels
        self.tabBarHideContacts = tabBarHideContacts
        self.tabBarHideCalls = tabBarHideCalls
        self.outgoingPhotoQuality = outgoingPhotoQuality
        self.sendLargePhotos = sendLargePhotos
        self.swipeVideoPip = swipeVideoPip
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
        self.sessionGuardBaselineSeeded = try container.decodeIfPresent(Bool.self, forKey: "sessionGuardBaselineSeeded") ?? defaults.sessionGuardBaselineSeeded
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
        self.hideReactions = try container.decodeIfPresent(Bool.self, forKey: "hideReactions") ?? defaults.hideReactions
        self.chatListPreviewLines = try container.decodeIfPresent(Int32.self, forKey: "chatListPreviewLines") ?? defaults.chatListPreviewLines
        self.chatListDisableSwipe = try container.decodeIfPresent(Bool.self, forKey: "chatListDisableSwipe") ?? defaults.chatListDisableSwipe
        self.chatListHideDeleteSwipe = try container.decodeIfPresent(Bool.self, forKey: "chatListHideDeleteSwipe") ?? defaults.chatListHideDeleteSwipe
        self.hideVoiceRecordButton = try container.decodeIfPresent(Bool.self, forKey: "hideVoiceRecordButton") ?? defaults.hideVoiceRecordButton
        self.hideSendAsButton = try container.decodeIfPresent(Bool.self, forKey: "hideSendAsButton") ?? defaults.hideSendAsButton
        self.disableThanosDeleteEffect = try container.decodeIfPresent(Bool.self, forKey: "disableThanosDeleteEffect") ?? defaults.disableThanosDeleteEffect
        self.sendWithReturnKey = try container.decodeIfPresent(Bool.self, forKey: "sendWithReturnKey") ?? defaults.sendWithReturnKey
        self.formattingToolbar = try container.decodeIfPresent(Bool.self, forKey: "formattingToolbar") ?? defaults.formattingToolbar
        self.doubleTapToEdit = try container.decodeIfPresent(Bool.self, forKey: "doubleTapToEdit") ?? defaults.doubleTapToEdit
        self.ctxMenuShowReply = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowReply") ?? defaults.ctxMenuShowReply
        self.ctxMenuShowCopy = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowCopy") ?? defaults.ctxMenuShowCopy
        self.ctxMenuShowForward = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowForward") ?? defaults.ctxMenuShowForward
        self.ctxMenuShowPin = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowPin") ?? defaults.ctxMenuShowPin
        self.ctxMenuShowReport = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowReport") ?? defaults.ctxMenuShowReport
        self.ctxMenuShowSave = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowSave") ?? defaults.ctxMenuShowSave
        self.ctxMenuShowSelect = try container.decodeIfPresent(Bool.self, forKey: "ctxMenuShowSelect") ?? defaults.ctxMenuShowSelect
        self.messageFilterKeywords = try container.decodeIfPresent([String].self, forKey: "messageFilterKeywords") ?? defaults.messageFilterKeywords
        self.confirmBeforeCall = try container.decodeIfPresent(Bool.self, forKey: "confirmBeforeCall") ?? defaults.confirmBeforeCall
        self.mutePinnedNotifications = try container.decodeIfPresent(Bool.self, forKey: "mutePinnedNotifications") ?? defaults.mutePinnedNotifications
        self.muteMentionReplyNotifications = try container.decodeIfPresent(Bool.self, forKey: "muteMentionReplyNotifications") ?? defaults.muteMentionReplyNotifications

        self.hideAllChatsFolder = try container.decodeIfPresent(Bool.self, forKey: "hideAllChatsFolder") ?? defaults.hideAllChatsFolder
        self.compactFolderTabs = try container.decodeIfPresent(Bool.self, forKey: "compactFolderTabs") ?? defaults.compactFolderTabs
        self.wideFolderTabs = try container.decodeIfPresent(Bool.self, forKey: "wideFolderTabs") ?? defaults.wideFolderTabs
        self.rememberLastFolder = try container.decodeIfPresent(Bool.self, forKey: "rememberLastFolder") ?? defaults.rememberLastFolder
        self.lastSelectedFolderId = try container.decodeIfPresent(Int32.self, forKey: "lastSelectedFolderId") ?? defaults.lastSelectedFolderId
        self.hideTabBar = try container.decodeIfPresent(Bool.self, forKey: "hideTabBar") ?? defaults.hideTabBar
        self.tabBarHideLabels = try container.decodeIfPresent(Bool.self, forKey: "tabBarHideLabels") ?? defaults.tabBarHideLabels
        self.tabBarHideContacts = try container.decodeIfPresent(Bool.self, forKey: "tabBarHideContacts") ?? defaults.tabBarHideContacts
        self.tabBarHideCalls = try container.decodeIfPresent(Bool.self, forKey: "tabBarHideCalls") ?? defaults.tabBarHideCalls

        self.outgoingPhotoQuality = try container.decodeIfPresent(Int32.self, forKey: "outgoingPhotoQuality") ?? defaults.outgoingPhotoQuality
        self.sendLargePhotos = try container.decodeIfPresent(Bool.self, forKey: "sendLargePhotos") ?? defaults.sendLargePhotos
        self.swipeVideoPip = try container.decodeIfPresent(Bool.self, forKey: "swipeVideoPip") ?? defaults.swipeVideoPip
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
        try container.encode(self.sessionGuardBaselineSeeded, forKey: "sessionGuardBaselineSeeded")
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
        try container.encode(self.hideReactions, forKey: "hideReactions")
        try container.encode(self.chatListPreviewLines, forKey: "chatListPreviewLines")
        try container.encode(self.chatListDisableSwipe, forKey: "chatListDisableSwipe")
        try container.encode(self.chatListHideDeleteSwipe, forKey: "chatListHideDeleteSwipe")
        try container.encode(self.hideVoiceRecordButton, forKey: "hideVoiceRecordButton")
        try container.encode(self.hideSendAsButton, forKey: "hideSendAsButton")
        try container.encode(self.disableThanosDeleteEffect, forKey: "disableThanosDeleteEffect")
        try container.encode(self.sendWithReturnKey, forKey: "sendWithReturnKey")
        try container.encode(self.formattingToolbar, forKey: "formattingToolbar")
        try container.encode(self.doubleTapToEdit, forKey: "doubleTapToEdit")
        try container.encode(self.ctxMenuShowReply, forKey: "ctxMenuShowReply")
        try container.encode(self.ctxMenuShowCopy, forKey: "ctxMenuShowCopy")
        try container.encode(self.ctxMenuShowForward, forKey: "ctxMenuShowForward")
        try container.encode(self.ctxMenuShowPin, forKey: "ctxMenuShowPin")
        try container.encode(self.ctxMenuShowReport, forKey: "ctxMenuShowReport")
        try container.encode(self.ctxMenuShowSave, forKey: "ctxMenuShowSave")
        try container.encode(self.ctxMenuShowSelect, forKey: "ctxMenuShowSelect")
        try container.encode(self.messageFilterKeywords, forKey: "messageFilterKeywords")
        try container.encode(self.confirmBeforeCall, forKey: "confirmBeforeCall")
        try container.encode(self.mutePinnedNotifications, forKey: "mutePinnedNotifications")
        try container.encode(self.muteMentionReplyNotifications, forKey: "muteMentionReplyNotifications")

        try container.encode(self.hideAllChatsFolder, forKey: "hideAllChatsFolder")
        try container.encode(self.compactFolderTabs, forKey: "compactFolderTabs")
        try container.encode(self.wideFolderTabs, forKey: "wideFolderTabs")
        try container.encode(self.rememberLastFolder, forKey: "rememberLastFolder")
        try container.encode(self.lastSelectedFolderId, forKey: "lastSelectedFolderId")
        try container.encode(self.hideTabBar, forKey: "hideTabBar")
        try container.encode(self.tabBarHideLabels, forKey: "tabBarHideLabels")
        try container.encode(self.tabBarHideContacts, forKey: "tabBarHideContacts")
        try container.encode(self.tabBarHideCalls, forKey: "tabBarHideCalls")

        try container.encode(self.outgoingPhotoQuality, forKey: "outgoingPhotoQuality")
        try container.encode(self.sendLargePhotos, forKey: "sendLargePhotos")
        try container.encode(self.swipeVideoPip, forKey: "swipeVideoPip")
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
