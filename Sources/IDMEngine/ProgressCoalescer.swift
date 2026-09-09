import Foundation

/// Coalesces high-frequency progress byte deltas from multiple transfer workers
/// and emits full sorted `DownloadProgress` snapshots periodically (approx. every 200ms)
/// or immediately on lifecycle events (dynamic split, parent shrink, task completion, pause/cancel).
final class ProgressCoalescer: @unchecked Sendable {
    private struct SegmentDescriptor: Sendable {
        let index: Int
        let start: Int64
        var endExclusive: Int64
        var receivedBytes: Int64

        var totalBytes: Int64? {
            endExclusive > start ? (endExclusive - start) : nil
        }
    }

    private let lock = NSRecursiveLock()
    private let emissionLock = NSRecursiveLock()
    private let totalBytes: Int64?
    private let onEmit: @Sendable (DownloadProgress) -> Void

    private var totalReceived: Int64 = 0
    private var segments: [SegmentDescriptor] = []
    private var segmentIndexMap: [Int: Int] = [:]
    private var isDirty: Bool = false
    private var isFinished: Bool = false
    private var sequenceNumber: UInt64 = 0
    private var lastEmittedSequence: UInt64 = 0
    private var tickerTask: Task<Void, Never>?

    // Test & metric observation
    private(set) var snapshotCount: Int = 0
    private(set) var addCallCount: Int = 0

    init(
        totalBytes: Int64?,
        segments initialSegments: [SegmentCheckpoint],
        interval: TimeInterval = 0.2,
        onEmit: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.totalBytes = totalBytes
        self.onEmit = onEmit
        self.segments = initialSegments.map {
            SegmentDescriptor(
                index: $0.index,
                start: $0.start,
                endExclusive: $0.endExclusive,
                receivedBytes: max(0, $0.nextUncommittedOffset - $0.start)
            )
        }.sorted { $0.index < $1.index }
        self.totalReceived = self.segments.reduce(0) { $0 + $1.receivedBytes }
        self.rebuildSegmentMapLocked()

        if interval > 0 {
            let intervalNs = UInt64(interval * 1_000_000_000)
            self.tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: intervalNs)
                    guard let self else { break }
                    self.flushIfDirty()
                }
            }
        }
    }

    deinit {
        tickerTask?.cancel()
    }

    var currentReceived: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalReceived
    }

    var stats: (addCalls: Int, snapshotsEmitted: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (addCallCount, snapshotCount)
    }

    /// High-frequency hot path: records byte delta in O(1) via segmentIndexMap without heap allocation or sorting.
    /// Unknown segment indices are safely ignored and do not mutate totalReceived.
    func add(bytes: Int64, to segmentIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = segmentIndexMap[segmentIndex] else {
            return
        }
        addCallCount += 1
        totalReceived += bytes
        segments[idx].receivedBytes += bytes
        isDirty = true
    }

    /// Dynamic split: registers a synthetic split-child segment and immediately emits an updated snapshot.
    func register(index: Int, totalBytes childTotal: Int64?, start: Int64) {
        lock.lock()
        let endExclusive = start + (childTotal ?? 0)
        if let existingIdx = segmentIndexMap[index] {
            segments[existingIdx].endExclusive = endExclusive
        } else {
            segments.append(
                SegmentDescriptor(
                    index: index,
                    start: start,
                    endExclusive: endExclusive,
                    receivedBytes: 0
                )
            )
            segments.sort { $0.index < $1.index }
            rebuildSegmentMapLocked()
        }
        isDirty = true
        let snapshotPackage = produceSnapshotLocked()
        lock.unlock()
        deliver(snapshotPackage)
    }

    /// Dynamic split: shrinks a parent's total range at the split point and immediately emits an updated snapshot.
    func applySplit(parentIndex: Int, truncationEnd: Int64) {
        lock.lock()
        if let idx = segmentIndexMap[parentIndex] {
            segments[idx].endExclusive = truncationEnd
            let parentTotal = max(0, truncationEnd - segments[idx].start)
            if segments[idx].receivedBytes > parentTotal {
                let excess = segments[idx].receivedBytes - parentTotal
                segments[idx].receivedBytes = parentTotal
                totalReceived -= excess
            }
        }
        isDirty = true
        let snapshotPackage = produceSnapshotLocked()
        lock.unlock()
        deliver(snapshotPackage)
    }

    /// Periodic flush: emits a snapshot if dirty.
    func flushIfDirty() {
        lock.lock()
        guard !isFinished, isDirty else {
            lock.unlock()
            return
        }
        let snapshotPackage = produceSnapshotLocked()
        lock.unlock()
        deliver(snapshotPackage)
    }

    /// Immediate flush of current state.
    func flushImmediate() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let snapshotPackage = produceSnapshotLocked()
        lock.unlock()
        deliver(snapshotPackage)
    }

    /// Terminal completion: flushes exact final progress snapshot and terminates ticker.
    func finish() {
        lock.lock()
        tickerTask?.cancel()
        tickerTask = nil
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let snapshotPackage = produceSnapshotLocked()
        lock.unlock()
        deliver(snapshotPackage)
    }

    private func rebuildSegmentMapLocked() {
        segmentIndexMap.removeAll(keepingCapacity: true)
        for (pos, seg) in segments.enumerated() {
            segmentIndexMap[seg.index] = pos
        }
    }

    private func produceSnapshotLocked() -> (DownloadProgress, UInt64) {
        sequenceNumber += 1
        snapshotCount += 1
        isDirty = false
        let snapshot = makeSnapshotLocked()
        return (snapshot, sequenceNumber)
    }

    private func deliver(_ package: (snapshot: DownloadProgress, sequence: UInt64)) {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        lock.lock()
        let finished = isFinished
        let isNewer = package.sequence > lastEmittedSequence
        if isNewer && (!finished || package.sequence == sequenceNumber) {
            lastEmittedSequence = package.sequence
            lock.unlock()
            onEmit(package.snapshot)
        } else {
            lock.unlock()
        }
    }

    private func makeSnapshotLocked() -> DownloadProgress {
        let segmentSnapshots = segments.map {
            DownloadSegmentProgress(
                index: $0.index,
                receivedBytes: $0.receivedBytes,
                totalBytes: $0.totalBytes
            )
        }
        return DownloadProgress(
            receivedBytes: totalReceived,
            totalBytes: totalBytes,
            segments: segmentSnapshots
        )
    }
}
