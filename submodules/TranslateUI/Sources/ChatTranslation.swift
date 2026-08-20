import Foundation
import NaturalLanguage
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext
import TelegramUIPreferences

public struct ChatTranslationState: Codable {
    enum CodingKeys: String, CodingKey {
        case baseLang
        case fromLang
        case timestamp
        case toLang
        case isEnabled
    }
    
    public let baseLang: String
    public let fromLang: String
    public let timestamp: Int32?
    public let toLang: String?
    public let isEnabled: Bool
    
    public init(
        baseLang: String,
        fromLang: String,
        timestamp: Int32?,
        toLang: String?,
        isEnabled: Bool
    ) {
        self.baseLang = baseLang
        self.fromLang = fromLang
        self.timestamp = timestamp
        self.toLang = toLang
        self.isEnabled = isEnabled
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.baseLang = try container.decode(String.self, forKey: .baseLang)
        self.fromLang = try container.decode(String.self, forKey: .fromLang)
        self.timestamp = try container.decodeIfPresent(Int32.self, forKey: .timestamp)
        self.toLang = try container.decodeIfPresent(String.self, forKey: .toLang)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.baseLang, forKey: .baseLang)
        try container.encode(self.fromLang, forKey: .fromLang)
        try container.encodeIfPresent(self.timestamp, forKey: .timestamp)
        try container.encodeIfPresent(self.toLang, forKey: .toLang)
        try container.encode(self.isEnabled, forKey: .isEnabled)
    }

    public func withToLang(_ toLang: String?) -> ChatTranslationState {
        return ChatTranslationState(
            baseLang: self.baseLang,
            fromLang: self.fromLang,
            timestamp: self.timestamp,
            toLang: toLang,
            isEnabled: self.isEnabled
        )
    }
    
    public func withIsEnabled(_ isEnabled: Bool) -> ChatTranslationState {
        return ChatTranslationState(
            baseLang: self.baseLang,
            fromLang: self.fromLang,
            timestamp: self.timestamp,
            toLang: self.toLang,
            isEnabled: isEnabled
        )
    }
}

private func cachedChatTranslationState(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<ChatTranslationState?, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    return engine.data.subscribe(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key))
    |> map { entry -> ChatTranslationState? in
        return entry?.get(ChatTranslationState.self)
    }
}

private func updateChatTranslationState(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?, state: ChatTranslationState?) -> Signal<Never, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    if let state {
        return engine.itemCache.put(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key, item: state)
    } else {
        return engine.itemCache.remove(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key)
    }
}

public func updateChatTranslationStateInteractively(engine: TelegramEngine, peerId: EnginePeer.Id, threadId: Int64?, _ f: @escaping (ChatTranslationState?) -> ChatTranslationState?) -> Signal<Never, NoError> {
    let key: EngineDataBuffer
    if let threadId {
        key = EngineDataBuffer(length: 16)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
        key.setInt64(8, value: threadId)
    } else {
        key = EngineDataBuffer(length: 8)
        key.setInt64(0, value: peerId.id._internalGetInt64Value())
    }
    
    return engine.data.get(TelegramEngine.EngineData.Item.ItemCache.Item(collectionId: ApplicationSpecificItemCacheCollectionId.translationState, id: key))
    |> map { entry -> ChatTranslationState? in
        return entry?.get(ChatTranslationState.self)
    }
    |> mapToSignal { current -> Signal<Never, NoError> in
        if let current {
            return updateChatTranslationState(engine: engine, peerId: peerId, threadId: threadId, state: f(current))
        } else {
            return .never()
        }
    }
}

// LuminaGram: force-enable/disable chat translation from the always-present header button.
// updateChatTranslationStateInteractively no-ops when no ChatTranslationState is cached yet --
// the normal case before the language scanner has run -- which made the header button look dead.
// Resolve chatTranslationState first (it runs detection and caches a state when the chat has
// foreign content), skip its spurious initial nil, then write the enabled flag directly. If nothing
// translatable turns up within a short window, complete without changing anything.
public func luminaSetChatTranslationEnabled(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?, enabled: Bool) -> Signal<Never, NoError> {
    return chatTranslationState(context: context, peerId: peerId, threadId: threadId)
    |> filter { $0 != nil }
    |> take(1)
    |> timeout(3.0, queue: Queue.mainQueue(), alternate: .single(nil as ChatTranslationState?))
    |> mapToSignal { state -> Signal<Never, NoError> in
        guard let state else {
            return .complete()
        }
        return updateChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId, state: state.withIsEnabled(enabled))
    }
}

// LuminaGram: set the incoming chat-translation target language from an EXPLICIT user pick
// (the header menu). Unlike luminaSetChatTranslationEnabled, this does NOT depend on the
// language scanner -- it writes a ChatTranslationState directly, so picking a language works
// even in chats with too little/own-language content to auto-detect. baseLang is computed the
// same way chatTranslationState does so its freshness check keeps the written state; fromLang
// is left empty (the engine auto-detects the source per message) and is not an ignored language,
// so chatTranslationState returns the state rather than dropping it. toLang == nil disables.
public func luminaSetIncomingTranslationLanguage(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?, toLang: String?) -> Signal<Never, NoError> {
    var baseLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    let rawSuffix = "-raw"
    if baseLang.hasSuffix(rawSuffix) {
        baseLang = String(baseLang.dropLast(rawSuffix.count))
    }
    let resolvedBaseLang = baseLang
    return cachedChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId)
    |> take(1)
    |> mapToSignal { current -> Signal<Never, NoError> in
        let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        if let toLang, !toLang.isEmpty, toLang != "off" {
            let state = ChatTranslationState(
                baseLang: resolvedBaseLang,
                fromLang: current?.fromLang ?? "",
                timestamp: now,
                toLang: toLang,
                isEnabled: true
            )
            return updateChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId, state: state)
        } else if let current {
            return updateChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId, state: current.withIsEnabled(false))
        } else {
            return .complete()
        }
    }
}


@available(iOS 12.0, *)
private let languageRecognizer = NLLanguageRecognizer()

public func translateMessageIds(context: AccountContext, messageIds: [EngineMessage.Id], fromLang: String?, toLang: String) -> Signal<Never, NoError> {
    return context.account.postbox.transaction { transaction -> Signal<Never, NoError> in
        var messageIdsToTranslate: [EngineMessage.Id] = []
        var messageIdsSet = Set<EngineMessage.Id>()
        for messageId in messageIds {
            if let message = transaction.getMessage(messageId) {
                if let replyAttribute = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute, let replyMessage = message.associatedMessages[replyAttribute.messageId] {
                    if !replyMessage.text.isEmpty {
                        if let translation = replyMessage.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == toLang {
                        } else {
                            if !messageIdsSet.contains(replyMessage.id) {
                                messageIdsToTranslate.append(replyMessage.id)
                                messageIdsSet.insert(replyMessage.id)
                            }
                        }
                    }
                }
                guard message.author?.id != context.account.peerId else {
                    continue
                }
                if let translation = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, translation.toLang == toLang {
                    continue
                }
                
                if !message.text.isEmpty {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                } else if let _ = message.richText {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                } else if let _ = message.media.first(where: { $0 is TelegramMediaPoll }) {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                } else if let audioTranscription = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute, !audioTranscription.text.isEmpty && !audioTranscription.isPending {
                    if !messageIdsSet.contains(messageId) {
                        messageIdsToTranslate.append(messageId)
                        messageIdsSet.insert(messageId)
                    }
                }
            } else {
                if !messageIdsSet.contains(messageId) {
                    messageIdsToTranslate.append(messageId)
                    messageIdsSet.insert(messageId)
                }
            }
        }
        
        // LuminaGram: also collect the plain text of each message to translate, so the
        // custom-engine path can translate it itself instead of calling Telegram's RPC.
        var messageTextsToTranslate: [(EngineMessage.Id, String)] = []
        for id in messageIdsToTranslate {
            if let message = transaction.getMessage(id), !message.text.isEmpty {
                messageTextsToTranslate.append((id, message.text))
            }
        }

        return luminaCurrentSettings(context: context)
        |> mapToSignal { settings -> Signal<Never, NoError> in
            // LuminaGram: honour the user's chosen translation engine on the read path.
            // "telegram" keeps Telegram's own RPC (with its premium behaviour); any other
            // engine translates each message itself and writes a local TranslationMessageAttribute,
            // so the free translate bar no longer depends on Telegram's Cocoon backend.
            if settings.translateEngine == "telegram" {
                let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                var enableLocalIfPossible = false
                switch translationConfiguration.auto {
                case .system:
                    if #available(iOS 18.0, *) {
                        enableLocalIfPossible = true
                    }
                default:
                    break
                }
                return context.engine.messages.translateMessages(messageIds: messageIdsToTranslate, fromLang: fromLang, toLang: toLang, enableLocalIfPossible: enableLocalIfPossible)
                |> `catch` { _ -> Signal<Never, NoError> in
                    return .complete()
                }
            } else {
                if messageTextsToTranslate.isEmpty {
                    return .complete()
                }
                let peerId = messageTextsToTranslate.first?.0.peerId
                return LuminaTranslatorRegistry.current(context: context)
                |> mapToSignal { engine -> Signal<Never, NoError> in
                    let signals: [Signal<(EngineMessage.Id, String)?, NoError>] = messageTextsToTranslate.map { item -> Signal<(EngineMessage.Id, String)?, NoError> in
                        return engine.translate(text: item.1, toLang: toLang, peerId: peerId, context: context)
                        |> map { result -> (EngineMessage.Id, String)? in
                            return (item.0, result.text)
                        }
                        |> `catch` { _ -> Signal<(EngineMessage.Id, String)?, NoError> in
                            return .single(nil)
                        }
                    }
                    return combineLatest(signals)
                    |> mapToSignal { pairs -> Signal<Never, NoError> in
                        return context.account.postbox.transaction { transaction -> Void in
                            for pair in pairs {
                                guard let (id, text) = pair, !text.isEmpty else {
                                    continue
                                }
                                let updatedAttribute = TranslationMessageAttribute(text: text, entities: [], toLang: toLang)
                                transaction.updateMessage(id, update: { currentMessage in
                                    let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                                    var attributes = currentMessage.attributes.filter { !($0 is TranslationMessageAttribute) }
                                    attributes.append(updatedAttribute)
                                    return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                                })
                            }
                        }
                        |> ignoreValues
                    }
                }
            }
        }
    } |> switchToLatest
}

public func chatTranslationState(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<ChatTranslationState?, NoError> {
    if peerId.id == EnginePeer.Id.Id._internalFromInt64Value(777000) {
        return .single(nil)
    }
    
    guard canTranslateChats(context: context) else {
        return .single(nil)
    }
    
    let loggingEnabled = context.sharedContext.immediateExperimentalUISettings.logLanguageRecognition
    
    if #available(iOS 12.0, *) {
        var baseLang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let rawSuffix = "-raw"
        if baseLang.hasSuffix(rawSuffix) {
            baseLang = String(baseLang.dropLast(rawSuffix.count))
        }

        return combineLatest(
            context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.translationSettings])
            |> map { sharedData -> TranslationSettings in
                return sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) ?? TranslationSettings.defaultSettings
            },
            context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.AutoTranslateEnabled(id: peerId)),
            // LuminaGram: group-skip my languages
            luminaCurrentSettings(context: context)
        )
        |> mapToSignal { settings, autoTranslateEnabled, luminaSettings in
            // LuminaGram: chat translation is free and always offered; the persisted
            // translateChats toggle no longer suppresses the bar (mirrors the forced
            // showTranslate for the per-message button). Users can still hide it per chat.

            var dontTranslateLanguages = Set<String>()
            if let ignoredLanguages = settings.ignoredLanguages {
                dontTranslateLanguages = Set(ignoredLanguages)
            } else {
                dontTranslateLanguages.insert(baseLang)
                for language in systemLanguageCodes() {
                    dontTranslateLanguages.insert(language)
                }
            }
            // LuminaGram: group-skip my languages — extend Telegram's own ignored-language set
            // with LuminaSettings.myLanguages/trReadLang, gated by groupSkipMyLanguages.
            dontTranslateLanguages.formUnion(luminaAdditionalIgnoredTranslationLanguages(settings: luminaSettings))
            
            return cachedChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId)
            |> mapToSignal { cached in
                let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                if let cached, let timestamp = cached.timestamp, cached.baseLang == baseLang && currentTime - timestamp < 60 * 60 {
                    if !dontTranslateLanguages.contains(cached.fromLang) {
                        return .single(cached)
                    } else {
                        return .single(nil)
                    }
                } else {
                    return .single(nil)
                    |> then(
                        context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: threadId), index: .upperBound, anchorIndex: .upperBound, count: 32, fixedCombinedReadStates: nil)
                        |> filter { messageHistoryView -> Bool in
                            return messageHistoryView.0.entries.count > 1
                        }
                        |> take(1)
                        |> map { messageHistoryView, _, _ -> ChatTranslationState? in
                            let messages = messageHistoryView.entries.map(\.message)
                            
                            if loggingEnabled {
                                Logger.shared.log("ChatTranslation", "Start language recognizing for \(peerId)")
                            }
                            var fromLangs: [String: Int] = [:]
                            var count = 0
                            for message in messages {
                                if message.effectivelyIncoming(context.account.peerId), message.text.count >= 10 {
                                    if let summaryAttribute = message.attributes.first(where: { $0 is SummarizationMessageAttribute }) as? SummarizationMessageAttribute, !summaryAttribute.fromLang.isEmpty {
                                        let fromLang = normalizeTranslationLanguage(summaryAttribute.fromLang)
                                        if supportedTranslationLanguages.contains(fromLang) {
                                            fromLangs[fromLang] = (fromLangs[fromLang] ?? 0) + message.text.count
                                            count += 1
                                        }
                                    } else {
                                        var text = String(message.text.prefix(256))
                                        if var entities = message.textEntitiesAttribute?.entities.filter({ entity in
                                            switch entity.type {
                                            case .Pre, .Code, .Url, .Email, .Mention, .Hashtag, .BotCommand:
                                                return true
                                            default:
                                                return false
                                            }
                                        }) {
                                            entities = entities.sorted(by: { $0.range.lowerBound > $1.range.lowerBound })
                                            var ranges: [Range<String.Index>] = []
                                            for entity in entities {
                                                if entity.range.lowerBound > text.count || entity.range.upperBound > text.count {
                                                    continue
                                                }
                                                ranges.append(text.index(text.startIndex, offsetBy: entity.range.lowerBound) ..< text.index(text.startIndex, offsetBy: entity.range.upperBound))
                                            }
                                            for range in ranges {
                                                if range.upperBound < text.endIndex {
                                                    text.removeSubrange(range)
                                                }
                                            }
                                        }
                                        
                                        if message.text.count < 10 {
                                            continue
                                        }
                                        
                                        languageRecognizer.processString(text)
                                        let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 4)
                                        languageRecognizer.reset()
                                        
                                        let filteredLanguages = hypotheses.filter { supportedTranslationLanguages.contains(normalizeTranslationLanguage($0.key.rawValue)) }.sorted(by: { $0.value > $1.value })
                                        if let language = filteredLanguages.first {
                                            let fromLang = normalizeTranslationLanguage(language.key.rawValue)
                                            if loggingEnabled && !["en", "ru"].contains(fromLang) && !dontTranslateLanguages.contains(fromLang) {
                                                Logger.shared.log("ChatTranslation", "\(text)")
                                                Logger.shared.log("ChatTranslation", "Recognized as: \(fromLang), other hypotheses: \(hypotheses.map { $0.key.rawValue }.joined(separator: ",")) ")
                                            }
                                            fromLangs[fromLang] = (fromLangs[fromLang] ?? 0) + message.text.count
                                            count += 1
                                        }
                                    }
                                }
                                if count >= 16 {
                                    break
                                }
                            }
                                                        
                            var mostFrequent: (String, Int)?
                            for (lang, count) in fromLangs {
                                if let current = mostFrequent {
                                    if count > current.1 {
                                        mostFrequent = (lang, count)
                                    }
                                } else {
                                    mostFrequent = (lang, count)
                                }
                            }
                            let fromLang = mostFrequent?.0 ?? ""
                            if loggingEnabled {
                                Logger.shared.log("ChatTranslation", "Ended with: \(fromLang)")
                            }
                            
                            let isEnabled: Bool
                            if let currentIsEnabled = cached?.isEnabled {
                                isEnabled = currentIsEnabled
                            } else if autoTranslateEnabled {
                                isEnabled = true
                            } else {
                                isEnabled = false
                            }
                            
                            let state = ChatTranslationState(
                                baseLang: baseLang,
                                fromLang: fromLang,
                                timestamp: currentTime,
                                toLang: cached?.toLang,
                                isEnabled: isEnabled
                            )
                            let _ = updateChatTranslationState(engine: context.engine, peerId: peerId, threadId: threadId, state: state).start()
                            if !dontTranslateLanguages.contains(fromLang) {
                                return state
                            } else {
                                return nil
                            }
                        }
                    )
                }
            }
        }
    } else {
        return .single(nil)
    }
}
