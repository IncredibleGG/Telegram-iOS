import Foundation

// LuminaGram AdShield: account level (SPEC §8.1, §8.4) – one directory per account, one file per chat, ForgetAll,
// emergency wipe, orphan purge and the total size cap. Port of `AccountStore` / `purge_orphans` / `wipe_root` /
// `enforce_total_cap` in `adshield/ref/adshield.py`.
//
// Layout: <root>/<hex(H("acct", userId))>/<hex(H("chat", chatId))>.bin. On iOS the root is
// `<existing account-<id> directory>/lumina-adshield`: the engine creates directories ONE level at a time (never with
// intermediates), so a deleted account directory is never recreated. All file access goes through
// `LuminaAdShieldFileSystem`, so tests run without the app (in memory or in a temp directory).
//
// Same single-queue confinement as ChatStore (see LuminaAdShieldStore.swift).

/// The few file operations the engine needs. Paths are plain POSIX paths joined with "/".
public protocol LuminaAdShieldFileSystem: AnyObject {
    /// Entry names of a directory, or nil if it is not a directory.
    func contentsOfDirectory(_ path: String) -> [String]?
    func isDirectory(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    func readFile(_ path: String) -> [UInt8]?
    /// At most `count` bytes from the start of the file.
    func readFilePrefix(_ path: String, count: Int) -> [UInt8]?
    /// Writes `path + ".tmp"` and renames it over `path` (the rename updates the mtime used by the LRU cap).
    func writeFileAtomically(_ path: String, bytes: [UInt8]) -> Bool
    /// Creates ONE directory level; fails when the parent does not exist. Succeeds if it already exists.
    func createDirectory(_ path: String) -> Bool
    /// Removes a file or a whole directory tree.
    @discardableResult
    func removeItem(_ path: String) -> Bool
    /// (size in bytes, modification time in nanoseconds) of a regular file.
    func fileSizeAndMtime(_ path: String) -> (size: Int64, mtimeNanos: Int64)?
}

/// FileManager-backed implementation. New directories are excluded from iCloud / iTunes backup (SPEC §8.1) and files
/// are written with `completeUntilFirstUserAuthentication` protection.
public final class LuminaAdShieldDiskFileSystem: LuminaAdShieldFileSystem {
    public init() {
    }

    public func contentsOfDirectory(_ path: String) -> [String]? {
        if !self.isDirectory(path) {
            return nil
        }
        return try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileExists(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    public func readFile(_ path: String) -> [UInt8]? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return [UInt8](data)
    }

    public func readFilePrefix(_ path: String, count: Int) -> [UInt8]? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: count) else {
            return []
        }
        return [UInt8](data)
    }

    public func writeFileAtomically(_ path: String, bytes: [UInt8]) -> Bool {
        let tmp = path + ".tmp"
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        if !FileManager.default.createFile(atPath: tmp, contents: Data(bytes), attributes: attributes) {
            return false
        }
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    public func createDirectory(_ path: String) -> Bool {
        if self.isDirectory(path) {
            return true
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
        } catch {
            return false
        }
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }

    @discardableResult
    public func removeItem(_ path: String) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    public func fileSizeAndMtime(_ path: String) -> (size: Int64, mtimeNanos: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let nanos = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
        return (size, nanos)
    }
}

extension LuminaAdShield {
    static func joinPath(_ a: String, _ b: String) -> String {
        if a.hasSuffix("/") {
            return a + b
        }
        return a + "/" + b
    }

    /// keyCheck of a chat file (bytes 16..<24), or nil when the header cannot be read or the magic is wrong.
    static func fileKeyCheck(_ path: String, fs: LuminaAdShieldFileSystem) -> UInt64? {
        guard let head = fs.readFilePrefix(path, count: 24), head.count >= 24 else {
            return nil
        }
        if head[0] != 0x4C || head[1] != 0x47 || head[2] != 0x41 || head[3] != 0x53 { // "LGAS"
            return nil
        }
        var v: UInt64 = 0
        for i in 0 ..< 8 {
            v |= UInt64(head[16 + i]) << (8 * UInt64(i))
        }
        return v
    }

    static func hasBinSuffix(_ name: String) -> Bool {
        let u = Array(name.utf8)
        return u.count >= 4 && Array(u[(u.count - 4)...]) == [0x2E, 0x62, 0x69, 0x6E] // ".bin"
    }

    /// At startup (and from ForgetAll): delete chat files whose keyCheck does not match the current key (left over
    /// after the key was lost or replaced) or whose header cannot be read, temp files, stray files in the root, and
    /// then empty account directories. Returns the number of entries deleted.
    @discardableResult
    public static func purgeOrphans(root: String, key: [UInt8], fs: LuminaAdShieldFileSystem) -> Int {
        guard key.count == 16, let entries = fs.contentsOfDirectory(root) else {
            return 0
        }
        let want = AdShieldTables.keyedHash(key16: key, tag: "check", payload: "LGAS")
        var removed = 0
        for d in entries.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let p = joinPath(root, d)
            guard let names = fs.contentsOfDirectory(p) else {
                fs.removeItem(p)
                removed += 1
                continue
            }
            for name in names {
                let fp = joinPath(p, name)
                if !hasBinSuffix(name) || fs.isDirectory(fp) || fileKeyCheck(fp, fs: fs) != want {
                    fs.removeItem(fp)
                    removed += 1
                }
            }
            if let left = fs.contentsOfDirectory(p), left.isEmpty {
                fs.removeItem(p)
            }
        }
        return removed
    }

    /// Emergency wipe: the whole AdShield root (every account, orphan directories, temp files).
    public static func wipeRoot(_ root: String, fs: LuminaAdShieldFileSystem) {
        if fs.isDirectory(root) {
            fs.removeItem(root)
        }
    }

    /// When all accounts together exceed `cap`, delete whole chat files oldest-mtime first (ties: path order).
    /// Returns the number of files deleted.
    @discardableResult
    public static func enforceTotalCap(root: String, cap: Int64 = totalCapBytes, fs: LuminaAdShieldFileSystem) -> Int {
        guard let entries = fs.contentsOfDirectory(root) else {
            return 0
        }
        var files: [(mtime: Int64, path: [UInt8], size: Int64)] = []
        for d in entries {
            let p = joinPath(root, d)
            guard let names = fs.contentsOfDirectory(p) else {
                continue
            }
            for name in names where hasBinSuffix(name) {
                let fp = joinPath(p, name)
                if let st = fs.fileSizeAndMtime(fp) {
                    files.append((st.mtimeNanos, Array(fp.utf8), st.size))
                }
            }
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        files.sort { a, b in
            if a.mtime != b.mtime {
                return a.mtime < b.mtime
            }
            if a.path != b.path {
                return a.path.lexicographicallyPrecedes(b.path)
            }
            return a.size < b.size
        }
        var removed = 0
        for f in files {
            if total <= cap {
                break
            }
            fs.removeItem(String(decoding: f.path, as: UTF8.self))
            total -= f.size
            removed += 1
        }
        return removed
    }

    // ===========================================================================
    // AccountStore
    // ===========================================================================

    /// One per account, keyed by userId (never by slot index). Creating it touches no file; the first `flush`
    /// creates `<root>/<account dir>`. After `forgetAll` every write is refused; create a new AccountStore to
    /// re-enable the feature.
    public final class AccountStore {
        public let userId: Int64
        let key: [UInt8]
        public let root: String?
        let fs: LuminaAdShieldFileSystem
        let gate = WriteGate()
        private var chats: [Int64: ChatStore] = [:]

        public init(userId: Int64, key: [UInt8], root: String?, fs: LuminaAdShieldFileSystem = LuminaAdShieldDiskFileSystem()) {
            precondition(key.count == 16, "AdShield key must be 16 bytes")
            self.userId = userId
            self.key = key
            self.root = root
            self.fs = fs
        }

        public var isForgotten: Bool {
            return self.gate.forgotten
        }

        /// hex(H("acct", userId)): the directory name does not reveal the user id.
        public var dirName: String {
            return AdShieldTables.hex64(khash(self.key, "acct", dec(self.userId)))
        }

        /// hex(H("chat", chatId)) + ".bin": the file name does not reveal the chat id.
        public func chatFileName(_ chatId: Int64) -> String {
            return AdShieldTables.hex64(khash(self.key, "chat", dec(chatId))) + ".bin"
        }

        public var loadedChatIds: [Int64] {
            return self.chats.keys.sorted()
        }

        /// The chat's store, loaded from disk if a valid file exists (an invalid one is ignored and replaced on the
        /// next flush). The integration keeps at most `maxLoadedChats` loaded (flush + `unload`).
        public func chat(_ chatId: Int64) throws -> ChatStore {
            if self.gate.forgotten {
                throw StoreError.forgotten
            }
            if let cs = self.chats[chatId] {
                return cs
            }
            var cs: ChatStore?
            if let root = self.root {
                let p = joinPath(joinPath(root, self.dirName), self.chatFileName(chatId))
                if self.fs.fileExists(p), let data = self.fs.readFile(p) {
                    cs = ChatStore.deserialize(data, chatId: chatId, key: self.key, gate: self.gate)
                }
            }
            let store = cs ?? ChatStore(chatId: chatId, key: self.key, gate: self.gate)
            self.chats[chatId] = store
            return store
        }

        private func ensureAccountDir() -> String? {
            guard let root = self.root else {
                return nil
            }
            if !self.fs.createDirectory(root) {
                return nil
            }
            let d = joinPath(root, self.dirName)
            if !self.fs.createDirectory(d) {
                return nil
            }
            return d
        }

        /// Atomically writes one loaded chat. Refused after forgetAll. Returns whether it wrote.
        @discardableResult
        public func flush(chatId: Int64) -> Bool {
            if self.gate.forgotten {
                return false
            }
            guard let cs = self.chats[chatId], let d = self.ensureAccountDir() else {
                return false
            }
            return self.fs.writeFileAtomically(joinPath(d, self.chatFileName(chatId)), bytes: cs.serialize())
        }

        /// Atomically writes every loaded chat. Refused after forgetAll. Returns whether it wrote.
        @discardableResult
        public func flush() -> Bool {
            if self.gate.forgotten {
                return false
            }
            guard let d = self.ensureAccountDir() else {
                return false
            }
            var ok = true
            for chatId in self.chats.keys.sorted() {
                if let cs = self.chats[chatId], !self.fs.writeFileAtomically(joinPath(d, self.chatFileName(chatId)), bytes: cs.serialize()) {
                    ok = false
                }
            }
            return ok
        }

        /// Drops a chat from memory (flush it first if it should be kept).
        public func unload(_ chatId: Int64) {
            self.chats.removeValue(forKey: chatId)
        }

        /// Logout / account removal: refuse writes from now on, clear memory, delete this account's directory and
        /// orphans. `panic` (emergency wipe) deletes the whole root. The integration must cancel its debounce /
        /// flush timers BEFORE calling this; any later flush is refused anyway.
        public func forgetAll(panic: Bool = false) {
            self.gate.forgotten = true
            self.chats.removeAll()
            guard let root = self.root else {
                return
            }
            if panic {
                wipeRoot(root, fs: self.fs)
                return
            }
            let d = joinPath(root, self.dirName)
            if self.fs.isDirectory(d) {
                self.fs.removeItem(d)
            }
            purgeOrphans(root: root, key: self.key, fs: self.fs)
        }
    }
}
