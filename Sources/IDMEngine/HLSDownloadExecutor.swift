import CryptoKit
import Darwin
import Foundation
import os

extension HLSDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .mergerUnavailable:
            return "HLS 音视频合并需要已配置的 FFmpeg 合并服务。"
        }
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
                control: control,
                titleMetadata: FFmpegMetadata.title(forOutput: request.destination)
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
                control: control,
                titleMetadata: FFmpegMetadata.title(forOutput: pair.destination)
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
