import Foundation

public struct HTTPHandler: DownloadProtocolHandler {
    private let probeRequestTimeout: TimeInterval
    private let probeResourceTimeout: TimeInterval
    private let sessionConfiguration: URLSessionConfiguration?

    public init(
        probeRequestTimeout: TimeInterval = 30,
        probeResourceTimeout: TimeInterval = 60,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.probeRequestTimeout = probeRequestTimeout
        self.probeResourceTimeout = probeResourceTimeout
        self.sessionConfiguration = sessionConfiguration
    }

    public let identifier = "http"

    public func supports(_ request: DownloadRequest) -> Bool {
        let scheme = request.url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    public func probe(_ request: DownloadRequest) async throws -> ResourceInfo {
        try Task.checkCancellation()
        try InputValidator.validate(request)
        var head = URLRequest(url: request.url)
        head.httpMethod = "HEAD"
        request.requestContext?.apply(to: &head, boundTo: request.url)
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // HEAD is advisory only. Some media CDNs (including Bilibili's
        // mcdn endpoints) return 404 for HEAD while serving the same resource
        // correctly to a ranged GET. The GET/Range response below is the
        // authoritative probe and will still reject an actually unavailable
        // resource.
        let headResponse: HTTPURLResponse?
        do {
            headResponse = try await HTTPProbe.perform(
                head,
                requestTimeout: probeRequestTimeout,
                resourceTimeout: probeResourceTimeout,
                sessionConfiguration: sessionConfiguration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch IDMError.cancelled {
            throw IDMError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            headResponse = nil
        }
        try Task.checkCancellation()

        var range = URLRequest(url: headResponse?.url ?? request.url)
        range.httpMethod = "GET"
        request.requestContext?.apply(to: &range, boundTo: request.url)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        range.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var rangeResponse = try await HTTPProbe.perform(
            range,
            requestTimeout: probeRequestTimeout,
            resourceTimeout: probeResourceTimeout,
            sessionConfiguration: sessionConfiguration
        )
        try Task.checkCancellation()

        // Some signed media CDNs reject a one-byte range probe while allowing
        // the same URL as a normal GET. Probe that fallback using a delegate
        // that cancels immediately after response headers; this never pulls a
        // media body into memory, and the final transfer still validates the
        // response before writing any bytes.
        if rangeResponse.statusCode == 403 {
            var unbounded = URLRequest(url: rangeResponse.url ?? request.url)
            unbounded.httpMethod = "GET"
            request.requestContext?.apply(to: &unbounded, boundTo: request.url)
            unbounded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            do {
                if let fallbackResponse = try await HTTPProbe.perform(
                    unbounded,
                    requestTimeout: probeRequestTimeout,
                    resourceTimeout: probeResourceTimeout,
                    sessionConfiguration: sessionConfiguration
                ) as HTTPURLResponse?,
                    (200...399).contains(fallbackResponse.statusCode) || fallbackResponse.statusCode == 405
                {
                    rangeResponse = fallbackResponse
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch IDMError.cancelled {
                throw IDMError.cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                // Fallback network error is ignored
            }
            try Task.checkCancellation()
        }
        try validateProbeStatus(rangeResponse.statusCode)

        // HEAD is advisory only: many servers (including those that disallow
        // HEAD with 405) return a meaningless Content-Length on HEAD that
        // must not be trusted as the resource size. Only honor headSize when
        // HEAD returned a 2xx and the value is present.
        let headIsAuthoritative = headResponse.map { (200...299).contains($0.statusCode) } ?? false
        let headSize =
            headIsAuthoritative
            ? headResponse.flatMap { headerInt64($0, "Content-Length") }
            : nil
        let encoding = normalizedEncoding(rangeResponse.value(forHTTPHeaderField: "Content-Encoding"))
        let parsed = ContentRangeParser.parse(rangeResponse.value(forHTTPHeaderField: "Content-Range"))
        let etag = strongETag(rangeResponse.value(forHTTPHeaderField: "ETag"))
        let finalURL = rangeResponse.url ?? headResponse?.url ?? request.url
        let rangeResponseContentLength = headerInt64(rangeResponse, "Content-Length")

        let rangeIsValid = HTTPRangeResponseValidator.accepts(
            rangeResponse, start: 0, endInclusive: 0, total: headSize)

        if rangeResponse.statusCode == 401 { throw IDMError.authenticationRequired }
        if rangeResponse.statusCode == 206, parsed == nil {
            throw IDMError.invalidContentRange
        }

        // Size resolution priority:
        // 1. Valid 206 range → parsed.total (authoritative).
        // 2. 206 with a parseable Content-Range → parsed.total.
        // 3. GET 200 ignoring Range — use the GET response's own
        //    Content-Length, NOT the HEAD's. A 405-on-HEAD server often
        //    reports Content-Length: 0 on the HEAD; trusting that would
        //    publish a 0-byte "completed" file without downloading a byte.
        // 4. HEAD 2xx Content-Length as a last resort.
        // 5. nil (unknown length, single stream).
        let size: Int64?
        if rangeIsValid {
            size = parsed?.total
        } else if rangeResponse.statusCode == 206, let parsed {
            size = parsed.total
        } else if rangeResponse.statusCode == 200 {
            if let parsed {
                // A 200 that reports a Content-Range knows the resource total
                // even when it lacks a strong ETag (Bilibili's mcdn edges):
                // its own Content-Length is the slice length and must never
                // be taken as the size.
                size = parsed.total
            } else {
                // GET returned 200 ignoring Range. Trust the GET's
                // Content-Length, but only accept size==0 when the GET itself
                // explicitly said so — never inherit a 0 from a 405 HEAD.
                size = rangeResponseContentLength ?? headSize
            }
        } else if headSize != nil {
            size = headSize
        } else {
            size = nil
        }

        return ResourceInfo(
            finalURL: finalURL,
            size: size,
            supportsRange: rangeIsValid,
            mimeType: headResponse?.mimeType ?? rangeResponse.mimeType,
            suggestedFilename: headResponse?.suggestedFilename ?? rangeResponse.suggestedFilename,
            strongETag: rangeIsValid ? etag : nil,
            lastModified: headResponse?.value(forHTTPHeaderField: "Last-Modified"),
            contentEncoding: encoding
        )
    }

    public func makePlan(_ info: ResourceInfo, parallelRequests: Int) throws -> DownloadPlan {
        guard (1...64).contains(parallelRequests) else {
            throw IDMError.invalidParallelRequests
        }
        guard let size = info.size else { return DownloadPlan(units: []) }
        if size == 0 { return DownloadPlan(units: []) }
        let count = info.supportsRange ? min(Int64(parallelRequests), size) : 1
        let base = size / count
        let remainder = size % count
        var cursor: Int64 = 0
        var units: [DownloadUnit] = []
        for index in 0..<Int(count) {
            let length = base + (Int64(index) < remainder ? 1 : 0)
            units.append(
                DownloadUnit(
                    index: index,
                    range: ByteRange(start: cursor, endExclusive: cursor + length)
                ))
            cursor += length
        }
        return DownloadPlan(units: units)
    }

    private func validateProbeStatus(_ status: Int) throws {
        if status == 401 { throw IDMError.authenticationRequired }
        guard (200...399).contains(status) || status == 405 else {
            throw IDMError.httpStatus(status)
        }
    }
}

private func headerInt64(_ response: HTTPURLResponse, _ name: String) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: name), let result = Int64(value),
        result >= 0
    else { return nil }
    return result
}

func normalizedEncoding(_ value: String?) -> String {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return value.isEmpty ? "identity" : value
}

private final class HTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var isCancelled = false
    private var isFinished = false
    private var redirects = 0

    static func perform(
        _ request: URLRequest,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let probe = HTTPProbe()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                probe.start(
                    request: request,
                    requestTimeout: requestTimeout,
                    resourceTimeout: resourceTimeout,
                    sessionConfiguration: sessionConfiguration,
                    continuation: continuation
                )
            }
        } onCancel: {
            probe.cancel()
        }
    }

    func start(
        request: URLRequest,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        sessionConfiguration: URLSessionConfiguration?,
        continuation: CheckedContinuation<HTTPURLResponse, Error>
    ) {
        lock.lock()
        if isCancelled || Task.isCancelled {
            isCancelled = true
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration =
            sessionConfiguration
            ?? EngineSessionPolicy.makeConfiguration(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            )
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()

        task.resume()
    }

    func cancel() {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return
        }
        isCancelled = true
        let taskToCancel = self.task
        let sessionToInvalidate = self.session
        let continuationToResume: CheckedContinuation<HTTPURLResponse, Error>?
        if !isFinished {
            isFinished = true
            continuationToResume = self.continuation
            self.continuation = nil
        } else {
            continuationToResume = nil
        }
        lock.unlock()

        taskToCancel?.cancel()
        sessionToInvalidate?.invalidateAndCancel()
        continuationToResume?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        DownloadProxyPolicy.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirects += 1
        let count = redirects
        lock.unlock()

        guard count <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            completionHandler(nil)
            return
        }
        var safe = request
        EngineSessionPolicy.sanitizeRedirectRequest(
            &safe,
            originalURL: response.url,
            targetURL: request.url,
            preserveReferer: true
        )
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
            completionHandler(.cancel)
            finish(.failure(IDMError.invalidURL))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.cancel)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let resp = self.response
        let cancelled = self.isCancelled
        lock.unlock()

        if cancelled {
            finish(.failure(CancellationError()))
        } else if let resp {
            finish(.success(resp))
        } else if let error {
            finish(.failure(error))
        } else {
            finish(.failure(IDMError.invalidURL))
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let cont = self.continuation
        self.continuation = nil
        let sess = self.session
        lock.unlock()

        cont?.resume(with: result)
        sess?.finishTasksAndInvalidate()
    }
}
