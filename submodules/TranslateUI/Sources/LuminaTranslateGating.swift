import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram — group-skip "only translate what I can't read" (iOS twin of Android's
// groupSkipMyLanguages/myLanguages/isMyLanguage and desktop's TranslateOfferSkip gating in
// lumina_translate_gating.cpp). Telegram-iOS already has the primitive this extends:
// effectiveIgnoredTranslationLanguages(context:ignoredLanguages:) in Translate.swift, which
// returns the set of language codes translation is NOT offered for. This adds LuminaSettings'
// user-editable "my languages" set plus trReadLang on top of that set, gated by
// groupSkipMyLanguages (default ON) — see the `// LuminaGram: group-skip my languages`
// insertion in effectiveIgnoredTranslationLanguages for the call site.
public func luminaAdditionalIgnoredTranslationLanguages(settings: LuminaSettings) -> Set<String> {
    guard settings.groupSkipMyLanguages else {
        return []
    }
    var result = Set<String>()
    for language in settings.myLanguages {
        result.insert(normalizeTranslationLanguage(language))
    }
    // trReadLang is "the language I read chats in"; empty means "follow the interface
    // language", which effectiveIgnoredTranslationLanguages already covers on its own via
    // baseLang/systemLanguageCodes(), so there is nothing to add in that case.
    if !settings.trReadLang.isEmpty {
        result.insert(normalizeTranslationLanguage(settings.trReadLang))
    }
    return result
}

// MARK: - Automatic-translation exclusions (privacy)

// LuminaGram: chats whose content must NEVER reach a translation provider (Google web, DeepL,
// LLM relays, Telegram's translate RPC) through an AUTOMATIC flow - whole-chat translation and
// its batch translation of visible messages, the translate bar, channel auto-translate, the
// pinned-message translation and the auto-translate step after voice-to-text. Login codes from
// 777000 / the verification-codes chat and the user's own Saved Messages are the obvious cases;
// official Telegram accounts (support flag, BotFather, ...) carry account/bot secrets too.
// Explicit per-message actions (Translate on one message, Explain, Transcribe) are not gated by
// this - the user chose to send that one message.
//
// Well-known Telegram system users (CloudUser namespace): 777000 service notifications,
// 333000 its legacy alias, 42777 Telegram, 93372553 BotFather, 489000 verification codes.
private let luminaAutoTranslateSystemUserIds: Set<Int64> = [777000, 333000, 42777, 93372553, 489000]

public func luminaIsTelegramSystemUser(_ peerId: PeerId) -> Bool {
    return peerId.namespace == Namespaces.Peer.CloudUser && luminaAutoTranslateSystemUserIds.contains(peerId.id._internalGetInt64Value())
}

// An official account: a well-known system id, or a user carrying Telegram's support flag.
private func luminaIsOfficialTelegramAccount(peerId: PeerId, peer: Peer?) -> Bool {
    if luminaIsTelegramSystemUser(peerId) {
        return true
    }
    if let user = peer as? TelegramUser, user.flags.contains(.isSupport) {
        return true
    }
    return false
}

// Chat-level check. `peer` is the chat's own peer when the caller has it (needed for the
// support flag); passing nil checks only Saved Messages and the well-known ids.
public func luminaIsAutoTranslateExcludedChat(accountPeerId: PeerId, peerId: PeerId, peer: Peer?) -> Bool {
    if peerId == accountPeerId {
        return true
    }
    return luminaIsOfficialTelegramAccount(peerId: peerId, peer: peer)
}

// Message-level check: the chat it lives in, plus who wrote it and where it was forwarded from,
// so a login code or BotFather token forwarded into an ordinary chat is not auto-translated
// either. The user's own authorship is not an exclusion (only the Saved Messages chat is).
public func luminaIsAutoTranslateExcludedMessage(accountPeerId: PeerId, message: Message) -> Bool {
    if luminaIsAutoTranslateExcludedChat(accountPeerId: accountPeerId, peerId: message.id.peerId, peer: message.peers[message.id.peerId]) {
        return true
    }
    if let author = message.author, luminaIsOfficialTelegramAccount(peerId: author.id, peer: author) {
        return true
    }
    if let forwardInfo = message.forwardInfo {
        if let forwardAuthor = forwardInfo.author, luminaIsOfficialTelegramAccount(peerId: forwardAuthor.id, peer: forwardAuthor) {
            return true
        }
        if let forwardSource = forwardInfo.source, luminaIsOfficialTelegramAccount(peerId: forwardSource.id, peer: forwardSource) {
            return true
        }
    }
    return false
}

// Async chat-level check that resolves the peer, so the support flag is honoured even when the
// caller only has an id.
public func luminaAutoTranslateExcludedChat(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Bool, NoError> {
    let accountPeerId = context.account.peerId
    if luminaIsAutoTranslateExcludedChat(accountPeerId: accountPeerId, peerId: peerId, peer: nil) {
        return .single(true)
    }
    if peerId.namespace != Namespaces.Peer.CloudUser {
        return .single(false)
    }
    return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> map { peer -> Bool in
        return luminaIsAutoTranslateExcludedChat(accountPeerId: accountPeerId, peerId: peerId, peer: peer?._asPeer())
    }
}
