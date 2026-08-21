import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramUIPreferences

// LuminaGram: translation-settings ROAMING — the per-account controller half (crypto/serialize
// live in TelegramUIPreferences/LuminaTranslationSync). It keeps ONE encrypted carrier message in
// the account's Saved Messages (self chat) in sync with the local LuminaSettings:
//  - PULL: observe the carrier; when another device edits it (newer ts, different device id),
//    decrypt + apply the settings locally.
//  - PUSH: when local translation settings change, debounce ~1.5s, then edit the carrier (or
//    create it the first time).
// Loop-safety: a `lastSyncedBody` snapshot means applying a pulled change never triggers a push,
// and pushing never re-applies our own write (device-id echo guard + ts monotonicity).
public final class LuminaTranslationSyncController {
    private let context: AccountContext
    private let accountId: Int64
    private let selfPeerId: PeerId
    private let deviceId: String
    private let queue = Queue.mainQueue()

    private var lastAppliedTs: Int64
    private var anchorMessageId: Int32?
    private var lastSyncedBody: LuminaTranslationSync.Body?

    private var settingsDisposable: Disposable?
    private let observeDisposable = MetaDisposable()
    private let findDisposable = MetaDisposable()
    private let opDisposable = MetaDisposable()
    private var pushTimer: SwiftSignalKit.Timer?
    private var pushInFlight = false
    private var started = false

    private var tsKey: String { return "LuminaRoam.ts.\(self.accountId)" }
    private var anchorKey: String { return "LuminaRoam.anchor.\(self.accountId)" }

    public init(context: AccountContext) {
        self.context = context
        self.accountId = context.account.peerId.id._internalGetInt64Value()
        self.selfPeerId = context.account.peerId
        let defaults = UserDefaults.standard
        if let d = defaults.string(forKey: "LuminaRoam.dev.\(self.accountId)") {
            self.deviceId = d
        } else {
            let d = UUID().uuidString
            defaults.set(d, forKey: "LuminaRoam.dev.\(self.accountId)")
            self.deviceId = d
        }
        self.lastAppliedTs = Int64(defaults.integer(forKey: "LuminaRoam.ts.\(self.accountId)"))
        let storedAnchor = defaults.integer(forKey: "LuminaRoam.anchor.\(self.accountId)")
        self.anchorMessageId = storedAnchor != 0 ? Int32(clamping: storedAnchor) : nil
    }

    public func start() {
        self.queue.async {
            if self.started {
                return
            }
            self.started = true
            // Baseline: treat the current local settings as already-synced, so we only push a
            // genuine change and never re-push what we just pulled.
            self.lastSyncedBody = LuminaTranslationSync.makeBody(from: LuminaSettingsCache.shared.current())
            self.resolveAndObserve()
            self.settingsDisposable = (LuminaSettingsCache.changes()
            |> deliverOn(self.queue)).start(next: { [weak self] _ in
                self?.scheduleMaybePush()
            })
        }
    }

    public func stop() {
        self.queue.async {
            self.settingsDisposable?.dispose()
            self.settingsDisposable = nil
            self.observeDisposable.dispose()
            self.findDisposable.dispose()
            self.opDisposable.dispose()
            self.pushTimer?.invalidate()
            self.pushTimer = nil
            self.started = false
        }
    }

    // MARK: Resolve anchor + observe

    private func resolveAndObserve() {
        if let id = self.anchorMessageId {
            self.observe(MessageId(peerId: self.selfPeerId, namespace: Namespaces.Message.Cloud, id: id))
        } else {
            self.watchRecentForAnchor()
        }
    }

    // Live view of the recent self-chat; picks up an existing carrier and the one we create.
    private func watchRecentForAnchor() {
        self.findDisposable.set((self.context.account.postbox.aroundMessageHistoryViewForLocation(
            .peer(peerId: self.selfPeerId, threadId: nil),
            anchor: .upperBound,
            ignoreMessagesInTimestampRange: nil,
            ignoreMessageIds: Set(),
            count: 30,
            fixedCombinedReadStates: nil,
            topTaggedMessageIdNamespaces: Set(),
            tag: nil,
            appendMessagesFromTheSameGroup: false,
            namespaces: .not(Namespaces.Message.allNonRegular),
            orderStatistics: [])
        |> deliverOn(self.queue)).start(next: { [weak self] view, _, _ in
            guard let self else {
                return
            }
            var found: MessageId?
            for entry in view.entries.reversed() {
                let message = entry.message
                if message.id.namespace == Namespaces.Message.Cloud, LuminaTranslationSync.isCarrier(message.text) {
                    found = message.id
                    break
                }
            }
            if let found {
                self.anchorMessageId = found.id
                UserDefaults.standard.set(Int(found.id), forKey: self.anchorKey)
                self.findDisposable.set(nil)
                self.observe(found)
            }
        }))
    }

    private func observe(_ messageId: MessageId) {
        self.observeDisposable.set((self.context.account.postbox.messageView(messageId)
        |> deliverOn(self.queue)).start(next: { [weak self] view in
            guard let self, let message = view.message else {
                return
            }
            self.onCarrier(text: message.text)
        }))
    }

    private func onCarrier(text: String) {
        guard LuminaTranslationSync.isCarrier(text) else {
            return
        }
        guard let payload = try? LuminaTranslationSync.decodeCarrier(text: text, accountId: self.accountId) else {
            return
        }
        if payload.dev == self.deviceId {
            return
        }
        if payload.ts <= self.lastAppliedTs {
            return
        }
        self.lastAppliedTs = payload.ts
        UserDefaults.standard.set(Int(payload.ts), forKey: self.tsKey)
        self.lastSyncedBody = payload.body
        let body = payload.body
        let platform = payload.platform
        let _ = updateLuminaSettingsInteractively(accountManager: self.context.sharedContext.accountManager) { current in
            return LuminaTranslationSync.apply(body, to: current, platform: platform)
        }.start()
    }

    // MARK: Push

    private func scheduleMaybePush() {
        self.pushTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 1.5, repeat: false, completion: { [weak self] in
            self?.maybePush()
        }, queue: self.queue)
        self.pushTimer = timer
        timer.start()
    }

    private func maybePush() {
        if self.pushInFlight {
            self.scheduleMaybePush()
            return
        }
        let current = LuminaSettingsCache.shared.current()
        let body = LuminaTranslationSync.makeBody(from: current)
        if let last = self.lastSyncedBody, last == body {
            return
        }
        let ts = Int64(Date().timeIntervalSince1970 * 1000.0)
        guard let carrier = try? LuminaTranslationSync.encodeCarrier(settings: current, accountId: self.accountId, dev: self.deviceId, ts: ts) else {
            return
        }
        self.lastSyncedBody = body
        self.lastAppliedTs = ts
        UserDefaults.standard.set(Int(ts), forKey: self.tsKey)
        self.pushInFlight = true
        if let id = self.anchorMessageId {
            let messageId = MessageId(peerId: self.selfPeerId, namespace: Namespaces.Message.Cloud, id: id)
            self.opDisposable.set((self.context.engine.messages.requestEditMessage(messageId: messageId, text: carrier, media: .keep, entities: nil, richText: nil, inlineStickers: [:], disableUrlPreview: true)
            |> deliverOn(self.queue)).start(error: { [weak self] _ in
                guard let self else {
                    return
                }
                // The cached anchor is gone/stale: forget it and let the next change recreate it.
                self.pushInFlight = false
                self.anchorMessageId = nil
                UserDefaults.standard.removeObject(forKey: self.anchorKey)
                self.watchRecentForAnchor()
            }, completed: { [weak self] in
                self?.pushInFlight = false
            }))
        } else {
            // No anchor yet: create it (silent). The recent-chat watch (still active) will pick up
            // its cloud id once the send is confirmed.
            self.opDisposable.set((self.context.engine.messages.enqueueOutgoingMessage(to: self.selfPeerId, replyTo: nil, content: .text(carrier, []), silentPosting: true)
            |> deliverOn(self.queue)).start(completed: { [weak self] in
                self?.pushInFlight = false
            }))
        }
    }
}
