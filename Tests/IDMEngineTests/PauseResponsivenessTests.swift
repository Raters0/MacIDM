import Foundation
import XCTest

@testable import IDMEngine

/// Regression guard for the "pause takes seconds to take effect" bug: while
/// a ranged download ran, pausing cancelled the sibling transfers while their
/// URLSession data tasks were suspended (the backpressure pattern suspends a
/// task between chunks). URLSession queues didCompleteWithError behind the
/// suspension, so the transfers' continuations were not resumed until seconds
/// later and the pause visibly stalled in the "Pausing" state. The processing chain now
/// resumes the data task on every exit path, so pause must take effect fast.
final class PauseResponsivenessTests: XCTestCase {
    private var serverProcess: Process?
    private var port = 0

    override func setUp() async throws {
        try await super.setUp()
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            rootURL.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
        try await waitUntilServerReady(URL(string: "http://127.0.0.1:\(port)/range?size=1")!)
    }

    override func tearDown() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        super.tearDown()
    }

    func testPauseStopsARangedDownloadPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPauseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // delay=0.02 per 16 KiB chunk keeps every segment streaming long
        // enough that the pause lands while all four transfers are active.
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range?size=2097152&delay=0.02")
        )
        let request = DownloadRequest(
            url: url,
            destination: directory.appendingPathComponent("paused.bin"),
            maximumParallelRequests: 4,
            taskID: UUID()
        )
        let token = PauseToken()
        let engine = DownloadEngine(retryPolicy: DownloadRetryPolicy(maxAttempts: 1))
        let started = Date()

        do {
            _ = try await engine.download(
                request,
                control: { token.read() }
            ) { progress in
                if progress.receivedBytes > 65_536 { token.pause() }
            }
            XCTFail("expected the download to stop with IDMError.paused")
        } catch let error as IDMError {
            guard case .paused = error else {
                return XCTFail("expected .paused, got \(error)")
            }
        }

        // Before the fix the sibling drain alone took 5-10 seconds; a healthy
        // pause settles well under a second. The generous bound keeps the
        // test stable on slow CI machines while still catching the regression.
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.0, "pause took \(elapsed)s to take effect")
    }

    func testPauseUnderTightGlobalRateLimitTakesEffectPromptly() async throws {
        // Regression: with a tight shared token bucket each segment queued
        // multi-second rate-limit reservations, and the pause control check
        // only ran around a single acquire() for the whole chunk — so a
        // pause stalled until every queued reservation expired (5-10+ s in
        // production logs). Acquiring the limit in slices with control
        // checks between slices bounds the pause latency to one slice wait.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPauseLimitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range?size=2097152&delay=0.001")
        )
        let limiter = try TokenBucketRateLimiter(rateBytesPerSecond: 96 * 1024)
        let request = DownloadRequest(
            url: url,
            destination: directory.appendingPathComponent("limited.bin"),
            maximumParallelRequests: 4,
            taskID: UUID(),
            rateLimiter: limiter
        )
        let token = PauseToken()
        let engine = DownloadEngine(retryPolicy: DownloadRetryPolicy(maxAttempts: 1))
        let started = Date()

        do {
            _ = try await engine.download(
                request,
                control: { token.read() }
            ) { progress in
                if progress.receivedBytes > 65_536 { token.pause() }
            }
            XCTFail("expected the download to stop with IDMError.paused")
        } catch let error as IDMError {
            guard case .paused = error else {
                return XCTFail("expected .paused, got \(error)")
            }
        }

        // A 32 KiB slice at 96 KB/s waits ~0.33 s; allow headroom for the
        // in-flight chunk plus teardown while staying far below the old
        // multi-second stall.
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.5, "rate-limited pause took \(elapsed)s to take effect")
    }

    private func waitUntilServerReady(_ probe: URL) async throws {
        for _ in 0..<100 {
            if (try? Data(contentsOf: probe)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IDMError.storageError("fixture server did not become ready")
    }
}

private final class PauseToken: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    func read() -> DownloadControl {
        lock.lock()
        defer { lock.unlock() }
        return paused ? .pause : .continue
    }
}
