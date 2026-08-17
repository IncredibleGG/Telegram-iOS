import Foundation

/// LuminaFileGuard — purely local, on-device detection of "masqueraded" documents: files whose
/// displayed name / type hides what they really are. Port of Android's
/// `org.telegram.messenger.LuminaFileGuard`. Two classic attacks are covered without any
/// network access:
///
///  1. Bidirectional (RTL) filename spoofing. A right-to-left override (U+202E) or an isolate
///     control makes "evil<RLO>gpj.apk" render as "evilapk.jpg", so the victim opens what looks
///     like an image but is really an APK/EXE-equivalent payload.
///
///  2. Extension / MIME masquerade (a.k.a. "EvilVideo"). An executable (apk/exe/scr/js/...) is
///     presented as a photo, video or PDF — either because the declared MIME lies, or because a
///     benign-looking extension hides a second executable extension, or because the file's own
///     magic bytes betray an executable while the name says otherwise.
///
/// Everything here is fail-open by contract: any error, or an inability to decide, yields a
/// non-suspicious result so the guard can never block a user from opening a legitimate file. The
/// caller (the document-tap hook in `ChatMessageFileBubbleContentNode.swift`) turns a suspicious
/// result into a dismissible confirmation alert; this file renders no UI and holds no state.
public enum LuminaFileGuard {
    public enum Reason {
        case none
        case rtl          // name carries bidi / RTL-override control characters
        case executable   // real type is an app / program disguised as media / doc
        case mismatch     // media extension conflicts with a different media MIME
    }

    public struct Result {
        public let suspicious: Bool
        public let reason: Reason
        /// Filename with bidi/control characters stripped — always safe to render.
        public let safeName: String
        /// Short technical token describing what the file really is, e.g. ".apk", "Windows program (.exe)".
        public let realType: String?
        /// Short technical token describing what the file claims to be, e.g. ".mp4" or "video/mp4".
        public let claimedType: String?

        fileprivate static func safe(_ safeName: String) -> Result {
            return Result(suspicious: false, reason: .none, safeName: safeName, realType: nil, claimedType: nil)
        }
    }

    private enum Category {
        case other, image, video, audio, pdf, document, archive, executable
    }

    /// - Parameters:
    ///   - fileName: the document's stored (logical) name as shown to the user; may be nil/empty.
    ///   - mimeType: the document's declared MIME type; may be nil/empty.
    ///   - fileURL: optional local file for a cheap magic-byte peek; may be nil or not-yet-downloaded.
    public static func check(fileName: String?, mimeType: String?, fileURL: URL? = nil) -> Result {
        let rawName = fileName ?? ""

        // (1) Bidi / RTL-override spoofing. Highest-signal: the very presence of these controls
        // in a filename has no legitimate purpose and is the clearest tell.
        if containsBidiControl(rawName) {
            let safe = stripBidiControls(rawName)
            let realExt = extensionOf(safe)
            return Result(suspicious: true, reason: .rtl, safeName: safe, realType: realExt.isEmpty ? nil : ".\(realExt)", claimedType: nil)
        }

        let safeName = rawName // no bidi controls present, per the check above
        let ext = extensionOf(safeName)
        let extCat = category(forExtension: ext)
        let mimeCat = category(forMime: mimeType)

        // (2a) Executable hidden behind a benign-looking MIME (classic "EvilVideo": extension
        // .apk-equivalent while the declared MIME is video/*, image/*, audio/* or PDF).
        if extCat == .executable, isBenignViewable(mimeCat) {
            return Result(suspicious: true, reason: .executable, safeName: safeName, realType: ".\(ext)", claimedType: mimeType)
        }

        // (2b) Reverse: MIME says installer/executable while the name wears a benign extension.
        if mimeCat == .executable, isBenignNamed(extCat) {
            return Result(suspicious: true, reason: .executable, safeName: safeName, realType: mimeExecToken(mimeType), claimedType: ext.isEmpty ? nil : ".\(ext)")
        }

        // (2c) Double extension: a benign extension immediately followed by an executable one,
        // e.g. "invoice.pdf.apk" or "holiday.jpg.exe". Independent of the (possibly absent) MIME.
        if extCat == .executable {
            let penultimate = penultimateExtension(safeName)
            if isBenignExt(penultimate) {
                return Result(suspicious: true, reason: .executable, safeName: safeName, realType: ".\(ext)", claimedType: ".\(penultimate)")
            }
        }

        // (2d) Optional magic-byte peek. Only escalates when the name looks like harmless media
        // but the header is an unambiguous executable (PE / ELF / Mach-O / shebang). Never lowers
        // suspicion; never throws; skips silently when the file is absent or unreadable.
        if isBenignViewable(extCat), let fileURL, let magic = executableMagicToken(fileURL) {
            return Result(suspicious: true, reason: .executable, safeName: safeName, realType: magic, claimedType: ext.isEmpty ? nil : ".\(ext)")
        }

        // (3) Narrow media-vs-media mismatch: the extension names one concrete media kind while
        // the MIME names a *different* concrete media kind (e.g. ".mp4" declared image/jpeg).
        // Restricted to IMAGE/VIDEO/AUDIO/PDF, where legitimate files reliably agree, to keep
        // false positives near zero.
        if isConcreteMedia(extCat), isConcreteMedia(mimeCat), extCat != mimeCat {
            return Result(suspicious: true, reason: .mismatch, safeName: safeName, realType: mimeType, claimedType: ".\(ext)")
        }

        return .safe(safeName)
    }

    // MARK: - Bidi / RTL handling

    /// Bidi controls abused for filename spoofing: LRM/RLM, the embeddings/overrides, the
    /// isolates, and the Arabic letter mark. None have any legitimate place in a filename.
    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F: // LRM, RLM
            return true
        case 0x202A...0x202E: // LRE, RLE, PDF, LRO, RLO
            return true
        case 0x2066...0x2069: // LRI, RLI, FSI, PDI
            return true
        case 0x061C: // ALM
            return true
        default:
            return false
        }
    }

    private static func containsBidiControl(_ s: String) -> Bool {
        return s.unicodeScalars.contains { isBidiControl($0) }
    }

    private static func stripBidiControls(_ s: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isBidiControl(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    // MARK: - Extension helpers

    private static func extensionOf(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        guard let dotRange = base.range(of: ".", options: .backwards), dotRange.upperBound < base.endIndex else {
            return ""
        }
        return String(base[dotRange.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The extension segment just before the final one, e.g. "pdf" in "invoice.pdf.apk".
    private static func penultimateExtension(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        guard let lastDot = base.range(of: ".", options: .backwards) else {
            return ""
        }
        let head = base[base.startIndex..<lastDot.lowerBound]
        guard let prevDot = head.range(of: ".", options: .backwards) else {
            return ""
        }
        return String(head[prevDot.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func isBenignExt(_ ext: String) -> Bool {
        let cat = category(forExtension: ext)
        return cat == .image || cat == .video || cat == .audio || cat == .pdf || cat == .document
    }

    private static func isBenignViewable(_ cat: Category) -> Bool {
        return cat == .image || cat == .video || cat == .audio || cat == .pdf
    }

    private static func isBenignNamed(_ cat: Category) -> Bool {
        return cat == .image || cat == .video || cat == .audio || cat == .pdf || cat == .document
    }

    private static func isConcreteMedia(_ cat: Category) -> Bool {
        return cat == .image || cat == .video || cat == .audio || cat == .pdf
    }

    private static func category(forExtension ext: String) -> Category {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "tiff", "tif", "ico", "svg":
            return .image
        case "mp4", "mkv", "mov", "avi", "webm", "3gp", "m4v", "flv", "wmv", "mpeg", "mpg", "ts":
            return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "amr", "wma":
            return .audio
        case "pdf":
            return .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "csv", "epub":
            return .document
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .archive
        case "apk", "xapk", "apks", "aab",
             "exe", "scr", "msi", "bat", "cmd", "com",
             "js", "jse", "vbs", "vbe", "wsf", "wsh",
             "ps1", "psm1", "jar", "sh", "bin", "dex",
             "deb", "dmg", "pkg", "app", "run", "hta",
             "cpl", "dll", "so", "elf":
            return .executable
        default:
            return .other
        }
    }

    private static func category(forMime mime: String?) -> Category {
        guard let mime else {
            return .other
        }
        let m = mime.trimmingCharacters(in: .whitespaces).lowercased()
        if m.isEmpty {
            return .other
        }
        switch m {
        case "application/vnd.android.package-archive",
             "application/x-msdownload", "application/x-msdos-program", "application/x-ms-installer",
             "application/x-dosexec", "application/vnd.microsoft.portable-executable",
             "application/x-executable", "application/x-elf", "application/x-sharedlib",
             "application/x-mach-binary", "application/java-archive", "application/x-java-archive",
             "text/javascript", "application/javascript", "application/x-javascript",
             "application/x-sh", "application/x-shellscript", "application/x-bat",
             "application/bat", "application/x-msi":
            return .executable
        case "application/pdf":
            return .pdf
        case "application/msword", "application/rtf", "text/rtf", "application/epub+zip":
            return .document
        case "application/zip", "application/x-zip-compressed", "application/x-rar-compressed",
             "application/vnd.rar", "application/x-7z-compressed", "application/x-tar",
             "application/gzip", "application/x-gzip":
            return .archive
        case "application/ogg":
            return .audio
        default:
            break
        }
        if m.hasPrefix("image/") { return .image }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        if m.hasPrefix("text/") { return .document }
        if m.hasPrefix("application/vnd.openxmlformats-officedocument")
            || m.hasPrefix("application/vnd.ms-")
            || m.hasPrefix("application/vnd.oasis.opendocument") {
            return .document
        }
        return .other
    }

    /// Short, human-recognizable token for an executable/installer MIME type.
    private static func mimeExecToken(_ mime: String?) -> String {
        guard let mime else {
            return "app / program"
        }
        switch mime.trimmingCharacters(in: .whitespaces).lowercased() {
        case "application/vnd.android.package-archive":
            return "Android app (.apk)"
        case "application/x-msdownload", "application/x-msdos-program", "application/x-dosexec",
             "application/vnd.microsoft.portable-executable":
            return "Windows program (.exe)"
        case "application/x-ms-installer", "application/x-msi":
            return "Windows installer (.msi)"
        case "application/java-archive", "application/x-java-archive":
            return "Java program (.jar)"
        case "text/javascript", "application/javascript", "application/x-javascript":
            return "script (.js)"
        case "application/x-sh", "application/x-shellscript":
            return "shell script (.sh)"
        default:
            return "app / program"
        }
    }

    // MARK: - Optional magic-byte peek (cheap, fail-open)

    /// Returns a token if `fileURL`'s first bytes are an unambiguous executable format (Windows
    /// PE, ELF, Mach-O, or a shell shebang); otherwise nil. Deliberately ignores ambiguous
    /// containers such as ZIP (docx/xlsx/jar/epub all share "PK"). Reads at most 8 bytes and
    /// swallows every error — this must never throw into the caller.
    private static func executableMagicToken(_ fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        let head: Data
        if #available(iOS 13.4, *) {
            guard let h = try? handle.read(upToCount: 8) else {
                return nil
            }
            head = h
        } else {
            head = handle.readData(ofLength: 8)
        }
        guard head.count >= 4 else {
            return nil
        }
        let b0 = head[head.startIndex], b1 = head[head.startIndex + 1]
        let b2 = head[head.startIndex + 2], b3 = head[head.startIndex + 3]
        // ELF: 0x7F 'E' 'L' 'F'
        if b0 == 0x7F, b1 == 0x45, b2 == 0x4C, b3 == 0x46 {
            return "native program (ELF)"
        }
        // Windows PE: "MZ"
        if b0 == 0x4D, b1 == 0x5A {
            return "Windows program (.exe)"
        }
        // Mach-O (32/64-bit, either endianness) — iOS/macOS's own native-executable magic,
        // the closest analogue of Android's DEX check for "this is secretly a program".
        let machOMagics: Set<[UInt8]> = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], // fat/universal binary
        ]
        if machOMagics.contains([b0, b1, b2, b3]) {
            return "native program (Mach-O)"
        }
        // Shell/script shebang: "#!"
        if b0 == 0x23, b1 == 0x21 {
            return "script"
        }
        return nil
    }
}
