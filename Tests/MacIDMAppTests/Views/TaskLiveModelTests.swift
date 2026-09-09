import XCTest

@testable import MacIDMApp

/// The task table's data snapshot only rebuilds on structural changes, so
/// completion-time values must reach the cells through the live model.
/// These tests pin the exact fields `apply` mirrors, guarding the fix for
/// the average speed that used to appear only after a restart or the next
/// structural change.
@MainActor
final class TaskLiveModelTests: XCTestCase {
    func testApplyPropagatesCompletionAverageSpeed() {
        var task = makeTask()
        let live = TaskLiveModel(task: task)
        XCTAssertNil(live.averageSpeed)

        // Simulate the completion update path: finish() sets the average
        // and AppModel pushes the fresh task through updateLive/apply.
        task.status = .completed
        task.receivedBytes = 1_048_576
        task.totalBytes = 1_048_576
        task.averageSpeed = 524_288
        live.apply(task)

        XCTAssertEqual(live.status, .completed)
        XCTAssertEqual(live.averageSpeed, 524_288)
    }

    func testApplyPropagatesCompletionTotalDuration() {
        // Regression: the duration cell read the recorded total off the
        // table snapshot, which only rebuilds on structural changes. Right
        // after a download finished the snapshot still carried nil and the
        // cell fell back to updatedAt - createdAt from insertion time,
        // briefly showing "0.01 s" instead of the real total.
        var task = makeTask()
        let live = TaskLiveModel(task: task)
        XCTAssertNil(live.totalDuration)

        task.status = .completed
        task.totalDuration = 137.4
        live.apply(task)

        XCTAssertEqual(live.status, .completed)
        XCTAssertEqual(live.totalDuration, 137.4)
    }

    func testApplyKeepsAverageSpeedNilUntilCompletionRecordsIt() {
        var task = makeTask()
        task.status = .running
        task.receivedBytes = 4096
        task.bytesPerSecond = 2048
        let live = TaskLiveModel(task: task)

        XCTAssertNil(live.averageSpeed)
        XCTAssertEqual(live.bytesPerSecond, 2048)
    }

    private func makeTask() -> AppTask {
        AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: "/tmp/file.zip",
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
    }
}
