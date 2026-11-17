import Foundation

// LuminaGram: short-link resolution for the link-safety sheet (LuminaLinkSafetyHook.swift in
// submodules/TelegramUI/Sources/Lumina). When the user taps a link whose host is a known URL shortener
// (`LuminaLinkSafety.urlShorteners`), the sheet asks that short-link service once where the link
// leads, so it can show the real address instead of the shortener's own.
//
// What is sent, and to whom: only requests to hosts on the shortener list, never to the final
// destination (resolution stops at the first address whose host is not a shortener). Each request is
// a HEAD over https (a GET of at most 64 KB when HEAD names no destination), through an ephemeral URLSession that
// keeps no cookies, cache or credentials, follows no redirect by itself, and sends a generic
// User-Agent and no Referer. Nothing about the link is logged.
//
// Pure Foundation, so it type-checks on its own (see the note in LuminaLocalization.swift).

public enum LuminaShortLink {
    /// Redirects followed at most; a link still on a shortener after that many is shown as unresolved.
    public static let maxRedirects = 5
    /// One request's time limit.
    public static let requestTimeout: TimeInterval = 5.0
    /// The whole resolution's time limit.
    public static let totalTimeout: TimeInterval = 12.0
    /// Most of a GET reply's body that is read (for a `<meta http-equiv="refresh">`).
    public static let maxBodyBytes = 64 * 1024
    /// Generic and not a browser's: shorteners answer a browser with a script page instead of a redirect.
    public static let userAgent = "LinkResolver/1.0"
    /// Longest address the sheet shows in its text (the edit field always holds all of it), as upstream's
    /// "Open this link?" prompt shortens it.
    public static let maxDisplayLength = 180

    /// The address to resolve when `link`, a link as tapped, is a short link: an http(s) address whose
    /// host is on `LuminaLinkSafety.urlShorteners`. A link written without a scheme ("t.co/abc") is
    /// read as https (see `requestUrl`). Nil for any other link.
    public static func shortLinkUrl(fromLinkString link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        var candidate: URL?
        if let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                candidate = parsed
            }
        } else if !trimmed.contains("://") && !trimmed.contains(":") {
            candidate = URL(string: "https://" + trimmed)
        }
        guard let url = candidate, let host = url.host, !host.isEmpty, LuminaLinkSafety.isKnownShortenerHost(host) else {
            return nil
        }
        return url
    }

    /// `text`, typed into the sheet's address field, as an address the sheet may open: only an
    /// absolute http or https address with a host. Nil for anything else.
    public static func openableEditedUrl(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// What a resolution request asks for: `url` without its login part (which would otherwise turn into
    /// an Authorization header) and fragment, and over https when its host is a listed shortener. Every
    /// listed shortener serves https, a browser is sent there anyway (HSTS), and some answer plain http
    /// with an error page instead of the redirect (t.co: HTTP 520).
    static func requestUrl(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let upgradesScheme = components.scheme?.lowercased() == "http" && components.host.map(LuminaLinkSafety.isKnownShortenerHost) == true
        if components.user == nil && components.password == nil && components.fragment == nil && !upgradesScheme {
            return url
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if upgradesScheme {
            components.scheme = "https"
            if components.port == 80 {
                components.port = nil
            }
        }
        return components.url ?? url
    }

    /// Every character that may appear in a URL unencoded, for addresses that `URL(string:)` rejects as given.
    private static let urlCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    /// The absolute address a redirect target (a Location header or a refresh URL) names, read against `base`.
    static func redirectTarget(_ value: String, base: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if let url = URL(string: trimmed, relativeTo: base) {
            return url.absoluteURL
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: urlCharacters), let url = URL(string: encoded, relativeTo: base) {
            return url.absoluteURL
        }
        return nil
    }

    // MARK: - <meta http-equiv="refresh">

    /// The URL of the first `<meta http-equiv="refresh" content="N; url=...">` in `html`, as written
    /// (possibly relative). Nil when there is none or it names no URL.
    public static func metaRefreshTarget(inHTML html: String) -> String? {
        guard let tagExpression = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else {
            return nil
        }
        let nsHtml = html as NSString
        for match in tagExpression.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length)) {
            let tag = nsHtml.substring(with: match.range)
            guard let equiv = attributeValue(named: "http-equiv", inTag: tag), equiv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh" else {
                continue
            }
            guard let content = attributeValue(named: "content", inTag: tag), let target = refreshUrl(fromContent: content) else {
                continue
            }
            return target
        }
        return nil
    }

    /// The value of attribute `name` in `tag` (quoted with " or ', or bare), with the common HTML
    /// entities decoded.
    static func attributeValue(named name: String, inTag tag: String) -> String? {
        let pattern = "(?:^|[\\s\"'/])" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsTag = tag as NSString
        guard let match = expression.firstMatch(in: tag, options: [], range: NSRange(location: 0, length: nsTag.length)) else {
            return nil
        }
        for group in 1 ... 3 {
            let range = match.range(at: group)
            if range.location != NSNotFound {
                return decodeHtmlEntities(nsTag.substring(with: range))
            }
        }
        return nil
    }

    /// The URL in a refresh `content` value: "0;URL=https://a", "0; url='https://a'", "5, https://a".
    static func refreshUrl(fromContent content: String) -> String? {
        var rest = Substring(content.trimmingCharacters(in: .whitespacesAndNewlines))
        // The delay.
        while let first = rest.first, first.isASCII, first.isNumber || first == "." {
            rest = rest.dropFirst()
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let separator = rest.first, separator == ";" || separator == "," else {
            return nil
        }
        rest = Substring(rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.lowercased().hasPrefix("url") {
            let afterName = rest.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            if afterName.hasPrefix("=") {
                rest = Substring(afterName.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            if let end = rest.firstIndex(of: quote) {
                rest = rest[..<end]
            }
        }
        let value = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func decodeHtmlEntities(_ value: String) -> String {
        if !value.contains("&") {
            return value
        }
        var result = value
        for (entity, replacement) in [("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#x2F;", "/"), ("&#x2f;", "/"), ("&#47;", "/")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Last, so that "&amp;quot;" stays "&quot;".
        result = result.replacingOccurrences(of: "&#38;", with: "&")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    // MARK: - Display

    /// Second-level labels under which a country-code domain registers names ("example.co.uk",
    /// "example.com.cn"). A small stand-in for the public suffix list, which iOS does not provide.
    private static let countryCodeSecondLevels: Set<String> = [
        "ac", "co", "com", "edu", "go", "gob", "gov", "idv", "ltd", "mil", "ne", "net", "nom", "or", "org", "plc", "sch",
    ]

    /// The registrable part of `host` ("apprcn.com" for "appstore.apprcn.com", "example.co.uk" for
    /// "www.example.co.uk"). An IP address is returned whole.
    public static func registrableDomain(ofHost host: String) -> String {
        var value = host.lowercased()
        if value.hasSuffix(".") {
            value.removeLast()
        }
        if value.contains(":") || value.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }) {
            return value
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.count <= 2 {
            return value
        }
        let topLevel = labels[labels.count - 1]
        let secondLevel = labels[labels.count - 2]
        if topLevel.count == 2 && countryCodeSecondLevels.contains(secondLevel) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Bidirectional controls, which could make an address read differently from what it is.
    private static let bidiControls = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    /// `url` as the sheet shows it, without bidirectional controls and shortened past
    /// `maxDisplayLength`, plus the UTF-16 range of its registrable domain (to emphasise), when shown.
    public static func displayText(for url: URL) -> (text: String, domainRange: NSRange?) {
        var text = String(url.absoluteString.unicodeScalars.filter { !bidiControls.contains($0) })
        var domainRange: NSRange?
        if let host = url.host, !host.isEmpty, let schemeEnd = text.range(of: "://") {
            let authorityEnd = text[schemeEnd.upperBound...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
            let authority = schemeEnd.upperBound ..< authorityEnd
            // The host follows any login part, so the last match in the authority is the host.
            if let hostRange = text.range(of: host, options: [.caseInsensitive, .backwards], range: authority) {
                let domain = registrableDomain(ofHost: host)
                if let range = text.range(of: domain, options: [.caseInsensitive, .backwards, .anchored], range: hostRange) {
                    domainRange = NSRange(range, in: text)
                }
            }
        }
        if text.count > maxDisplayLength {
            text = String(text.prefix(maxDisplayLength - 1)) + "\u{2026}"
            if let range = domainRange, range.location + range.length > (text as NSString).length - 1 {
                domainRange = nil
            }
        }
        return (text, domainRange)
    }
}

/// Resolves one short link: asks the short-link service where it leads, hop by hop, without following any
/// redirect by itself. See the notes at the top of this file. `start` returns at once; the outcome is
/// delivered on the main queue, once, unless `cancel()` came first.
public final class LuminaShortLinkResolver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Failure: Equatable {
        case timeout
        case network
        case tooManyRedirects
        case unsupportedScheme
        case invalidAddress
        case noDestination
        case httpStatus(Int)

        /// A short reason for the sheet.
        public var text: String {
            switch self {
            case .timeout:
                return LuminaL10n.tr("The short-link service did not answer in time.")
            case .network:
                return LuminaL10n.tr("Could not reach the short-link service.")
            case .tooManyRedirects:
                return LuminaL10n.tr("The link redirects too many times.")
            case .unsupportedScheme:
                return LuminaL10n.tr("The link leads to an address that is not a web link.")
            case .invalidAddress:
                return LuminaL10n.tr("The short-link service returned an invalid address.")
            case .noDestination:
                return LuminaL10n.tr("The short-link service did not reveal where the link leads.")
            case let .httpStatus(code):
                return LuminaL10n.tr("The short-link service answered with an error (HTTP %@).").replacingOccurrences(of: "%@", with: "\(code)")
            }
        }
    }

    public enum Outcome: Equatable {
        /// The first address off the shortener list, and how many redirects led there.
        case resolved(URL, redirects: Int)
        case failed(Failure)
    }

    // Everything below is used on `queue` only (the session's delegate queue runs on it as well).
    private let queue = DispatchQueue(label: "LuminaShortLinkResolver")
    private let delegateQueue = OperationQueue()
    private var session: URLSession?
    private var completion: ((Outcome) -> Void)?
    private var current: URL
    private var redirects = 0
    private var startTime: CFAbsoluteTime = 0.0
    private var task: URLSessionDataTask?
    private var isGet = false
    private var body = Data()
    private var bodyLimitReached = false
    private var isFinished = false

    private init(url: URL, completion: @escaping (Outcome) -> Void) {
        self.current = LuminaShortLink.requestUrl(url)
        self.completion = completion
        super.init()
        self.delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue.underlyingQueue = self.queue
    }

    /// Starts resolving `url` (see `LuminaShortLink.shortLinkUrl`).
    public static func start(url: URL, completion: @escaping (Outcome) -> Void) -> LuminaShortLinkResolver {
        let resolver = LuminaShortLinkResolver(url: url, completion: completion)
        resolver.queue.async {
            resolver.begin()
        }
        return resolver
    }

    /// Stops resolving; the completion is not called after this.
    public func cancel() {
        self.queue.async {
            self.finish(nil)
        }
    }

    private func begin() {
        if self.isFinished {
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = LuminaShortLink.requestTimeout
        configuration.timeoutIntervalForResource = LuminaShortLink.requestTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: self.delegateQueue)
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.queue.asyncAfter(deadline: .now() + LuminaShortLink.totalTimeout) { [weak self] in
            self?.finish(.failed(.timeout))
        }
        self.requestCurrent()
    }

    private func requestCurrent() {
        guard !self.isFinished, let session = self.session else {
            return
        }
        let remaining = LuminaShortLink.totalTimeout - (CFAbsoluteTimeGetCurrent() - self.startTime)
        if remaining <= 0.0 {
            self.finish(.failed(.timeout))
            return
        }
        var request = URLRequest(url: self.current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(LuminaShortLink.requestTimeout, remaining))
        request.httpMethod = self.isGet ? "GET" : "HEAD"
        request.httpShouldHandleCookies = false
        request.setValue(LuminaShortLink.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        self.body = Data()
        self.bodyLimitReached = false
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    private func handle(response: HTTPURLResponse) {
        let status = response.statusCode
        if (300 ..< 400).contains(status), let location = response.value(forHTTPHeaderField: "Location") {
            self.advance(to: location)
            return
        }
        if !self.isGet {
            // HEAD named no destination (405, 400, 200, ...): ask again with GET.
            self.isGet = true
            self.requestCurrent()
            return
        }
        if (200 ..< 300).contains(status), let target = LuminaShortLink.metaRefreshTarget(inHTML: String(decoding: self.body, as: UTF8.self)) {
            self.advance(to: target)
            return
        }
        if status >= 400 {
            self.finish(.failed(.httpStatus(status)))
        } else {
            self.finish(.failed(.noDestination))
        }
    }

    private func advance(to target: String) {
        guard let next = LuminaShortLink.redirectTarget(target, base: self.current) else {
            self.finish(.failed(.invalidAddress))
            return
        }
        guard let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            self.finish(.failed(.unsupportedScheme))
            return
        }
        guard let host = next.host, !host.isEmpty else {
            self.finish(.failed(.invalidAddress))
            return
        }
        self.redirects += 1
        if !LuminaLinkSafety.isKnownShortenerHost(host) {
            self.finish(.resolved(next, redirects: self.redirects))
            return
        }
        if self.redirects >= LuminaShortLink.maxRedirects {
            self.finish(.failed(.tooManyRedirects))
            return
        }
        self.current = LuminaShortLink.requestUrl(next)
        self.isGet = false
        self.requestCurrent()
    }

    private func finish(_ outcome: Outcome?) {
        if self.isFinished {
            return
        }
        self.isFinished = true
        self.task?.cancel()
        self.task = nil
        // Releases the session's hold on its delegate (this object).
        self.session?.invalidateAndCancel()
        self.session = nil
        self.body = Data()
        let completion = self.completion
        self.completion = nil
        if let outcome, let completion {
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // nil = do not follow: the task completes with the 3xx response, whose Location is read in handle(response:).
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === self.task, !self.bodyLimitReached else {
            return
        }
        let room = LuminaShortLink.maxBodyBytes - self.body.count
        if data.count >= room {
            self.body.append(data.prefix(room))
            self.bodyLimitReached = true
            dataTask.cancel()
        } else {
            self.body.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, !self.isFinished else {
            return
        }
        self.task = nil
        if let error = error as NSError?, !(self.bodyLimitReached && error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                self.finish(.failed(.timeout))
            } else {
                self.finish(.failed(.network))
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            self.finish(.failed(.network))
            return
        }
        self.handle(response: response)
    }
}
