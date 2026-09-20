import IDMEngine
import XCTest

@testable import MacIDMApp

/// Completion average caliber (product-spec §4.1): `averageSpeed` must be
/// `transferredBytes / activeTransferDuration`, where the active duration
/// only accumulates while bytes advance — pauses never count.
@MainActor
final class AppModelSpeedTests: XCTestCase {
    func testAverageSpeedUsesActiveTransferDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedAverageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let runner = ScriptedDownloadRunner()
        // Two transferring bursts of ~0.8 s each, separated by a byte-frozen
        // stall of ~2.5 s. The stall publishes no byte progress, so the
        // active duration must stay far below the wall-clock duration.
        runner.script = [
            .progress(bytes: 100, total: 400),
            .sleep(0.8),
            .progress(bytes: 200, total: 400),
            .sleep(2.5),
            .progress(bytes: 400, total: 400),
            .complete(byteCount: 400),
        ]
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: runner
        )
        try model.addDownload(
            urlString: "https://example.com/file.zip",
            destination: directory.appendingPathComponent("file.zip"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: true
        )

        try await waitForCompletion(model: model)
        let task = try XCTUnwrap(model.tasks.first)

        XCTAssertEqual(task.status, .completed)
        XCTAssertGreaterThan(task.activeTransferDuration, 0.8)
        // Wall clock covers both bursts plus the 2.5 s stall; the active
        // duration must exclude the stall.
        let wallClock = try XCTUnwrap(task.totalDuration)
        XCTAssertLessThan(task.activeTransferDuration, wallClock - 1.5)
        // The completion average is defined by the active duration, not by
        // the last instantaneous sample.
        let expected = Double(task.receivedBytes) / task.activeTransferDuration
        XCTAssertEqual(try XCTUnwrap(task.averageSpeed), expected, accuracy: 0.01)
    }

    func testPauseTimeIsExcludedFromActiveTransferDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSpeedPauseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let runner = ScriptedDownloadRunner()
        // Run 1 transfers a little, then honors the pause control.
        runner.script = [
            .progress(bytes: 100, total: 400),
            .sleep(0.6),
            .progress(bytes: 150, total: 400),
            .awaitPause,
        ]
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: runner
        )
        try model.addDownload(
            urlString: "https://example.com/file.zip",
            destination: directory.appendingPathComponent("file.zip"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: true
        )
        try await waitForStatus(model: model, .running)

        model.pause(try XCTUnwrap(model.tasks.first).id)
        try await waitForStatus(model: model, .paused)
        // A pause long enough that it must visibly shrink the average's
        // denominator if (and only if) pauses are excluded.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // Run 2 resumes the transfer to completion.
        runner.script = [
            .progress(bytes: 250, total: 400),
            .sleep(0.8),
            .progress(bytes: 400, total: 400),
            .complete(byteCount: 400),
        ]
        model.resume(try XCTUnwrap(model.tasks.first).id)

        try await waitForCompletion(model: model)
        let task = try XCTUnwrap(model.tasks.first)

        XCTAssertEqual(task.status, .completed)
        let wallClock = try XCTUnwrap(task.totalDuration)
        XCTAssertGreaterThan(wallClock, 3.0)
        // The 2.5 s pause must not enter the active duration.
        XCTAssertLessThan(task.activeTransferDuration, wallClock - 1.5)
        let expected = Double(task.receivedBytes) / task.activeTransferDuration
        XCTAssertEqual(try XCTUnwrap(task.averageSpeed), expected, accuracy: 0.01)
    }

    private func waitForCompletion(model: AppModel) async throws {
        for _ in 0..<3_000 {
            if model.tasks.first?.status == .completed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("task never completed, status=\(String(describing: model.tasks.first?.status))")
    }

    private func waitForStatus(model: AppModel, _ status: AppTaskStatus) async throws {
        for _ in 0..<1_000 {
            if model.tasks.first?.status == status { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "task never reached \(status), status=\(String(describing: model.tasks.first?.status))"
        )
    }
}

private struct ScriptExhaustedError: Error {}

/// Test runner executing a scripted sequence of progress bursts, stalls,
/// pause handoffs and completion. Steps are consumed across runs so a
/// resume continues with the next script segment.
private final class ScriptedDownloadRunner: AppDownloadRunning, @unchecked Sendable {
    enum Step {
        case progress(bytes: Int64, total: Int64)
        case sleep(TimeInterval)
        case awaitPause
        case complete(byteCount: Int64)
    }

    private let lock = NSLock()
    private var steps: [Step] = []

    var script: [Step] {
        get { lock.withLock { steps } }
        set { lock.withLock { steps = newValue } }
    }

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        while true {
            let step: Step? = lock.withLock { steps.isEmpty ? nil : steps.removeFirst() }
            guard let step else {
                throw ScriptExhaustedError()
            }
            switch step {
            case .progress(let bytes, let total):
                progress(DownloadProgress(receivedBytes: bytes, totalBytes: total))
            case .sleep(let interval):
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            case .awaitPause:
                // Honor the pause control like the real engine does.
                for _ in 0..<200 {
                    if control() == .pause { throw IDMError.paused }
                    if Task.isCancelled { throw IDMError.paused }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw ScriptExhaustedError()
            case .complete(let byteCount):
                try FileManager.default.createDirectory(
                    at: request.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(count: Int(byteCount)).write(to: request.destination, options: .atomic)
                progress(DownloadProgress(receivedBytes: byteCount, totalBytes: byteCount))
                return DownloadResult(
                    destination: request.destination,
                    byteCount: byteCount,
                    sha256: "scripted",
                    usedParallelRequests: request.maximumParallelRequests,
                    resumed: false,
                    verification: "test"
                )
            }
        }
    }
}
