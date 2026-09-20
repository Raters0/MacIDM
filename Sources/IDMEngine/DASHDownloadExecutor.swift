import CryptoKit
import Darwin
import Foundation

public struct DASHDownloadRequest: Sendable {
    public let url: URL
    public let destination: URL
    public let outputKind: FFmpegOutputKind
    public let maximumParallelRequests: Int
    public let taskID: UUID
    public let requestContext: DownloadRequestContext?
    public let rateLimiter: (any DownloadRateLimiting)?

    public init(
        url: URL,
        destination: URL,
        outputKind: FFmpegOutputKind = .mp4,
        maximumParallelRequests: Int = 8,
        taskID: UUID = UUID(),
        requestContext: DownloadRequestContext? = nil,
        rateLimiter: (any DownloadRateLimiting)? = nil
    ) {
        self.url = url
        self.destination = destination
        self.outputKind = outputKind
        self.maximumParallelRequests = maximumParallelRequests
        self.taskID = taskID
        self.requestContext = requestContext
        self.rateLimiter = rateLimiter
    }
}

public struct DASHPairDownloadRequest: Sendable {
    public let videoURL: URL
    public let audioURL: URL
    public let destination: URL
    public let outputKind: FFmpegOutputKind
    public let maximumParallelRequests: Int
    public let taskID: UUID
    public let requestContext: DownloadRequestContext?
    public let rateLimiter: (any DownloadRateLimiting)?

    public init(
        videoURL: URL,
        audioURL: URL,
        destination: URL,
        outputKind: FFmpegOutputKind = .mp4,
        maximumParallelRequests: Int = 8,
        taskID: UUID = UUID(),
        requestContext: DownloadRequestContext? = nil,
        rateLimiter: (any DownloadRateLimiting)? = nil
    ) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.destination = destination
        self.outputKind = outputKind
        self.maximumParallelRequests = maximumParallelRequests
        self.taskID = taskID
        self.requestContext = requestContext
        self.rateLimiter = rateLimiter
    }
}

public enum DASHDownloadError: Error, Equatable, Sendable {
    case mergerUnavailable
    case missingVideoRepresentation
    case invalidResponse
    case resumeCorrupt
    case resumeIncompatible
}

extension DASHDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .mergerUnavailable: "DASH 下载需要已配置的 FFmpeg 合并服务。"
        case .missingVideoRepresentation: "DASH MPD 没有可合并的视频或音频轨道。"
        case .invalidResponse: "DASH 分片响应不符合请求的范围。"
        case .resumeCorrupt: "DASH 断点记录与临时分片不一致。"
        case .resumeIncompatible: "DASH 资源已变化，不能继续拼接旧分片。"
        }
    }
}

public struct DASHDownloadExecutor: Sendable {
    private let client: any HLSResourceClient
    private let parser: DASHParser
    private let merger: (any FFmpegMerging)?
    private let budget: MediaBufferBudget?
    private let groupCommitBytesThreshold: Int64
    private let groupCommitTimeThreshold: Duration

    public init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        parser: DASHParser = DASHParser(),
        merger: (any FFmpegMerging)? = nil,
        budget: MediaBufferBudget? = nil,
        groupCommitBytesThreshold: Int64 = 8 * 1024 * 1024,
        groupCommitTimeThreshold: Duration = .seconds(5)
    ) {
        self.client = client
        self.parser = parser
        self.merger = merger
        self.budget = budget
        self.groupCommitBytesThreshold = groupCommitBytesThreshold
        self.groupCommitTimeThreshold = groupCommitTimeThreshold
    }

    public func download(
        _ request: DASHDownloadRequest,
        control: @escaping @Sendable () -> DownloadControl = { .continue },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadResult {
        try validate(request)
        guard let merger else { throw DASHDownloadError.mergerUnavailable }

        let taskBudget =
            budget
            ?? MediaBufferBudget(
                capacity: DownloadResourceLimits.maximumTaskBufferedResourceBytes,
                parent: GlobalMediaBufferBudget.shared
            )

        let manifestResponse = try await client.fetch(
            HLSFetchRequest(
                url: request.url,
                requestContext: request.requestContext,
                contextOriginURL: request.url,
                control: control
            )
        )
        guard manifestResponse.statusCode == 200,
            let text = String(data: manifestResponse.data, encoding: .utf8)
        else { throw DASHDownloadError.invalidResponse }
        let manifest = try parser.parse(text, baseURL: manifestResponse.finalURL)
        let video = manifest.videoRepresentations.max(by: compareRepresentation)
        let audio = manifest.audioRepresentations.max(by: compareRepresentation)
        guard video != nil || audio != nil else {
            throw DASHDownloadError.missingVideoRepresentation
        }
        let temporaryDirectory = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(request.taskID.uuidString).macidm.dash", isDirectory: true)
        let sidecarURL = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(request.taskID.uuidString).macidm.dash.resume")
        let selectedRepresentations: [(key: String, representation: DASHRepresentation)] = [
            video.map { ("video:" + $0.id, $0) },
            audio.map { ("audio:" + $0.id, $0) },
        ].compactMap { $0 }
        let manifestFingerprint = digest(Data(manifestResponse.data))
        let expectedResume = DASHResumeRecord(
            formatVersion: 1,
            taskID: request.taskID,
            manifestFingerprint: manifestFingerprint,
            representations: selectedRepresentations.map { item in
                DASHResumeRepresentation(
                    id: item.key,
                    units: resumeUnits(for: item.representation)
                )
            }
        )
        let tracker: DASHResumeTracker
        let resumed: Bool
        if FileManager.default.fileExists(atPath: sidecarURL.path),
            FileManager.default.fileExists(atPath: temporaryDirectory.path)
        {
            do {
                tracker = try DASHResumeTracker(
                    sidecarURL: sidecarURL,
                    expected: expectedResume
                )
                resumed = tracker.hasCompletedUnits
            } catch {
                try? FileManager.default.removeItem(at: temporaryDirectory)
                try? FileManager.default.removeItem(at: sidecarURL)
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                tracker = try DASHResumeTracker(sidecarURL: sidecarURL, record: expectedResume)
                resumed = false
            }
        } else {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try? FileManager.default.removeItem(at: sidecarURL)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            tracker = try DASHResumeTracker(sidecarURL: sidecarURL, record: expectedResume)
            resumed = false
        }
        let videoURL = temporaryDirectory.appendingPathComponent("video.m4s")
        let audioURL = temporaryDirectory.appendingPathComponent("audio.m4s")
        var cleanup = false
        defer {
            if cleanup || control() == .cancel {
                try? FileManager.default.removeItem(at: temporaryDirectory)
                try? FileManager.default.removeItem(at: sidecarURL)
            } else {
                cleanupDASHUnitTemporaries(in: temporaryDirectory)
            }
        }
        let progressBox = DASHPairProgressBox(progress: progress)

        if let video {
            _ = try await downloadRepresentation(
                video,
                to: videoURL,
                temporaryDirectory: temporaryDirectory,
                request: request,
                control: control,
                tracker: tracker,
                resumeID: "video:" + video.id,
                budget: taskBudget,
                progress: { received, total in
                    progressBox.update(
                        track: .video,
                        value: DownloadProgress(
                            receivedBytes: received,
                            totalBytes: total > 0 ? total : nil
                        )
                    )
                }
            )
        }
        if let audio {
            _ = try await downloadRepresentation(
                audio,
                to: audioURL,
                temporaryDirectory: temporaryDirectory,
                request: request,
                control: control,
                tracker: tracker,
                resumeID: "audio:" + audio.id,
                budget: taskBudget,
                progress: { received, total in
                    progressBox.update(
                        track: .audio,
                        value: DownloadProgress(
                            receivedBytes: received,
                            totalBytes: total > 0 ? total : nil
                        )
                    )
                }
            )
        }
        try checkControl(control)
        let mergeResult = try await merger.merge(
            FFmpegMergeRequest(
                videoURL: video == nil ? nil : videoURL,
                audioURL: audio == nil ? nil : audioURL,
                outputURL: request.destination,
                outputKind: request.outputKind,
                expectedDuration: manifest.duration,
                control: control
            )
        )
        cleanup = true
        return DownloadResult(
            destination: mergeResult.destination,
            byteCount: mergeResult.byteCount,
            sha256: mergeResult.sha256,
            usedParallelRequests: request.maximumParallelRequests,
            resumed: resumed,
            verification: "dash-ffmpeg-ffprobe"
        )
    }

    public func downloadPair(
        _ request: DASHPairDownloadRequest,
        control: @escaping @Sendable () -> DownloadControl = { .continue },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
        directDownload:
            @escaping @Sendable (
                DownloadRequest,
                @escaping @Sendable () -> DownloadControl,
                @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> DownloadResult
    ) async throws -> DownloadResult {
        try validatePair(request)
        guard let merger else { throw DASHDownloadError.mergerUnavailable }

        let directory = request.destination.deletingLastPathComponent()
            .appendingPathComponent(
                "." + request.taskID.uuidString + ".macidm.dash-pair",
                isDirectory: true
            )
        try checkControl(control)
        var checkpoint = try MediaPairCheckpoint(
            directory: directory, videoURL: request.videoURL, audioURL: request.audioURL)
        let videoDestination = directory.appendingPathComponent("video.m4s")
        let audioDestination = directory.appendingPathComponent("audio.m4s")
        var cleanup = false
        defer {
            if cleanup || control() == .cancel {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let progressBox = DASHPairProgressBox(progress: progress)
        let videoRequest = DownloadRequest(
            url: request.videoURL,
            destination: videoDestination,
            sourceKind: .http,
            maximumParallelRequests: request.maximumParallelRequests,
            taskID: request.taskID,
            requestContext: request.requestContext,
            rateLimiter: request.rateLimiter
        )
        let videoResult: DownloadResult
        if let existing = try checkpoint.existingTrack(at: videoDestination) {
            videoResult = existing
            progressBox.update(
                track: .video,
                value: DownloadProgress(
                    receivedBytes: existing.byteCount,
                    totalBytes: existing.byteCount
                )
            )
        } else {
            videoResult = try await directDownload(
                videoRequest,
                control,
                { value in progressBox.update(track: .video, value: value) }
            )
            try checkpoint.recordCompleted(at: videoDestination)
        }

        try checkControl(control)
        let audioRequest = DownloadRequest(
            url: request.audioURL,
            destination: audioDestination,
            sourceKind: .http,
            maximumParallelRequests: request.maximumParallelRequests,
            taskID: request.taskID,
            requestContext: request.requestContext,
            rateLimiter: request.rateLimiter
        )
        let audioResult: DownloadResult
        if let existing = try checkpoint.existingTrack(at: audioDestination) {
            audioResult = existing
            progressBox.update(
                track: .audio,
                value: DownloadProgress(
                    receivedBytes: existing.byteCount,
                    totalBytes: existing.byteCount
                )
            )
        } else {
            audioResult = try await directDownload(
                audioRequest,
                control,
                { value in progressBox.update(track: .audio, value: value) }
            )
            try checkpoint.recordCompleted(at: audioDestination)
        }

        try checkControl(control)
        let mergeResult = try await merger.merge(
            FFmpegMergeRequest(
                videoURL: videoDestination,
                audioURL: audioDestination,
                outputURL: request.destination,
                outputKind: request.outputKind,
                expectedDuration: nil,
                control: control
            )
        )
        cleanup = true
        return DownloadResult(
            destination: mergeResult.destination,
            byteCount: mergeResult.byteCount,
            sha256: mergeResult.sha256,
            usedParallelRequests: request.maximumParallelRequests,
            resumed: videoResult.resumed || audioResult.resumed,
            verification: "dash-pair-ffmpeg-ffprobe"
        )
    }

    private func downloadRepresentation(
        _ representation: DASHRepresentation,
        to destination: URL,
        temporaryDirectory: URL,
        request: DASHDownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        tracker: DASHResumeTracker,
        resumeID: String,
        budget: MediaBufferBudget,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (receivedBytes: Int64, totalBytes: Int64) {
        let units: [(url: URL, range: DASHByteRange?)] =
            (representation.initialization.map { [(url: $0.url, range: $0.byteRange)] } ?? [])
            + representation.segments.map { (url: $0.url, range: $0.byteRange) }
        guard !units.isEmpty else { throw DASHDownloadError.missingVideoRepresentation }
        let fingerprints = tracker.fingerprints(for: resumeID)
        guard fingerprints.count == units.count else { throw DASHDownloadError.resumeIncompatible }
        let completedUnits = tracker.completedCount(for: resumeID)
        let expectedBytes = tracker.completedBytes(for: resumeID)

        // A hostile manifest can declare a range ending at Int64.max whose
        // saturated length overflows the sum; the total is an estimate, so
        // overflow degrades it to "unknown" instead of trapping.
        var knownTotalSum: Int64 = 0
        var totalOverflow = false
        if units.allSatisfy({ $0.range != nil }) {
            for unit in units {
                let summed = knownTotalSum.addingReportingOverflow(unit.range?.length ?? 0)
                if summed.overflow {
                    totalOverflow = true
                    break
                }
                knownTotalSum = summed.partialValue
            }
        }
        let knownTotalBytes = totalOverflow ? 0 : knownTotalSum
        var estimatedTotalBytes: Int64 = knownTotalBytes
        if completedUnits > units.count { throw DASHDownloadError.resumeCorrupt }
        if !FileManager.default.fileExists(atPath: destination.path) {
            let initialSink = try SafeFileDescriptor(creatingExclusiveAt: destination)
            try initialSink.closeFile()
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let storedSize = attributes[.size] as? NSNumber, storedSize.int64Value >= expectedBytes else {
            throw DASHDownloadError.resumeCorrupt
        }

        if storedSize.int64Value > expectedBytes {
            try handle.truncate(atOffset: UInt64(expectedBytes))
            guard fsync(handle.fileDescriptor) == 0 else {
                throw IDMError.storageError(String(cString: strerror(errno)))
            }
        }
        try handle.seek(toOffset: UInt64(expectedBytes))
        var received: Int64 = expectedBytes
        var expected: Int64 = expectedBytes
        let baseInFlight = Swift.min(
            request.maximumParallelRequests,
            DownloadResourceLimits.maximumMediaInFlightRequests
        )
        var activeConcurrency = max(1, baseInFlight)

        var stagedUnitsToCommit: [(index: Int, tempURL: URL, size: Int64)] = []
        var committedBoundaryOffset = received
        var stagedUncommittedBytes: Int64 = 0
        var lastCommitInstant = ContinuousClock.now
        let groupCommitBytesThreshold: Int64 = self.groupCommitBytesThreshold
        let groupCommitTimeThreshold: Duration = self.groupCommitTimeThreshold

        func commitStagedBatch() throws {
            guard !stagedUnitsToCommit.isEmpty else { return }
            let initialSyncRes = fsync(handle.fileDescriptor)
            let initialSyncErrno = errno
            guard initialSyncRes == 0 else {
                do {
                    try handle.truncate(atOffset: UInt64(committedBoundaryOffset))
                    let rollbackSyncRes = fsync(handle.fileDescriptor)
                    let rollbackSyncErrno = errno
                    if rollbackSyncRes != 0 {
                        throw IDMError.storageError(String(cString: strerror(rollbackSyncErrno)))
                    }
                } catch let rollbackErr {
                    throw IDMError.storageError(
                        "fsync failed (\(String(cString: strerror(initialSyncErrno)))) and rollback truncate failed: \(rollbackErr.localizedDescription)"
                    )
                }
                throw IDMError.storageError(String(cString: strerror(initialSyncErrno)))
            }
            do {
                try tracker.markCompletedBatch(
                    representationID: resumeID,
                    units: stagedUnitsToCommit.map { ($0.index, $0.size) }
                )
                for item in stagedUnitsToCommit {
                    try? FileManager.default.removeItem(at: item.tempURL)
                }
                committedBoundaryOffset = received
                stagedUncommittedBytes = 0
                lastCommitInstant = ContinuousClock.now
                stagedUnitsToCommit.removeAll(keepingCapacity: true)
            } catch {
                do {
                    try handle.truncate(atOffset: UInt64(committedBoundaryOffset))
                    let rollbackSyncRes = fsync(handle.fileDescriptor)
                    let rollbackSyncErrno = errno
                    if rollbackSyncRes != 0 {
                        throw IDMError.storageError(String(cString: strerror(rollbackSyncErrno)))
                    }
                } catch let rollbackError {
                    received = committedBoundaryOffset
                    stagedUncommittedBytes = 0
                    stagedUnitsToCommit.removeAll(keepingCapacity: true)
                    throw IDMError.storageError(
                        "Sidecar commit failed (\(error.localizedDescription)) and rollback truncate failed: \(rollbackError.localizedDescription)"
                    )
                }
                received = committedBoundaryOffset
                stagedUncommittedBytes = 0
                stagedUnitsToCommit.removeAll(keepingCapacity: true)
                throw error
            }
        }

        func rollbackStagedBatch() throws {
            do {
                try handle.truncate(atOffset: UInt64(committedBoundaryOffset))
                let syncRes = fsync(handle.fileDescriptor)
                let syncErrno = errno
                guard syncRes == 0 else {
                    throw IDMError.storageError(String(cString: strerror(syncErrno)))
                }
            } catch {
                received = committedBoundaryOffset
                stagedUncommittedBytes = 0
                stagedUnitsToCommit.removeAll(keepingCapacity: true)
                throw IDMError.storageError("DASH rollback truncate failed: \(error.localizedDescription)")
            }
            received = committedBoundaryOffset
            stagedUncommittedBytes = 0
            stagedUnitsToCommit.removeAll(keepingCapacity: true)
        }

        var nextUnitIndex = completedUnits
        do {
            while nextUnitIndex < units.count {
                try checkControl(control)
                var fetchedUnits: [(Int, URL, Int64)] = []
                var batchSucceeded = false
                var retriesRemaining = 3
                var currentBatchCount = 0

                while !batchSucceeded && retriesRemaining >= 0 {
                    try checkControl(control)
                    let currentBatchSize = max(1, activeConcurrency)
                    let batchEnd = min(units.count, nextUnitIndex + currentBatchSize)
                    let batchCount = batchEnd - nextUnitIndex
                    currentBatchCount = batchCount

                    do {
                        fetchedUnits = try await withThrowingTaskGroup(of: (Int, URL, Int64).self) { group in
                            for i in 0..<batchCount {
                                let uIndex = nextUnitIndex + i
                                let unit = units[uIndex]
                                let safeID = resumeID.replacingOccurrences(of: ":", with: "_")
                                let unitTemp = temporaryDirectory.appendingPathComponent(
                                    "unit-\(safeID)-\(uIndex).dash.tmp")
                                group.addTask {
                                    let size = try await fetchDASHUnitToDisk(
                                        unit: unit,
                                        destinationURL: unitTemp,
                                        requestContext: request.requestContext,
                                        contextOriginURL: request.url,
                                        budget: budget,
                                        control: control
                                    )
                                    return (uIndex, unitTemp, size)
                                }
                            }
                            var results: [(Int, URL, Int64)] = []
                            for try await item in group {
                                results.append(item)
                            }
                            return results.sorted { $0.0 < $1.0 }
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

                for (uIndex, unitTempURL, size) in fetchedUnits {
                    try checkControl(control)
                    if let rateLimiter = request.rateLimiter {
                        try await rateLimiter.acquire(size)
                    }

                    try appendUnitToTrack(
                        unitURL: unitTempURL,
                        handle: handle,
                        currentOffset: received,
                        expectedBytes: size
                    )
                    received += size
                    expected += size
                    stagedUncommittedBytes += size
                    stagedUnitsToCommit.append((uIndex, unitTempURL, size))

                    if estimatedTotalBytes == 0, completedUnits == 0, received > 0 {
                        let downloadedUnits = uIndex + 1
                        let avgSize = received / Int64(downloadedUnits)
                        estimatedTotalBytes = avgSize * Int64(units.count)
                    }
                }

                let now = ContinuousClock.now
                if stagedUncommittedBytes >= groupCommitBytesThreshold
                    || (now - lastCommitInstant) >= groupCommitTimeThreshold
                {
                    try commitStagedBatch()
                }
                progress(received, estimatedTotalBytes)
                nextUnitIndex += currentBatchCount
            }

            try checkControl(control)
            try commitStagedBatch()
        } catch {
            if isCancellationOrPauseError(error) {
                do {
                    try commitStagedBatch()
                } catch {
                    throw error
                }
            } else {
                do {
                    try rollbackStagedBatch()
                } catch let rollbackError {
                    throw IDMError.storageError(
                        "DASH execution error: \(error.localizedDescription); Rollback failed: \(rollbackError.localizedDescription)"
                    )
                }
            }
            throw error
        }
        return (received, expected)
    }

    private func fetchDASHUnitToDisk(
        unit: (url: URL, range: DASHByteRange?),
        destinationURL: URL,
        requestContext: DownloadRequestContext?,
        contextOriginURL: URL,
        budget: MediaBufferBudget,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> Int64 {
        // Clean up any leftover stale file
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        // Stream directly to a dedicated temp file via client.streamToFile —
        // zero full-body in-memory aggregation
        let result = try await client.streamToFile(
            HLSFetchRequest(
                url: unit.url,
                byteRange: unit.range.map {
                    HLSByteRange(length: $0.length, offset: $0.start)
                },
                requestContext: requestContext,
                contextOriginURL: contextOriginURL,
                control: control
            ),
            to: destinationURL,
            budget: budget,
            control: control,
            progress: nil
        )

        if let range = unit.range {
            guard result.statusCode == 206,
                let contentRange = result.contentRange,
                contentRange.start == range.start,
                contentRange.endInclusive == range.endInclusive,
                // No `endInclusive + 1`: a manifest range ending at
                // Int64.max would trap the addition.
                contentRange.total > range.endInclusive,
                result.byteCount == range.length
            else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw DASHDownloadError.invalidResponse
            }
        } else {
            guard result.statusCode == 200 else {
                try? FileManager.default.removeItem(at: destinationURL)
                throw DASHDownloadError.invalidResponse
            }
        }

        return result.byteCount
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if case IDMError.timedOut = error { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut { return true }
        return false
    }

    private func appendUnitToTrack(
        unitURL: URL,
        handle: FileHandle,
        currentOffset: Int64,
        expectedBytes: Int64
    ) throws {
        let unitHandle = try FileHandle(forReadingFrom: unitURL)
        defer { try? unitHandle.close() }
        let chunkSize = 256 * 1024
        var written: Int64 = 0

        while written < expectedBytes {
            let toRead = Int(min(Int64(chunkSize), expectedBytes - written))
            guard let chunk = try unitHandle.read(upToCount: toRead), !chunk.isEmpty else {
                break
            }
            guard written + Int64(chunk.count) <= expectedBytes else {
                throw IDMError.responseTooLong
            }
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        guard written == expectedBytes else {
            throw IDMError.storageError("DASH Unit 写入长度不匹配 (预期 \(expectedBytes)，实际 \(written))")
        }
    }

    private func cleanupDASHUnitTemporaries(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            if file.hasPrefix("unit-") && file.hasSuffix(".dash.tmp") {
                let fullPath = directory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fullPath)
            }
        }
    }

    private func validate(_ request: DASHDownloadRequest) throws {
        guard request.maximumParallelRequests > 0, request.maximumParallelRequests <= 64 else {
            throw IDMError.invalidParallelRequests
        }
        guard let scheme = request.url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw IDMError.unsupportedScheme
        }
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw IDMError.filenameConflict(request.destination.path)
        }
    }

    private func validatePair(_ request: DASHPairDownloadRequest) throws {
        guard request.maximumParallelRequests > 0,
            request.maximumParallelRequests <= 64
        else { throw IDMError.invalidParallelRequests }
        for url in [request.videoURL, request.audioURL] {
            guard let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host != nil
            else { throw IDMError.unsupportedScheme }
        }
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw IDMError.filenameConflict(request.destination.path)
        }
    }

    private func checkControl(_ control: @escaping @Sendable () -> DownloadControl) throws {
        try Task.checkCancellation()
        switch control() {
        case .continue: return
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
    }

    private func compareRepresentation(_ lhs: DASHRepresentation, _ rhs: DASHRepresentation) -> Bool {
        (lhs.height ?? 0, lhs.bandwidth) < (rhs.height ?? 0, rhs.bandwidth)
    }

    private func resumeUnits(for representation: DASHRepresentation) -> [DASHResumeUnit] {
        let units: [(url: URL, range: DASHByteRange?)] =
            (representation.initialization.map { [(url: $0.url, range: $0.byteRange)] } ?? [])
            + representation.segments.map { (url: $0.url, range: $0.byteRange) }
        return units.map { unit in
            let range = unit.range.map { String($0.start) + "-" + String($0.endInclusive) } ?? "full"
            return DASHResumeUnit(
                fingerprint: digest(Data((unit.url.absoluteString + "|" + range).utf8)),
                byteCount: nil
            )
        }
    }
}

private final class DASHPairProgressBox: @unchecked Sendable {
    enum Track {
        case video
        case audio
    }

    private let lock = NSLock()
    private let progress: @Sendable (DownloadProgress) -> Void
    private var videoReceived: Int64 = 0
    private var audioReceived: Int64 = 0
    private var videoTotal: Int64?
    private var audioTotal: Int64?

    init(progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.progress = progress
    }

    func update(track: Track, value: DownloadProgress) {
        lock.lock()
        switch track {
        case .video:
            videoReceived = value.receivedBytes
            videoTotal = value.totalBytes
        case .audio:
            audioReceived = value.receivedBytes
            audioTotal = value.totalBytes
        }
        let received = videoReceived + audioReceived
        let total: Int64?
        if let videoTotal, let audioTotal {
            total = videoTotal + audioTotal
        } else {
            total = nil
        }
        let segments: [DownloadSegmentProgress] = [
            DownloadSegmentProgress(index: 0, receivedBytes: videoReceived, totalBytes: videoTotal),
            DownloadSegmentProgress(index: 1, receivedBytes: audioReceived, totalBytes: audioTotal),
        ]
        lock.unlock()
        progress(DownloadProgress(receivedBytes: received, totalBytes: total, segments: segments))
    }
}

struct DASHResumeUnit: Codable, Equatable, Sendable {
    let fingerprint: String
    var byteCount: Int64?
}

struct DASHResumeRepresentation: Codable, Equatable, Sendable {
    let id: String
    var units: [DASHResumeUnit]
}

struct DASHResumeRecord: Codable, Equatable, Sendable {
    let formatVersion: Int
    let taskID: UUID
    let manifestFingerprint: String
    var representations: [DASHResumeRepresentation]
}

struct DASHResumeEnvelope: Codable, Sendable {
    let record: DASHResumeRecord
    let checksum: String
}

final class DASHResumeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let sidecarURL: URL
    private var record: DASHResumeRecord

    init(sidecarURL: URL, record: DASHResumeRecord) throws {
        self.sidecarURL = sidecarURL
        self.record = record
        try writeLocked()
    }

    init(sidecarURL: URL, expected: DASHResumeRecord) throws {
        self.sidecarURL = sidecarURL
        do {
            let envelope = try JSONDecoder().decode(
                DASHResumeEnvelope.self,
                from: Data(contentsOf: sidecarURL)
            )
            let encoded = try Self.canonicalData(envelope.record)
            guard digest(encoded) == envelope.checksum else {
                throw DASHDownloadError.resumeCorrupt
            }
            record = envelope.record
        } catch {
            throw DASHDownloadError.resumeCorrupt
        }
        guard record.formatVersion == expected.formatVersion,
            record.taskID == expected.taskID,
            record.manifestFingerprint == expected.manifestFingerprint,
            record.representations.count == expected.representations.count,
            zip(record.representations, expected.representations).allSatisfy({ stored, current in
                stored.id == current.id
                    && stored.units.map(\.fingerprint) == current.units.map(\.fingerprint)
                    && stored.units.allSatisfy { unit in
                        unit.byteCount == nil || (unit.byteCount ?? 0) > 0
                    }
            })
        else { throw DASHDownloadError.resumeIncompatible }
        guard
            record.representations.allSatisfy({ representation in
                let completed = contiguousCompletedCount(representation)
                return representation.units.dropFirst(completed).allSatisfy { $0.byteCount == nil }
            })
        else {
            throw DASHDownloadError.resumeCorrupt
        }
    }

    var hasCompletedUnits: Bool {
        lock.lock()
        defer { lock.unlock() }
        return record.representations.contains { contiguousCompletedCount($0) > 0 }
    }

    func fingerprints(for representationID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return record.representations.first(where: { $0.id == representationID })?.units.map(\.fingerprint) ?? []
    }

    func completedCount(for representationID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let representation = record.representations.first(where: { $0.id == representationID }) else {
            return 0
        }
        return contiguousCompletedCount(representation)
    }

    func completedBytes(for representationID: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let representation = record.representations.first(where: { $0.id == representationID }) else {
            return 0
        }
        return representation.units.prefix(while: { $0.byteCount != nil })
            .compactMap(\.byteCount)
            .reduce(0, +)
    }

    func markCompletedBatch(
        representationID: String,
        units: [(index: Int, byteCount: Int64)]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let representationIndex = record.representations.firstIndex(where: { $0.id == representationID })
        else { throw DASHDownloadError.resumeCorrupt }

        let previousRecord = record
        var current = contiguousCompletedCount(record.representations[representationIndex])
        for unit in units {
            guard unit.byteCount > 0,
                unit.index == current,
                unit.index < record.representations[representationIndex].units.count
            else { throw DASHDownloadError.resumeCorrupt }
            record.representations[representationIndex].units[unit.index].byteCount = unit.byteCount
            current += 1
        }
        do {
            try writeLocked()
        } catch {
            record = previousRecord
            throw error
        }
    }

    private func writeLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let envelope = DASHResumeEnvelope(
                record: record,
                checksum: digest(try Self.canonicalData(record))
            )
            try FileSupport.atomicWrite(encoder.encode(envelope), to: sidecarURL)
        } catch {
            throw IDMError.storageError("DASH 断点记录写入失败")
        }
    }

    private static func canonicalData(_ record: DASHResumeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func contiguousCompletedCount(_ representation: DASHResumeRepresentation) -> Int {
        representation.units.prefix(while: { $0.byteCount != nil }).count
    }
}

private func contiguousCompletedCount(_ representation: DASHResumeRepresentation) -> Int {
    representation.units.prefix(while: { $0.byteCount != nil }).count
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
