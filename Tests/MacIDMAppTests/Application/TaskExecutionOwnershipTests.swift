import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

/// Retains callbacks after returning, as a queued bridge callback can outlive
/// the engine invocation. Continuations are always explicitly released.
private actor HeldDownloadRunner: AppDownloadRunning {
    var callbacks: [@Sendable (DownloadProgress) -> Void] = []
    var continuations: [Int: CheckedContinuation<DownloadResult, Error>] = [:]

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let index = callbacks.count
        callbacks.append(progress)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    var count: Int { callbacks.count }
    func emit(_ index: Int, bytes: Int64) {
        callbacks[index](DownloadProgress(receivedBytes: bytes, totalBytes: 100, segments: []))
    }
    func stop(_ index: Int, error: IDMError = .paused) {
        continuations.removeValue(forKey: index)?.resume(throwing: error)
    }
}

@MainActor
final class TaskExecutionOwnershipTests: XCTestCase {
    private func fixture(sourceKind: DownloadSourceKind = .http) throws -> (AppModel, HeldDownloadRunner, URL, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = HeldDownloadRunner()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults()), downloadRunner: runner
        )
        addTeardownBlock { @MainActor in
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        try model.addDownload(
            urlString: "https://example.test/data", destination: directory.appendingPathComponent("data.bin"),
            maximumParallelRequests: 1, expectedSHA256: nil, startImmediately: true, sourceKind: sourceKind
        )
        return (model, runner, directory, try XCTUnwrap(model.tasks.first?.id))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Controlled execution did not reach the expected state")
    }

    func testLateCallbackCannotCompleteReplacementExecution() async throws {
        let (model, runner, _, id) = try fixture()
        try await waitUntil { await runner.count == 1 }
        model.pause(id)
        await runner.stop(0)
        try await waitUntil { model.executions[id].task == nil }
        model.resume(id)
        try await waitUntil { await runner.count == 2 }
        await runner.emit(1, bytes: 10)
        try await Task.sleep(nanoseconds: 400_000_000)
        await runner.emit(0, bytes: 100)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.task(with: id)?.receivedBytes, 10)
        XCTAssertEqual(model.task(with: id)?.status, .running)
        await runner.stop(1)
        try await waitUntil { model.executions[id].task == nil }
    }

    func testSupersededHLSFailureCannotDeleteCurrentInput() async throws {
        let (model, runner, _, id) = try fixture(sourceKind: .hls)
        try await waitUntil { await runner.count == 1 }
        let input = model.hlsInputURL(for: try XCTUnwrap(model.task(with: id)))
        // Model an already superseded invocation whose await later throws.
        // The production catch must check ownership before its file effects.
        let oldExecution = try XCTUnwrap(model.executions[id].task)
        model.executions[id].generation += 1
        try Data("replacement input".utf8).write(to: input)
        await runner.stop(0, error: .cancelled)
        await oldExecution.value
        XCTAssertEqual(try Data(contentsOf: input), Data("replacement input".utf8))
        model.cleanUpExecution(id)
    }

    func testStuckPauseRetainsWriterUntilItActuallyReturns() async throws {
        let (model, runner, _, id) = try fixture()
        try await waitUntil { await runner.count == 1 }
        model.pause(id)
        try await Task.sleep(nanoseconds: 20_200_000_000)
        XCTAssertEqual(model.task(with: id)?.errorCode, "STOP_TIMEOUT")
        XCTAssertNotNil(model.executions[id].task)
        XCTAssertNotNil(model.executions[id].control)
        XCTAssertEqual(model.activeCount, 1)
        model.resume(id)
        let count = await runner.count
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.presentedError)
        await runner.stop(0)
        try await waitUntil { model.executions[id].task == nil }
        XCTAssertEqual(model.task(with: id)?.status, .paused)
    }

    func testRemoveWaitsForWriterBeforeDeletingPartialArtifact() async throws {
        let (model, runner, _, id) = try fixture()
        try await waitUntil { await runner.count == 1 }
        let task = try XCTUnwrap(model.task(with: id))
        let artifact = try XCTUnwrap(AppModel.partialArtifactURLs(for: task).first)
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: artifact)
        model.remove(id, deletingFile: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertFalse(model.task(with: id)?.isArchived ?? true)
        await runner.stop(0)
        try await waitUntil { model.task(with: id)?.isArchived == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertNil(model.executions[id].task)
    }
}
