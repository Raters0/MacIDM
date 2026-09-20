import Foundation

public actor DownloadEngine {
    private let router: DownloadProtocolRouter
    private let hlsExecutor: HLSDownloadExecutor
    private let dashExecutor: DASHDownloadExecutor
    private let retryPolicy: DownloadRetryPolicy
    private let policyLearner: ConnectionPolicyLearner?
    private let verifier: ArtifactVerifier

    public init(
        handler: HTTPHandler = HTTPHandler(),
        hlsExecutor: HLSDownloadExecutor = HLSDownloadExecutor(),
        dashExecutor: DASHDownloadExecutor = DASHDownloadExecutor(),
        retryPolicy: DownloadRetryPolicy = DownloadRetryPolicy(),
        connectionPolicyLearner: ConnectionPolicyLearner? = nil,
        verifier: ArtifactVerifier = ArtifactVerifier()
    ) {
        router = DownloadProtocolRouter(handlers: [handler])
        self.hlsExecutor = hlsExecutor
        self.dashExecutor = dashExecutor
        self.retryPolicy = retryPolicy
        self.policyLearner = connectionPolicyLearner
        self.verifier = verifier
    }

    public init(
        router: DownloadProtocolRouter,
        hlsExecutor: HLSDownloadExecutor = HLSDownloadExecutor(),
        dashExecutor: DASHDownloadExecutor = DASHDownloadExecutor(),
        retryPolicy: DownloadRetryPolicy = DownloadRetryPolicy(),
        connectionPolicyLearner: ConnectionPolicyLearner? = nil,
        verifier: ArtifactVerifier = ArtifactVerifier()
    ) {
        self.router = router
        self.hlsExecutor = hlsExecutor
        self.dashExecutor = dashExecutor
        self.retryPolicy = retryPolicy
        self.policyLearner = connectionPolicyLearner
        self.verifier = verifier
    }

    public func download(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl = { .continue },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadResult {
        var attempt = 1
        while true {
            do {
                return try await downloadOnce(request, control: control, progress: progress)
            } catch {
                guard attempt < retryPolicy.maxAttempts, retryPolicy.shouldRetry(error) else {
                    throw error
                }
                try checkRetryControl(control)
                let delay = retryPolicy.delayNanoseconds(beforeAttempt: attempt + 1)
                if delay > 0 {
                    try await interruptibleSleep(nanoseconds: delay, control: control)
                }
                try checkRetryControl(control)
                attempt += 1
            }
        }
    }

    /// Sleeps in small slices so a user pause or cancel interrupts a retry
    /// backoff immediately instead of waiting out the whole delay (up to
    /// several seconds per attempt).
    private func interruptibleSleep(
        nanoseconds: UInt64,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws {
        var remaining = nanoseconds
        let slice: UInt64 = 100_000_000
        while remaining > 0 {
            try checkRetryControl(control)
            let step = min(slice, remaining)
            try await Task.sleep(nanoseconds: step)
            remaining -= step
        }
        try checkRetryControl(control)
    }

    private func downloadOnce(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        if request.sourceKind == .hls {
            // Separate-audio master inspected by the extension: the variant
            // media playlist carries a pairAudioURL (EXT-X-MEDIA rendition),
            // so both tracks are fetched and muxed into one MP4.
            if let pairAudioURL = request.pairAudioURL {
                return try await hlsExecutor.downloadPair(
                    HLSPairDownloadRequest(
                        videoURL: request.url,
                        audioURL: pairAudioURL,
                        destination: request.destination,
                        outputKind: .mp4,
                        maximumParallelRequests: request.maximumParallelRequests,
                        taskID: request.taskID,
                        requestContext: request.requestContext,
                        rateLimiter: request.rateLimiter,
                        expectedSHA256: request.expectedSHA256
                    ),
                    control: control,
                    progress: progress
                )
            }
            return try await hlsExecutor.download(
                request,
                control: control,
                progress: progress
            )
        }
        if request.sourceKind == .dash {
            if let pairAudioURL = request.pairAudioURL {
                return try await dashExecutor.downloadPair(
                    DASHPairDownloadRequest(
                        videoURL: request.url,
                        audioURL: pairAudioURL,
                        destination: request.destination,
                        outputKind: .mp4,
                        maximumParallelRequests: request.maximumParallelRequests,
                        taskID: request.taskID,
                        requestContext: request.requestContext,
                        rateLimiter: request.rateLimiter
                    ),
                    control: control,
                    progress: progress,
                    directDownload: { [self] trackRequest, trackControl, trackProgress in
                        try await self.download(
                            trackRequest,
                            control: trackControl,
                            progress: trackProgress
                        )
                    }
                )
            }
            return try await dashExecutor.download(
                DASHDownloadRequest(
                    url: request.url,
                    destination: request.destination,
                    outputKind: .mp4,
                    maximumParallelRequests: request.maximumParallelRequests,
                    taskID: request.taskID,
                    requestContext: request.requestContext,
                    rateLimiter: request.rateLimiter
                ),
                control: control,
                progress: progress
            )
        }
        try InputValidator.validate(request)
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw IDMError.filenameConflict(request.destination.path)
        }

        let handler = try router.handler(for: request)
        guard handler.identifier == "http" else {
            throw IDMError.unsupportedScheme
        }
        let info = try await handler.probe(request)
        let paths = temporaryPaths(for: request)
        // Query the connection policy learner for the recommended parallel
        // request count. When no learner is configured the original value
        // from the request is used unchanged.
        let effectiveParallel: Int
        if let learner = policyLearner, let host = request.url.host {
            effectiveParallel = await learner.recommendedConnections(
                for: host, requested: request.maximumParallelRequests
            )
        } else {
            effectiveParallel = request.maximumParallelRequests
        }
        let plan = try handler.makePlan(info, parallelRequests: effectiveParallel)
        if info.size == 0 {
            return try publishEmpty(request: request, paths: paths)
        }

        do {
            if info.supportsRange, let identity = info.identity {
                let result = try await rangedDownload(
                    request: request,
                    info: info,
                    identity: identity,
                    plan: plan,
                    paths: paths,
                    control: control,
                    progress: progress
                )
                // Record successful download so the learner can raise the hint.
                if let learner = policyLearner, let host = request.url.host {
                    await learner.recordSuccess(host: host, connectionCount: plan.units.count)
                }
                return result
            }
            let result = try await singleStreamDownload(
                request: request,
                info: info,
                paths: paths,
                control: control,
                progress: progress
            )
            // No success recording for single-stream downloads: a count of 1
            // proves nothing about parallelism tolerance and would pollute
            // the learner's hint, capping future ranged downloads to one
            // connection. recordSuccess itself also guards against count < 2.
            return result
        } catch {
            // Record rejection only for rate-limiting statuses. 403/401 are
            // authentication or access-control problems, not evidence that the
            // connection count was too high, and capping on them would
            // silently degrade every later download on the host.
            if let learner = policyLearner, let host = request.url.host,
                isConnectionRejection(error)
            {
                await learner.recordRejection(host: host, connectionCount: plan.units.count)
            }
            throw error
        }
    }

    /// Checks whether an error indicates the server rate-limited the
    /// connection count (HTTP 429 or 503 from a CDN wind-control system).
    /// Auth failures (401/403) are deliberately excluded.
    private func isConnectionRejection(_ error: Error) -> Bool {
        if case IDMError.httpStatus(let code) = error {
            return code == 429 || code == 503
        }
        return false
    }

    private func checkRetryControl(
        _ control: @escaping @Sendable () -> DownloadControl
    ) throws {
        try Task.checkCancellation()
        switch control() {
        case .continue: return
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
    }

    private func rangedDownload(
        request: DownloadRequest,
        info: ResourceInfo,
        identity: ResourceIdentity,
        plan: DownloadPlan,
        paths: TemporaryPaths,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let resumed: Bool
        let sink: RandomAccessSink
        let payload: SidecarPayload

        if FileManager.default.fileExists(atPath: paths.sidecar.path),
            FileManager.default.fileExists(atPath: paths.temporary.path)
        {
            do {
                let loaded = try SidecarStore.read(from: paths.sidecar)
                // Legacy records omitted query identity. Discard once rather than
                // reusing ambiguous bytes or leaving the task in a restart loop.
                guard loaded.resourceIdentity.effectiveURL.hasPrefix("sha256:") else {
                    throw IDMError.sidecarCorrupt
                }
                guard loaded.taskID == request.taskID,
                    loaded.resourceIdentity == identity,
                    loaded.totalSize == identity.totalSize,
                    validateCoverage(loaded.segments, total: identity.totalSize)
                else { throw IDMError.resourceChanged }
                let candidate = try RandomAccessSink(
                    url: paths.temporary, totalSize: identity.totalSize, create: false)
                guard try candidate.identity() == loaded.fileIdentity else {
                    throw IDMError.sidecarCorrupt
                }
                payload = loaded
                sink = candidate
                resumed = loaded.segments.contains { $0.nextUncommittedOffset > $0.start }
            } catch IDMError.resourceChanged {
                // A new validator for the exact same complete URL and size
                // can restart from zero, but never reuse unverified old bytes.
                let loaded = try? SidecarStore.read(from: paths.sidecar)
                if let loaded,
                    loaded.taskID == request.taskID,
                    loaded.resourceIdentity.effectiveURL == identity.effectiveURL,
                    loaded.totalSize == identity.totalSize
                {
                    (sink, payload) = try makeFreshRangedState(
                        request: request, identity: identity, plan: plan, paths: paths)
                    resumed = false
                } else {
                    throw IDMError.resourceChanged
                }
            } catch {
                // Resume validation failed (corrupt sidecar, unreadable or
                // swapped temporary file, device/inode mismatch). The
                // committed bytes can no longer be trusted and must never be
                // resumed on top of; recover by discarding the artifacts and
                // restarting from scratch instead of failing the task with
                // “corrupt resume state”, which used to demand a manual cancel and
                // re-download to achieve exactly this fresh start.
                (sink, payload) = try makeFreshRangedState(
                    request: request, identity: identity, plan: plan, paths: paths)
                resumed = false
            }
        } else {
            (sink, payload) = try makeFreshRangedState(
                request: request, identity: identity, plan: plan, paths: paths)
            resumed = false
        }

        let tracker = SynchronousCheckpointTracker(payload: payload, sidecarURL: paths.sidecar, sink: sink)
        let coalescer = ProgressCoalescer(
            totalBytes: identity.totalSize,
            segments: payload.segments,
            onEmit: progress
        )
        let taskSession = TaskScopedSession(
            requestTimeout: 30,
            resourceTimeout: 24 * 60 * 60,
            proxyDictionary: DownloadProxyPolicy.connectionProxyDictionary
        )
        defer {
            coalescer.finish()
            taskSession.finishTasksAndInvalidate()
        }

        // Dynamic re-segmentation: a coordinator hands queued segments to
        // idle workers and proposes in-half splits of the slowest active
        // segment. Committed splits shrink the parent in the checkpoint
        // tracker and truncate the parent transfer at the split point, so
        // the child worker owns the tail exclusively and no byte range is
        // fetched twice. Single-segment downloads never split (the proposal
        // guard requires remaining >= 512 KB *and* an idle worker).
        let incompleteSegments = payload.segments.filter {
            $0.nextUncommittedOffset < $0.endExclusive
        }
        let coordinator = SegmentCoordinator(
            workItems: incompleteSegments.map {
                var item = SegmentCoordinator.WorkItem(
                    segmentIndex: $0.index,
                    range: ByteRange(start: $0.start, endExclusive: $0.endExclusive),
                    requestStart: $0.nextUncommittedOffset
                )
                item.initialDownloaded = $0.nextUncommittedOffset - $0.start
                return item
            })
        let registry = TransferRegistry()
        let progressRelay = CoordinatorProgressRelay(coordinator: coordinator)

        // Runs one work item to completion and reports it to the coordinator.
        let runItem: @Sendable (SegmentCoordinator.WorkItem) async throws -> Void = { item in
            let unit = DownloadUnit(index: item.segmentIndex, range: item.range)
            progressRelay.seed(item.segmentIndex, item.initialDownloaded)
            let transfer = HTTPTransfer(
                specification: TransferSpecification(
                    url: info.finalURL,
                    unit: unit,
                    requestStart: item.requestStart,
                    totalSize: identity.totalSize,
                    identity: identity,
                    isRange: true,
                    requestContext: request.requestContext,
                    contextOriginURL: request.url,
                    rateLimiter: request.rateLimiter
                ),
                sink: sink,
                tracker: tracker,
                control: control,
                scopedSession: taskSession
            ) { added in
                coalescer.add(bytes: added, to: item.segmentIndex)
                progressRelay.report(item.segmentIndex, added)
            }
            registry.register(item.segmentIndex, transfer)
            defer { registry.unregister(item.segmentIndex) }
            _ = try await transfer.start()
            await coordinator.markCompleted(segmentIndex: item.segmentIndex)
        }

        // Hoisted out of the do-block so the catch can read it: the engine
        // collects every error thrown by the TaskGroup's children, then picks
        // a root cause by priority instead of trusting TaskGroup's "first
        // error wins" semantics (which can surface a sibling's .cancelled
        // rather than the real failure).
        var collectedErrors: [Error] = []
        do {
            try await withThrowingTaskGroup(of: Int64.self) { group in
                let workerCount = max(1, incompleteSegments.count)
                for _ in 0..<workerCount {
                    group.addTask {
                        while true {
                            switch control() {
                            case .continue: break
                            case .pause: throw IDMError.paused
                            case .cancel: throw IDMError.cancelled
                            }
                            let decision = await coordinator.nextDecision()
                            switch decision {
                            case .done:
                                return 0
                            case .work(let item):
                                try await runItem(item)
                            case .split(let parentIndex, let truncationEnd, let child):
                                // Commit order matters: install the truncation
                                // first so chunks processed before the sidecar
                                // split are already clamped at the split
                                // point; the tracker split then makes the
                                // clamped range the parent's committed bound.
                                guard let parent = registry.transfer(for: parentIndex) else {
                                    await coordinator.abandonSplit(parentIndex: parentIndex)
                                    continue
                                }
                                let splitEnd = truncationEnd
                                parent.installTruncation { splitEnd }
                                guard
                                    tracker.applySplit(
                                        parentIndex: parentIndex,
                                        truncationEnd: truncationEnd,
                                        childIndex: child.segmentIndex
                                    )
                                else {
                                    // Stale proposal: the parent raced past the
                                    // split point. It will cover the child's
                                    // range itself, so drop the proposal.
                                    parent.clearTruncation()
                                    await coordinator.abandonSplit(parentIndex: parentIndex)
                                    continue
                                }
                                await coordinator.commitSplit(
                                    parentIndex: parentIndex,
                                    truncationEnd: truncationEnd,
                                    childIndex: child.segmentIndex,
                                    childRange: child.range
                                )
                                coalescer.register(
                                    index: child.segmentIndex,
                                    totalBytes: child.range.endExclusive - child.range.start,
                                    start: child.range.start
                                )
                                coalescer.applySplit(
                                    parentIndex: parentIndex,
                                    truncationEnd: truncationEnd
                                )
                                try await runItem(child)
                            }
                        }
                    }
                }
                // Do not use `try?` here. It turns a failed child into an
                // apparently exhausted group, allowing finalization and
                // publication of an incomplete file. Re-throw the child
                // error, cancel siblings, and drain them before leaving the
                // group so the outer catch can persist a failed checkpoint.
                do {
                    while let _ = try await group.next() {}
                } catch {
                    group.cancelAll()
                    // Drain remaining tasks, collecting their errors so the
                    // root-cause selector has the full picture instead of
                    // only the first error thrown.
                    while let result = await group.nextResult() {
                        if case .failure(let drainError) = result {
                            collectedErrors.append(drainError)
                        }
                    }
                    throw error
                }
            }
            try tracker.checkpoint(phase: "finalizing")
        } catch {
            collectedErrors.append(error)
            // Root-cause selection: the control token is the single source
            // of truth for user intent. Only treat the run as cancelled when
            // the user actually requested cancellation — a sibling's
            // .cancelled propagated through the TaskGroup must not override
            // a real failure. Non-cancellation errors always win over
            // .cancelled so a transient network blip is never misread as a
            // user cancel (which would delete the sidecar).
            let reportedError: Error
            let userCancelled: Bool
            switch control() {
            case .pause:
                reportedError = IDMError.paused
                userCancelled = false
            case .cancel:
                reportedError = IDMError.cancelled
                userCancelled = true
            case .continue:
                // Prefer any non-.cancelled error over a .cancelled one so
                // the real root cause surfaces instead of a sibling's
                // cancellation.
                let nonCancelled = collectedErrors.first {
                    if case IDMError.cancelled = $0 { return false }
                    return true
                }
                reportedError = nonCancelled ?? error
                userCancelled = false
            }
            let phase: String
            if case IDMError.paused = reportedError {
                phase = "paused"
            } else if case IDMError.cancelled = reportedError {
                phase = "cancelled"
            } else {
                phase = "failed"
            }
            try? tracker.checkpoint(phase: phase)
            if userCancelled {
                try? removeIfPresent(paths.temporary)
                try? removeIfPresent(paths.sidecar)
            }
            throw reportedError
        }

        return try verifyAndPublish(
            request: request,
            temporary: paths.temporary,
            sidecar: paths.sidecar,
            byteCount: identity.totalSize,
            usedParallelRequests: plan.units.count,
            resumed: resumed
        )
    }

    private func singleStreamDownload(
        request: DownloadRequest,
        info: ResourceInfo,
        paths: TemporaryPaths,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        try removeIfPresent(paths.temporary)
        try removeIfPresent(paths.sidecar)
        let sink = try RandomAccessSink(url: paths.temporary, totalSize: info.size, create: true)
        let upperBound = info.size ?? Int64.max
        let unit = DownloadUnit(index: 0, range: ByteRange(start: 0, endExclusive: upperBound))
        let coalescer = ProgressCoalescer(
            totalBytes: info.size,
            segments: [
                SegmentCheckpoint(
                    index: 0,
                    start: 0,
                    endExclusive: info.size ?? 0,
                    nextUncommittedOffset: 0
                )
            ],
            onEmit: progress
        )
        let taskSession = TaskScopedSession(
            requestTimeout: 30,
            resourceTimeout: 24 * 60 * 60,
            proxyDictionary: DownloadProxyPolicy.connectionProxyDictionary
        )
        defer {
            coalescer.finish()
            taskSession.finishTasksAndInvalidate()
        }
        do {
            let transfer = HTTPTransfer(
                specification: TransferSpecification(
                    url: info.finalURL,
                    unit: unit,
                    requestStart: 0,
                    totalSize: info.size,
                    identity: nil,
                    isRange: false,
                    requestContext: request.requestContext,
                    contextOriginURL: request.url,
                    rateLimiter: request.rateLimiter
                ),
                sink: sink,
                tracker: nil,
                control: control,
                scopedSession: taskSession
            ) { added in
                coalescer.add(bytes: added, to: 0)
            }
            _ = try await transfer.start()
            try sink.synchronize()
        } catch {
            let reportedError: Error
            switch control() {
            case .pause: reportedError = IDMError.paused
            case .cancel: reportedError = IDMError.cancelled
            case .continue: reportedError = error
            }
            if case IDMError.cancelled = reportedError { try? removeIfPresent(paths.temporary) }
            throw reportedError
        }
        let size = coalescer.currentReceived
        return try verifyAndPublish(
            request: request,
            temporary: paths.temporary,
            sidecar: nil,
            byteCount: size,
            usedParallelRequests: 1,
            resumed: false
        )
    }

    private func publishEmpty(request: DownloadRequest, paths: TemporaryPaths) throws -> DownloadResult {
        let sink = try RandomAccessSink(url: paths.temporary, totalSize: 0, create: true)
        try sink.synchronize()
        return try verifyAndPublish(
            request: request,
            temporary: paths.temporary,
            sidecar: nil,
            byteCount: 0,
            usedParallelRequests: 0,
            resumed: false
        )
    }

    private func verifyAndPublish(
        request: DownloadRequest,
        temporary: URL,
        sidecar: URL?,
        byteCount: Int64,
        usedParallelRequests: Int,
        resumed: Bool
    ) throws -> DownloadResult {
        return try verifier.verifyAndPublish(
            temporary: temporary,
            destination: request.destination,
            expectedSHA256: request.expectedSHA256,
            sidecar: sidecar,
            byteCount: byteCount,
            usedParallelRequests: usedParallelRequests,
            resumed: resumed,
            defaultVerification: "range-and-size",
            synchronizeParentDirectory: true
        )
    }

    private func temporaryPaths(for request: DownloadRequest) -> TemporaryPaths {
        let directory = request.destination.deletingLastPathComponent()
        let name = InputValidator.safeFilename(request.destination.lastPathComponent)
        let base = ".\(name).\(request.taskID.uuidString)"
        return TemporaryPaths(
            temporary: directory.appendingPathComponent("\(base).macidm.download"),
            sidecar: directory.appendingPathComponent("\(base).macidm")
        )
    }

    private func validateCoverage(_ segments: [SegmentCheckpoint], total: Int64) -> Bool {
        let sorted = segments.sorted { $0.start < $1.start }
        var cursor: Int64 = 0
        for segment in sorted {
            guard segment.start == cursor, segment.endExclusive > segment.start,
                segment.nextUncommittedOffset >= segment.start,
                segment.nextUncommittedOffset <= segment.endExclusive
            else { return false }
            cursor = segment.endExclusive
        }
        return cursor == total
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Discards any leftover artifacts and creates a brand-new ranged
    /// transfer state. Shared by the normal first attempt and the corrupted
    /// resume recovery path, which restarts from zero instead of resuming on
    /// top of unvalidated checkpoint data.
    private func makeFreshRangedState(
        request: DownloadRequest,
        identity: ResourceIdentity,
        plan: DownloadPlan,
        paths: TemporaryPaths
    ) throws -> (sink: RandomAccessSink, payload: SidecarPayload) {
        try removeIfPresent(paths.temporary)
        try removeIfPresent(paths.sidecar)
        let sink = try RandomAccessSink(
            url: paths.temporary, totalSize: identity.totalSize, create: true)
        let segments = plan.units.map {
            SegmentCheckpoint(
                index: $0.index,
                start: $0.range.start,
                endExclusive: $0.range.endExclusive,
                nextUncommittedOffset: $0.range.start
            )
        }
        let payload = SidecarPayload(
            formatVersion: 1,
            taskID: request.taskID,
            fileIdentity: try sink.identity(),
            totalSize: identity.totalSize,
            resourceIdentity: identity,
            segments: segments,
            generation: 1,
            phase: "running"
        )
        try SidecarStore.write(payload, to: paths.sidecar)
        return (sink, payload)
    }
}

private struct TemporaryPaths {
    let temporary: URL
    let sidecar: URL
}

/// Maps live segment indexes to their in-flight transfers so the split
/// commit path can install a truncation point on the parent transfer.
private final class TransferRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: HTTPTransfer] = [:]

    func register(_ index: Int, _ transfer: HTTPTransfer) {
        lock.lock()
        transfers[index] = transfer
        lock.unlock()
    }

    func unregister(_ index: Int) {
        lock.lock()
        transfers.removeValue(forKey: index)
        lock.unlock()
    }

    func transfer(for index: Int) -> HTTPTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[index]
    }
}

/// Forwards per-chunk progress to the segment coordinator with a 1 MiB
/// throttle so the hot chunk path does not spawn an actor hop per chunk.
/// The coordinator only needs coarse speed estimates to pick split targets.
private final class CoordinatorProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: [Int: Int64] = [:]
    private var lastReported: [Int: Int64] = [:]
    private let threshold: Int64 = 1024 * 1024
    private let coordinator: SegmentCoordinator

    init(coordinator: SegmentCoordinator) {
        self.coordinator = coordinator
    }

    /// Seeds a segment's baseline (bytes committed by a previous run).
    func seed(_ index: Int, _ bytes: Int64) {
        lock.lock()
        accumulated[index] = bytes
        lastReported[index] = bytes
        lock.unlock()
    }

    func report(_ index: Int, _ added: Int64) {
        lock.lock()
        accumulated[index, default: 0] += added
        let total = accumulated[index, default: 0]
        let shouldReport = total - lastReported[index, default: 0] >= threshold
        if shouldReport { lastReported[index] = total }
        lock.unlock()
        guard shouldReport else { return }
        let coordinator = self.coordinator
        Task {
            await coordinator.reportProgress(segmentIndex: index, bytesDownloaded: total)
        }
    }
}
