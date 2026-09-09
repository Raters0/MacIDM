import CryptoKit
import Foundation

public enum DownloadSourceKind: String, Codable, Sendable {
    case http
    case hls
    case dash
}

/// Selects the component that obtains the media bytes. Most downloads use the
/// native HTTP/HLS/DASH engine; a small number of site-specific protocols need
/// a dedicated extractor process.
public enum DownloadBackend: String, Codable, Sendable {
    case native
    case youtubeExtractor
}

public struct DownloadRequest: Sendable {
    public let url: URL
    public let destination: URL
    public let sourceKind: DownloadSourceKind
    public let maximumParallelRequests: Int
    public let expectedSHA256: String?
    public let taskID: UUID
    public let requestContext: DownloadRequestContext?
    public let rateLimiter: (any DownloadRateLimiting)?
    /// Optional audio track for a transient DASH pair. It is intentionally
    /// not Codable and is only supplied by an authenticated browser/App flow.
    public let pairAudioURL: URL?
    public let pairCID: String?
    public let backend: DownloadBackend

    public init(
        url: URL,
        destination: URL,
        sourceKind: DownloadSourceKind = .http,
        maximumParallelRequests: Int = 8,
        expectedSHA256: String? = nil,
        taskID: UUID = UUID(),
        requestContext: DownloadRequestContext? = nil,
        rateLimiter: (any DownloadRateLimiting)? = nil,
        pairAudioURL: URL? = nil,
        pairCID: String? = nil,
        backend: DownloadBackend = .native
    ) {
        self.url = url
        self.destination = destination
        self.sourceKind = sourceKind
        self.maximumParallelRequests = maximumParallelRequests
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.taskID = taskID
        self.requestContext = requestContext
        self.rateLimiter = rateLimiter
        self.pairAudioURL = pairAudioURL
        self.pairCID = pairCID
        self.backend = backend
    }
}

/// Transient HTTP material supplied by an explicitly authorized browser profile.
///
/// This value is deliberately not Codable so callers cannot accidentally include
/// it in task persistence or sidecars.
public struct DownloadRequestContext: Sendable, Equatable {
    public let cookie: String?
    public let referer: String?
    public let userAgent: String?

    public init(cookie: String? = nil, referer: String? = nil, userAgent: String? = nil) {
        self.cookie = cookie
        self.referer = referer
        self.userAgent = userAgent
    }

    public func apply(to request: inout URLRequest, boundTo originalURL: URL) {
        let sameOrigin = request.url?.httpOrigin == originalURL.httpOrigin
        let isHTTPSDowngrade =
            originalURL.scheme?.lowercased() == "https"
            && request.url?.scheme?.lowercased() == "http"
        // Cookies are sensitive credentials: only send same-origin.
        if sameOrigin, let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        // Referer/UA are not sensitive and media CDNs (bilibili, YouTube)
        // require them cross-origin to avoid 403. The Referer here is the
        // explicitly declared page referrer from the request context — we
        // never synthesize one — so it is safe to send across origins, except
        // when a secure page would be disclosed to an HTTP destination.
        if !isHTTPSDowngrade, let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            // Browser media requests also carry the page origin when the
            // bytes come from another host. YouTube's signed googlevideo
            // endpoints use it to distinguish the player request from a
            // bare server-side fetch. The origin is derived only from the
            // explicitly supplied referrer; it is not synthesized from the
            // media URL and contains no credentials.
            if request.url?.httpOrigin != originalURL.httpOrigin,
                let refererURL = URL(string: referer),
                let origin = webOrigin(refererURL)
            {
                request.setValue(origin, forHTTPHeaderField: "Origin")
            }
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }

        // YouTube's signed googlevideo endpoints distinguish a browser media
        // request from a generic server-side fetch. Keep this narrowly scoped
        // to that CDN family so ordinary HTTP downloads do not receive
        // browser-only fetch metadata.
        if isGoogleVideoHost(request.url?.host) {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("video", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        }
    }
}

extension URL {
    var httpOrigin: String? {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return nil }
        let normalizedPort = port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(normalizedPort)"
    }
}

private func webOrigin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(),
        (scheme == "http" || scheme == "https"),
        let host = url.host?.lowercased()
    else { return nil }
    let defaultPort = scheme == "https" ? 443 : 80
    let portSuffix = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(portSuffix)"
}

private func isGoogleVideoHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
}

public struct ResourceIdentity: Codable, Hashable, Sendable {
    public let effectiveURL: String
    public let totalSize: Int64
    public let strongETag: String
    public let contentEncoding: String
    public let generation: Int

    public init(
        effectiveURL: String,
        totalSize: Int64,
        strongETag: String,
        contentEncoding: String,
        generation: Int = 1
    ) {
        self.effectiveURL = effectiveURL
        self.totalSize = totalSize
        self.strongETag = strongETag
        self.contentEncoding = contentEncoding
        self.generation = generation
    }
}

/// Opaque identity of the complete resource URL. Query parameters can select
/// different resources; strong validators are not unique across resources.
/// The digest keeps signed URLs out of persisted checkpoint metadata.
func resourceLocatorString(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    components?.user = nil
    components?.password = nil
    let canonical = components?.string ?? url.absoluteString
    return "sha256:" + SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct ResourceInfo: Sendable {
    public let finalURL: URL
    public let size: Int64?
    public let supportsRange: Bool
    public let mimeType: String?
    public let suggestedFilename: String?
    public let strongETag: String?
    public let lastModified: String?
    public let contentEncoding: String

    public init(
        finalURL: URL,
        size: Int64?,
        supportsRange: Bool,
        mimeType: String? = nil,
        suggestedFilename: String? = nil,
        strongETag: String? = nil,
        lastModified: String? = nil,
        contentEncoding: String = "identity"
    ) {
        self.finalURL = finalURL
        self.size = size
        self.supportsRange = supportsRange
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
        self.strongETag = strongETag
        self.lastModified = lastModified
        self.contentEncoding = contentEncoding
    }

    public var identity: ResourceIdentity? {
        guard supportsRange, let size, let strongETag else { return nil }
        return ResourceIdentity(
            effectiveURL: resourceLocatorString(finalURL),
            totalSize: size,
            strongETag: strongETag,
            contentEncoding: contentEncoding
        )
    }
}

public struct ByteRange: Codable, Hashable, Sendable {
    public let start: Int64
    public let endExclusive: Int64

    public init(start: Int64, endExclusive: Int64) {
        self.start = start
        self.endExclusive = endExclusive
    }

    public var count: Int64 { endExclusive - start }
}

public struct DownloadUnit: Codable, Hashable, Sendable {
    public let index: Int
    public let range: ByteRange
}

public struct DownloadPlan: Sendable {
    public let units: [DownloadUnit]
}

public struct DownloadSegmentProgress: Hashable, Sendable {
    public let index: Int
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(index: Int, receivedBytes: Int64, totalBytes: Int64?) {
        self.index = index
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

public struct DownloadProgress: Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let segments: [DownloadSegmentProgress]
    public let speed: Double?
    /// Optional stage-aware overall fraction supplied by multi-phase
    /// downloaders. Byte totals remain authoritative for size display, while
    /// this value prevents a completed subresource from masquerading as the
    /// completion of the whole task.
    public let overallFraction: Double?

    public init(
        receivedBytes: Int64,
        totalBytes: Int64?,
        segments: [DownloadSegmentProgress] = [],
        speed: Double? = nil,
        overallFraction: Double? = nil
    ) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.segments = segments
        self.speed = speed
        self.overallFraction = overallFraction
    }
}

public struct DownloadResult: Sendable {
    public let destination: URL
    public let byteCount: Int64
    public let sha256: String?
    public let usedParallelRequests: Int
    public let resumed: Bool
    public let verification: String

    public init(
        destination: URL,
        byteCount: Int64,
        sha256: String? = nil,
        usedParallelRequests: Int,
        resumed: Bool,
        verification: String
    ) {
        self.destination = destination
        self.byteCount = byteCount
        self.sha256 = sha256
        self.usedParallelRequests = usedParallelRequests
        self.resumed = resumed
        self.verification = verification
    }
}

public enum DownloadControl: Sendable {
    case `continue`
    case pause
    case cancel
}

public protocol DownloadProtocolHandler: Sendable {
    var identifier: String { get }
    func supports(_ request: DownloadRequest) -> Bool
    func probe(_ request: DownloadRequest) async throws -> ResourceInfo
    func makePlan(_ info: ResourceInfo, parallelRequests: Int) throws -> DownloadPlan
}

public struct DownloadProtocolRouter: Sendable {
    private let handlers: [any DownloadProtocolHandler]

    public init(handlers: [any DownloadProtocolHandler] = [HTTPHandler()]) {
        self.handlers = handlers
    }

    public func handler(for request: DownloadRequest) throws -> any DownloadProtocolHandler {
        guard let handler = handlers.first(where: { $0.supports(request) }) else {
            throw IDMError.unsupportedScheme
        }
        return handler
    }

    public var identifiers: [String] {
        handlers.map(\.identifier)
    }
}
