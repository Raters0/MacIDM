import Foundation

final class SynchronousCheckpointTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: SidecarPayload
    private let sidecarURL: URL
    private let sink: RandomAccessSink
    private var pendingBytes: Int64 = 0
    private var lastCheckpoint = Date()

    init(payload: SidecarPayload, sidecarURL: URL, sink: RandomAccessSink) {
        self.payload = payload
        self.sidecarURL = sidecarURL
        self.sink = sink
    }

    func record(segment index: Int, nextOffset: Int64, addedBytes: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let position = payload.segments.firstIndex(where: { $0.index == index }) else {
            throw IDMError.sidecarCorrupt
        }
        let current = payload.segments[position]
        guard nextOffset >= current.nextUncommittedOffset, nextOffset <= current.endExclusive else {
            throw IDMError.sidecarCorrupt
        }
        payload.segments[position].nextUncommittedOffset = nextOffset
        pendingBytes += addedBytes
        if pendingBytes >= 8 * 1_024 * 1_024 || Date().timeIntervalSince(lastCheckpoint) >= 5 {
            try checkpointLocked()
        }
    }

    func checkpoint(phase: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let phase { payload.phase = phase }
        try checkpointLocked()
    }

    /// Atomically commits a coordinator-driven segment split: the parent's
    /// committed range shrinks to `truncationEnd` and a synthetic child
    /// segment `[truncationEnd, parent.endExclusive)` is appended, keeping
    /// byte-range coverage intact for resume. The sidecar is flushed before
    /// returning so the split survives a crash.
    ///
    /// Returns `false` when the proposal is stale — the parent has already
    /// committed bytes at or past `truncationEnd` — so the caller can
    /// abandon the split and let the parent finish its original range.
    func applySplit(parentIndex: Int, truncationEnd: Int64, childIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let position = payload.segments.firstIndex(where: { $0.index == parentIndex })
        else { return false }
        let parent = payload.segments[position]
        guard truncationEnd > parent.nextUncommittedOffset,
            truncationEnd < parent.endExclusive,
            !payload.segments.contains(where: { $0.index == childIndex })
        else { return false }
        let child = SegmentCheckpoint(
            index: childIndex,
            start: truncationEnd,
            endExclusive: parent.endExclusive,
            nextUncommittedOffset: truncationEnd
        )
        payload.segments[position].endExclusive = truncationEnd
        payload.segments.append(child)
        do {
            try checkpointLocked()
        } catch {
            return false
        }
        return true
    }

    func snapshot() -> SidecarPayload {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    private func checkpointLocked() throws {
        try sink.synchronize()
        try SidecarStore.write(payload, to: sidecarURL)
        pendingBytes = 0
        lastCheckpoint = Date()
    }
}

struct TransferSpecification: Sendable {
    let url: URL
    let unit: DownloadUnit
    let requestStart: Int64
    let totalSize: Int64?
    let identity: ResourceIdentity?
    let isRange: Bool
    let requestContext: DownloadRequestContext?
    let contextOriginURL: URL
    let rateLimiter: (any DownloadRateLimiting)?
}

final class HTTPTransfer: NSObject, URLSessionDataDelegate, SessionDataTaskRoutingDelegate, @unchecked Sendable {
    /// Granularity of rate-limit acquisitions. Pausing checks run between
    /// slices, so the pause latency under a speed limit is bounded by one
    /// slice's wait (≤0.4 s at the spec's minimum 100 KB/s limit).
    static let rateLimitAcquireSliceBytes: Int64 = 32 * 1024

    private let specification: TransferSpecification
    private let sink: RandomAccessSink
    private let tracker: SynchronousCheckpointTracker?
    private let control: @Sendable () -> DownloadControl
    private let scopedSession: TaskScopedSession?
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDataTask?
    private var currentOffset: Int64
    private var received: Int64 = 0
    private var acceptedResponse = false
    private var terminalError: Error?
    private var redirects = 0
    private var session: URLSession?
    private var ownsSession = false
    private var pendingProcessingChunks = 0
    private var processingChain: Task<Void, Never>?
    private var didComplete = false
    private var completionError: Error?
    private var didFinish = false
    private var truncationProvider: (@Sendable () -> Int64?)?
    private var truncatedAt: Int64?

    init(
        specification: TransferSpecification,
        sink: RandomAccessSink,
        tracker: SynchronousCheckpointTracker?,
        control: @escaping @Sendable () -> DownloadControl,
        scopedSession: TaskScopedSession? = nil,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.specification = specification
        self.sink = sink
        self.tracker = tracker
        self.control = control
        self.scopedSession = scopedSession
        self.progress = progress
        currentOffset = specification.requestStart
    }

    /// Installs a dynamic truncation point. Once the committed offset
    /// reaches the provided end, the transfer cancels its request and
    /// completes successfully at that offset. Used by the segment
    /// coordinator's in-half division: the split's child worker downloads
    /// the tail while this transfer stops at the split point, so no byte
    /// range is fetched twice.
    ///
    /// Must be installed *before* the matching checkpoint split commits:
    /// chunks processed in between are already clamped at the truncation
    /// point but still validate against the original (wider) range.
    func installTruncation(_ provider: @escaping @Sendable () -> Int64?) {
        lock.lock()
        truncationProvider = provider
        lock.unlock()
    }

    /// Removes a truncation point after an abandoned split proposal.
    func clearTruncation() {
        lock.lock()
        truncationProvider = nil
        lock.unlock()
    }

    func start() async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                var request = URLRequest(url: specification.url)
                request.httpMethod = "GET"
                specification.requestContext?.apply(
                    to: &request,
                    boundTo: specification.contextOriginURL
                )
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if specification.isRange, let identity = specification.identity {
                    request.setValue(
                        "bytes=\(specification.requestStart)-\(specification.unit.range.endExclusive - 1)",
                        forHTTPHeaderField: "Range"
                    )
                    request.setValue(identity.strongETag, forHTTPHeaderField: "If-Range")
                }
                let session: URLSession
                let ownsSession: Bool
                if let scoped = self.scopedSession {
                    session = scoped.session
                    ownsSession = false
                } else {
                    let configuration = EngineSessionPolicy.makeConfiguration()
                    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    ownsSession = true
                }
                let task = session.dataTask(with: request)
                if let scoped = self.scopedSession {
                    scoped.multiplexer.register(dataTask: task, delegate: self)
                }
                lock.lock()
                self.session = session
                self.ownsSession = ownsSession
                self.task = task
                let shouldCancel = terminalError != nil
                lock.unlock()
                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        if terminalError == nil { terminalError = IDMError.cancelled }
        let task = self.task
        lock.unlock()
        // When a chunk is mid-processing the data task is suspended and the
        // processing chain owns the resume; it observes the terminal error
        // (or the pause/cancel control) and resumes+cancels the task itself.
        // Calling resume() here as well would unbalance URLSession's
        // suspend/resume counter, and cancelling a suspended task without a
        // resume merely queues didCompleteWithError until the chain resumes
        // it — which the chain now does promptly on every exit path.
        task?.cancel()
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
        let redirectCount = redirects
        lock.unlock()
        guard redirectCount <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            setTerminalError(IDMError.invalidURL)
            completionHandler(nil)
            task.cancel()
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
        do {
            guard let response = response as? HTTPURLResponse else { throw IDMError.invalidURL }
            try validate(response)
            lock.lock()
            acceptedResponse = true
            lock.unlock()
            completionHandler(.allow)
        } catch {
            setTerminalError(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let canReceive = terminalError == nil && acceptedResponse
        if canReceive {
            pendingProcessingChunks += 1
        }
        let previous = processingChain
        lock.unlock()
        guard canReceive else { return }

        // URLSession does not offer an async delegate callback. Suspend the
        // data task while the bounded rate limiter and disk write make
        // progress, then resume it. This keeps backpressure at the network
        // boundary instead of blocking URLSession's delegate queue with a
        // semaphore.
        //
        // `suspend()` does not recall delegate callbacks that are already in
        // flight, so a second `didReceive` can still run before the first
        // chunk finishes. Chain the async work so chunk processing stays
        // strictly serial; otherwise two chunks could write to the same file
        // offset and silently corrupt the download.
        dataTask.suspend()
        let next = Task { [weak self, dataTask] in
            await previous?.value
            guard let self else {
                dataTask.resume()
                return
            }
            do {
                try await self.process(data)
            } catch {
                self.setTerminalError(error)
            }
            // Always resume before leaving the chain: URLSession withholds
            // delegate callbacks — including the cancellation completion —
            // while the task is suspended. Resuming here (and cancelling
            // when a terminal error is set) is what lets didCompleteWithError
            // fire immediately on pause/cancel instead of seconds later.
            let shouldCancel = self.hasTerminalError()
            dataTask.resume()
            if shouldCancel { dataTask.cancel() }
            self.processingFinished()
        }
        lock.lock()
        processingChain = next
        lock.unlock()
    }

    private func process(_ data: Data) async throws {
        try Task.checkCancellation()
        switch control() {
        case .continue: break
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
        // Acquire the rate limit in small slices with a control check
        // between slices. A single acquire for the whole chunk can sleep for
        // seconds under a tight global limit — and the token bucket queues
        // reservations across all segments, so a pause issued mid-download
        // would not take effect until every queued reservation expired
        // (observed as 5–10+ seconds stuck in the "pausing" state). Slicing bounds
        // the pause latency to one slice's wait.
        if let rateLimiter = specification.rateLimiter {
            var remaining = Int64(data.count)
            while remaining > 0 {
                switch control() {
                case .continue: break
                case .pause: throw IDMError.paused
                case .cancel: throw IDMError.cancelled
                }
                try Task.checkCancellation()
                let step = min(Self.rateLimitAcquireSliceBytes, remaining)
                try await rateLimiter.acquire(step)
                remaining -= step
            }
            switch control() {
            case .continue: break
            case .pause: throw IDMError.paused
            case .cancel: throw IDMError.cancelled
            }
        }
        let offset = currentOffsetValue()
        let specificationEnd =
            specification.isRange
            ? specification.unit.range.endExclusive
            : (specification.totalSize ?? Int64.max)
        // Dynamic truncation installed by the segment coordinator: clamp
        // this chunk at the split point and finish successfully once it is
        // reached, so the split's child worker owns the tail exclusively.
        var limit = specificationEnd
        var truncationActive = false
        if let truncationEnd = truncationLimitValue(), truncationEnd < limit {
            limit = truncationEnd
            truncationActive = true
        }
        if offset >= limit {
            finishTruncated(at: offset)
            return
        }
        let writable = min(Int64(data.count), limit - offset)
        let chunk = writable < Int64(data.count) ? Data(data.prefix(Int(writable))) : data
        try sink.write(chunk, at: offset, limit: limit)
        let byteCount = Int64(chunk.count)
        let nextOffset = advance(by: byteCount)
        if let tracker {
            try tracker.record(
                segment: specification.unit.index,
                nextOffset: nextOffset,
                addedBytes: byteCount
            )
        }
        progress(byteCount)
        if truncationActive && nextOffset >= limit {
            finishTruncated(at: nextOffset)
        }
    }

    /// Completes a truncated transfer successfully at `offset` and cancels
    /// the underlying request. Idempotent: only the first call wins.
    private func finishTruncated(at offset: Int64) {
        lock.lock()
        guard truncatedAt == nil else {
            lock.unlock()
            return
        }
        truncatedAt = offset
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        didComplete = true
        completionError = error
        let shouldFinish = pendingProcessingChunks == 0
        lock.unlock()
        if shouldFinish { finishIfReady() }
    }

    private func finishIfReady() {
        lock.lock()
        guard didComplete, pendingProcessingChunks == 0, !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let terminalError = self.terminalError
        let offset = currentOffset
        let received = self.received
        let completionError = self.completionError
        let session = self.session
        let ownsSession = self.ownsSession
        let task = self.task
        let scoped = self.scopedSession
        let truncation = self.truncatedAt
        lock.unlock()
        if let task, let scoped {
            scoped.multiplexer.unregister(taskIdentifier: task.taskIdentifier)
        }
        if ownsSession {
            session?.finishTasksAndInvalidate()
        }
        if let terminalError {
            finish(.failure(terminalError))
        } else if let completionError, !isCancellationOrPauseError(completionError) {
            finish(.failure(completionError))
        } else {
            // A truncated transfer completes successfully at the split point
            // instead of the original range end; the child segment owns the
            // tail and its checkpoint tracks it independently.
            let expected =
                truncation
                ?? (specification.isRange
                    ? specification.unit.range.endExclusive
                    : specification.totalSize)
            if let expected, offset != expected {
                finish(.failure(offset < expected ? IDMError.responseTooShort : IDMError.responseTooLong))
            } else {
                finish(.success(received))
            }
        }
    }

    private func processingFinished() {
        lock.lock()
        pendingProcessingChunks = max(0, pendingProcessingChunks - 1)
        let shouldFinish = didComplete && pendingProcessingChunks == 0
        lock.unlock()
        if shouldFinish { finishIfReady() }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 { throw IDMError.authenticationRequired }
        let encoding = normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding"))
        guard encoding == "identity" else { throw IDMError.resourceChanged }
        if specification.isRange {
            guard response.statusCode == 206 || response.statusCode == 200 else {
                throw IDMError.httpStatus(response.statusCode)
            }
            let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
            // A 200 without a Content-Range ignored the Range header entirely;
            // only the 200 dialect echoing an exact-slice Content-Range
            // (Bilibili's CDN) is acceptable partial content.
            if response.statusCode == 200, contentRange == nil {
                throw IDMError.rangeIgnored
            }
            guard let identity = specification.identity,
                response.url.map(resourceLocatorString) == identity.effectiveURL,
                strongETag(response.value(forHTTPHeaderField: "ETag")) == identity.strongETag,
                HTTPRangeResponseValidator.accepts(
                    response, start: specification.requestStart,
                    endInclusive: specification.unit.range.endExclusive - 1, total: identity.totalSize)
            else { throw IDMError.resourceChanged }
        } else {
            guard response.statusCode == 200 else { throw IDMError.httpStatus(response.statusCode) }
        }
    }

    private func finish(_ result: Result<Int64, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func setTerminalError(_ error: Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
    }

    private func currentOffsetValue() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return currentOffset
    }

    /// Resolves the dynamic truncation point, if one is installed. Kept
    /// synchronous so the async chunk-processing path never touches the
    /// lock directly.
    private func truncationLimitValue() -> Int64? {
        lock.lock()
        let provider = truncationProvider
        lock.unlock()
        return provider?()
    }

    private func hasTerminalError() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalError != nil
    }

    private func advance(by byteCount: Int64) -> Int64 {
        lock.lock()
        currentOffset += byteCount
        received += byteCount
        let nextOffset = currentOffset
        lock.unlock()
        return nextOffset
    }
}
