import Foundation
import IDMEngine

struct WebPageMediaCandidate: Equatable, Sendable {
    let url: URL
    let sourceKind: DownloadSourceKind
    let filenameHint: String
    let label: String
}

struct WebPageMediaDiscovery: Sendable {
    let pageURL: URL
    let title: String?
    let candidates: [WebPageMediaCandidate]
}

protocol WebPageMediaDiscovering: Sendable {
    func discover(
        url: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> WebPageMediaDiscovery
}

enum WebPageMediaDiscoveryError: LocalizedError, Equatable {
    case invalidPage
    case pageTooLarge
    case noCandidates
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPage: String(localized: "网页响应不是可读取的 HTML。")
        case .pageTooLarge: String(localized: "网页超过安全读取上限，未继续解析。")
        case .noCandidates: String(localized: "网页中没有发现可直接下载的媒体地址。")
        case .httpStatus(let status):
            String(localized: "网页返回 HTTP \(status)，暂时无法嗅探。")
        }
    }
}

struct URLSessionWebPageMediaDiscoverer: WebPageMediaDiscovering {
    private let maximumHTMLBytes = 8 * 1024 * 1024

    func discover(
        url: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> WebPageMediaDiscovery {
        guard let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else { throw WebPageMediaDiscoveryError.invalidPage }

        let fetched = try await WebPageFetchOperation(
            url: url,
            requestContext: requestContext,
            maximumHTMLBytes: maximumHTMLBytes
        ).run()
        guard let html = String(data: fetched.data, encoding: .utf8) else {
            throw WebPageMediaDiscoveryError.invalidPage
        }

        let pageURL = fetched.finalURL
        let title = Self.pageTitle(in: html)
        let candidates = Self.extractCandidates(from: html, baseURL: pageURL, title: title)
        guard !candidates.isEmpty else { throw WebPageMediaDiscoveryError.noCandidates }
        return WebPageMediaDiscovery(pageURL: pageURL, title: title, candidates: candidates)
    }

    private static func extractCandidates(
        from html: String,
        baseURL: URL,
        title: String?
    ) -> [WebPageMediaCandidate] {
        let mediaPattern =
            #"\.(?:m3u8|mpd|mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mp2t|mkv|avi|wmv|flv|opus|wav)(?:$|[?#])"#
        let tagPattern = #"(?is)(<(?:video|audio|source)\b[^>]*>)"#
        let quotedPattern = #"(?is)[\"']([^\"']{1,8192})[\"']"#
        let values =
            matches(tagPattern, in: html).flatMap { tag in
                matches(quotedPattern, in: tag)
            } + matches(quotedPattern, in: html)

        var seen = Set<URL>()
        var labelCounts: [String: Int] = [:]
        var result: [WebPageMediaCandidate] = []
        for raw in values {
            let value = decodeHTML(raw)
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\u0026", with: "&")
            guard value.range(of: mediaPattern, options: .regularExpression) != nil,
                let candidateURL = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                let scheme = candidateURL.scheme?.lowercased(),
                (scheme == "http" || scheme == "https"),
                candidateURL.host != nil,
                candidateURL.user == nil,
                candidateURL.password == nil,
                seen.insert(candidateURL).inserted
            else { continue }
            let sourceKind = sourceKind(for: candidateURL)
            let filename = filename(for: candidateURL, title: title, sourceKind: sourceKind)
            let labelBase = label(for: candidateURL, sourceKind: sourceKind)
            let occurrence = labelCounts[labelBase, default: 0] + 1
            labelCounts[labelBase] = occurrence
            result.append(
                WebPageMediaCandidate(
                    url: candidateURL,
                    sourceKind: sourceKind,
                    filenameHint: filename,
                    label: occurrence == 1 ? labelBase : "\(labelBase) #\(occurrence)"
                )
            )
            if result.count == 50 { break }
        }
        return result
    }

    private static func pageTitle(in html: String) -> String? {
        let pattern = #"(?is)<title\b[^>]*>(.*?)</title>"#
        guard let raw = matches(pattern, in: html).first else { return nil }
        let title = decodeHTML(raw).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(180))
    }

    private static func sourceKind(for url: URL) -> DownloadSourceKind {
        switch url.pathExtension.lowercased() {
        case "m3u8": return .hls
        case "mpd": return .dash
        default: return .http
        }
    }

    /// Video/audio container extensions whose original URL suffix is kept for
    /// HTTP direct downloads instead of defaulting to .mp4. Kept in sync with
    /// `NewDownloadView.recognizedMediaExtensions`.
    private static let recognizedMediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "wmv", "ts", "m4s",
        "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "mpg", "mpeg",
        "m2ts", "vob", "3gp", "ogv",
    ]

    private static func filename(
        for url: URL,
        title: String?,
        sourceKind: DownloadSourceKind
    ) -> String {
        let decodedPathName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
        let pathName = decodedPathName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = title
        } else if let pathName,
            !pathName.isEmpty,
            !["download", "media", "video", "audio"].contains(pathName.lowercased())
        {
            base = pathName
        } else {
            base = "media"
        }
        let extensionName: String
        switch sourceKind {
        case .hls, .dash: extensionName = "mp4"
        case .http:
            let lowered = url.pathExtension.lowercased()
            extensionName = recognizedMediaExtensions.contains(lowered) ? lowered : "mp4"
        }
        let safe = InputValidator.safeFilename(base)
        return safe.lowercased().hasSuffix("." + extensionName) ? safe : safe + "." + extensionName
    }

    private static func label(for url: URL, sourceKind: DownloadSourceKind) -> String {
        let pathName =
            url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? ""
        let trimmed = pathName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
            !["download", "media", "video", "audio"].contains(trimmed.lowercased())
        {
            return InputValidator.safeFilename(trimmed)
        }
        return sourceKind == .http ? String(localized: "媒体资源") : sourceKind.rawValue.uppercased()
    }

    private static func matches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: value)
            else { return nil }
            return String(value[valueRange])
        }
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private struct WebPageFetchResult: Sendable {
    let data: Data
    let finalURL: URL
}

private final class WebPageFetchOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let requestContext: DownloadRequestContext?
    private let maximumHTMLBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebPageFetchResult, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var redirects = 0
    private var terminalError: Error?

    init(url: URL, requestContext: DownloadRequestContext?, maximumHTMLBytes: Int) {
        self.url = url
        self.requestContext = requestContext
        self.maximumHTMLBytes = maximumHTMLBytes
    }

    func run() async throws -> WebPageFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(
                "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            requestContext?.apply(to: &request, boundTo: url)
            // Page-discovery requests do not inject the download proxy (preserves existing
            // configuration semantics; ordinary page sniffing must not be forced through it)
            let configuration = EngineSessionPolicy.makeConfiguration(
                requestTimeout: 15,
                resourceTimeout: 30,
                proxyDictionary: nil
            )
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            lock.lock()
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        guard redirects <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            terminalError = WebPageMediaDiscoveryError.invalidPage
            completionHandler(nil)
            task.cancel()
            return
        }
        var safe = request
        let crossOrigin = webPageHTTPOrigin(response.url) != webPageHTTPOrigin(request.url)
        EngineSessionPolicy.sanitizeRedirectRequest(
            &safe,
            originalURL: response.url,
            targetURL: request.url,
            preserveReferer: false
        )
        if crossOrigin {
            // Preserve only the explicitly supplied page referrer. Never let
            // URLSession synthesize a sensitive referrer on this hop.
            if let referer = requestContext?.referer {
                safe.setValue(referer, forHTTPHeaderField: "Referer")
            }
        }
        requestContext?.apply(to: &safe, boundTo: url)
        if response.url?.scheme?.lowercased() == "https" && request.url?.scheme?.lowercased() == "http" {
            safe.setValue(nil, forHTTPHeaderField: "Referer")
        }
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(safe)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            terminalError = WebPageMediaDiscoveryError.invalidPage
            completionHandler(.cancel)
            return
        }
        self.response = response
        if response.expectedContentLength > Int64(maximumHTMLBytes) {
            terminalError = WebPageMediaDiscoveryError.pageTooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard Int64(self.data.count) <= Int64(maximumHTMLBytes) - Int64(data.count) else {
            terminalError = WebPageMediaDiscoveryError.pageTooLarge
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let terminalError {
            finish(.failure(terminalError))
            return
        }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish(.failure(error))
            return
        }
        guard let response else {
            finish(.failure(WebPageMediaDiscoveryError.invalidPage))
            return
        }
        guard (200...399).contains(response.statusCode) else {
            finish(.failure(WebPageMediaDiscoveryError.httpStatus(response.statusCode)))
            return
        }
        finish(.success(WebPageFetchResult(data: data, finalURL: response.url ?? url)))
    }

    private func finish(_ result: Result<WebPageFetchResult, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private func webPageHTTPOrigin(_ url: URL?) -> String? {
    guard let url,
        let scheme = url.scheme?.lowercased(),
        let host = url.host?.lowercased(),
        scheme == "http" || scheme == "https"
    else { return nil }
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    return scheme + "://" + host + ":" + String(port)
}
