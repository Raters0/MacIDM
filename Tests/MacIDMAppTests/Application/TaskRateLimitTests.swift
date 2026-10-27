import IDMEngine
import XCTest

@testable import MacIDMApp

@MainActor
final class TaskRateLimitTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRateLimitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults())
        )
        return model
    }

    /// A paused task with no local file; no network is touched.
    private func makeTask(in model: AppModel) throws -> AppTask {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rate-\(UUID().uuidString).bin")
        try model.addDownload(
            urlString: "https://example.com/rate.bin",
            destination: destination,
            maximumParallelRequests: 2,
            expectedSHA256: nil,
            startImmediately: false
        )
        guard let task = model.tasks.first else {
            throw XCTSkip("task was not created")
        }
        return task
    }

    func testUncappedTaskStillGetsAnUnlimitedPerTaskLimiter() throws {
        let model = try makeModel()
        let task = try makeTask(in: model)

        XCTAssertNil(task.rateLimitKBps)
        // Every started task carries its own (unlimited) wrapper so a cap
        // set later reaches the in-flight transfer.
        XCTAssertTrue(model.rateLimiter(for: task) is CombinedRateLimiter)
        XCTAssertNotNil(model.taskRateLimiters[task.id])
    }

    func testCapSetWhileRunningReconfiguresTheLimiterTheTransferHolds() throws {
        let model = try makeModel()
        let task = try makeTask(in: model)
        // The transfer captured the limiter at start, before any cap existed.
        _ = model.rateLimiter(for: task)
        let held = try XCTUnwrap(model.taskRateLimiters[task.id])

        model.setTaskRateLimit(256, for: task.id)

        XCTAssertEqual(model.tasks.first?.rateLimitKBps, 256)
        XCTAssertTrue(model.taskRateLimiters[task.id] === held)

        model.setTaskRateLimit(0, for: task.id)
        XCTAssertNil(model.tasks.first?.rateLimitKBps)
        XCTAssertTrue(model.taskRateLimiters[task.id] === held)
    }

    func testEffectiveLimitForYTDlpIsTheTighterOfGlobalAndTask() throws {
        let model = try makeModel()
        var task = try makeTask(in: model)

        model.settings.speedLimitKBps = 0
        XCTAssertNil(model.effectiveRateLimitKBps(for: task))
        task.rateLimitKBps = 300
        XCTAssertEqual(model.effectiveRateLimitKBps(for: task), 300)
        model.settings.speedLimitKBps = 200
        XCTAssertEqual(model.effectiveRateLimitKBps(for: task), 200)
        task.rateLimitKBps = nil
        XCTAssertEqual(model.effectiveRateLimitKBps(for: task), 200)
    }

    func testPerTaskCapSurvivesAStoreRoundTrip() throws {
        let model = try makeModel()
        var task = try makeTask(in: model)
        task.rateLimitKBps = 640
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRateLimitStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try AppTaskStore(directory: directory).save([task])

        let reloaded = try XCTUnwrap(AppTaskStore(directory: directory).load().first)
        XCTAssertEqual(reloaded.rateLimitKBps, 640)
    }

    func testRemovingTheTaskDiscardsItsLimiter() throws {
        let model = try makeModel()
        let task = try makeTask(in: model)
        _ = model.rateLimiter(for: task)
        model.setTaskRateLimit(128, for: task.id)
        XCTAssertNotNil(model.taskRateLimiters[task.id])

        model.remove(task.id)

        XCTAssertNil(model.taskRateLimiters[task.id])
    }
}
