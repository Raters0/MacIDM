import Foundation

public struct HLSFetchRequest: Sendable {
    public let url: URL
    public let byteRange: HLSByteRange?
    public let requestContext: DownloadRequestContext?
    public let contextOriginURL: URL
    public let control: (@Sendable () -> DownloadControl)?

    public init(
        url: URL,
        byteRange: HLSByteRange? = nil,
        requestContext: DownloadRequestContext? = nil,
        contextOriginURL: URL,
        control: (@Sendable () -> DownloadControl)? = nil
    ) {
        self.url = url
        self.byteRange = byteRange
        self.requestContext = requestContext
        self.contextOriginURL = contextOriginURL
        self.control = control
    }
}

public struct HLSFetchResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let statusCode: Int
    public let contentRange: ParsedContentRange?

    public init(
        data: Data,
        finalURL: URL,
        statusCode: Int = 200,
        contentRange: ParsedContentRange? = nil
    ) {
        self.data = data
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentRange = contentRange
    }
}

public struct HLSStreamToFileResult: Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let byteCount: Int64
    public let contentRange: ParsedContentRange?

    public init(
        finalURL: URL,
        statusCode: Int = 200,
        byteCount: Int64,
        contentRange: ParsedContentRange? = nil
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.byteCount = byteCount
        self.contentRange = contentRange
    }
}

public enum HLSDownloadError: Error, Equatable, Sendable {
    case mergerUnavailable
}

public protocol HLSResourceClient: Sendable {
    /// Fetches small metadata such as manifests and keys (strict safety size cap;
    /// must not be used for large media segments).
    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse

    /// Streams a media segment to disk.
    /// - Production implementations (e.g. `URLSessionHLSResourceClient`): use
    ///   `URLSessionDownloadTask` to avoid aggregating the full body in App-heap memory,
    ///   then copy and decrypt via bounded chunked I/O governed by `MediaBufferBudget`
    ///   after the terminal state to prevent memory bloat.
    /// - Default extension implementation: falls back to the in-memory `fetch` with a
    ///   safety cap (`maximumBufferedResourceBytes`), reserved for mocks and small-resource
    ///   tests.
    /// Note: underlying Foundation/URLSession network buffers are managed by the system
    /// kernel and are not accounted for in `MediaBufferBudget`.
    func streamToFile(
        _ request: HLSFetchRequest,
        to destinationURL: URL,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> HLSStreamToFileResult
}

extension HLSResourceClient {
    /// Default fallback streaming implementation (used by existing mock-compatible tests)
    public func streamToFile(
        _ request: HLSFetchRequest,
        to destinationURL: URL,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HLSStreamToFileResult {
        let response = try await fetch(request)
        guard Int64(response.data.count) <= DownloadResourceLimits.maximumBufferedResourceBytes else {
            throw IDMError.resourceTooLarge(DownloadResourceLimits.maximumBufferedResourceBytes)
        }

        var destinationCreatedBySelf = false
        var createdSink: SafeFileDescriptor? = nil
        var isSuccess = false

        defer {
            if !isSuccess {
                try? createdSink?.closeFile()
                if destinationCreatedBySelf {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }
        }

        // Create the destination file exclusively; if a same-named file already exists,
        // throw a conflict error and never delete the existing file
        let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
        createdSink = sink
        destinationCreatedBySelf = true

        let chunkSize = min(64 * 1024, max(1024, Int(budget.capacity)))
        var offset = 0

        while offset < response.data.count {
            try Task.checkCancellation()
            switch control() {
            case .continue: break
            case .pause: throw IDMError.paused
            case .cancel: throw IDMError.cancelled
            }

            let length = min(chunkSize, response.data.count - offset)
            let chunk = response.data.subdata(in: offset..<(offset + length))

            let reservation = try await budget.reserve(bytes: Int64(chunk.count))
            do {
                try sink.writeAll(chunk)
                reservation.release()
            } catch {
                reservation.release()
                throw error
            }

            offset += length
            progress?(Int64(length))
        }

        try sink.synchronize()
        try sink.closeFile()
        isSuccess = true

        return HLSStreamToFileResult(
            finalURL: response.finalURL,
            statusCode: response.statusCode,
            byteCount: Int64(response.data.count),
            contentRange: response.contentRange
        )
    }
}
