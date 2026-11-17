import Foundation
import UIKit
import ImageIO
import CoreGraphics
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import TemporaryCachedPeerDataManager
import TinyThumbnail
import ContextUI
import PresentationDataUtils
import AppBundle

// LuminaGram「隱藏重複廣告」(hide repeated ads): the TelegramUI side of the integration (stage 1, plumbing).
//
//  - `luminaAdShieldInstall`: called once from SharedAccountContextImpl.init. Starts LuminaAdShieldService, feeds it
//    the logged-in accounts (an account that disappears = logout / removal → ForgetAll), flushes on background and
//    terminate, and forwards message deletions of the chats the engine has loaded.
//  - `LuminaAdShieldHistoryObserver`: one per ChatHistoryListNodeImpl of a group (main history or forum topic).
//    Idle unless the feature is in effect for that group; then it builds the ChatContext (admins, bots, pinned
//    texts, linked channel, description, my username), hands new / edited loaded messages to the AdShield queue
//    and keeps `session` (a LuminaAdShieldChatSession, the decision cache the chat list reads) current.
//  - Postbox → LuminaAdShield.MessageInput mapping (SPEC §9.1, media whitelist §3) and the dHash of the stripped
//    thumbnail (SPEC §5.4). The per-group mode row is in ChatListUI (LuminaAdShieldGroupMenu.swift).
//
// Nothing here logs. With the feature off (default) an observer holds one settings subscription and never
// subscribes to anything else, maps a message or touches the engine.

// MARK: - Ids

/// Bot-API style id: users `<id>`, basic groups `-<id>`, channels / supergroups `-100<id>`; 0 for anything else.
func luminaAdShieldBotApiId(_ peerId: PeerId) -> Int64 {
    let raw = peerId.id._internalGetInt64Value()
    if peerId.namespace == Namespaces.Peer.CloudUser {
        return raw
    } else if peerId.namespace == Namespaces.Peer.CloudGroup {
        return -raw
    } else if peerId.namespace == Namespaces.Peer.CloudChannel {
        return Int64("-100\(raw)") ?? (-1_000_000_000_000 - raw)
    } else {
        return 0
    }
}

/// The bot-API chat id of a basic group / channel peer id (the AdShield chat id), nil for anything else.
func luminaAdShieldGroupChatId(_ peerId: PeerId) -> Int64? {
    if peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel {
        return luminaAdShieldBotApiId(peerId)
    }
    return nil
}

/// SPEC §6.1 chat type; `.other` (ineligible) for private chats, secret chats, broadcast channels, monoforums.
func luminaAdShieldChatType(_ peer: Peer?) -> LuminaAdShield.ChatType {
    if peer is TelegramGroup {
        return .group
    }
    guard let channel = peer as? TelegramChannel, case .group = channel.info else {
        return .other
    }
    if channel.flags.contains(.isMonoforum) {
        return .other
    }
    if channel.flags.contains(.isForum) {
        return .forum
    }
    if channel.flags.contains(.isGigagroup) {
        return .gigagroup
    }
    return .supergroup
}

// MARK: - dHash (SPEC §5.4)

/// 64-bit dHash of a stripped thumbnail (`immediateThumbnailData`), on the AdShield queue. nil if it cannot be decoded.
private func luminaAdShieldThumbnailHash(_ data: Data) -> UInt64? {
    guard let jpeg = decodeTinyThumbnail(data: data), let source = CGImageSourceCreateWithData(jpeg as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    var pixels = [UInt8](repeating: 0, count: 72)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return false
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0.0, y: 0.0, width: 9.0, height: 8.0))
        return true
    }
    if !drawn {
        return nil
    }
    return luminaAdShieldDifferenceHash(gray9x8: pixels)
}

// MARK: - Install (SharedAccountContextImpl.init)

private final class LuminaAdShieldInstallation {
    static let shared = LuminaAdShieldInstallation()

    var installed = false
    let deletions = DisposableDict<String>()
    var deletionPaths = Set<String>()
}

/// Starts the service and wires the account lifecycle (main thread, once).
func luminaAdShieldInstall(sharedContext: SharedAccountContextImpl) {
    // Main app only: an extension's SharedAccountContextImpl must never touch the AdShield files.
    if !sharedContext.applicationBindings.isMainApp {
        return
    }
    let installation = LuminaAdShieldInstallation.shared
    if installation.installed {
        return
    }
    installation.installed = true
    let service = LuminaAdShieldService.shared
    service.start(accountManager: sharedContext.accountManager, chatIdForPeer: { rawPeerId in
        return luminaAdShieldGroupChatId(PeerId(rawPeerId))
    }, thumbnailHasher: { data in
        return luminaAdShieldThumbnailHash(data)
    })

    let _ = (sharedContext.activeAccountContexts
    |> deliverOnMainQueue).startStandalone(next: { _, accounts, _ in
        var paths: [String: Int64] = [:]
        var contexts: [String: AccountContext] = [:]
        for (_, context, _) in accounts {
            paths[context.account.basePath] = context.account.peerId.id._internalGetInt64Value()
            contexts[context.account.basePath] = context
        }
        service.updateAccounts(paths)

        // Deletions (remote and my own) of every logged-in account; applied only while the feature is on, and only
        // to chats the engine has in memory.
        for basePath in installation.deletionPaths where contexts[basePath] == nil {
            installation.deletions.set(nil, forKey: basePath)
        }
        for (basePath, context) in contexts where !installation.deletionPaths.contains(basePath) {
            installation.deletions.set((context.account.stateManager.deletedMessages
            |> deliverOnMainQueue).startStrict(next: { ids in
                if !LuminaAdShieldService.shared.isAnyOn {
                    return
                }
                var byChat: [Int64: [Int32]] = [:]
                var globalIds: [Int32] = []
                for id in ids {
                    switch id {
                    case let .messageId(messageId):
                        if messageId.namespace == Namespaces.Message.Cloud, let chatId = luminaAdShieldGroupChatId(messageId.peerId) {
                            byChat[chatId, default: []].append(messageId.id)
                        }
                    case let .global(globalId):
                        globalIds.append(globalId)
                    }
                }
                if byChat.isEmpty && globalIds.isEmpty {
                    return
                }
                LuminaAdShieldService.shared.messagesDeleted(basePath: basePath, byChat: byChat, globalIds: globalIds)
            }), forKey: basePath)
        }
        installation.deletionPaths = Set(contexts.keys)
    })

    let _ = (sharedContext.applicationBindings.applicationInForeground
    |> distinctUntilChanged
    |> deliverOnMainQueue).startStandalone(next: { inForeground in
        if !inForeground {
            LuminaAdShieldService.shared.flushAll()
        }
    })

    // The raw name of UIApplication.willTerminateNotification, observed without touching UIApplication.
    let _ = NotificationCenter.default.addObserver(forName: NSNotification.Name("UIApplicationWillTerminateNotification"), object: nil, queue: nil, using: { _ in
        LuminaAdShieldService.shared.flushAllSynchronously()
    })
}

// MARK: - Message mapping (SPEC §9.1)

/// What the role mapping needs to know about the chat, captured on the main thread.
struct LuminaAdShieldRoles {
    let accountPeerId: PeerId
    let chatPeerId: PeerId
    let linkedChannelPeerId: PeerId?
    let adminIds: Set<PeerId>
    let creatorId: PeerId?
}

/// SPEC §9.1: the first that holds, in this fixed order – self (anything I sent, also as a channel or as an
/// anonymous admin) > anonymous admin / channel / creator / admin > bot > contact > member. Admin here means real
/// admin rights (the loaded admin list), never a custom rank alone. A bot that is also an admin or the creator of the
/// group stays admin / creator (endorsing), exactly as before v3.
private func luminaAdShieldRole(message: Message, authorIsContact: Bool, roles: LuminaAdShieldRoles) -> LuminaAdShield.Role {
    if !message.effectivelyIncoming(roles.accountPeerId) {
        return .selfUser
    }
    guard let author = message.author else {
        return .member
    }
    if author.id == roles.accountPeerId {
        return .selfUser
    }
    if author.id == roles.chatPeerId {
        return .anonAdmin
    }
    if author is TelegramChannel || author is TelegramGroup {
        return .channel
    }
    if let creatorId = roles.creatorId, author.id == creatorId {
        return .creator
    }
    if roles.adminIds.contains(author.id) {
        return .admin
    }
    if let user = author as? TelegramUser, user.botInfo != nil {
        return .bot
    }
    if authorIsContact {
        return .contact
    }
    return .member
}

/// Postbox message → engine input, nil for anything the engine never observes (service, sponsored, local or
/// scheduled messages). Runs on the AdShield queue (Message is immutable).
func luminaAdShieldObserveItem(message: Message, authorIsContact: Bool, roles: LuminaAdShieldRoles) -> LuminaAdShieldObserveItem? {
    if message.id.namespace != Namespaces.Message.Cloud || message.id.id <= 0 || message.adAttribute != nil {
        return nil
    }

    // Media whitelist (SPEC §3): only what is attached to the message itself, never a web page preview's media.
    var media: LuminaAdShield.Media?
    var hasWebpage = false
    var thumbnail: Data?
    var aspect: Int8 = 0
    for item in message.media {
        if item is TelegramMediaAction {
            return nil
        }
        if media != nil {
            continue
        }
        if let image = item as? TelegramMediaImage {
            media = LuminaAdShield.Media(kind: .photo, id: String(image.imageId.id))
            thumbnail = image.immediateThumbnailData
            var best: PixelDimensions?
            for representation in image.representations {
                let dimensions = representation.dimensions
                if let current = best, Int64(current.width) * Int64(current.height) >= Int64(dimensions.width) * Int64(dimensions.height) {
                    continue
                }
                best = dimensions
            }
            if let best {
                aspect = luminaAdShieldAspectBucket(width: best.width, height: best.height)
            }
        } else if let file = item as? TelegramMediaFile {
            let kind: LuminaAdShield.MediaKind
            if file.isSticker || file.isAnimatedSticker || file.isVideoSticker || file.isCustomEmoji {
                kind = .sticker
            } else if file.isInstantVideo {
                kind = .round
            } else if file.isVoice {
                kind = .voice
            } else if file.isAnimated {
                kind = .gif
            } else if file.isVideo {
                kind = .video
            } else if file.isMusic {
                kind = .audio
            } else {
                kind = .document
            }
            media = LuminaAdShield.Media(kind: kind, id: String(file.fileId.id))
        } else if let contact = item as? TelegramMediaContact {
            media = LuminaAdShield.Media(kind: .contact, userId: contact.peerId.flatMap { luminaAdShieldBotApiId($0) } ?? 0, phone: contact.phoneNumber)
        } else if item is TelegramMediaDice {
            media = LuminaAdShield.Media(kind: .dice)
        } else if let map = item as? TelegramMediaMap {
            media = LuminaAdShield.Media(kind: map.venue != nil ? .venue : .location)
        } else if item is TelegramMediaPoll {
            media = LuminaAdShield.Media(kind: .poll)
        } else if item is TelegramMediaWebpage {
            hasWebpage = true
        } else if item is TelegramMediaGame {
            media = LuminaAdShield.Media(kind: .game)
        } else if item is TelegramMediaStory {
            media = LuminaAdShield.Media(kind: .story)
        } else if item is TelegramMediaInvoice {
            media = LuminaAdShield.Media(kind: .invoice)
        } else if item is TelegramMediaGiveaway || item is TelegramMediaGiveawayResults {
            media = LuminaAdShield.Media(kind: .giveaway)
        } else if item is TelegramMediaPaidContent {
            media = LuminaAdShield.Media(kind: .paid)
        }
    }
    if media == nil && hasWebpage {
        media = LuminaAdShield.Media(kind: .webpage)
    }
    if media?.kind != .photo {
        thumbnail = nil
    }

    // Sender (anonymous admin = the group itself, a message sent as a channel = that channel).
    let role = luminaAdShieldRole(message: message, authorIsContact: authorIsContact, roles: roles)
    var senderId: Int64 = 0
    var senderUsername: String?
    if let author = message.author {
        senderId = luminaAdShieldBotApiId(author.id)
        senderUsername = author.addressName
    }
    let sender = LuminaAdShield.Sender(id: senderId, role: role, username: senderUsername)

    // Entities in their original order: hidden links and mentions of users without a username.
    var entities: [LuminaAdShield.Entity] = []
    var buttons: [String] = []
    var viaBot = false
    var replyTo: Int32?
    var replyToMe = false
    var mentionsMe = false
    var autoForward = false
    for attribute in message.attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            for entity in attribute.entities {
                switch entity.type {
                case let .TextUrl(url):
                    entities.append(.textUrl(url))
                case let .TextMention(peerId):
                    entities.append(.mentionName(userId: luminaAdShieldBotApiId(peerId)))
                default:
                    break
                }
            }
        } else if let attribute = attribute as? ReplyMarkupMessageAttribute {
            for row in attribute.rows {
                for button in row.buttons {
                    if case let .url(url) = button.action {
                        buttons.append(url)
                    }
                }
            }
        } else if attribute is InlineBotMessageAttribute {
            viaBot = true
        } else if let attribute = attribute as? ReplyMessageAttribute {
            // In a forum topic every message points at the topic root; that is not a reply.
            let isTopicRoot = message.threadId != nil && Int64(attribute.messageId.id) == message.threadId
            if attribute.messageId.peerId == message.id.peerId && !isTopicRoot {
                replyTo = attribute.messageId.id
                if let replied = message.associatedMessages[attribute.messageId], !replied.effectivelyIncoming(roles.accountPeerId) {
                    replyToMe = true
                }
            }
        } else if attribute is ConsumablePersonalMentionMessageAttribute {
            mentionsMe = true
        } else if let attribute = attribute as? SourceReferenceMessageAttribute {
            // A channel post the discussion group received automatically (saved_from_peer == linked channel).
            if let linked = roles.linkedChannelPeerId, attribute.messageId.peerId == linked {
                autoForward = true
            }
        }
    }

    // A post of the linked channel that the discussion group shows as authored by the channel itself.
    if let linked = roles.linkedChannelPeerId, message.forwardInfo != nil, message.author?.id == linked {
        autoForward = true
    }

    // Forward origin.
    var forward: LuminaAdShield.Forward?
    if let info = message.forwardInfo {
        let date = Int64(info.date)
        let channel = (info.source as? TelegramChannel) ?? (info.author as? TelegramChannel)
        if let channel {
            var postId: Int32 = 0
            if let sourceMessageId = info.sourceMessageId, sourceMessageId.peerId == channel.id {
                postId = sourceMessageId.id
            }
            forward = LuminaAdShield.Forward(fromKind: .channel, fromId: luminaAdShieldBotApiId(channel.id), postId: postId, username: channel.addressName, date: date)
        } else if let author = info.author {
            forward = LuminaAdShield.Forward(fromKind: .user, fromId: luminaAdShieldBotApiId(author.id), username: author.addressName, date: date)
        } else {
            forward = LuminaAdShield.Forward(fromKind: .hidden, fromName: info.authorSignature, date: date)
        }
    }

    let input = LuminaAdShield.MessageInput(
        id: message.id.id,
        date: Int64(message.timestamp),
        sender: sender,
        text: message.text,
        entities: entities,
        media: media,
        album: message.groupingKey ?? 0,
        forward: forward,
        buttons: buttons,
        viaBot: viaBot,
        replyToMe: replyToMe,
        mentionsMe: mentionsMe,
        pinned: message.tags.contains(.pinned),
        autoForward: autoForward,
        service: false,
        sponsored: false,
        scheduled: false,
        replyTo: replyTo
    )
    return LuminaAdShieldObserveItem(input: input, photoThumbnail: thumbnail, photoAspect: aspect)
}

// MARK: - Chat context

/// Everything the ChatContext and the roles are built from; compared to decide whether loaded messages must be
/// observed again (SPEC §6.9: after the admin list loads).
private struct LuminaAdShieldChatEnv: Equatable {
    var type: LuminaAdShield.ChatType
    var username: String?
    var linkedChannelPeerId: PeerId?
    var linkedChannelUsername: String?
    var description: String
    var pinnedTexts: [String]
    var adminsKnown: Bool
    var adminIds: Set<PeerId>
    var creatorId: PeerId?
    var memberHandles: [String]
    var selfUsername: String?
}

private struct LuminaAdShieldAdmins: Equatable {
    var known: Bool
    var ids: Set<PeerId>
    var creatorId: PeerId?
    var usernames: [String]
}

/// The admin list of a supergroup / forum / gigagroup. PeerChannelMemberCategoriesContextsManager is main-confined
/// (getContext asserts the main queue), and this is subscribed from inside a Postbox peerView emission, so it runs
/// on the main queue like upstream's own wrappers there (recentOnline, profileData).
private func luminaAdShieldChannelAdmins(context: AccountContext, peerId: PeerId) -> Signal<LuminaAdShieldAdmins, NoError> {
    return Signal { subscriber in
        let (disposable, _) = context.peerChannelMemberCategoriesContextsManager.admins(engine: context.engine, accountPeerId: context.account.peerId, peerId: peerId, updated: { state in
            var ids = Set<PeerId>()
            var creatorId: PeerId?
            var usernames: [String] = []
            for participant in state.list {
                switch participant.participant {
                case .creator:
                    creatorId = participant.peer.id
                    ids.insert(participant.peer.id)
                case let .member(_, _, adminInfo, _, _, _):
                    if adminInfo != nil {
                        ids.insert(participant.peer.id)
                    }
                }
                if let username = participant.peer.addressName, !username.isEmpty {
                    usernames.append(username)
                }
            }
            var known = true
            if case .loading(initial: true) = state.loadingState {
                known = false
            }
            subscriber.putNext(LuminaAdShieldAdmins(known: known, ids: ids, creatorId: creatorId, usernames: usernames))
        })
        return disposable
    }
    |> runOn(Queue.mainQueue())
}

private func luminaAdShieldChatEnv(context: AccountContext, peerId: PeerId) -> Signal<LuminaAdShieldChatEnv?, NoError> {
    let peerView = context.account.postbox.peerView(id: peerId)
    return peerView
    |> map { view -> LuminaAdShield.ChatType in
        return luminaAdShieldChatType(view.peers[view.peerId])
    }
    |> distinctUntilChanged
    |> mapToSignal { type -> Signal<LuminaAdShieldChatEnv?, NoError> in
        if type == .other {
            return .single(nil)
        }
        let accountPeer = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> map { peer -> String? in
            return peer?.addressName
        }
        |> distinctUntilChanged
        let pinned = context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), index: .upperBound, anchorIndex: .upperBound, count: 50, fixedCombinedReadStates: nil, tag: .tag(MessageTags.pinned))
        |> map { view, _, _ -> [String] in
            var texts: [String] = []
            for entry in view.entries where !entry.message.text.isEmpty {
                texts.append(entry.message.text)
            }
            return texts
        }
        |> distinctUntilChanged
        let admins: Signal<LuminaAdShieldAdmins?, NoError>
        if peerId.namespace == Namespaces.Peer.CloudChannel {
            admins = luminaAdShieldChannelAdmins(context: context, peerId: peerId)
            |> map { value -> LuminaAdShieldAdmins? in
                return value
            }
            |> distinctUntilChanged
        } else {
            admins = .single(nil)
        }
        // Combined on the serial env queue: the inputs come from the Postbox queue and the main queue (admins).
        return combineLatest(queue: LuminaAdShieldHistoryObserver.envQueue, peerView, accountPeer, pinned, admins)
        |> map { view, selfUsername, pinnedTexts, admins -> LuminaAdShieldChatEnv? in
            let peer = view.peers[view.peerId]
            var env = LuminaAdShieldChatEnv(type: luminaAdShieldChatType(peer), username: peer?.addressName, linkedChannelPeerId: nil, linkedChannelUsername: nil, description: "", pinnedTexts: pinnedTexts, adminsKnown: false, adminIds: Set(), creatorId: nil, memberHandles: [], selfUsername: selfUsername)
            var handles: [String] = []
            if let cachedData = view.cachedData as? CachedChannelData {
                env.description = cachedData.about ?? ""
                if case let .known(linkedId) = cachedData.linkedDiscussionPeerId, let linkedId {
                    env.linkedChannelPeerId = linkedId
                    env.linkedChannelUsername = view.peers[linkedId]?.addressName
                }
                for botInfo in cachedData.botInfos {
                    if let username = view.peers[botInfo.peerId]?.addressName {
                        handles.append(username)
                    }
                }
            } else if let cachedData = view.cachedData as? CachedGroupData {
                env.description = cachedData.about ?? ""
                for botInfo in cachedData.botInfos {
                    if let username = view.peers[botInfo.peerId]?.addressName {
                        handles.append(username)
                    }
                }
                if let participants = cachedData.participants {
                    env.adminsKnown = true
                    for participant in participants.participants {
                        switch participant {
                        case let .creator(id, _):
                            env.creatorId = id
                            env.adminIds.insert(id)
                        case let .admin(id, _, _, _):
                            env.adminIds.insert(id)
                        case .member:
                            break
                        }
                        if env.adminIds.contains(participant.peerId), let username = view.peers[participant.peerId]?.addressName {
                            handles.append(username)
                        }
                    }
                }
            }
            if let admins {
                env.adminsKnown = admins.known
                env.adminIds = admins.ids
                env.creatorId = admins.creatorId
                handles.append(contentsOf: admins.usernames)
            }
            env.memberHandles = Array(Set(handles.filter { !$0.isEmpty })).sorted()
            return env
        }
        |> distinctUntilChanged
    }
}

private func luminaAdShieldContext(chatId: Int64, env: LuminaAdShieldChatEnv) -> LuminaAdShield.ChatContext {
    return LuminaAdShield.ChatContext(
        chatId: chatId,
        type: env.type,
        username: env.username,
        linkedChannelId: env.linkedChannelPeerId.flatMap { luminaAdShieldBotApiId($0) } ?? 0,
        linkedChannelUsername: env.linkedChannelUsername,
        description: env.description,
        pinnedTexts: env.pinnedTexts,
        adminsKnown: env.adminsKnown,
        memberHandles: env.memberHandles,
        selfUsername: env.selfUsername
    )
}

/// The keyword filter's own test (ChatHistoryEntriesForView luminaTextMatchesFilterKeywords): lowercased substring,
/// empty text never matches.
private func luminaAdShieldMatchesFilterKeywords(_ text: String, _ loweredKeywords: [String]) -> Bool {
    if text.isEmpty {
        return false
    }
    let loweredText = text.lowercased()
    for keyword in loweredKeywords where loweredText.contains(keyword) {
        return true
    }
    return false
}

// MARK: - History observer

/// One per ChatHistoryListNodeImpl of a group's main history or forum topic (main thread). See the file header.
final class LuminaAdShieldHistoryObserver {
    let context: AccountContext
    let peerId: PeerId
    let chatId: Int64
    /// The decision cache and UI state the chat list reads (stage 2).
    let session: LuminaAdShieldChatSession

    private var settingsDisposable: Disposable?
    private let envDisposable = MetaDisposable()
    private var envApplyTimer: SwiftSignalKit.Timer?
    private var refreshTimer: SwiftSignalKit.Timer?
    private var pendingEnv: (LuminaAdShieldChatEnv, LuminaAdShield.ChatContext)?
    private var env: LuminaAdShieldChatEnv?
    private var chatContext: LuminaAdShield.ChatContext?
    private var roles: LuminaAdShieldRoles?
    private var lastView: MessageHistoryView?
    private var observed: [Int32: UInt32] = [:]
    /// Every message id seen since the feature became effective here, its maximum, and whether the last processed
    /// view reached the newest message: new ids beyond it at the newest edge are arrivals (no fold grace).
    private var known = Set<Int32>()
    private var maxKnownId: Int32 = 0
    private var lastViewAtNewest = false
    private var sawFirstView = false
    private var lastDecideIds: [Int32] = []
    private var engineSettings: LuminaAdShield.Settings?
    private var isEffective = false
    private var trialRun = false
    /// An eligible group's env has arrived (the chat type is known): only then is the session active. A broadcast
    /// channel or monoforum (ineligible) never activates it, so it gets no fold work, no jump expansion, no toast.
    private var isEligible = false
    /// The env stream has said whether the chat is an eligible group (since the feature became effective here).
    private var envArrived = false
    /// The chat's first loaded view, kept until the session activates: its unread incoming messages are this opening's
    /// "new messages" (the all-folded toast). A view is a snapshot, so they are the ones unread when it loaded.
    private var openingView: MessageHistoryView?
    /// Messages jumped to before the session activated: unfolded on activation.
    private var pendingJumpIds = Set<Int32>()

    static let envCoalesceDelay: Double = 0.4
    static let refreshInterval: Double = 10.0 * 60.0
    /// Serial: the env inputs are combined here and the ChatContexts built here, in arrival order, so the newest env
    /// always reaches the main thread last (a concurrent queue, or inputs combined on several threads, could deliver
    /// an older one after it).
    fileprivate static let envQueue = Queue(name: "org.luminagram.adshield.env", qos: .utility)

    /// nil unless the node shows a group's normal history (or a forum topic) in bubbles: never scheduled / pinned /
    /// search / custom lists, private or secret chats, channels.
    static func make(context: AccountContext, chatLocation: ChatLocation, subject: ChatControllerSubject?, source: ChatHistoryListSource, mode: ChatHistoryListMode) -> LuminaAdShieldHistoryObserver? {
        guard case .bubbles = mode, case .default = source else {
            return nil
        }
        if let subject {
            guard case .message = subject else {
                return nil
            }
        }
        let peerId: PeerId
        switch chatLocation {
        case let .peer(id):
            peerId = id
        case let .replyThread(message):
            guard message.isForumPost else {
                return nil
            }
            peerId = message.peerId
        case .customChatContents:
            return nil
        }
        guard let chatId = luminaAdShieldGroupChatId(peerId) else {
            return nil
        }
        return LuminaAdShieldHistoryObserver(context: context, peerId: peerId, chatId: chatId)
    }

    private init(context: AccountContext, peerId: PeerId, chatId: Int64) {
        self.context = context
        self.peerId = peerId
        self.chatId = chatId
        self.session = LuminaAdShieldChatSession(userId: context.account.peerId.id._internalGetInt64Value(), basePath: context.account.basePath, chatId: chatId, peerId: peerId.toInt64())

        self.session.reobserveAll = { [weak self] in
            guard let self else {
                return
            }
            self.observed.removeAll()
            self.lastDecideIds = []
            self.process(force: true)
        }
        self.session.redecide = { [weak self] in
            self?.process(force: true)
        }

        self.settingsDisposable = (LuminaAdShieldService.shared.settingsSignal
        |> deliverOnMainQueue).startStrict(next: { [weak self] settings in
            self?.settingsUpdated(settings)
        })
    }

    deinit {
        self.settingsDisposable?.dispose()
        self.envDisposable.dispose()
        self.envApplyTimer?.invalidate()
        self.refreshTimer?.invalidate()
    }

    private func settingsUpdated(_ settings: LuminaSettings?) {
        let effective = settings?.luminaAdShieldIsOn(peerId: self.peerId.toInt64()) ?? false
        let trialRun = settings?.adShieldDryRun ?? false
        // The group's own engine settings (incl. 「連管理員和頻道的也收」): any change re-decides every loaded message.
        let engineSettings = settings?.luminaAdShieldEngineSettings(peerId: self.peerId.toInt64())
        self.trialRun = trialRun
        if effective != self.isEffective {
            self.isEffective = effective
            if effective {
                // The session activates when the env shows an eligible group (envUpdated).
                self.engineSettings = engineSettings
                self.startEnv()
            } else {
                self.stopEnv()
                self.session.setActive(false, trialRun: trialRun)
            }
            return
        }
        if !effective {
            return
        }
        if self.isEligible {
            self.session.setActive(true, trialRun: trialRun)
        }
        if engineSettings != self.engineSettings {
            self.engineSettings = engineSettings
            self.process(force: true)
        }
    }

    private func startEnv() {
        let chatId = self.chatId
        self.envDisposable.set((luminaAdShieldChatEnv(context: self.context, peerId: self.peerId)
        |> deliverOn(LuminaAdShieldHistoryObserver.envQueue)
        |> map { env -> (LuminaAdShieldChatEnv, LuminaAdShield.ChatContext)? in
            // Building a ChatContext extracts the links of the description and every pinned text: off the main thread.
            guard let env else {
                return nil
            }
            return (env, luminaAdShieldContext(chatId: chatId, env: env))
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self] value in
            self?.envUpdated(value)
        }))
        self.refreshTimer?.invalidate()
        let refreshTimer = SwiftSignalKit.Timer(timeout: LuminaAdShieldHistoryObserver.refreshInterval, repeat: true, completion: { [weak self] in
            // Decisions depend on `now` (expiry), so re-decide the loaded messages now and then.
            self?.process(force: true)
        }, queue: Queue.mainQueue())
        self.refreshTimer = refreshTimer
        refreshTimer.start()
    }

    private func stopEnv() {
        self.envDisposable.set(nil)
        self.envApplyTimer?.invalidate()
        self.envApplyTimer = nil
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        self.pendingEnv = nil
        self.env = nil
        self.chatContext = nil
        self.roles = nil
        self.isEligible = false
        self.envArrived = false
        self.openingView = nil
        self.pendingJumpIds.removeAll()
        self.observed.removeAll()
        self.known.removeAll()
        self.maxKnownId = 0
        self.lastViewAtNewest = false
        self.lastDecideIds = []
    }

    /// Env changes arrive in bursts while a chat opens (peer, admins, pinned): apply the last one 0.4 s later.
    private func envUpdated(_ value: (LuminaAdShieldChatEnv, LuminaAdShield.ChatContext)?) {
        guard self.isEffective else {
            return
        }
        self.envArrived = true
        guard let value else {
            // Not an eligible group (a broadcast channel, a monoforum): stay idle, session inactive.
            self.envApplyTimer?.invalidate()
            self.envApplyTimer = nil
            self.pendingEnv = nil
            self.env = nil
            self.chatContext = nil
            self.roles = nil
            self.isEligible = false
            self.openingView = nil
            self.pendingJumpIds.removeAll()
            self.session.setActive(false, trialRun: self.trialRun)
            return
        }
        if !self.isEligible {
            self.isEligible = true
            self.session.setActive(true, trialRun: self.trialRun)
            if !self.pendingJumpIds.isEmpty {
                let ids = Array(self.pendingJumpIds)
                self.pendingJumpIds.removeAll()
                self.session.expand(ids)
            }
            if let openingView = self.openingView {
                self.openingView = nil
                self.captureOpeningUnread(openingView)
            }
        }
        self.pendingEnv = value
        self.envApplyTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: LuminaAdShieldHistoryObserver.envCoalesceDelay, repeat: false, completion: { [weak self] in
            self?.applyPendingEnv()
        }, queue: Queue.mainQueue())
        self.envApplyTimer = timer
        timer.start()
    }

    private func applyPendingEnv() {
        self.envApplyTimer = nil
        guard self.isEffective, let pending = self.pendingEnv else {
            return
        }
        self.pendingEnv = nil
        let env = pending.0
        let chatContext = pending.1
        if env == self.env {
            return
        }
        self.env = env
        self.chatContext = chatContext
        self.roles = LuminaAdShieldRoles(
            accountPeerId: self.context.account.peerId,
            chatPeerId: self.peerId,
            linkedChannelPeerId: env.linkedChannelPeerId,
            adminIds: env.adminIds,
            creatorId: env.creatorId
        )
        // Roles, trusted tokens or known members changed: observe every loaded message again (rows and
        // endorsement records upsert by msgId, SPEC §6.3).
        self.observed.removeAll()
        self.process(force: true)
    }

    /// A jump to message `id` of this chat (reply quote, search, link, pinned bar, opening at a message): unfold its
    /// segment. Before the session is active (the env of an eligible group not here yet, e.g. a chat opened at a
    /// message) it is remembered and applied on activation; nothing at all while the feature is off here or the chat
    /// is not an eligible group. Dispatched, so that a location set while a history transition is being computed
    /// never re-enters it; the new history view arrives later anyway.
    func expandForJump(_ id: Int32) {
        if self.session.isActive {
            let session = self.session
            Queue.mainQueue().justDispatch {
                session.expand([id])
            }
        } else if self.isEffective && !self.envArrived {
            self.pendingJumpIds.insert(id)
        }
    }

    /// ChatHistoryListNodeImpl calls this with every history view (main thread). Cheap when idle.
    func historyViewUpdated(_ view: MessageHistoryView) {
        self.lastView = view
        if !self.sawFirstView && !view.isLoading {
            // The chat's first loaded view: its unread incoming messages are the "new messages" of this opening
            // (the all-folded toast). Captured before anything is shown, so before they are read.
            self.sawFirstView = true
            if self.isEffective {
                if self.session.isActive {
                    self.captureOpeningUnread(view)
                } else {
                    // Captured when the session activates (the chat is then known to be an eligible group).
                    self.openingView = view
                }
            }
        }
        if self.isEffective && self.chatContext != nil {
            self.process(force: false)
        }
    }

    private func captureOpeningUnread(_ view: MessageHistoryView) {
        let keywords = LuminaSettingsCache.settings.messageFilterKeywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        let accountPeerId = self.context.account.peerId
        var filteredAlbums = Set<Int64>()
        if !keywords.isEmpty {
            for entry in view.entries {
                if let groupingKey = entry.message.groupingKey, luminaAdShieldMatchesFilterKeywords(entry.message.text, keywords) {
                    filteredAlbums.insert(groupingKey)
                }
            }
        }
        var ids: [Int32] = []
        for entry in view.entries {
            let message = entry.message
            if entry.isRead || message.id.peerId != self.peerId || message.id.namespace != Namespaces.Message.Cloud || !message.effectivelyIncoming(accountPeerId) {
                continue
            }
            if message.media.contains(where: { $0 is TelegramMediaAction }) {
                continue
            }
            if !keywords.isEmpty {
                if luminaAdShieldMatchesFilterKeywords(message.text, keywords) {
                    continue
                }
                if let groupingKey = message.groupingKey, filteredAlbums.contains(groupingKey) {
                    continue
                }
            }
            ids.append(message.id.id)
        }
        self.session.setOpeningUnread(ids, complete: view.laterId == nil)
    }

    private func process(force: Bool) {
        guard self.isEffective, let chatContext = self.chatContext, let roles = self.roles, let view = self.lastView else {
            return
        }
        // The keyword message filter (LuminaGram #22) runs first and stays unchanged: AdShield never sees what it
        // hides. Same rule as ChatHistoryEntriesForView: a match hides the message, and in an album the whole album.
        let keywords = LuminaSettingsCache.settings.messageFilterKeywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        var filteredAlbums = Set<Int64>()
        if !keywords.isEmpty {
            for entry in view.entries {
                if let groupingKey = entry.message.groupingKey, luminaAdShieldMatchesFilterKeywords(entry.message.text, keywords) {
                    filteredAlbums.insert(groupingKey)
                }
            }
        }
        var decideIds: [Int32] = []
        var seen = Set<Int32>()
        var pending: [(Message, Bool)] = []
        var historyIds: [Int32] = []
        var arrivalIds: [Int32] = []
        let atNewest = view.laterId == nil
        let arrivalsPossible = self.session.hasDecided && self.lastViewAtNewest && atNewest
        let maxKnownBefore = self.maxKnownId
        for entry in view.entries {
            let message = entry.message
            if message.id.peerId != self.peerId || message.id.namespace != Namespaces.Message.Cloud {
                continue
            }
            if !keywords.isEmpty {
                if luminaAdShieldMatchesFilterKeywords(message.text, keywords) {
                    continue
                }
                if let groupingKey = message.groupingKey, filteredAlbums.contains(groupingKey) {
                    continue
                }
            }
            let id = message.id.id
            if !seen.insert(id).inserted {
                continue
            }
            decideIds.append(id)
            if self.known.insert(id).inserted {
                if arrivalsPossible && id > maxKnownBefore {
                    arrivalIds.append(id)
                } else {
                    historyIds.append(id)
                }
                self.maxKnownId = max(self.maxKnownId, id)
            }
            if self.observed[id] != message.stableVersion {
                self.observed[id] = message.stableVersion
                pending.append((message, entry.attributes.authorIsContact))
            }
        }
        self.lastViewAtNewest = atNewest
        if !historyIds.isEmpty || !arrivalIds.isEmpty {
            self.session.noteObserved(historyIds: historyIds, arrivalIds: arrivalIds)
        }
        if !force && pending.isEmpty && decideIds == self.lastDecideIds {
            return
        }
        self.lastDecideIds = decideIds
        self.session.submit(context: chatContext, prepare: {
            var items: [LuminaAdShieldObserveItem] = []
            for (message, authorIsContact) in pending {
                if let item = luminaAdShieldObserveItem(message: message, authorIsContact: authorIsContact, roles: roles) {
                    items.append(item)
                }
            }
            items.sort(by: { $0.input.id < $1.input.id })
            return items
        }, decideIds: decideIds)
    }
}

// MARK: - Per-group mode row

// The 「隱藏重複廣告」 row of the chat header menu (LuminaChatLanguageMenu) and of the forum's own menu, and
// `luminaAdShieldSetChatMode` (the fold row's 「在此群關閉」), live in ChatListUI (LuminaAdShieldGroupMenu.swift), the
// lowest module both menus can reach.
