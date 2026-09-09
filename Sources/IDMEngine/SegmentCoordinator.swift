import Foundation

/// Coordinates segment work across parallel download workers.
///
/// Instead of statically assigning one segment per worker, this coordinator
/// maintains a work queue and hands out segments on demand. When a worker
/// finishes early, the coordinator proposes splitting the slowest active
/// segment: the idle worker downloads the tail half while the original
/// worker is truncated at the split point, so no byte range is downloaded
/// twice (in-half division, inspired by FluxDown's segment coordinator).
///
/// ## Split protocol
///
/// Splitting touches the checkpoint sidecar and an in-flight HTTP transfer,
/// both owned by the engine, so the coordinator only *proposes*. The engine
/// commits or abandons each proposal:
///
/// 1. An idle worker receives ``Decision/split(parentIndex:truncationEnd:child:)``.
///    The coordinator marks the parent split-pending so no second proposal
///    targets it concurrently.
/// 2. The engine installs the truncation point on the parent transfer
///    (future writes clamp at `truncationEnd`), then atomically commits the
///    split in the checkpoint tracker (parent range shrinks, synthetic child
///    segment is appended, sidecar is flushed).
/// 3. On success the engine calls ``commitSplit(parentIndex:childIndex:)``
///    and runs the child work item. When the parent has raced past the
///    truncation point the tracker refuses the split; the engine then calls
///    ``abandonSplit(parentIndex:)`` and the parent simply finishes its
///    original range.
///
/// ## Thread safety
///
/// `SegmentCoordinator` is an actor; all mutations are serialized.
public actor SegmentCoordinator {

    // MARK: - Types

    /// A unit of work handed to a worker.
    public struct WorkItem: Sendable {
        /// Unique identifier for this work item (matches the original
        /// segment index for non-split items; synthetic for splits).
        public let segmentIndex: Int
        /// The byte range to download.
        public let range: ByteRange
        /// The offset to start the HTTP Range request from. May differ
        /// from `range.start` when resuming a partially downloaded segment.
        public let requestStart: Int64
        /// Bytes already committed for this range before this run (resume).
        public var initialDownloaded: Int64 = 0

        public init(segmentIndex: Int, range: ByteRange, requestStart: Int64) {
            self.segmentIndex = segmentIndex
            self.range = range
            self.requestStart = requestStart
        }
    }

    /// The outcome of an idle worker asking for work.
    public enum Decision: Sendable {
        /// A queued segment ready to download.
        case work(WorkItem)
        /// A proposal to split `parentIndex` at `truncationEnd`; the worker
        /// should download `child` after committing the split in the engine.
        case split(parentIndex: Int, truncationEnd: Int64, child: WorkItem)
        /// No work remains and nothing can be split; the worker exits.
        case done
    }

    /// Tracks an in-flight segment so the coordinator can decide whether
    /// to split it for an idle worker.
    private struct ActiveSegment {
        let segmentIndex: Int
        var range: ByteRange
        let startedAt: ContinuousClock.Instant
        var bytesDownloaded: Int64
        var splitPending = false
    }

    // MARK: - State

    /// Segments that have not been started yet.
    private var pendingQueue: [WorkItem] = []
    /// Segments currently being downloaded by a worker.
    private var activeSegments: [Int: ActiveSegment] = [:]
    /// Monotonically increasing segment index for split segments.
    private var nextSyntheticIndex: Int
    /// Minimum segment size in bytes. Segments with less remaining than
    /// twice this value are not worth the split overhead.
    private let minimumSplitSize: Int64 = 256 * 1024  // 256 KB

    // MARK: - Init

    /// Creates a coordinator from a set of initial work items.
    /// - Parameter workItems: The original segments from the download plan.
    public init(workItems: [WorkItem]) {
        self.pendingQueue = workItems
        self.nextSyntheticIndex = (workItems.map(\.segmentIndex).max() ?? -1) + 1
    }

    // MARK: - Worker API

    /// Returns the next decision for an idle worker.
    ///
    /// The strategy is:
    /// 1. If there are pending segments, hand out the next one.
    /// 2. If the slowest active segment has enough remaining bytes and no
    ///    split for it is already pending, propose an in-half split.
    /// 3. Otherwise the worker exits.
    public func nextDecision() -> Decision {
        // Fast path: pending queue has work.
        if !pendingQueue.isEmpty {
            let item = pendingQueue.removeFirst()
            activeSegments[item.segmentIndex] = ActiveSegment(
                segmentIndex: item.segmentIndex,
                range: item.range,
                startedAt: .now,
                bytesDownloaded: item.initialDownloaded
            )
            return .work(item)
        }

        guard !activeSegments.isEmpty else { return .done }

        // Slow path: propose splitting the slowest active segment. Since
        // this method is only called by an idle worker, at least one worker
        // is available to take the child half.
        let now = ContinuousClock.Instant.now
        let candidates =
            activeSegments.values
            .filter { !$0.splitPending }
            .compactMap { seg -> (seg: ActiveSegment, speed: Double)? in
                let elapsed = seg.startedAt.duration(to: now)
                let nanoseconds =
                    Double(elapsed.components.seconds) * 1_000_000_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000
                guard nanoseconds > 0 else { return nil }
                return (seg, Double(seg.bytesDownloaded) / nanoseconds)
            }
            .sorted { $0.speed < $1.speed }

        guard let slowest = candidates.first?.seg else { return .done }
        let committed = slowest.bytesDownloaded
        let remaining = slowest.range.endExclusive - slowest.range.start - committed
        // Only split when the remaining portion is worth the overhead.
        guard remaining >= minimumSplitSize * 2 else { return .done }

        // The child takes the tail half of what is still outstanding.
        let midpoint = slowest.range.start + committed + remaining / 2
        let alignedMidpoint = midpoint - (midpoint % 4096)  // Page-align for pwrite.

        guard
            alignedMidpoint > slowest.range.start + committed,
            alignedMidpoint < slowest.range.endExclusive
        else { return .done }

        let splitIndex = nextSyntheticIndex
        nextSyntheticIndex += 1
        activeSegments[slowest.segmentIndex]?.splitPending = true

        return .split(
            parentIndex: slowest.segmentIndex,
            truncationEnd: alignedMidpoint,
            child: WorkItem(
                segmentIndex: splitIndex,
                range: ByteRange(start: alignedMidpoint, endExclusive: slowest.range.endExclusive),
                requestStart: alignedMidpoint
            )
        )
    }

    /// Confirms a previously proposed split after the engine has committed
    /// it to the checkpoint tracker. The parent's tracked range shrinks to
    /// the truncation point and the child becomes an active segment.
    public func commitSplit(parentIndex: Int, truncationEnd: Int64, childIndex: Int, childRange: ByteRange) {
        if var parent = activeSegments[parentIndex] {
            parent.splitPending = false
            parent.range = ByteRange(start: parent.range.start, endExclusive: truncationEnd)
            activeSegments[parentIndex] = parent
        }
        activeSegments[childIndex] = ActiveSegment(
            segmentIndex: childIndex,
            range: childRange,
            startedAt: .now,
            bytesDownloaded: 0
        )
    }

    /// Drops a split proposal the engine could not commit (for example the
    /// parent raced past the truncation point). The parent becomes eligible
    /// for future proposals again.
    public func abandonSplit(parentIndex: Int) {
        activeSegments[parentIndex]?.splitPending = false
    }

    /// Reports absolute committed progress for a segment so the coordinator
    /// can make informed split decisions.
    public func reportProgress(segmentIndex: Int, bytesDownloaded: Int64) {
        activeSegments[segmentIndex]?.bytesDownloaded = bytesDownloaded
    }

    /// Marks a segment as completed. The coordinator removes it from
    /// the active set.
    public func markCompleted(segmentIndex: Int) {
        activeSegments.removeValue(forKey: segmentIndex)
    }

    /// Returns true when all work is done (no pending, no active segments,
    /// and no outstanding split proposals).
    public var isComplete: Bool {
        pendingQueue.isEmpty
            && activeSegments.values.allSatisfy { !$0.splitPending }
            && activeSegments.isEmpty
    }
}
