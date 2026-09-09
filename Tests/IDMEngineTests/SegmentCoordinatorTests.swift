import XCTest

@testable import IDMEngine

final class SegmentCoordinatorTests: XCTestCase {

    private func makeItem(_ index: Int, start: Int64, size: Int64) -> SegmentCoordinator.WorkItem {
        SegmentCoordinator.WorkItem(
            segmentIndex: index,
            range: ByteRange(start: start, endExclusive: start + size),
            requestStart: start
        )
    }

    func testHandsOutQueuedWorkInOrderBeforeProposingSplits() async throws {
        let coordinator = SegmentCoordinator(workItems: [
            makeItem(0, start: 0, size: 4 * 1024 * 1024),
            makeItem(1, start: 4 * 1024 * 1024, size: 4 * 1024 * 1024),
        ])

        guard case .work(let first) = await coordinator.nextDecision() else {
            return XCTFail("expected work, got done or split")
        }
        XCTAssertEqual(first.segmentIndex, 0)

        guard case .work(let second) = await coordinator.nextDecision() else {
            return XCTFail("expected work, got done or split")
        }
        XCTAssertEqual(second.segmentIndex, 1)
    }

    func testIdleWorkerReceivesSplitProposalForSlowestSegment() async throws {
        let size: Int64 = 4 * 1024 * 1024
        let coordinator = SegmentCoordinator(workItems: [
            makeItem(0, start: 0, size: size),
            makeItem(1, start: size, size: size),
        ])

        // Two workers claim the queued segments.
        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected first work item")
        }
        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected second work item")
        }

        // Segment 0 is fast; segment 1 has committed nothing and is slowest.
        await coordinator.reportProgress(segmentIndex: 0, bytesDownloaded: 2 * 1024 * 1024)
        await coordinator.reportProgress(segmentIndex: 1, bytesDownloaded: 0)
        try await Task.sleep(nanoseconds: 20_000_000)

        guard case .split(let parentIndex, let truncationEnd, let child) = await coordinator.nextDecision()
        else {
            return XCTFail("expected a split proposal for the idle worker")
        }
        XCTAssertEqual(parentIndex, 1)
        // The child owns the tail half and starts exactly at the truncation
        // point, so parent and child never overlap.
        XCTAssertEqual(child.range.start, truncationEnd)
        XCTAssertEqual(child.range.endExclusive, 2 * size)
        XCTAssertEqual(truncationEnd % 4096, 0, "split point must be page aligned")
        XCTAssertGreaterThan(child.segmentIndex, 1, "synthetic index must not collide")
    }

    func testSplitPendingBlocksDuplicateProposalsUntilCommitted() async throws {
        let size: Int64 = 4 * 1024 * 1024
        let coordinator = SegmentCoordinator(workItems: [makeItem(0, start: 0, size: size)])

        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected work item")
        }
        await coordinator.reportProgress(segmentIndex: 0, bytesDownloaded: 0)
        try await Task.sleep(nanoseconds: 20_000_000)

        guard case .split = await coordinator.nextDecision() else {
            return XCTFail("expected first split proposal")
        }

        // A second idle worker must not receive a duplicate proposal for the
        // same parent while the first is uncommitted; nothing else is queued.
        guard case .done = await coordinator.nextDecision() else {
            return XCTFail("expected done while a split is pending")
        }

        // After abandoning, the parent becomes eligible again.
        await coordinator.abandonSplit(parentIndex: 0)
        guard case .split(_, let retryEnd, let retryChild) = await coordinator.nextDecision() else {
            return XCTFail("expected a new proposal after abandon")
        }
        // Commit releases the pending flag and activates the child.
        await coordinator.commitSplit(
            parentIndex: 0,
            truncationEnd: retryEnd,
            childIndex: retryChild.segmentIndex,
            childRange: retryChild.range
        )
        await coordinator.markCompleted(segmentIndex: 0)
        await coordinator.markCompleted(segmentIndex: retryChild.segmentIndex)
        let complete = await coordinator.isComplete
        XCTAssertTrue(complete)
    }

    func testSmallRemainderIsNeverSplit() async throws {
        // 400 KB total with nothing downloaded: remaining < 2 * 256 KB,
        // so even an idle worker gets no split proposal.
        let coordinator = SegmentCoordinator(workItems: [
            makeItem(0, start: 0, size: 400 * 1024)
        ])
        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected work item")
        }
        await coordinator.reportProgress(segmentIndex: 0, bytesDownloaded: 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .done = await coordinator.nextDecision() else {
            return XCTFail("expected done: remainder too small to split")
        }
    }

    func testIsCompleteTracksPendingAndActiveWork() async throws {
        let coordinator = SegmentCoordinator(workItems: [makeItem(0, start: 0, size: 1024 * 1024)])
        var complete = await coordinator.isComplete
        XCTAssertFalse(complete)

        guard case .work(let item) = await coordinator.nextDecision() else {
            return XCTFail("expected work item")
        }
        await coordinator.markCompleted(segmentIndex: item.segmentIndex)
        complete = await coordinator.isComplete
        XCTAssertTrue(complete)
    }

    func testResumeInitialDownloadedFeedsSplitSpeedEstimate() async throws {
        // A resumed segment starts with committed progress; the coordinator
        // must treat it as already partially downloaded so the idle worker
        // targets the *other* segment.
        let size: Int64 = 4 * 1024 * 1024
        var resumed = SegmentCoordinator.WorkItem(
            segmentIndex: 0,
            range: ByteRange(start: 0, endExclusive: size),
            requestStart: 3 * 1024 * 1024
        )
        resumed.initialDownloaded = 3 * 1024 * 1024
        let coordinator = SegmentCoordinator(workItems: [
            resumed,
            makeItem(1, start: size, size: size),
        ])
        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected first work item")
        }
        guard case .work = await coordinator.nextDecision() else {
            return XCTFail("expected second work item")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        guard case .split(let parentIndex, _, _) = await coordinator.nextDecision() else {
            return XCTFail("expected split proposal")
        }
        XCTAssertEqual(parentIndex, 1, "the untouched segment is the slowest target")
    }
}
