import Foundation

// LuminaGram — translate-before-send original capture (iOS twin of Android's LuminaTBS.java).
// When translate-before-send fires, the user's typed ORIGINAL is replaced with the
// TRANSLATION before the message is enqueued; this stores a small
// {correlationId -> originalText} map so a sent bubble can later reveal the pre-translation
// original.
//
// Simpler than Android's two-step random_id/mid correlation: on iOS the caller assigns
// EnqueueMessage.message's correlationId once, up front (see luminaTranslateMessagesBeforeSend),
// and TelegramCore copies it verbatim onto the resulting message's OutgoingMessageInfoAttribute
// (EnqueueMessage.swift's enqueueMessages implementation) — a single stable id, no reassignment
// step to correlate against, and no separate reload-survival key needed.
//
// Persistence is a small plist array in UserDefaults, pruned to the most recent maxEntries so
// it cannot grow unbounded. Nothing here is ever sent to Telegram.
public enum LuminaTranslateBeforeSendStore {
    private static let defaultsKey = "LuminaGram.translateBeforeSendOriginals"
    private static let maxEntries = 500
    private static let lock = NSLock()
    private static var cache: [Int64: String]?
    private static var order: [Int64] = []

    public static func remember(correlationId: Int64, original: String) {
        guard correlationId != 0 else {
            return
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.ensureLoaded()
        self.cache?[correlationId] = original
        self.order.removeAll(where: { $0 == correlationId })
        self.order.append(correlationId)
        while self.order.count > self.maxEntries {
            let oldest = self.order.removeFirst()
            self.cache?.removeValue(forKey: oldest)
        }
        self.save()
    }

    public static func original(correlationId: Int64?) -> String? {
        guard let correlationId, correlationId != 0 else {
            return nil
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.ensureLoaded()
        return self.cache?[correlationId]
    }

    private static func ensureLoaded() {
        guard self.cache == nil else {
            return
        }
        var loaded: [Int64: String] = [:]
        var loadedOrder: [Int64] = []
        if let raw = UserDefaults.standard.array(forKey: self.defaultsKey) as? [[String: Any]] {
            for entry in raw {
                if let id = entry["c"] as? NSNumber, let original = entry["o"] as? String {
                    let key = id.int64Value
                    loaded[key] = original
                    loadedOrder.append(key)
                }
            }
        }
        self.cache = loaded
        self.order = loadedOrder
    }

    private static func save() {
        guard let cache = self.cache else {
            return
        }
        var array: [[String: Any]] = []
        for id in self.order {
            if let original = cache[id] {
                array.append(["c": NSNumber(value: id), "o": original])
            }
        }
        UserDefaults.standard.set(array, forKey: self.defaultsKey)
    }
}
