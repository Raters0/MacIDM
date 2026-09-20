import IDMEngine
import XCTest

@testable import MacIDMApp

/// 完成态任务的文件存在性巡检（AGENTS.md「诊断日志」约束）：本轮会话开始前
/// 就已丢失的文件只是既有状态，表格照旧标记，但不得在每次启动时逐条弹通知、
/// 逐条写日志；会话期间真正丢失的文件仍要提醒用户。
@MainActor
final class FileMissingSweepTests: XCTestCase {
    func testAnnouncementRuleTreatsTheFirstObservationOfALaunchTaskAsBaseline() {
        let launchTask = UUID()
        let sessionTask = UUID()

        // 启动时就已完成的任务，第一次观察 = 既有状态，不播报。
        XCTAssertFalse(
            AppModel.shouldAnnounceFileMissing(
                taskID: launchTask,
                baselineTaskIDs: [launchTask],
                seenTaskIDs: []
            )
        )
        // 同一次启动中的第二次观察（文件回来后又消失）= 会话事件，要播报。
        XCTAssertTrue(
            AppModel.shouldAnnounceFileMissing(
                taskID: launchTask,
                baselineTaskIDs: [launchTask],
                seenTaskIDs: [launchTask]
            )
        )
        // 会话中新完成的任务永远不是基线：它完成时文件是在的。
        XCTAssertTrue(
            AppModel.shouldAnnounceFileMissing(
                taskID: sessionTask,
                baselineTaskIDs: [launchTask],
                seenTaskIDs: []
            )
        )
    }

    func testSweepFlagsAPreExistingLossAndRecordsItAsSeenWithoutRepeating() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMFileMissingSweepTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let missingTaskID = UUID()
        let store = try AppTaskStore(directory: directory)
        try store.save([
            Self.completedTask(
                id: missingTaskID,
                // 目标文件从未存在：模拟用户在 App 退出期间删除了下载结果。
                destinationPath: directory.appendingPathComponent("already-deleted.mp4").path
            )
        ])

        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: makeIsolatedDefaults()),
            useEnvironmentFFmpeg: false
        )
        model.startFileExistenceCheck()
        defer { model.shutdown() }

        // 启动快照必须只包含当时已完成的任务，否则会话中新完成的任务会被
        // 误判为「既有丢失」而永远不提醒。
        XCTAssertEqual(model.fileCheckBaselineTaskIDs, [missingTaskID])
        XCTAssertTrue(model.fileCheckSeenTaskIDs.isEmpty)

        model.checkCompletedTaskFiles()
        try await waitForFlag(on: model, taskID: missingTaskID)

        // 既有丢失仍然要更新标记：表格的「文件已丢失」警告不能因为不播报而消失。
        XCTAssertTrue(
            model.tasks.first { $0.id == missingTaskID }?.fileMissing == true,
            "巡检必须为已丢失的目标文件设置 fileMissing 标记"
        )
        XCTAssertTrue(
            model.fileCheckSeenTaskIDs.contains(missingTaskID),
            "第一次观察后必须记入已见集合，后续同一丢失不再重复播报"
        )

        // 第二次巡检：状态没有变化，既不该再次改动标记，也不该产生新的播报。
        model.checkCompletedTaskFiles()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.tasks.first { $0.id == missingTaskID }?.fileMissing == true)
    }

    /// 巡检在 detached 任务里做磁盘检查后回到主 actor 应用结果；测试用轮询
    /// 等待，避免在 MainActor 上用 wait(for:) 把自己阻塞死。
    private func waitForFlag(on model: AppModel, taskID: UUID) async throws {
        for _ in 0..<100 {
            if model.tasks.first(where: { $0.id == taskID })?.fileMissing == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("巡检未在预算内为丢失文件设置标记")
    }

    private static func completedTask(id: UUID, destinationPath: String) -> AppTask {
        AppTask(
            id: id,
            sourceURL: "https://cdn.example.test/media/movie.mp4",
            destinationPath: destinationPath,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .http,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .completed,
            receivedBytes: 1024,
            totalBytes: 1024,
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
