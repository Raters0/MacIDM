import XCTest

@testable import IDMEngine

private final class TestProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [DownloadProgress] = []

    func receive(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        list.append(progress)
    }

    var snapshots: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    var lastSnapshot: DownloadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return list.last
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return list.count
    }
}

final class ProgressCoalescerTests: XCTestCase {
    func testConcurrentAddByteDeltaAccuracy() async throws {
        let segments = (0..<8).map {
            SegmentCheckpoint(
                index: $0,
                start: Int64($0 * 1000),
                endExclusive: Int64(($0 + 1) * 1000),
                nextUncommittedOffset: Int64($0 * 1000)
            )
        }

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 8000,
            segments: segments,
            interval: 0.05,
            onEmit: { collector.receive($0) }
        )

        // 8 concurrent workers pushing 500 chunks each to their respective segment
        await withTaskGroup(of: Void.self) { group in
            for segIdx in 0..<8 {
                group.addTask {
                    for _ in 0..<500 {
                        coalescer.add(bytes: 2, to: segIdx)
                    }
                }
            }
        }

        coalescer.finish()

        let (addCalls, snapshots) = coalescer.stats
        XCTAssertEqual(addCalls, 4000)
        XCTAssertEqual(coalescer.currentReceived, 8000)

        guard let finalSnapshot = collector.lastSnapshot else {
            XCTFail("Expected final snapshot")
            return
        }

        XCTAssertEqual(finalSnapshot.receivedBytes, 8000)
        XCTAssertEqual(finalSnapshot.totalBytes, 8000)
        XCTAssertEqual(finalSnapshot.segments.count, 8)

        for (idx, seg) in finalSnapshot.segments.enumerated() {
            XCTAssertEqual(seg.index, idx)
            XCTAssertEqual(seg.receivedBytes, 1000)
            XCTAssertEqual(seg.totalBytes, 1000)
        }

        // Snapshots emitted must be orders of magnitude fewer than 4000 add calls
        XCTAssertLessThan(snapshots, 100)
    }

    func testDynamicSplitImmediateFlushAndShrink() {
        let initialSegments = [
            SegmentCheckpoint(
                index: 0,
                start: 0,
                endExclusive: 100,
                nextUncommittedOffset: 50
            ),
            SegmentCheckpoint(
                index: 1,
                start: 100,
                endExclusive: 200,
                nextUncommittedOffset: 100
            ),
        ]

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 200,
            segments: initialSegments,
            interval: 10.0,  // High interval so only manual/lifecycle flushes occur
            onEmit: { collector.receive($0) }
        )

        // Add 10 bytes to segment 0 (so received becomes 60)
        coalescer.add(bytes: 10, to: 0)

        // Perform split: child 2 takes [80, 100) and parent 0 truncates to 80
        coalescer.register(index: 2, totalBytes: 20, start: 80)
        coalescer.applySplit(parentIndex: 0, truncationEnd: 80)

        // Split registration and applySplit must immediately emit snapshots
        XCTAssertGreaterThanOrEqual(collector.count, 2)

        guard let latest = collector.lastSnapshot else {
            XCTFail("No snapshot emitted")
            return
        }

        let byIndex = Dictionary(uniqueKeysWithValues: latest.segments.map { ($0.index, $0) })
        XCTAssertEqual(byIndex[0]?.totalBytes, 80)
        XCTAssertEqual(byIndex[0]?.receivedBytes, 60)
        XCTAssertEqual(byIndex[1]?.totalBytes, 100)
        XCTAssertEqual(byIndex[1]?.receivedBytes, 0)
        XCTAssertEqual(byIndex[2]?.totalBytes, 20)
        XCTAssertEqual(byIndex[2]?.receivedBytes, 0)

        // Parent reaches its truncated total (80)
        coalescer.add(bytes: 20, to: 0)
        coalescer.flushImmediate()

        let finishedParentSnapshot = collector.lastSnapshot?.segments.first { $0.index == 0 }
        XCTAssertEqual(finishedParentSnapshot?.receivedBytes, 80)
        XCTAssertEqual(finishedParentSnapshot?.totalBytes, 80)
        XCTAssertTrue((finishedParentSnapshot?.receivedBytes ?? 0) >= (finishedParentSnapshot?.totalBytes ?? 1))

        coalescer.finish()
    }

    func testSplitClampsBytesAlreadyCountedPastSplitPoint() {
        let initialSegments = [
            SegmentCheckpoint(
                index: 0,
                start: 200,
                endExclusive: 400,
                nextUncommittedOffset: 200
            )
        ]

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 200,
            segments: initialSegments,
            interval: 10.0,
            onEmit: { collector.receive($0) }
        )

        // Download 160 bytes on parent (received is 160)
        coalescer.add(bytes: 160, to: 0)

        // Split committed at byte 320: parent range [200, 320) total 120
        coalescer.register(index: 1, totalBytes: 80, start: 320)
        coalescer.applySplit(parentIndex: 0, truncationEnd: 320)

        let parent = collector.lastSnapshot?.segments.first { $0.index == 0 }
        XCTAssertEqual(parent?.totalBytes, 120)
        XCTAssertEqual(parent?.receivedBytes, 120)  // Clamped to new total

        // Assert totalReceived is deducted consistently
        XCTAssertEqual(coalescer.currentReceived, 120)
        let lastSnap = collector.lastSnapshot
        XCTAssertEqual(lastSnap?.receivedBytes, 120)
        let sumOfSegments = lastSnap?.segments.reduce(0) { $0 + $1.receivedBytes }
        XCTAssertEqual(sumOfSegments, 120)

        coalescer.finish()
    }

    func testTerminalFlushGuaranteesExactFinalBytes() {
        let initialSegments = [
            SegmentCheckpoint(
                index: 0,
                start: 0,
                endExclusive: 1000,
                nextUncommittedOffset: 0
            )
        ]

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 1000,
            segments: initialSegments,
            interval: 10.0,
            onEmit: { collector.receive($0) }
        )

        coalescer.add(bytes: 345, to: 0)
        // Without waiting for interval, calling finish() must flush exact bytes
        coalescer.finish()

        let last = collector.lastSnapshot
        XCTAssertEqual(last?.receivedBytes, 345)
        XCTAssertEqual(last?.totalBytes, 1000)
        XCTAssertEqual(last?.segments.first?.receivedBytes, 345)
    }

    func testNoStaleSnapshotAfterFinishUnderHighConcurrency() async throws {
        let initialSegments = (0..<4).map {
            SegmentCheckpoint(
                index: $0,
                start: Int64($0 * 1000),
                endExclusive: Int64(($0 + 1) * 1000),
                nextUncommittedOffset: Int64($0 * 1000)
            )
        }

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 4000,
            segments: initialSegments,
            interval: 0.001,  // Very aggressive 1ms ticker to maximize race window
            onEmit: { collector.receive($0) }
        )

        // Multiple tasks pushing data rapidly
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    for _ in 0..<100 {
                        coalescer.add(bytes: 10, to: i)
                    }
                }
            }
        }

        // Finish called
        coalescer.finish()

        // Wait a short moment to ensure no background ticker sneaks in an older snapshot
        try await Task.sleep(nanoseconds: 50_000_000)

        guard let finalSnapshot = collector.lastSnapshot else {
            XCTFail("Expected final snapshot")
            return
        }

        // Final snapshot receivedBytes must be exactly 4000
        XCTAssertEqual(finalSnapshot.receivedBytes, 4000)
        XCTAssertEqual(finalSnapshot.totalBytes, 4000)
        let totalSegmentBytes = finalSnapshot.segments.reduce(0) { $0 + $1.receivedBytes }
        XCTAssertEqual(totalSegmentBytes, 4000)
    }

    func testUnknownSegmentIndexIsSafelyIgnoredAndDoesNotCorruptTotalReceived() {
        let initialSegments = [
            SegmentCheckpoint(
                index: 0,
                start: 0,
                endExclusive: 1000,
                nextUncommittedOffset: 0
            )
        ]

        let collector = TestProgressCollector()
        let coalescer = ProgressCoalescer(
            totalBytes: 1000,
            segments: initialSegments,
            interval: 10.0,
            onEmit: { collector.receive($0) }
        )

        // Add to valid segment 0
        coalescer.add(bytes: 100, to: 0)
        XCTAssertEqual(coalescer.currentReceived, 100)

        // Add to unknown segment 99 -> must be ignored and not mutate totalReceived
        coalescer.add(bytes: 500, to: 99)
        XCTAssertEqual(coalescer.currentReceived, 100)

        coalescer.finish()

        let last = collector.lastSnapshot
        XCTAssertEqual(last?.receivedBytes, 100)
        let sumOfSegments = last?.segments.reduce(0) { $0 + $1.receivedBytes }
        XCTAssertEqual(sumOfSegments, 100)
    }

    func testCallbackReentrancyDoesNotDeadlock() {
        final class ReentrancyBox: @unchecked Sendable {
            let lock = NSLock()
            weak var coalescer: ProgressCoalescer?
            var count = 0
            var observed: Int64 = 0

            func record(progress: DownloadProgress) {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                if let c = coalescer {
                    observed = c.currentReceived
                }
            }
        }

        let initialSegments = [
            SegmentCheckpoint(
                index: 0,
                start: 0,
                endExclusive: 1000,
                nextUncommittedOffset: 0
            )
        ]

        let box = ReentrancyBox()
        let coalescer = ProgressCoalescer(
            totalBytes: 1000,
            segments: initialSegments,
            interval: 10.0,
            onEmit: { progress in
                box.record(progress: progress)
            }
        )
        box.coalescer = coalescer

        coalescer.add(bytes: 250, to: 0)
        coalescer.flushImmediate()

        XCTAssertEqual(box.count, 1)
        XCTAssertEqual(box.observed, 250)

        coalescer.finish()
        XCTAssertEqual(box.count, 2)
    }
}
