import XCTest

@testable import IDMEngine

/// Regression tests for the silent-corruption defect measured in the
/// 2026-09-13 competitor-analysis lab runs: a dynamic split whose parent
/// committed exactly at the truncation point orphaned the tail segment, and
/// publication verified only size, so the preallocated tail shipped as
/// zeros under a "completed" status.
final class SegmentCoverageGateTests: XCTestCase {
    private func segment(
        _ index: Int,
        _ start: Int64,
        _ end: Int64,
        committed: Int64? = nil
    ) -> SegmentCheckpoint {
        SegmentCheckpoint(
            index: index,
            start: start,
            endExclusive: end,
            nextUncommittedOffset: committed ?? start
        )
    }

    // MARK: - Publish gate

    func testFullyCommittedTilingPassesThePublishGate() {
        let segments = [
            segment(0, 0, 60, committed: 60),
            segment(2, 60, 100, committed: 100),
        ]
        XCTAssertTrue(SegmentCoverage.isFullyCommitted(segments, total: 100))
    }

    func testOrphanedTailFailsThePublishGateButStaysAResumableLayout() {
        // Counterexample for the measured defect: the parent stopped at the
        // split point and the synthetic child never committed its tail. Size
        // and range checks pass — the preallocated tail reads as zeros — so
        // only the coverage gate refuses publication, while the resume
        // layout stays valid so a retry downloads exactly the tail.
        let segments = [
            segment(0, 0, 60, committed: 50),
            segment(1, 60, 100, committed: 60),
        ]
        XCTAssertFalse(SegmentCoverage.isFullyCommitted(segments, total: 100))
        XCTAssertTrue(SegmentCoverage.isValidResumeLayout(segments, total: 100))
    }

    func testGapOrOverlapFailsBothGates() {
        let gap = [
            segment(0, 0, 40, committed: 40),
            segment(1, 60, 100, committed: 100),
        ]
        XCTAssertFalse(SegmentCoverage.isValidResumeLayout(gap, total: 100))
        XCTAssertFalse(SegmentCoverage.isFullyCommitted(gap, total: 100))

        let overlap = [
            segment(0, 0, 60, committed: 60),
            segment(1, 50, 100, committed: 100),
        ]
        XCTAssertFalse(SegmentCoverage.isValidResumeLayout(overlap, total: 100))
        XCTAssertFalse(SegmentCoverage.isFullyCommitted(overlap, total: 100))
    }

    func testEmptyLayoutIsCompleteOnlyForZeroTotal() {
        XCTAssertTrue(SegmentCoverage.isFullyCommitted([], total: 0))
        XCTAssertFalse(SegmentCoverage.isFullyCommitted([], total: 100))
    }

    // MARK: - Split-commit equality

    func testApplySplitAcceptsParentCommittedExactlyAtTruncationEnd() throws {
        // The parent's last chunk landed exactly on the split point: the
        // transfer has finished truncated there and will never fetch the
        // tail. The split must commit so the child owns [truncationEnd, end)
        // — the old strict `>` refused it and orphaned the tail.
        let fixture = try makeTracker(segments: [segment(0, 0, 100, committed: 60)])
        defer { fixture.cleanup() }
        let tracker = fixture.tracker

        XCTAssertTrue(tracker.applySplit(parentIndex: 0, truncationEnd: 60, childIndex: 1))

        let updated = tracker.snapshot()
        let parent = updated.segments.first { $0.index == 0 }
        XCTAssertEqual(parent?.endExclusive, 60)
        XCTAssertEqual(parent?.nextUncommittedOffset, 60)
        let child = updated.segments.first { $0.index == 1 }
        XCTAssertEqual(child?.start, 60)
        XCTAssertEqual(child?.endExclusive, 100)
        XCTAssertEqual(child?.nextUncommittedOffset, 60)
        // The parent is now complete and the child is the only owner of the
        // tail: the layout must pass both gates once the child commits.
        XCTAssertTrue(SegmentCoverage.isValidResumeLayout(updated.segments, total: 100))
    }

    func testApplySplitStillRefusesAParentCommittedPastThePoint() throws {
        // Past the point the parent has live bytes beyond the proposal; its
        // transfer keeps the original range and the split is stale.
        let fixture = try makeTracker(segments: [segment(0, 0, 100, committed: 70)])
        defer { fixture.cleanup() }
        let tracker = fixture.tracker

        XCTAssertFalse(tracker.applySplit(parentIndex: 0, truncationEnd: 60, childIndex: 1))
        XCTAssertEqual(tracker.snapshot().segments.count, 1)
    }

    // MARK: - Fixtures

    /// The tracker keeps an open sink and rewrites the sidecar on every
    /// checkpoint, so the backing directory must outlive this helper; tests
    /// receive the cleanup closure and run it on exit.
    private func makeTracker(
        segments: [SegmentCheckpoint]
    ) throws -> (tracker: SynchronousCheckpointTracker, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentCoverageGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(at: directory) }

        let temporary = directory.appendingPathComponent("artifact.part")
        let sidecar = directory.appendingPathComponent("artifact.macidm")
        let sink = try RandomAccessSink(url: temporary, totalSize: 100, create: true)
        let payload = SidecarPayload(
            formatVersion: 1,
            taskID: UUID(),
            fileIdentity: try sink.identity(),
            totalSize: 100,
            resourceIdentity: ResourceIdentity(
                effectiveURL: "sha256:abc",
                totalSize: 100,
                strongETag: "\"etag\"",
                contentEncoding: "identity"
            ),
            segments: segments,
            generation: 1,
            phase: "running"
        )
        try SidecarStore.write(payload, to: sidecar)
        let tracker = SynchronousCheckpointTracker(payload: payload, sidecarURL: sidecar, sink: sink)
        return (tracker, cleanup)
    }
}
