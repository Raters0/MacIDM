import Foundation
import XCTest

@testable import IDMEngine

final class HTTPContextTests: XCTestCase {
    func testCookieContextIsAppliedToProbeAndTransfer() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            root.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/cookie?size=65536"))
        try await waitUntilReady(
            URL(string: "http://127.0.0.1:\(port)/range?size=1")!
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHTTPContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unauthorized = DownloadRequest(
            url: url,
            destination: directory.appendingPathComponent("unauthorized.bin")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await HTTPHandler().probe(unauthorized)
        }

        let authorized = DownloadRequest(
            url: url,
            destination: directory.appendingPathComponent("authorized.bin"),
            maximumParallelRequests: 4,
            requestContext: DownloadRequestContext(cookie: "session=fixture-secret")
        )
        let result = try await DownloadEngine().download(authorized)

        XCTAssertEqual(result.byteCount, 65_536)
        XCTAssertEqual(try Data(contentsOf: result.destination).count, 65_536)
    }

    func testRangeProbe403CanStillCompleteSingleStreamTransfer() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            root.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range-403-get-200?size=65536")
        )
        try await waitUntilReady(URL(string: "http://127.0.0.1:\(port)/range?size=1")!)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHTTPFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await DownloadEngine().download(
            DownloadRequest(
                url: url,
                destination: directory.appendingPathComponent("fallback.mp4")
            )
        )

        XCTAssertEqual(result.byteCount, 65_536)
        XCTAssertEqual(try Data(contentsOf: result.destination).count, 65_536)
    }

    private func waitUntilReady(_ url: URL) async throws {
        for _ in 0..<50 {
            if let (_, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("fixture server did not start")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
