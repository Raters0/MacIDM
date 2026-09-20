import CryptoKit
import Darwin
import Foundation
import os

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

extension HLSDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .mergerUnavailable:
            return "HLS 音视频合并需要已配置的 FFmpeg 合并服务。"
        }
    }
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

public struct HLSDownloadExecutor: Sendable {
    private struct ExecutorStats {
        var lastMaxUncommittedRefs: Int = 0
    }

    private let client: any HLSResourceClient
    private let parser: HLSParser
    private let planner: HLSDownloadPlanner
    private let budget: MediaBufferBudget?
    private let statsLock = OSAllocatedUnfairLock(initialState: ExecutorStats())

    var maxObservedUncommittedRefs: Int {
        statsLock.withLock { $0.lastMaxUncommittedRefs }
    }

    private let verifier: ArtifactVerifier
    private let groupCommitBytesThreshold: Int64
    private let groupCommitTimeThreshold: Duration
    /// FFmpeg merge service for separate-audio HLS masters (EXT-X-MEDIA
    /// audio groups). Without a merger, only the video track is downloaded.
    private let merger: (any FFmpegMerging)?

    public init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        parser: HLSParser = HLSParser(),
        planner: HLSDownloadPlanner = HLSDownloadPlanner(),
        budget: MediaBufferBudget? = nil,
        verifier: ArtifactVerifier = ArtifactVerifier(),
        groupCommitBytesThreshold: Int64 = 8 * 1024 * 1024,
        groupCommitTimeThreshold: Duration = .seconds(5),
        merger: (any FFmpegMerging)? = nil
    ) {
        self.client = client
        self.parser = parser
        self.planner = planner
        self.budget = budget
        self.verifier = verifier
        self.groupCommitBytesThreshold = groupCommitBytesThreshold
        self.groupCommitTimeThreshold = groupCommitTimeThreshold
        self.merger = merger
    }

    public func download(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl = { .continue },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadResult {
        try InputValidator.validate(request)
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw IDMError.filenameConflict(request.destination.path)
        }

        let taskSession: TaskScopedSession?
        let effectiveClient: any HLSResourceClient
        if let urlClient = client as? URLSessionHLSResourceClient {
            if let _ = urlClient.scopedSession {
                taskSession = nil
                effectiveClient = urlClient
            } else {
                let session = TaskScopedSession(
                    requestTimeout: urlClient.requestTimeout,
                    resourceTimeout: urlClient.resourceTimeout,
                    proxyDictionary: DownloadProxyPolicy.connectionProxyDictionary
                )
                taskSession = session
                effectiveClient = URLSessionHLSResourceClient(
                    requestTimeout: urlClient.requestTimeout,
                    resourceTimeout: urlClient.resourceTimeout,
                    unitSafetyCap: urlClient.unitSafetyCap,
                    scopedSession: session
                )
            }
        } else {
            taskSession = nil
            effectiveClient = client
        }
        defer {
            taskSession?.finishTasksAndInvalidate()
        }

        let taskBudget =
            budget
            ?? MediaBufferBudget(
                capacity: DownloadResourceLimits.maximumTaskBufferedResourceBytes,
                parent: GlobalMediaBufferBudget.shared
            )

        let paths = temporaryPaths(for: request)
        if !FileManager.default.fileExists(atPath: paths.directory.path) {
            try FileManager.default.createDirectory(
                at: paths.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let (plan, contextOriginURL, separateAudioURL) = try await loadPlan(
            request: request,
            client: effectiveClient,
            control: control
        )

        let state: HLSResumeState
        let sink: RandomAccessSink
        let fileIdentity: HLSResumeFileIdentity
        let resumed: Bool

        if FileManager.default.fileExists(atPath: paths.temporary.path),
            FileManager.default.fileExists(atPath: paths.sidecar.path)
        {
            do {
                let record = try HLSResumeStore.read(from: paths.sidecar)
                guard let storedFileIdentity = record.fileIdentity,
                    storedFileIdentity == (try HLSResumeStore.fileIdentity(paths.temporary))
                else {
                    throw IDMError.sidecarCorrupt
                }
                let candidateState = try HLSResumeState(record: record, plan: plan)
                try candidateState.validatingCompatibility(taskID: request.taskID, plan: plan)
                let committed = committedBytes(candidateState)
                let actualSize = try HLSResumeStore.fileSize(paths.temporary)
                guard actualSize >= committed else {
                    throw IDMError.sidecarCorrupt
                }
                let candidateSink = try RandomAccessSink(url: paths.temporary, totalSize: nil, create: false)
                if actualSize > committed {
                    try candidateSink.truncate(to: committed)
                    try candidateSink.synchronize()
                }
                state = candidateState
                sink = candidateSink
                fileIdentity = storedFileIdentity
                resumed = candidateState.units.contains { $0.completed }
            } catch {
                try removeIfPresent(paths.temporary)
                try removeIfPresent(paths.sidecar)
                cleanupUnitTemporaries(matching: paths.unitPrefix, in: paths.directory)
                sink = try RandomAccessSink(url: paths.temporary, totalSize: nil, create: true)
                fileIdentity = try HLSResumeStore.fileIdentity(paths.temporary)
                state = HLSResumeState(taskID: request.taskID, plan: plan)
                try HLSResumeStore.write(state.record(fileIdentity: fileIdentity), to: paths.sidecar)
                resumed = false
            }
        } else {
            try removeIfPresent(paths.temporary)
            try removeIfPresent(paths.sidecar)
            cleanupUnitTemporaries(matching: paths.unitPrefix, in: paths.directory)
            sink = try RandomAccessSink(url: paths.temporary, totalSize: nil, create: true)
            fileIdentity = try HLSResumeStore.fileIdentity(paths.temporary)
            state = HLSResumeState(taskID: request.taskID, plan: plan)
            try HLSResumeStore.write(state.record(fileIdentity: fileIdentity), to: paths.sidecar)
            resumed = false
        }

        var mutableState = state
        let keyCache = HLSKeyCache()
        var outputBytes = committedBytes(mutableState)
        let baseInFlight = Swift.min(
            request.maximumParallelRequests,
            DownloadResourceLimits.maximumMediaInFlightRequests
        )
        var activeConcurrency = max(1, baseInFlight)

        var knownSegmentSizes: [Int: Int64] = Dictionary(
            uniqueKeysWithValues: mutableState.units.compactMap { checkpoint in
                checkpoint.completed ? (checkpoint.unitIndex, checkpoint.receivedBytes) : nil
            })
        let totalUnitCount = mutableState.units.count

        emitHLSProgress(
            mutableState: mutableState,
            outputBytes: outputBytes,
            knownSegmentSizes: knownSegmentSizes,
            totalUnitCount: totalUnitCount,
            progress: progress
        )

        let committer = HLSSequenceCommitter(
            initialExpectedIndex: mutableState.units.first(where: { !$0.completed })?.unitIndex ?? totalUnitCount,
            sink: sink,
            paths: paths,
            fileIdentity: fileIdentity,
            initialOutputBytes: outputBytes,
            groupCommitBytesThreshold: groupCommitBytesThreshold,
            groupCommitTimeThreshold: groupCommitTimeThreshold
        )

        defer {
            if control() == .cancel {
                try? removeIfPresent(paths.temporary)
                try? removeIfPresent(paths.sidecar)
            }
            cleanupUnitTemporaries(matching: paths.unitPrefix, in: paths.directory)
        }

        let pending = mutableState.units.filter { !$0.completed }
        var nextFetchIndex = 0

        do {
            while nextFetchIndex < pending.count {
                try checkControl(control)

                // Out-of-order window cap: strict backpressure once uncommitted refs reach 8
                while committer.outOfOrderCount >= 8 {
                    try checkControl(control)
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                var fetchedRefs: [HLSCompletedUnitDiskRef] = []
                var batchSucceeded = false
                var retriesRemaining = 3
                var currentBatchCount = 0

                while !batchSucceeded && retriesRemaining >= 0 {
                    try checkControl(control)

                    // The scheduled batch size is hard-capped at 8 so high concurrency never
                    // produces too many uncommitted refs at once
                    // Each retry recomputes the batch size from the latest activeConcurrency
                    let currentBatchSize = min(8, max(1, activeConcurrency))
                    let batchEnd = min(pending.count, nextFetchIndex + currentBatchSize)
                    let batch = Array(pending[nextFetchIndex..<batchEnd])
                    currentBatchCount = batch.count

                    do {
                        fetchedRefs = try await withThrowingTaskGroup(of: HLSCompletedUnitDiskRef.self) { group in
                            for checkpoint in batch {
                                group.addTask {
                                    try checkControl(control)
                                    let unitTemp = paths.unitTemporary(index: checkpoint.unitIndex)
                                    let ref = try await self.fetchUnitToDisk(
                                        checkpoint.unit,
                                        destinationURL: unitTemp,
                                        contextOriginURL: contextOriginURL,
                                        request: request,
                                        client: effectiveClient,
                                        keyCache: keyCache,
                                        budget: taskBudget,
                                        control: control
                                    )
                                    try checkControl(control)
                                    return ref
                                }
                            }
                            var results: [HLSCompletedUnitDiskRef] = []
                            for try await ref in group {
                                results.append(ref)
                            }
                            return results
                        }
                        batchSucceeded = true
                    } catch {
                        if isTimeoutError(error), activeConcurrency > 1, retriesRemaining > 0 {
                            activeConcurrency = max(1, activeConcurrency / 2)
                            retriesRemaining -= 1
                            try await Task.sleep(nanoseconds: 50_000_000)
                            continue
                        }
                        throw error
                    }
                }

                for ref in fetchedRefs {
                    try checkControl(control)
                    let committed = try committer.accept(
                        completedRef: ref,
                        mutableState: &mutableState
                    )
                    for (cIndex, cBytes) in committed {
                        knownSegmentSizes[cIndex] = cBytes
                    }
                    knownSegmentSizes[ref.index] = ref.byteCount
                }
                emitHLSProgress(
                    mutableState: mutableState,
                    outputBytes: committer.currentOutputBytes,
                    knownSegmentSizes: knownSegmentSizes,
                    totalUnitCount: totalUnitCount,
                    progress: progress
                )
                nextFetchIndex += currentBatchCount
            }

            try checkControl(control)
            let finalCommitted = try committer.quiesce(mutableState: &mutableState)
            for (cIndex, cBytes) in finalCommitted {
                knownSegmentSizes[cIndex] = cBytes
            }
            outputBytes = committer.currentOutputBytes
            // Flush committed segment details before publishing the completed file.
            emitHLSProgress(
                mutableState: mutableState,
                outputBytes: outputBytes,
                knownSegmentSizes: knownSegmentSizes,
                totalUnitCount: totalUnitCount,
                progress: progress
            )
        } catch {
            if isCancellationOrPauseError(error) {
                do {
                    _ = try committer.quiesce(mutableState: &mutableState)
                    outputBytes = committer.currentOutputBytes
                } catch {
                    throw error
                }
            } else {
                do {
                    try committer.rollbackUncommitted(mutableState: &mutableState)
                    outputBytes = committer.currentOutputBytes
                } catch let rollbackError {
                    outputBytes = committer.currentOutputBytes
                    throw IDMError.storageError(
                        "HLS execution error: \(error.localizedDescription); Rollback failed: \(rollbackError.localizedDescription)"
                    )
                }
            }
            throw error
        }

        statsLock.withLock { s in
            s.lastMaxUncommittedRefs = committer.maxObservedOutOfOrderCount
        }

        // Separate-audio master: the video track finished into the temporary
        // file; fetch the audio rendition and mux both into the destination
        // instead of publishing the muted video on its own.
        if let separateAudioURL, merger != nil {
            return try await mergeSeparateAudio(
                audioURL: separateAudioURL,
                videoTemporary: paths.temporary,
                videoSidecar: paths.sidecar,
                videoBytes: outputBytes,
                resumed: resumed,
                usedParallelRequests: Swift.min(activeConcurrency, plan.units.count),
                request: request,
                control: control,
                progress: progress
            )
        }

        defer {
            cleanupUnitTemporaries(matching: paths.unitPrefix, in: paths.directory)
        }
        return try verifier.verifyAndPublish(
            temporary: paths.temporary,
            destination: request.destination,
            expectedSHA256: request.expectedSHA256,
            sidecar: paths.sidecar,
            byteCount: outputBytes,
            usedParallelRequests: Swift.min(activeConcurrency, plan.units.count),
            resumed: resumed,
            defaultVerification: "segments-and-size",
            synchronizeParentDirectory: false
        )
    }

    /// Downloads the EXT-X-MEDIA audio rendition of a separate-audio HLS
    /// master and muxes it with the finished video track. Fail-closed: an
    /// audio-side failure fails the task instead of silently shipping a
    /// muted video (same contract as the DASH pair executor).
    private func mergeSeparateAudio(
        audioURL: URL,
        videoTemporary: URL,
        videoSidecar: URL,
        videoBytes: Int64,
        resumed: Bool,
        usedParallelRequests: Int,
        request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        guard let merger else { throw HLSDownloadError.mergerUnavailable }
        let audioTrack = request.destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(InputValidator.safeFilename(request.destination.lastPathComponent))"
                    + ".\(request.taskID.uuidString).audio.macidm.hls.track"
            )
        defer { try? removeIfPresent(audioTrack) }
        let audioResult = try await download(
            DownloadRequest(
                url: audioURL,
                destination: audioTrack,
                sourceKind: .hls,
                maximumParallelRequests: max(1, min(4, request.maximumParallelRequests)),
                taskID: request.taskID,
                requestContext: request.requestContext,
                rateLimiter: request.rateLimiter
            ),
            control: control
        ) { value in
            // 音频阶段的分段索引与视频分段索引在 App 的分段面板里是同一
            // 序列空间，直接透传会让两组分段串位；只上报聚合值。
            progress(
                DownloadProgress(
                    receivedBytes: videoBytes + value.receivedBytes,
                    totalBytes: value.totalBytes.map { $0 + videoBytes },
                    segments: []
                ))
        }
        try checkControl(control)
        let mergeResult = try await merger.merge(
            FFmpegMergeRequest(
                videoURL: videoTemporary,
                audioURL: audioTrack,
                outputURL: request.destination,
                outputKind: .mp4,
                expectedSHA256: request.expectedSHA256,
                control: control
            )
        )
        try? removeIfPresent(videoTemporary)
        try? removeIfPresent(videoSidecar)
        return DownloadResult(
            destination: mergeResult.destination,
            byteCount: mergeResult.byteCount,
            sha256: mergeResult.sha256,
            usedParallelRequests: usedParallelRequests,
            resumed: resumed || audioResult.resumed,
            verification: "hls-ffmpeg-ffprobe",
            artifactFormat: .mp4
        )
    }

    /// Explicit separate-audio entry point: downloads the variant media
    /// playlist and the audio rendition playlist, then muxes both into one
    /// MP4. Used when the extension submits an inspected variant whose
    /// master declared an audio group.
    public func downloadPair(
        _ pair: HLSPairDownloadRequest,
        control: @escaping @Sendable () -> DownloadControl = { .continue },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadResult {
        guard let merger else { throw HLSDownloadError.mergerUnavailable }
        guard !FileManager.default.fileExists(atPath: pair.destination.path) else {
            throw IDMError.filenameConflict(pair.destination.path)
        }
        let directory = pair.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(pair.taskID.uuidString).macidm.hls-pair", isDirectory: true)
        var checkpoint = try MediaPairCheckpoint(
            directory: directory, videoURL: pair.videoURL, audioURL: pair.audioURL)
        let videoTrack = directory.appendingPathComponent("video.track")
        let audioTrack = directory.appendingPathComponent("audio.track")
        var cleanup = false
        defer {
            // Keep the directory on failure so the nested track downloads can
            // resume from their sidecars on retry; remove after a successful
            // merge or on explicit cancel.
            if cleanup || control() == .cancel {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let videoResult: DownloadResult
        if let existing = try checkpoint.existingTrack(at: videoTrack) {
            videoResult = existing
        } else {
            videoResult = try await download(
                DownloadRequest(
                    url: pair.videoURL,
                    destination: videoTrack,
                    sourceKind: .hls,
                    maximumParallelRequests: pair.maximumParallelRequests,
                    taskID: pair.taskID,
                    requestContext: pair.requestContext,
                    rateLimiter: pair.rateLimiter
                ),
                control: control,
                progress: progress
            )
            try checkpoint.recordCompleted(at: videoTrack)
        }
        try checkControl(control)
        let videoBytes = videoResult.byteCount
        let audioResult: DownloadResult
        if let existing = try checkpoint.existingTrack(at: audioTrack) {
            audioResult = existing
        } else {
            audioResult = try await download(
                DownloadRequest(
                    url: pair.audioURL,
                    destination: audioTrack,
                    sourceKind: .hls,
                    maximumParallelRequests: max(1, min(4, pair.maximumParallelRequests)),
                    taskID: pair.taskID,
                    requestContext: pair.requestContext,
                    rateLimiter: pair.rateLimiter
                ),
                control: control
            ) { value in
                // Report aggregate audio progress while retaining video segment details.
                progress(
                    DownloadProgress(
                        receivedBytes: videoBytes + value.receivedBytes,
                        totalBytes: value.totalBytes.map { $0 + videoBytes },
                        segments: []
                    ))
            }
            try checkpoint.recordCompleted(at: audioTrack)
        }
        try checkControl(control)
        let mergeResult = try await merger.merge(
            FFmpegMergeRequest(
                videoURL: videoTrack,
                audioURL: audioTrack,
                outputURL: pair.destination,
                outputKind: pair.outputKind,
                expectedSHA256: pair.expectedSHA256,
                control: control
            )
        )
        cleanup = true
        return DownloadResult(
            destination: mergeResult.destination,
            byteCount: mergeResult.byteCount,
            sha256: mergeResult.sha256,
            usedParallelRequests: pair.maximumParallelRequests,
            resumed: videoResult.resumed || audioResult.resumed,
            verification: "hls-pair-ffmpeg-ffprobe",
            artifactFormat: pair.outputKind == .mp4 ? .mp4 : .unprocessed
        )
    }

    private func loadPlan(
        request: DownloadRequest,
        client: any HLSResourceClient,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> (plan: HLSDownloadPlan, contextOriginURL: URL, separateAudioURL: URL?) {
        try checkControl(control)
        let response = try await client.fetch(
            HLSFetchRequest(
                url: request.url,
                requestContext: request.requestContext,
                contextOriginURL: request.url,
                control: control
            ))
        let playlistText = try decodePlaylist(response.data)
        let parsed = try parser.parse(playlistText, baseURL: response.finalURL)
        switch parsed {
        case .media(let media):
            return (try planner.makePlan(media, playlistURL: response.finalURL), request.url, nil)
        case .master(let master):
            guard let variant = master.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSParserError.emptyPlaylist
            }
            try checkControl(control)
            let variantResponse = try await client.fetch(
                HLSFetchRequest(
                    url: variant.url,
                    requestContext: request.requestContext,
                    contextOriginURL: request.url,
                    control: control
                ))
            let variantText = try decodePlaylist(variantResponse.data)
            guard case .media(let media) = try parser.parse(variantText, baseURL: variantResponse.finalURL) else {
                throw HLSParserError.emptyPlaylist
            }
            // Separate-audio master (X/Twitter style): the selected variant's
            // AUDIO group references an EXT-X-MEDIA rendition playlist. When a
            // merger is configured the rendition is fetched and muxed in;
            // without a merger only the video track is downloaded.
            let separateAudioURL =
                merger == nil
                ? nil
                : HLSAudioRendition.resolve(variant: variant, in: master)?.url
            return (
                try planner.makePlan(media, playlistURL: variantResponse.finalURL),
                request.url,
                separateAudioURL
            )
        }
    }

    private func fetchUnitToDisk(
        _ unit: HLSDownloadUnit,
        destinationURL: URL,
        contextOriginURL: URL,
        request: DownloadRequest,
        client: any HLSResourceClient,
        keyCache: HLSKeyCache,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> HLSCompletedUnitDiskRef {
        try checkControl(control)

        // At the start of every unit attempt, uniformly clean up the Executor-owned temporary
        // plaintext file and the cipher temp file
        // (ensures that when a single unit failure inside the TaskGroup forces a whole-batch
        // retry, already-decrypted unit temp files do not make SafeFileDescriptor report
        // filenameConflict)
        let cipherTempURL = destinationURL.appendingPathExtension("cipher.tmp")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        if FileManager.default.fileExists(atPath: cipherTempURL.path) {
            try? FileManager.default.removeItem(at: cipherTempURL)
        }

        let finalSize: Int64

        if let encryptionKey = unit.encryptionKey {
            // 1. Stream the ciphertext directly to a temporary file on disk
            let cipherStreamResult = try await client.streamToFile(
                HLSFetchRequest(
                    url: unit.url,
                    byteRange: unit.byteRange,
                    requestContext: request.requestContext,
                    contextOriginURL: contextOriginURL,
                    control: control
                ),
                to: cipherTempURL,
                budget: budget,
                control: control,
                progress: nil
            )
            defer { try? FileManager.default.removeItem(at: cipherTempURL) }

            // Strictly re-validate Range and status code (after the ciphertext is on disk)
            try validateStreamResult(cipherStreamResult, for: unit, actualFile: cipherTempURL)
            try checkControl(control)

            // 2. Fetch the key and stream-decrypt to the plaintext destination in
            //    budget-guarded 64KB chunks
            let key = try await keyCache.value(
                for: encryptionKey,
                client: client,
                requestContext: request.requestContext,
                contextOriginURL: contextOriginURL,
                control: control
            )
            let iv = try HLSAES128.iv(for: unit, key: encryptionKey)
            let decryptedBytes = try await HLSAES128.decrypt(
                sourceURL: cipherTempURL,
                destinationURL: destinationURL,
                key: key,
                iv: iv,
                budget: budget
            )
            finalSize = decryptedBytes
        } else {
            // Stream the plaintext directly to the destination file
            let streamResult = try await client.streamToFile(
                HLSFetchRequest(
                    url: unit.url,
                    byteRange: unit.byteRange,
                    requestContext: request.requestContext,
                    contextOriginURL: contextOriginURL,
                    control: control
                ),
                to: destinationURL,
                budget: budget,
                control: control,
                progress: nil
            )

            // Strictly re-validate Range and status code (after the plaintext is on disk)
            try validateStreamResult(streamResult, for: unit, actualFile: destinationURL)
            finalSize = streamResult.byteCount
        }

        if let rateLimiter = request.rateLimiter {
            try await rateLimiter.acquire(finalSize)
        }

        return HLSCompletedUnitDiskRef(index: unit.index, tempURL: destinationURL, byteCount: finalSize)
    }

    /// Strictly re-validates protocol-level Range response invariants
    private func validateStreamResult(
        _ result: HLSStreamToFileResult,
        for unit: HLSDownloadUnit,
        actualFile: URL
    ) throws {
        guard result.byteCount <= DownloadResourceLimits.maximumMediaUnitBytes else {
            try? FileManager.default.removeItem(at: actualFile)
            throw IDMError.resourceTooLarge(DownloadResourceLimits.maximumMediaUnitBytes)
        }
        if let byteRange = unit.byteRange {
            // Must be 206 Partial Content
            guard result.statusCode == 206 else {
                try? FileManager.default.removeItem(at: actualFile)
                throw IDMError.invalidContentRange
            }
            let (endPlusOne, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
            guard !overflow, endPlusOne > 0 else {
                try? FileManager.default.removeItem(at: actualFile)
                throw IDMError.invalidContentRange
            }
            let expectedEndInclusive = endPlusOne - 1
            guard let contentRange = result.contentRange,
                contentRange.start == byteRange.offset,
                contentRange.endInclusive == expectedEndInclusive,
                contentRange.total >= endPlusOne,
                result.byteCount == byteRange.length
            else {
                try? FileManager.default.removeItem(at: actualFile)
                throw IDMError.invalidContentRange
            }
        } else {
            // Without a Range request it must be exactly 200 OK (206 is not acceptable)
            guard result.statusCode == 200 else {
                try? FileManager.default.removeItem(at: actualFile)
                throw IDMError.httpStatus(result.statusCode)
            }
        }
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if case IDMError.timedOut = error { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut { return true }
        return false
    }

    private func decodePlaylist(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSParserError.invalidURL("playlist is not UTF-8")
        }
        return text
    }

    private func emitHLSProgress(
        mutableState: HLSResumeState,
        outputBytes: Int64,
        knownSegmentSizes: [Int: Int64],
        totalUnitCount: Int,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        // 分段面板只上报已通过组提交检查点的分段：未提交的分段既没有可信
        // 字节数也没有总量，展示成「0 KB / 未知 / 0%」占位行只会与总进度
        // 脱节（分段全 0% 而总进度 100%）；行数随提交进度增长，最终
        // quiesce 后的全量上报保证收尾时所有分段完整显示。
        let segmentProgress = mutableState.units.compactMap { checkpoint -> DownloadSegmentProgress? in
            guard checkpoint.completed else { return nil }
            return DownloadSegmentProgress(
                index: checkpoint.unitIndex,
                receivedBytes: checkpoint.receivedBytes,
                totalBytes: checkpoint.receivedBytes
            )
        }
        let knownTotal = knownSegmentSizes.values.reduce(Int64(0), +)
        // 外推总量的分母用“已抓取段数”（knownSegmentSizes，含已 fetch 但尚未
        // 组提交的段）而非“已提交段数”。HLS 组提交要攒够字节/时间阈值才
        // 标记 completed，用已提交段数会让 totalBytes 在下载途中长期为 nil，UI
        // 进度条只能依赖扩展的初始估算（X.com 分离音视频场景该估算漏算
        // 音轨而偏小），导致进度条提前满/跳变。改用已抓取段数后，第一批段
        // 下载完 totalBytes 即出现，进度条能实时反映真实进度。外推值恒 ≥
        // outputBytes（已抓取 ⊇ 已提交），不会超 100%。
        let knownCount = knownSegmentSizes.count
        let estimatedTotal: Int64? =
            knownCount > 0
            ? Int64((Double(knownTotal) * Double(totalUnitCount) / Double(knownCount)).rounded())
            : nil
        progress(
            DownloadProgress(
                receivedBytes: outputBytes,
                totalBytes: estimatedTotal,
                segments: segmentProgress
            ))
    }

    private func checkControl(_ control: @escaping @Sendable () -> DownloadControl) throws {
        try Task.checkCancellation()
        switch control() {
        case .continue: return
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
    }

    private func committedBytes(_ state: HLSResumeState) -> Int64 {
        var total: Int64 = 0
        for checkpoint in state.units {
            guard checkpoint.completed else { break }
            total += checkpoint.receivedBytes
        }
        return total
    }

    private func temporaryPaths(for request: DownloadRequest) -> HLSTemporaryPaths {
        let directory = request.destination.deletingLastPathComponent()
        let name = InputValidator.safeFilename(request.destination.lastPathComponent)
        let base = ".\(name).\(request.taskID.uuidString)"
        return HLSTemporaryPaths(
            directory: directory,
            unitPrefix: "\(base).unit-",
            temporary: directory.appendingPathComponent("\(base).macidm.hls.download"),
            sidecar: directory.appendingPathComponent("\(base).macidm.hls"),
            baseName: base
        )
    }

    private func cleanupUnitTemporaries(matching prefix: String, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            if file.hasPrefix(prefix) && (file.hasSuffix(".macidm.hls.tmp") || file.contains(".macidm.hls.tmp.")) {
                let fullPath = directory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fullPath)
            }
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public struct URLSessionHLSResourceClient: HLSResourceClient, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let unitSafetyCap: Int64
    let scopedSession: TaskScopedSession?

    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 24 * 60 * 60) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = DownloadResourceLimits.maximumMediaUnitBytes
        self.scopedSession = nil
    }

    init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 24 * 60 * 60,
        unitSafetyCap: Int64 = DownloadResourceLimits.maximumMediaUnitBytes,
        scopedSession: TaskScopedSession? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = unitSafetyCap
        self.scopedSession = scopedSession
    }

    public func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        let operation = HLSDataFetchOperation(
            request: request,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            scopedSession: scopedSession
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    public func streamToFile(
        _ request: HLSFetchRequest,
        to destinationURL: URL,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HLSStreamToFileResult {
        let operation = HLSStreamToFileOperation(
            request: request,
            destinationURL: destinationURL,
            budget: budget,
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            unitSafetyCap: unitSafetyCap,
            control: control,
            scopedSession: scopedSession,
            progress: progress
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }
}

struct HLSCompletedUnitDiskRef: Sendable {
    let index: Int
    let tempURL: URL
    let byteCount: Int64
}

final class HLSSequenceCommitter: @unchecked Sendable {
    typealias SinkSynchronizer = @Sendable (RandomAccessSink) throws -> Void
    typealias SidecarWriter = @Sendable (HLSResumeRecord, URL) throws -> Void
    typealias NowProvider = @Sendable () -> ContinuousClock.Instant

    private let lock = NSLock()
    private var nextExpectedIndex: Int
    private var outOfOrder: [Int: HLSCompletedUnitDiskRef] = [:]
    private var stagedUnits: [HLSCompletedUnitDiskRef] = []
    private let sink: RandomAccessSink
    private let paths: HLSTemporaryPaths
    private let fileIdentity: HLSResumeFileIdentity
    private(set) var currentOutputBytes: Int64
    private(set) var committedOutputBytes: Int64
    private var stagedUncommittedBytes: Int64 = 0
    private var lastCommitTime: ContinuousClock.Instant
    private let groupCommitBytesThreshold: Int64
    private let groupCommitTimeThreshold: Duration
    private let nowProvider: NowProvider
    private let sinkSynchronizer: SinkSynchronizer?
    private let sidecarWriter: SidecarWriter?

    // Observable metrics for tests and benchmarks
    private(set) var syncCount: Int = 0
    private(set) var sidecarWriteCount: Int = 0

    init(
        initialExpectedIndex: Int,
        sink: RandomAccessSink,
        paths: HLSTemporaryPaths,
        fileIdentity: HLSResumeFileIdentity,
        initialOutputBytes: Int64,
        groupCommitBytesThreshold: Int64 = 8 * 1024 * 1024,
        groupCommitTimeThreshold: Duration = .seconds(5),
        nowProvider: @escaping NowProvider = { ContinuousClock.now },
        sinkSynchronizer: SinkSynchronizer? = nil,
        sidecarWriter: SidecarWriter? = nil
    ) {
        self.nextExpectedIndex = initialExpectedIndex
        self.sink = sink
        self.paths = paths
        self.fileIdentity = fileIdentity
        self.currentOutputBytes = initialOutputBytes
        self.committedOutputBytes = initialOutputBytes
        self.groupCommitBytesThreshold = groupCommitBytesThreshold
        self.groupCommitTimeThreshold = groupCommitTimeThreshold
        self.nowProvider = nowProvider
        self.sinkSynchronizer = sinkSynchronizer
        self.sidecarWriter = sidecarWriter
        self.lastCommitTime = nowProvider()
    }

    private var _maxObservedOutOfOrderCount: Int = 0

    var maxObservedOutOfOrderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxObservedOutOfOrderCount
    }

    var outOfOrderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outOfOrder.count
    }

    var uncommittedStagedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stagedUnits.count
    }

    var stats: (syncCount: Int, sidecarWriteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (syncCount, sidecarWriteCount)
    }

    func accept(
        completedRef: HLSCompletedUnitDiskRef,
        mutableState: inout HLSResumeState,
        forceFlush: Bool = false
    ) throws -> [(Int, Int64)] {
        lock.lock()
        defer { lock.unlock() }

        outOfOrder[completedRef.index] = completedRef
        if outOfOrder.count > _maxObservedOutOfOrderCount {
            _maxObservedOutOfOrderCount = outOfOrder.count
        }

        while let next = outOfOrder.removeValue(forKey: nextExpectedIndex) {
            let previousOutputBytes = currentOutputBytes
            do {
                try appendUnitToSink(from: next.tempURL, expectedBytes: next.byteCount)
                currentOutputBytes += next.byteCount
                stagedUncommittedBytes += next.byteCount
                stagedUnits.append(next)
                nextExpectedIndex += 1
            } catch {
                currentOutputBytes = previousOutputBytes
                do {
                    try sink.truncate(to: committedOutputBytes)
                    try synchronizeSinkLocked()
                } catch let rollbackError {
                    if let firstIncomplete = mutableState.units.first(where: { !$0.completed })?.unitIndex {
                        nextExpectedIndex = firstIncomplete
                    }
                    stagedUnits.removeAll(keepingCapacity: true)
                    outOfOrder.removeAll()
                    throw IDMError.storageError(
                        "Append unit failed (\(error.localizedDescription)) and rollback truncate failed: \(rollbackError.localizedDescription)"
                    )
                }
                throw error
            }
        }

        let now = nowProvider()
        let shouldCommit =
            forceFlush
            || stagedUncommittedBytes >= groupCommitBytesThreshold
            || (now - lastCommitTime) >= groupCommitTimeThreshold

        if shouldCommit && !stagedUnits.isEmpty {
            return try executeGroupCommitLocked(mutableState: &mutableState, now: now)
        }
        return []
    }

    /// Quiesces sequentially staged units on pause/cancel or final completion before publishing.
    /// Storage errors during quiesce are thrown directly.
    func quiesce(mutableState: inout HLSResumeState) throws -> [(Int, Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard !stagedUnits.isEmpty else { return [] }
        return try executeGroupCommitLocked(mutableState: &mutableState, now: nowProvider())
    }

    /// Rolls back any uncommitted staged data on ordinary errors, truncating sink to last committed boundary.
    func rollbackUncommitted(mutableState: inout HLSResumeState) throws {
        lock.lock()
        defer { lock.unlock() }
        currentOutputBytes = committedOutputBytes
        stagedUncommittedBytes = 0
        do {
            try sink.truncate(to: committedOutputBytes)
            try synchronizeSinkLocked()
        } catch {
            if let firstIncomplete = mutableState.units.first(where: { !$0.completed })?.unitIndex {
                nextExpectedIndex = firstIncomplete
            }
            stagedUnits.removeAll(keepingCapacity: true)
            outOfOrder.removeAll()
            throw IDMError.storageError("Rollback truncate/sync failed: \(error.localizedDescription)")
        }
        if let firstIncomplete = mutableState.units.first(where: { !$0.completed })?.unitIndex {
            nextExpectedIndex = firstIncomplete
        }
        stagedUnits.removeAll(keepingCapacity: true)
        outOfOrder.removeAll()
    }

    private func executeGroupCommitLocked(
        mutableState: inout HLSResumeState,
        now: ContinuousClock.Instant
    ) throws -> [(Int, Int64)] {
        var candidateState = mutableState
        for unit in stagedUnits {
            try candidateState.markCompleted(unitIndex: unit.index, receivedBytes: unit.byteCount)
        }
        do {
            try synchronizeSinkLocked()
            syncCount += 1
            let record = candidateState.record(fileIdentity: fileIdentity)
            if let sidecarWriter {
                try sidecarWriter(record, paths.sidecar)
            } else {
                try HLSResumeStore.write(record, to: paths.sidecar)
            }
            sidecarWriteCount += 1

            mutableState = candidateState
            committedOutputBytes = currentOutputBytes
            stagedUncommittedBytes = 0
            lastCommitTime = now

            let committed = stagedUnits.map { ($0.index, $0.byteCount) }
            for unit in stagedUnits {
                try? FileManager.default.removeItem(at: unit.tempURL)
            }
            stagedUnits.removeAll(keepingCapacity: true)
            return committed
        } catch {
            currentOutputBytes = committedOutputBytes
            stagedUncommittedBytes = 0
            do {
                try sink.truncate(to: committedOutputBytes)
                try synchronizeSinkLocked()
            } catch let rollbackError {
                if let firstIncomplete = mutableState.units.first(where: { !$0.completed })?.unitIndex {
                    nextExpectedIndex = firstIncomplete
                }
                stagedUnits.removeAll(keepingCapacity: true)
                outOfOrder.removeAll()
                throw IDMError.storageError(
                    "Commit failed and rollback truncate failed: \(error.localizedDescription) / \(rollbackError.localizedDescription)"
                )
            }
            if let firstIncomplete = mutableState.units.first(where: { !$0.completed })?.unitIndex {
                nextExpectedIndex = firstIncomplete
            }
            stagedUnits.removeAll(keepingCapacity: true)
            outOfOrder.removeAll()
            throw error
        }
    }

    private func synchronizeSinkLocked() throws {
        if let sinkSynchronizer {
            try sinkSynchronizer(sink)
        } else {
            try sink.synchronize()
        }
    }

    private func appendUnitToSink(from unitURL: URL, expectedBytes: Int64) throws {
        let handle = try FileHandle(forReadingFrom: unitURL)
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var writtenForUnit: Int64 = 0

        while writtenForUnit < expectedBytes {
            let toRead = Int(min(Int64(chunkSize), expectedBytes - writtenForUnit))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                break
            }
            let writeOffset = currentOutputBytes + writtenForUnit
            let writeLimit = currentOutputBytes + expectedBytes
            try sink.write(chunk, at: writeOffset, limit: writeLimit)
            writtenForUnit += Int64(chunk.count)
        }
        guard writtenForUnit == expectedBytes else {
            throw IDMError.storageError("Unit 写入长度不匹配 (预期 \(expectedBytes)，实际 \(writtenForUnit))")
        }
    }
}

struct HLSTemporaryPaths: Sendable {
    let directory: URL
    let unitPrefix: String
    let temporary: URL
    let sidecar: URL
    let baseName: String

    func unitTemporary(index: Int) -> URL {
        directory.appendingPathComponent("\(unitPrefix)\(index).macidm.hls.tmp")
    }
}

private actor HLSKeyCache {
    private var values: [String: Data] = [:]

    func value(
        for key: HLSEncryptionKey,
        client: any HLSResourceClient,
        requestContext: DownloadRequestContext?,
        contextOriginURL: URL,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> Data {
        let identity = "\(key.url.absoluteString)|\(key.iv ?? "")"
        if let value = values[identity] { return value }
        let response = try await client.fetch(
            HLSFetchRequest(
                url: key.url,
                requestContext: requestContext,
                contextOriginURL: contextOriginURL,
                control: control
            ))
        guard response.statusCode == 200, response.data.count == 16 else {
            throw HLSAES128Error.invalidKeyLength
        }
        values[identity] = response.data
        return response.data
    }
}

enum HLSResumeStore {
    private struct Envelope: Codable {
        let record: HLSResumeRecord
        let checksum: String
    }

    static func read(from url: URL) throws -> HLSResumeRecord {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard digest(try canonicalData(envelope.record)) == envelope.checksum else {
            throw IDMError.sidecarCorrupt
        }
        return envelope.record
    }

    static func write(
        _ record: HLSResumeRecord,
        to url: URL,
        synchronizeParentDirectory: Bool = false
    ) throws {
        let envelope = Envelope(record: record, checksum: digest(try canonicalData(record)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let temporary = url.appendingPathExtension("tmp.\(UUID().uuidString)")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        var isOpen = true
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let result = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw IDMError.storageError(String(cString: strerror(errno)))
                    }
                    if result == 0 {
                        throw IDMError.storageError("resume record write returned zero")
                    }
                    offset += result
                }
            }
            guard fsync(descriptor) == 0 else {
                throw IDMError.storageError(String(cString: strerror(errno)))
            }
            close(descriptor)
            isOpen = false
            guard rename(temporary.path, url.path) == 0 else {
                throw IDMError.storageError(String(cString: strerror(errno)))
            }
        } catch {
            if isOpen { close(descriptor) }
            unlink(temporary.path)
            throw error
        }
        if synchronizeParentDirectory {
            FileSupport.syncDirectory(url.deletingLastPathComponent())
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw IDMError.sidecarCorrupt }
        return size.int64Value
    }

    static func fileIdentity(_ url: URL) throws -> HLSResumeFileIdentity {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw IDMError.sidecarCorrupt
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw IDMError.sidecarCorrupt
        }
        return HLSResumeFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func canonicalData(_ record: HLSResumeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Small metadata fetch operation (strict 2MB cap)

private final class HLSDataFetchOperation: NSObject, URLSessionDataDelegate, SessionDataTaskRoutingDelegate,
    @unchecked Sendable
{
    private let request: HLSFetchRequest
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let scopedSession: TaskScopedSession?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HLSFetchResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var redirects = 0
    private var terminalError: Error?
    private var cancelled = false
    private var ownsSession = false

    init(
        request: HLSFetchRequest,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        scopedSession: TaskScopedSession? = nil
    ) {
        self.request = request
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.scopedSession = scopedSession
    }

    func run() async throws -> HLSFetchResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            if cancelled {
                lock.unlock()
                finish(.failure(terminalError ?? IDMError.cancelled))
                return
            }
            lock.unlock()
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "GET"
            request.requestContext?.apply(to: &urlRequest, boundTo: request.contextOriginURL)
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let byteRange = request.byteRange {
                guard byteRange.length > 0 else {
                    finish(.failure(IDMError.invalidContentRange))
                    return
                }
                urlRequest.setValue(
                    "bytes=\(byteRange.offset)-\(byteRange.offset + byteRange.length - 1)",
                    forHTTPHeaderField: "Range"
                )
            }
            let session: URLSession
            let ownsSession: Bool
            if let scoped = self.scopedSession {
                session = scoped.session
                ownsSession = false
            } else {
                let configuration = EngineSessionPolicy.makeConfiguration(
                    requestTimeout: requestTimeout,
                    resourceTimeout: resourceTimeout
                )
                session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                ownsSession = true
            }
            let task = session.dataTask(with: urlRequest)
            if let scoped = self.scopedSession {
                scoped.multiplexer.register(dataTask: task, delegate: self)
            }
            lock.lock()
            self.task = task
            self.ownsSession = ownsSession
            if cancelled {
                task.cancel()
            }
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if terminalError == nil { terminalError = IDMError.cancelled }
        let task = self.task
        lock.unlock()
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
        redirects += 1
        guard redirects <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            terminalError = IDMError.invalidURL
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
        guard let response = response as? HTTPURLResponse else {
            terminalError = IDMError.invalidURL
            completionHandler(.cancel)
            return
        }
        self.response = response
        if response.expectedContentLength > 2 * 1024 * 1024 {
            terminalError = IDMError.resourceTooLarge(2 * 1024 * 1024)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let control = request.control {
            switch control() {
            case .continue: break
            case .pause:
                terminalError = IDMError.paused
                dataTask.cancel()
                return
            case .cancel:
                terminalError = IDMError.cancelled
                dataTask.cancel()
                return
            }
        }
        guard Int64(self.data.count) <= 2 * 1024 * 1024 - Int64(data.count) else {
            terminalError = IDMError.resourceTooLarge(2 * 1024 * 1024)
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let ownsSession = self.ownsSession
        let scoped = self.scopedSession
        let currentTask = self.task
        lock.unlock()
        if let currentTask, let scoped {
            scoped.multiplexer.unregister(taskIdentifier: currentTask.taskIdentifier)
        }
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
        if let terminalError {
            finish(.failure(terminalError))
            return
        }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish(.failure(error))
            return
        }
        guard let response else {
            finish(.failure(IDMError.invalidURL))
            return
        }
        guard normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) == "identity" else {
            finish(.failure(IDMError.resourceChanged))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(
                .failure(
                    response.statusCode == 401
                        ? IDMError.authenticationRequired : IDMError.httpStatus(response.statusCode)))
            return
        }
        let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
        if let byteRange = request.byteRange {
            guard response.statusCode == 206,
                contentRange?.start == byteRange.offset,
                contentRange?.endInclusive == byteRange.offset + byteRange.length - 1,
                data.count == byteRange.length
            else {
                finish(.failure(IDMError.invalidContentRange))
                return
            }
        } else {
            guard response.statusCode == 200 else {
                finish(.failure(IDMError.httpStatus(response.statusCode)))
                return
            }
        }
        finish(
            .success(
                HLSFetchResponse(
                    data: data,
                    finalURL: response.url ?? request.url,
                    statusCode: response.statusCode,
                    contentRange: contentRange
                )))
    }

    private func finish(_ result: Result<HLSFetchResponse, Error>) {
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

// MARK: - True streaming media segment operation (URLSessionDownloadTask + unique transit
// file + MediaBufferBudget-bounded chunk copy)

private final class HLSStreamToFileOperation: NSObject, URLSessionDownloadDelegate, SessionDownloadTaskRoutingDelegate,
    @unchecked Sendable
{
    private struct OperationState {
        var continuation: CheckedContinuation<HLSStreamToFileResult, Error>?
        var downloadTask: URLSessionDownloadTask?
        var session: URLSession?
        var ownsSession: Bool = false
        var response: HTTPURLResponse?
        var transitURL: URL?
        var redirects: Int = 0
        var terminalError: Error?
        var isCancelled: Bool = false
        var completionTask: Task<Void, Never>?
        var networkError: Error?
        var didFinish: Bool = false
    }

    private let request: HLSFetchRequest
    private let destinationURL: URL
    private let budget: MediaBufferBudget
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let unitSafetyCap: Int64
    private let control: @Sendable () -> DownloadControl
    private let scopedSession: TaskScopedSession?
    private let progress: (@Sendable (Int64) -> Void)?

    private let stateLock = OSAllocatedUnfairLock(initialState: OperationState())

    init(
        request: HLSFetchRequest,
        destinationURL: URL,
        budget: MediaBufferBudget,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 24 * 60 * 60,
        unitSafetyCap: Int64 = DownloadResourceLimits.maximumMediaUnitBytes,
        control: @escaping @Sendable () -> DownloadControl,
        scopedSession: TaskScopedSession? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.budget = budget
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = unitSafetyCap
        self.control = control
        self.scopedSession = scopedSession
        self.progress = progress
    }

    func run() async throws -> HLSStreamToFileResult {
        // 1. Pre-validate the request before creating any file or Session
        //    (with Int64 addition overflow checks)
        if let byteRange = request.byteRange {
            guard byteRange.offset >= 0, byteRange.length > 0 else {
                throw IDMError.invalidContentRange
            }
            let (endPlusOne, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
            guard !overflow, endPlusOne > 0 else {
                throw IDMError.invalidContentRange
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let isAlreadyCancelled = stateLock.withLock { s -> Bool in
                    s.continuation = continuation
                    return s.isCancelled
                }
                if isAlreadyCancelled {
                    let err = stateLock.withLock { $0.terminalError ?? IDMError.cancelled }
                    finish(.failure(err))
                    return
                }

                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = "GET"
                request.requestContext?.apply(to: &urlRequest, boundTo: request.contextOriginURL)
                urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

                if let byteRange = request.byteRange {
                    let endInclusive = byteRange.offset + byteRange.length - 1
                    urlRequest.setValue(
                        "bytes=\(byteRange.offset)-\(endInclusive)",
                        forHTTPHeaderField: "Range"
                    )
                }

                let session: URLSession
                let ownsSession: Bool
                if let scoped = self.scopedSession {
                    session = scoped.session
                    ownsSession = false
                } else {
                    let configuration = EngineSessionPolicy.makeConfiguration(
                        requestTimeout: requestTimeout,
                        resourceTimeout: resourceTimeout
                    )
                    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    ownsSession = true
                }
                let task = session.downloadTask(with: urlRequest)
                if let scoped = self.scopedSession {
                    scoped.multiplexer.register(downloadTask: task, delegate: self)
                }

                let shouldCancel = stateLock.withLock { s -> Bool in
                    s.session = session
                    s.ownsSession = ownsSession
                    s.downloadTask = task
                    return s.isCancelled
                }

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
        let (task, compTask) = stateLock.withLock { s -> (URLSessionDownloadTask?, Task<Void, Never>?) in
            s.isCancelled = true
            if s.terminalError == nil { s.terminalError = IDMError.cancelled }
            return (s.downloadTask, s.completionTask)
        }
        task?.cancel()
        compTask?.cancel()
    }

    // MARK: - Common response metadata validation

    static func validateResponseMetadata(
        response: HTTPURLResponse,
        byteRange: HLSByteRange?
    ) throws {
        guard normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) == "identity" else {
            throw IDMError.resourceChanged
        }

        guard (200...299).contains(response.statusCode) else {
            let err =
                (response.statusCode == 401)
                ? IDMError.authenticationRequired
                : IDMError.httpStatus(response.statusCode)
            throw err
        }

        let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
        if let byteRange {
            let (endPlusOne, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
            guard !overflow, endPlusOne > 0 else {
                throw IDMError.invalidContentRange
            }
            let expectedEndInclusive = endPlusOne - 1
            guard response.statusCode == 206,
                let contentRange,
                contentRange.start == byteRange.offset,
                contentRange.endInclusive == expectedEndInclusive,
                contentRange.total >= endPlusOne
            else {
                throw IDMError.invalidContentRange
            }
        } else {
            // Without a Range request it must be exactly 200 OK (206 is not acceptable)
            guard response.statusCode == 200 else {
                throw IDMError.httpStatus(response.statusCode)
            }
        }
    }

    // MARK: - URLSession Delegate

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
        let count = stateLock.withLock { s -> Int in
            s.redirects += 1
            return s.redirects
        }

        guard count <= 10,
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
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            stateLock.withLock { $0.response = httpResponse }
            // On the first progress callback, quickly pre-validate response metadata
            do {
                try Self.validateResponseMetadata(response: httpResponse, byteRange: request.byteRange)
            } catch {
                setTerminalError(error)
                downloadTask.cancel()
                return
            }
        }

        switch control() {
        case .continue:
            break
        case .pause:
            setTerminalError(IDMError.paused)
            downloadTask.cancel()
            return
        case .cancel:
            setTerminalError(IDMError.cancelled)
            downloadTask.cancel()
            return
        }

        if totalBytesWritten > unitSafetyCap || totalBytesExpectedToWrite > unitSafetyCap {
            setTerminalError(IDMError.resourceTooLarge(unitSafetyCap))
            downloadTask.cancel()
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            stateLock.withLock { $0.response = httpResponse }
        }

        // Critical: keep the transit file in a dedicated path on the same filesystem as
        // `location`, ensuring a fast same-volume atomic rename
        let transitDir = location.deletingLastPathComponent()
        let transit = transitDir.appendingPathComponent("macidm_transit.\(UUID().uuidString).tmp")

        do {
            if FileManager.default.fileExists(atPath: transit.path) {
                try? FileManager.default.removeItem(at: transit)
            }
            try FileManager.default.moveItem(at: location, to: transit)
            stateLock.withLock { $0.transitURL = transit }
        } catch {
            setTerminalError(IDMError.storageError(error.localizedDescription))
        }

        // Never declare success here; wait for didCompleteWithError to run terminal handling
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Critical: atomically record the network terminal state, then create and
        // register the completionTask
        let (isCancelled, compTask) = stateLock.withLock { s -> (Bool, Task<Void, Never>) in
            s.networkError = error
            if let httpResponse = task.response as? HTTPURLResponse {
                s.response = httpResponse
            }
            let comp = Task { [weak self] in
                guard let self else { return }
                await self.processDownloadCompletion()
            }
            s.completionTask = comp
            return (s.isCancelled, comp)
        }

        if isCancelled {
            compTask.cancel()
        }
    }

    // MARK: - Terminal-state handling and MediaBufferBudget-bounded chunk copy

    private func processDownloadCompletion() async {
        let snap = stateLock.withLock {
            s -> (
                err: Error?,
                transit: URL?,
                resp: HTTPURLResponse?,
                cancelled: Bool,
                sess: URLSession?,
                task: URLSessionDownloadTask?,
                ownsSession: Bool
            ) in
            guard !s.didFinish else { return (nil, nil, nil, false, nil, nil, false) }
            s.didFinish = true
            let finalErr = s.terminalError ?? s.networkError
            return (finalErr, s.transitURL, s.response, s.isCancelled, s.session, s.downloadTask, s.ownsSession)
        }

        guard let session = snap.sess else { return }

        var destinationCreatedBySelf = false
        var createdSink: SafeFileDescriptor? = nil
        let transitURL = snap.transit
        var completionResult: Result<HLSStreamToFileResult, Error>

        do {
            if let err = snap.err {
                throw err
            }
            if snap.cancelled || Task.isCancelled {
                throw IDMError.cancelled
            }
            guard let transitURL, FileManager.default.fileExists(atPath: transitURL.path) else {
                throw IDMError.invalidURL
            }
            guard let response = snap.resp else {
                throw IDMError.invalidURL
            }

            // Strictly re-validate metadata at the terminal state
            try Self.validateResponseMetadata(response: response, byteRange: request.byteRange)

            let transitSize = try FileSupport.fileSize(transitURL)
            guard transitSize <= unitSafetyCap else {
                throw IDMError.resourceTooLarge(unitSafetyCap)
            }

            if let byteRange = request.byteRange {
                guard transitSize == byteRange.length else {
                    throw IDMError.invalidContentRange
                }
            }

            // Create the destination file exclusively; if a same-named file already exists,
            // throw an error and never delete the existing file
            let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
            createdSink = sink
            destinationCreatedBySelf = true

            let readHandle = try FileHandle(forReadingFrom: transitURL)
            defer { try? readHandle.close() }

            let chunkSize = min(64 * 1024, max(1024, Int(budget.capacity)))
            var copiedBytes: Int64 = 0

            while copiedBytes < transitSize {
                try Task.checkCancellation()
                switch control() {
                case .continue: break
                case .pause: throw IDMError.paused
                case .cancel: throw IDMError.cancelled
                }

                let toRead = Int(min(Int64(chunkSize), transitSize - copiedBytes))

                // Critical: acquire budget before reading each chunk from disk and writing it
                let reservation = try await budget.reserve(bytes: Int64(toRead))
                do {
                    guard let chunk = try readHandle.read(upToCount: toRead), !chunk.isEmpty else {
                        reservation.release()
                        break
                    }
                    try sink.writeAll(chunk)
                    reservation.release()
                    copiedBytes += Int64(chunk.count)
                    progress?(Int64(chunk.count))
                } catch {
                    reservation.release()
                    throw error
                }
            }

            guard copiedBytes == transitSize else {
                throw IDMError.storageError("复制字节数不完整 (预期 \(transitSize)，实际 \(copiedBytes))")
            }

            try sink.synchronize()
            try sink.closeFile()
            createdSink = nil  // closed successfully

            let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
            completionResult = .success(
                HLSStreamToFileResult(
                    finalURL: response.url ?? request.url,
                    statusCode: response.statusCode,
                    byteCount: copiedBytes,
                    contentRange: contentRange
                ))
        } catch {
            let finalError: Error
            if Task.isCancelled || (error as? IDMError) == .cancelled || error is CancellationError {
                finalError = IDMError.cancelled
            } else {
                finalError = error
            }
            completionResult = .failure(finalError)
        }

        // Complete file cleanup and terminate the session before waking the continuation with finish.
        if let task = snap.task, let scoped = self.scopedSession {
            scoped.multiplexer.unregister(taskIdentifier: task.taskIdentifier)
        }
        if snap.ownsSession {
            switch completionResult {
            case .success:
                session.finishTasksAndInvalidate()
            case .failure:
                session.invalidateAndCancel()
            }
        }
        switch completionResult {
        case .success:
            if let transitURL {
                try? FileManager.default.removeItem(at: transitURL)
            }
        case .failure:
            if let createdSink {
                try? createdSink.closeFile()
            }
            if destinationCreatedBySelf {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            if let transitURL {
                try? FileManager.default.removeItem(at: transitURL)
            }
        }

        stateLock.withLock { s in
            s.session = nil
            s.downloadTask = nil
            s.transitURL = nil
            s.completionTask = nil
        }

        // Destination/transit cleanup and session termination have been issued;
        // wake the continuation without waiting for the asynchronous invalidation callback.
        finish(completionResult)
    }

    private func finish(_ result: Result<HLSStreamToFileResult, Error>) {
        let cont = stateLock.withLock { s -> CheckedContinuation<HLSStreamToFileResult, Error>? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.resume(with: result)
    }

    private func setTerminalError(_ error: Error) {
        stateLock.withLock { s in
            if s.terminalError == nil {
                s.terminalError = error
            }
        }
    }
}
