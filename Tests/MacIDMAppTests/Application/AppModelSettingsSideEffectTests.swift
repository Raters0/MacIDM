import IDMEngine
import XCTest

@testable import MacIDMApp

/// 设置改动必须自己把副作用做完，不能等下一次别的触发。
/// `@Published` 在 `willSet` 就发通知，订阅里回头读属性会拿到上一个值；这些
/// 用例只等一次主队列轮转就要求效果出现，慢一拍的实现会直接失败。
@MainActor
final class AppModelSettingsSideEffectTests: XCTestCase {
    /// 一直停在传输中的假下载器：并发调度用例只需要任务保持 active。
    private final class HangingDownloadRunner: AppDownloadRunning, @unchecked Sendable {
        func run(
            _ request: DownloadRequest,
            control: @escaping @Sendable () -> DownloadControl,
            progress: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> DownloadResult {
            progress(DownloadProgress(receivedBytes: 1, totalBytes: 1_000))
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if control() == .pause { throw IDMError.paused }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw CancellationError()
        }
    }

    private func makeModel(
        downloadRunner: (any AppDownloadRunning)? = nil
    ) throws -> (AppModel, AppSettings, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSettingsEffects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: settings,
            downloadRunner: downloadRunner
        )
        addTeardownBlock { [weak model] in
            model?.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return (model, settings, directory)
    }

    /// 副作用订阅用 `receive(on: DispatchQueue.main)` 交付，这里排一次主队列，
    /// 让先入队的设置写入与它的回调都跑完。
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testProxySwitchAppliesBothDirectionsWithoutAnotherTrigger() async throws {
        let (model, settings, _) = try makeModel()
        defer { DownloadProxyPolicy.configure(nil) }
        XCTAssertNil(DownloadProxyPolicy.current)

        settings.proxyEnabled = true
        settings.proxyHost = "proxy.example.com"
        settings.proxyPort = 8_888
        await drainMainQueue()
        let applied = try XCTUnwrap(
            DownloadProxyPolicy.current,
            "打开代理开关后代理就要装上，不能等别的设置再触发一次"
        )
        XCTAssertEqual(applied.configuration.host, "proxy.example.com")
        XCTAssertEqual(applied.configuration.port, 8_888)

        settings.proxyEnabled = false
        await drainMainQueue()
        XCTAssertNil(
            DownloadProxyPolicy.current,
            "关掉代理后必须马上直连，否则下载还在走用户已经关掉的代理"
        )
        withExtendedLifetime(model) {}
    }

    func testRaisingTheConcurrentLimitStartsQueuedTasksWithoutAnotherTrigger() async throws {
        let (model, settings, directory) = try makeModel(downloadRunner: HangingDownloadRunner())
        settings.simultaneousDownloads = 1
        for name in ["a.bin", "b.bin"] {
            try model.addDownload(
                urlString: "https://example.com/\(name)",
                destination: directory.appendingPathComponent(name),
                maximumParallelRequests: 1,
                expectedSHA256: nil,
                startImmediately: true
            )
        }
        XCTAssertEqual(model.tasks.filter { $0.status.isActive }.count, 1)
        XCTAssertEqual(model.tasks.filter { $0.status == .queued }.count, 1)

        settings.simultaneousDownloads = 2
        await drainMainQueue()
        XCTAssertEqual(
            model.tasks.filter { $0.status.isActive }.count,
            2,
            "并发数提高后队列要立刻补位，而不是等下一个任务结束"
        )
    }

    /// 一次大额读取在预算时间内能不能完成：限速装上时必然完不成。
    private func acquireOutcome(
        _ limiter: DynamicRateLimiter,
        bytes: Int64,
        budgetNanoseconds: UInt64
    ) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                try? await limiter.acquire(bytes)
                return "acquired"
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: budgetNanoseconds)
                return "stillWaiting"
            }
            let first = await group.next() ?? "stillWaiting"
            group.cancelAll()
            return first
        }
    }

    func testSettingTheSpeedLimitThrottlesWithoutAnotherTrigger() async throws {
        let (model, settings, _) = try makeModel()
        // 起点：没设限速，大额读取立刻完成。
        let unlimited = await acquireOutcome(
            model.sharedRateLimiter,
            bytes: 200_000,
            budgetNanoseconds: 150_000_000
        )
        XCTAssertEqual(unlimited, "acquired")

        settings.speedLimitKBps = 1
        await drainMainQueue()

        // 1 KB/s 下读 200 KB 要等约 200 秒；限速器没装上才会立刻返回。
        let throttled = await acquireOutcome(
            model.sharedRateLimiter,
            bytes: 200_000,
            budgetNanoseconds: 150_000_000
        )
        XCTAssertEqual(
            throttled,
            "stillWaiting",
            "填了限速就该当场生效，而不是慢一次"
        )
    }
}
