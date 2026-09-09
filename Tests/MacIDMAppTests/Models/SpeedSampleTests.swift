import SQLite3
import XCTest

@testable import MacIDMApp

/// Rolling-window policy and persistence migration for timestamped speed
/// samples (docs/AI交接.md §4.1, product-spec §4.3 速率曲线口径).
final class SpeedSampleTests: XCTestCase {
    func testTrimmingKeepsOnlyTheMostRecent120Seconds() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-200), bytesPerSecond: 10),
            SpeedSample(timestamp: now.addingTimeInterval(-121), bytesPerSecond: 20),
            SpeedSample(timestamp: now.addingTimeInterval(-119), bytesPerSecond: 30),
            SpeedSample(timestamp: now.addingTimeInterval(-1), bytesPerSecond: 40),
        ]

        let trimmed = SpeedHistoryPolicy.trimmed(samples, now: now)

        XCTAssertEqual(trimmed.map(\.bytesPerSecond), [30, 40])
    }

    func testTrimmingKeepsTheBoundarySampleExactly120SecondsOld() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let boundary = SpeedSample(timestamp: now.addingTimeInterval(-120), bytesPerSecond: 5)

        let trimmed = SpeedHistoryPolicy.trimmed([boundary], now: now)

        XCTAssertEqual(trimmed, [boundary])
    }

    func testTrimmingCapsAbnormallyHighFrequencyReporting() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        // 500 distinct time-ordered samples inside the window: the point
        // cap must win, dropping the oldest samples rather than growing
        // without bound.
        let samples = (0..<500).map { offset in
            SpeedSample(
                timestamp: now.addingTimeInterval(-Double(499 - offset) * 0.2),
                bytesPerSecond: Double(offset)
            )
        }

        let trimmed = SpeedHistoryPolicy.trimmed(samples, now: now)

        XCTAssertEqual(trimmed.count, SpeedHistoryPolicy.maximumSamples)
        // The newest sample always survives.
        XCTAssertEqual(trimmed.last?.bytesPerSecond, 499)
    }

    func testUnevenIntervalsSurviveTrimmingUnchanged() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-60), bytesPerSecond: 1),
            SpeedSample(timestamp: now.addingTimeInterval(-59.7), bytesPerSecond: 2),
            SpeedSample(timestamp: now.addingTimeInterval(-5), bytesPerSecond: 3),
        ]

        XCTAssertEqual(SpeedHistoryPolicy.trimmed(samples, now: now), samples)
    }

    // ---- 乱序样本统一策略（docs/AI交接.md §10）----

    func testTrimmingSortsOutOfOrderSamplesByTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        // 乱序到达（回调竞态）：策略层按时间戳归位，曲线不再向左折返。
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-5), bytesPerSecond: 40),
            SpeedSample(timestamp: now.addingTimeInterval(-60), bytesPerSecond: 10),
            SpeedSample(timestamp: now.addingTimeInterval(-30), bytesPerSecond: 30),
            SpeedSample(timestamp: now.addingTimeInterval(-90), bytesPerSecond: 20),
        ]

        let trimmed = SpeedHistoryPolicy.trimmed(samples, now: now)

        XCTAssertEqual(trimmed.map(\.bytesPerSecond), [20, 10, 30, 40])
        XCTAssertEqual(trimmed.map(\.timestamp), trimmed.map(\.timestamp).sorted())
        XCTAssertEqual(trimmed.last?.bytesPerSecond, 40, "最新时间戳的样本必须在末尾")
    }

    func testWindowSamplesAndSummaryTakeNewestTimestampAfterSorting() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-10), bytesPerSecond: 999),
            SpeedSample(timestamp: now.addingTimeInterval(-50), bytesPerSecond: 500),
            SpeedSample(timestamp: now.addingTimeInterval(-1), bytesPerSecond: 777),
        ]
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: now)
        // 乱序输入下：图形最右点与可访问性 current 必须取最新时间戳，而不是数组末项。
        let summary = SpeedHistoryPolicy.visibleSummary(visible)
        XCTAssertEqual(summary.current, 777)
        XCTAssertEqual(summary.peak, 999, "peak 只取可见 120 秒窗口内的最大值")
        XCTAssertEqual(visible.last?.timestamp, now.addingTimeInterval(-1))
    }

    func testIdenticalTimestampsAreKeptWithoutFolding() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let stamp = now.addingTimeInterval(-10)
        let samples = [
            SpeedSample(timestamp: stamp, bytesPerSecond: 100),
            SpeedSample(timestamp: stamp, bytesPerSecond: 300),
        ]

        let trimmed = SpeedHistoryPolicy.trimmed(samples, now: now)

        XCTAssertEqual(trimmed.count, 2, "相同时间戳样本不得互相吞并")
        let summary = SpeedHistoryPolicy.visibleSummary(
            SpeedHistoryPolicy.windowSamples(trimmed, reference: now))
        XCTAssertEqual(summary.peak, 300)
    }

    func testNonFiniteAndNegativeSpeedsAreDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-40), bytesPerSecond: .infinity),
            SpeedSample(timestamp: now.addingTimeInterval(-30), bytesPerSecond: -.infinity),
            SpeedSample(timestamp: now.addingTimeInterval(-20), bytesPerSecond: .nan),
            SpeedSample(timestamp: now.addingTimeInterval(-10), bytesPerSecond: -1),
            SpeedSample(timestamp: now.addingTimeInterval(-5), bytesPerSecond: 42),
        ]

        let trimmed = SpeedHistoryPolicy.trimmed(samples, now: now)

        XCTAssertEqual(trimmed.map(\.bytesPerSecond), [42])
    }

    func testPersistenceRoundTripStaysSortOrderSafe() throws {
        // 持久化回读可能乱序：读取后的窗口/摘要仍必须按时间戳排序。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedOrderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var task = makeTask(directory: directory)
        task.speedHistory = [
            SpeedSample(timestamp: now.addingTimeInterval(-5), bytesPerSecond: 300),
            SpeedSample(timestamp: now.addingTimeInterval(-50), bytesPerSecond: 100),
            SpeedSample(timestamp: now.addingTimeInterval(-20), bytesPerSecond: 200),
        ]
        let store = try AppTaskStore(directory: directory)
        try store.save([task])

        let reloaded = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(reloaded.load().first)
        let reference = SpeedHistoryPolicy.windowReference(
            samples: loaded.speedHistory, now: now, isTerminal: false)
        let visible = SpeedHistoryPolicy.windowSamples(loaded.speedHistory, reference: reference)
        XCTAssertEqual(visible.map(\.bytesPerSecond), [100, 200, 300])
        XCTAssertEqual(
            SpeedHistoryPolicy.visibleSummary(visible).current, 300,
            "回读乱序历史的 current 仍须取最新时间戳")
    }

    // ---- 窗口参考时间与过滤（product-spec §4.3 固定横轴）----

    func testActiveWindowReferenceTracksWallClockEvenWithoutFreshSamples() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        // 最后一个样本已是 30 秒前（速度回调静默）：活动态仍以墙钟为右边界。
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-90), bytesPerSecond: 10),
            SpeedSample(timestamp: now.addingTimeInterval(-30), bytesPerSecond: 20),
        ]
        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: now, isTerminal: false)
        XCTAssertEqual(reference, now)
    }

    func testTerminalWindowReferenceFreezesAtFinalSample() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let finalSample = now.addingTimeInterval(-600)
        let samples = [
            SpeedSample(timestamp: finalSample.addingTimeInterval(-30), bytesPerSecond: 10),
            SpeedSample(timestamp: finalSample, bytesPerSecond: 20),
        ]
        // 终态冻结在最终采样时刻：稍后打开详情曲线不会继续老化。
        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: now, isTerminal: true)
        XCTAssertEqual(reference, finalSample)
    }

    func testWindowSamplesDropExpiredSamplesAgainstWallClock() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-200), bytesPerSecond: 10),
            SpeedSample(timestamp: now.addingTimeInterval(-121), bytesPerSecond: 20),
            SpeedSample(timestamp: now.addingTimeInterval(-119), bytesPerSecond: 30),
            SpeedSample(timestamp: now.addingTimeInterval(-1), bytesPerSecond: 40),
        ]
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: now)
        // 静默期墙钟前移后，超过 120 秒的旧样本离开窗口。
        XCTAssertEqual(visible.map(\.bytesPerSecond), [30, 40])
    }

    func testTerminalWindowKeepsCompletionSnapshot() {
        let end = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: end.addingTimeInterval(-150), bytesPerSecond: 10),
            SpeedSample(timestamp: end.addingTimeInterval(-100), bytesPerSecond: 30),
            SpeedSample(timestamp: end, bytesPerSecond: 40),
        ]
        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: end.addingTimeInterval(3600), isTerminal: true)
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: reference)
        // 冻结后的窗口保留完成时最后 120 秒历史，不随当前墙钟变空。
        XCTAssertEqual(visible.map(\.bytesPerSecond), [30, 40])
    }

    func testLegacyUntimestampedHistoryIsDroppedWithoutFabricatedTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedLegacyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        try store.save([makeTask(directory: directory)])

        // Simulate an old database row whose history is a plain `[Double]`.
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("tasks.sqlite3").path
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            return XCTFail("cannot reopen test database")
        }
        defer { sqlite3_close(database) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            "UPDATE tasks SET speed_history_json = '[1024, 2048]'",
            nil,
            nil,
            &errorPointer
        )
        if let errorPointer { sqlite3_free(errorPointer) }
        XCTAssertEqual(result, SQLITE_OK)

        let reloaded = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(reloaded.load().first)
        // The legacy values must degrade to an empty history — never to
        // samples with invented timestamps claiming a real 120s window.
        XCTAssertTrue(loaded.speedHistory.isEmpty)
    }

    func testVisibleSummaryMatchesVisibleWindowOnly() {
        // §5：可访问性 current/peak 必须与图形共用同一份可见窗口样本。
        let now = Date()
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-400), bytesPerSecond: 9_000),
            SpeedSample(timestamp: now.addingTimeInterval(-130), bytesPerSecond: 8_000),
            SpeedSample(timestamp: now.addingTimeInterval(-90), bytesPerSecond: 1_000),
            SpeedSample(timestamp: now.addingTimeInterval(-10), bytesPerSecond: 2_000),
        ]
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: now)
        let summary = SpeedHistoryPolicy.visibleSummary(visible)
        // 窗口外的高峰值不得被朗读。
        XCTAssertEqual(summary.peak, 2_000, "peak 只来自可见 120 秒窗口")
        XCTAssertEqual(summary.current, 2_000, "current 取可见窗口最后一个样本")
    }

    func testVisibleSummaryIsZeroWhenWindowEmpty() {
        // §5：全部样本早于 reference 120 秒 → 可见为空 → current/peak 均为 0。
        let now = Date()
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-400), bytesPerSecond: 9_000),
            SpeedSample(timestamp: now.addingTimeInterval(-121), bytesPerSecond: 8_000),
        ]
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: now)
        XCTAssertTrue(visible.isEmpty)
        let summary = SpeedHistoryPolicy.visibleSummary(visible)
        XCTAssertEqual(summary.current, 0)
        XCTAssertEqual(summary.peak, 0)
    }

    func testVisibleSummaryUsesFrozenReferenceInTerminalState() {
        // §5：终态冻结在最终采样时刻，可访问性与图形一致地使用该冻结 reference。
        let frozen = Date()
        let samples = [
            SpeedSample(timestamp: frozen.addingTimeInterval(-300), bytesPerSecond: 9_000),
            SpeedSample(timestamp: frozen.addingTimeInterval(-50), bytesPerSecond: 3_000),
            SpeedSample(timestamp: frozen, bytesPerSecond: 4_000),
        ]
        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: frozen.addingTimeInterval(10_000), isTerminal: true)
        XCTAssertEqual(reference, frozen, "终态必须冻结在最终采样时刻")
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: reference)
        let summary = SpeedHistoryPolicy.visibleSummary(visible)
        XCTAssertEqual(summary.peak, 4_000)
        XCTAssertEqual(summary.current, 4_000)
    }

    // ---- §5：终态参考时间与持久化回读净化（docs/AI交接.md 2026-08-29）----

    func testTerminalWindowReferenceIgnoresNewerInvalidSamples() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let lastValid = now.addingTimeInterval(-10)
        // 历史末尾存在时间更新但速度为负/非有限的无效样本：终态参考时间必须
        // 冻结在最后一个有效样本，而不是被无效样本抢先。
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-30), bytesPerSecond: 10),
            SpeedSample(timestamp: lastValid, bytesPerSecond: 42),
            SpeedSample(timestamp: now.addingTimeInterval(-2), bytesPerSecond: -1),
            SpeedSample(timestamp: now.addingTimeInterval(-1), bytesPerSecond: .nan),
        ]

        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: now, isTerminal: true)

        XCTAssertEqual(reference, lastValid, "终态参考时间必须取最后一个有效样本")
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: reference)
        XCTAssertEqual(visible.map(\.bytesPerSecond), [10, 42])
    }

    func testTerminalWindowReferenceFallsBackToNowWithoutValidSamples() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: now.addingTimeInterval(-5), bytesPerSecond: -10)
        ]

        let reference = SpeedHistoryPolicy.windowReference(
            samples: samples, now: now, isTerminal: true)

        XCTAssertEqual(reference, now, "没有有效样本时回退 now")
    }

    func testSanitizedRejectsNonFiniteTimestampsAndSortsStably() {
        let base = Date(timeIntervalSince1970: 1_800_000)
        let samples = [
            SpeedSample(timestamp: Date(timeIntervalSinceReferenceDate: .infinity), bytesPerSecond: 9),
            SpeedSample(timestamp: base.addingTimeInterval(-5), bytesPerSecond: 2),
            SpeedSample(timestamp: Date(timeIntervalSinceReferenceDate: .nan), bytesPerSecond: 3),
            SpeedSample(timestamp: base.addingTimeInterval(-10), bytesPerSecond: 1),
        ]

        let sanitized = SpeedHistoryPolicy.sanitized(samples)

        XCTAssertEqual(sanitized.map(\.bytesPerSecond), [1, 2], "非有限时间戳样本必须丢弃")
    }

    func testPersistenceReadbackHistoryIsSanitizedBeforeTaskConstruction() throws {
        // 持久化回读包含乱序与负速度样本：`loaded.speedHistory` 本身必须已净化并排序，
        // 而不是调用 windowSamples 后才看起来正确。异常行直接写入数据库列构造（
        // JSON 无法表达非有限值，负速度与乱序是持久化数据中真实可出现的异常）。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedSanitizeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        try store.save([makeTask(directory: directory)])

        let epoch = Date(timeIntervalSince1970: 1_800_000).timeIntervalSinceReferenceDate
        let row = """
            [{"timestamp": \(epoch - 5), "bytesPerSecond": 300},
             {"timestamp": \(epoch - 50), "bytesPerSecond": -1},
             {"timestamp": \(epoch - 20), "bytesPerSecond": 200},
             {"timestamp": \(epoch - 30), "bytesPerSecond": 100}]
            """
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("tasks.sqlite3").path
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            return XCTFail("cannot reopen test database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "UPDATE tasks SET speed_history_json = ?", -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            return XCTFail("cannot prepare update statement")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (row as NSString).utf8String, -1, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let reloaded = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(reloaded.load().first)

        XCTAssertEqual(
            loaded.speedHistory.map(\.bytesPerSecond), [100, 200, 300],
            "回读历史必须先净化排序再构造任务")
        XCTAssertEqual(
            loaded.speedHistory.map(\.timestamp),
            loaded.speedHistory.map(\.timestamp).sorted(),
            "回读历史必须按时间戳升序")
    }

    func testCompletedTaskKeepsFinalWindowSnapshotHoursLaterViaStore() throws {
        // 完成任务数小时后再打开：回读不得用当前墙钟做 120 秒裁剪，
        // 终态冻结窗口保留完成时最后 120 秒快照。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedCompletedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let end = Date(timeIntervalSince1970: 1_800_000)
        var task = makeTask(directory: directory)
        task.status = .completed
        task.speedHistory = [
            SpeedSample(timestamp: end.addingTimeInterval(-150), bytesPerSecond: 10),
            SpeedSample(timestamp: end.addingTimeInterval(-100), bytesPerSecond: 30),
            SpeedSample(timestamp: end, bytesPerSecond: 40),
        ]
        let store = try AppTaskStore(directory: directory)
        try store.save([task])

        let reloaded = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(reloaded.load().first)

        // 数小时后的墙钟不参与裁剪：全部净化后的样本仍在。
        XCTAssertEqual(loaded.speedHistory.count, 3, "回读不做 120 秒墙钟裁剪")
        let reference = SpeedHistoryPolicy.windowReference(
            samples: loaded.speedHistory, now: end.addingTimeInterval(6 * 3_600), isTerminal: true)
        let visible = SpeedHistoryPolicy.windowSamples(loaded.speedHistory, reference: reference)
        XCTAssertEqual(visible.map(\.bytesPerSecond), [30, 40], "完成快照保留最后 120 秒窗口")
    }

    private func makeTask(directory: URL) -> AppTask {
        AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: directory.appendingPathComponent("file.zip").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .running,
            receivedBytes: 100,
            totalBytes: 1_000,
            bytesPerSecond: 50,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
    }
}
