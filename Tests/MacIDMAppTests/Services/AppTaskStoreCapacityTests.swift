import XCTest

@testable import MacIDMApp

/// Model-level capacity probe backing the "1000+ 任务" performance gate
/// (product-spec §8.2). The UI-level gate stays a separate, manual evidence
/// tier; this probe keeps the persistence layer honest at capacity: bulk
/// insert, full reload, and repeated progress writes must each stay far below
/// anything a user could perceive as a stall.
final class AppTaskStoreCapacityTests: XCTestCase {
    func testThousandTwoHundredTaskStoreOperationsStayInteractive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppTaskStore(directory: directory)
        let tasks: [AppTask] = (0..<1_200).map { index in
            var task = AppTask(
                id: UUID(),
                sourceURL: "https://example.com/file-\(index).zip?token=private-\(index)",
                destinationPath: directory.appendingPathComponent("file-\(index).zip").path,
                maximumParallelRequests: 8,
                expectedSHA256: nil,
                browserClientID: nil,
                browserSubmissionType: nil,
                browserSubmissionKey: nil,
                createdAt: Date(),
                updatedAt: Date(),
                status: index % 3 == 0 ? .running : .queued,
                receivedBytes: Int64(index * 128),
                totalBytes: Int64(index * 128 + 1_024),
                bytesPerSecond: 256,
                speedHistory: [
                    SpeedSample(timestamp: Date(timeIntervalSinceNow: -4), bytesPerSecond: 128),
                    SpeedSample(timestamp: Date(timeIntervalSinceNow: -2), bytesPerSecond: 256),
                ],
                sha256: nil,
                verification: nil,
                errorCode: nil,
                errorMessage: nil,
                segments: [
                    SegmentSnapshot(index: 0, receivedBytes: Int64(index * 128), totalBytes: Int64(index * 128 + 1_024))
                ]
            )
            task.priority = index % 10
            return task
        }

        let insertStart = Date()
        try store.save(tasks)
        let insertSeconds = Date().timeIntervalSince(insertStart)

        let reloadStart = Date()
        let loaded = try store.load()
        let reloadSeconds = Date().timeIntervalSince(reloadStart)
        XCTAssertEqual(loaded.count, 1_200)

        // Progress writes are the hot path: every coalesced progress tick
        // rewrites the active task rows.
        let progressTasks = loaded.map { task -> AppTask in
            var updated = task
            updated.receivedBytes += 4_096
            updated.bytesPerSecond = 1_024
            return updated
        }
        let progressStart = Date()
        for _ in 0..<10 {
            try store.saveProgress(progressTasks)
        }
        let progressSeconds = Date().timeIntervalSince(progressStart)

        // Generous CI-safe ceilings (well under any user-perceptible stall),
        // tight enough to catch a path that goes per-task-linear without bound.
        XCTAssertLessThan(insertSeconds, 10.0, "bulk insert of 1200 tasks took \(insertSeconds)s")
        XCTAssertLessThan(reloadSeconds, 5.0, "full reload of 1200 tasks took \(reloadSeconds)s")
        XCTAssertLessThan(progressSeconds, 20.0, "10 progress sweeps over 1200 tasks took \(progressSeconds)s")
    }
}
