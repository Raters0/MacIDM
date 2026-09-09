import XCTest

@testable import IDMEngine

/// Exercises engine throttling against an isolated, test-owned HTTP fixture.
final class EngineThrottleProbeTests: XCTestCase {
    func testEngineThroughputWithOneMBpsLimiter() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let port = Int.random(in: 40_000...50_000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [
            root.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }
        let readinessURL = URL(string: "http://127.0.0.1:\(port)/range?size=1")!
        var ready = false
        for _ in 0..<60 {
            if let (_, response) = try? await URLSession.shared.data(from: readinessURL),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ready, server.isRunning else {
            throw NSError(
                domain: "HTTPFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Test fixture failed to start"])
        }
        let url = URL(string: "http://127.0.0.1:\(port)/range?size=20971520")!
        let limiter = DynamicRateLimiter()
        limiter.reconfigure(try TokenBucketRateLimiter(rateBytesPerSecond: 1_048_576))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-probe-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let engine = DownloadEngine()
        let request = DownloadRequest(
            url: url,
            destination: destination,
            sourceKind: .http,
            maximumParallelRequests: 1,
            rateLimiter: limiter
        )
        let start = Date()
        _ = try await engine.download(request, control: { .continue }, progress: { _ in })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(try Data(contentsOf: destination).count, 20_971_520)
        print("THROTTLE_PROBE elapsed=\(elapsed)s for 20971520 bytes (\(Double(20971520)/elapsed/1_048_576) MB/s)")
        XCTAssertGreaterThan(elapsed, 15, "expected ~19s throttled, got \(elapsed)s")
    }
}
