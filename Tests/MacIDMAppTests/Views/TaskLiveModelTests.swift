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

    func testApplyKeepsProgressMonotonicWhenTotalFluctuates() {
        // 回归（X.com HLS“卡验证”根因之一）：HLS 估算总量随分段大小波动，
        // 旧逻辑直接采用新比例会让进度条倒退甚至归零（100%→0% 跳变）。
        // 字节没退、仅比例下降时保持历史进度。
        var task = makeTask()
        task.status = .running
        task.receivedBytes = 3_000_000
        task.totalBytes = 6_000_000  // fraction = 0.5
        let live = TaskLiveModel(task: task)
        XCTAssertEqual(live.fractionCompleted, 0.5, accuracy: 0.0001)

        // total 上修（外推收敛）→ 比例降到 0.3，但字节没退：保持 0.5 不回退。
        task.totalBytes = 10_000_000
        live.apply(task)
        XCTAssertEqual(live.fractionCompleted, 0.5, accuracy: 0.0001)

        // 字节继续增长 → 跟随上升（0.6）。
        task.receivedBytes = 6_000_000
        live.apply(task)
        XCTAssertEqual(live.fractionCompleted, 0.6, accuracy: 0.0001)
    }

    func testApplyResetsProgressWhenTaskRetriesFromScratch() {
        // 单调不回退不能挡住真正的重置：任务失败重试、已下载字节归零时，
        // 进度必须跟随归零，而非卡在历史高值。
        var task = makeTask()
        task.status = .running
        task.receivedBytes = 5_000_000
        task.totalBytes = 6_000_000
        let live = TaskLiveModel(task: task)
        XCTAssertGreaterThan(live.fractionCompleted, 0.8)

        // 重试：字节倒退归零 → 进度跟随归零。
        task.receivedBytes = 0
        live.apply(task)
        XCTAssertEqual(live.fractionCompleted, 0, accuracy: 0.0001)
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
