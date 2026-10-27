import Foundation

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
