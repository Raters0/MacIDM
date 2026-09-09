import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

final class WebPageMediaDiscovererTests: XCTestCase {
    func testCrossOriginRedirectDropsCookieButPreservesExplicitRefererAndUserAgent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let externalSourcePort = environment["MACIDM_REDIRECT_SOURCE_PORT"].flatMap(Int.init)
        let externalTargetPort = environment["MACIDM_REDIRECT_TARGET_PORT"].flatMap(Int.init)
        let sourcePort = externalSourcePort ?? Int.random(in: 20_000...25_000)
        let targetPort = externalTargetPort ?? Int.random(in: 25_001...30_000)
        let recordURL = URL(
            fileURLWithPath: environment["MACIDM_REDIRECT_RECORD"]
                ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("macidm-page-headers-" + UUID().uuidString + ".json")
                .path
        )
        let script = root.appendingPathComponent("Tests/Support/web-page-redirect-server.py")
        var ownedProcesses: [Process] = []
        if externalSourcePort == nil || externalTargetPort == nil {
            let target = try startServer(
                script: script,
                arguments: ["--port", String(targetPort), "--record", recordURL.path]
            )
            let source = try startServer(
                script: script,
                arguments: [
                    "--port", String(sourcePort),
                    "--redirect-url", "http://127.0.0.1:" + String(targetPort) + "/target",
                ]
            )
            ownedProcesses = [source, target]
        }
        defer {
            for process in ownedProcesses where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            if externalSourcePort == nil || externalTargetPort == nil {
                try? FileManager.default.removeItem(at: recordURL)
            }
        }

        try await waitUntilReady(
            URL(string: "http://127.0.0.1:" + String(sourcePort) + "/health")!
        )
        try await waitUntilReady(
            URL(string: "http://127.0.0.1:" + String(targetPort) + "/health")!
        )
        let context = DownloadRequestContext(
            cookie: "session=must-not-cross-origin",
            referer: "https://page.example/watch",
            userAgent: "MacIDM-Redirect-Test"
        )
        let discovery = try await URLSessionWebPageMediaDiscoverer().discover(
            url: URL(string: "http://127.0.0.1:" + String(sourcePort) + "/redirect")!,
            requestContext: context
        )

        XCTAssertEqual(discovery.pageURL.port, targetPort)
        XCTAssertEqual(discovery.candidates.first?.url.path, "/media.mp4")
        let headersData = try Data(contentsOf: recordURL)
        let headers = try XCTUnwrap(
            JSONSerialization.jsonObject(with: headersData) as? [String: String]
        )
        XCTAssertNil(header("Cookie", in: headers))
        XCTAssertEqual(header("Referer", in: headers), context.referer)
        XCTAssertEqual(header("User-Agent", in: headers), context.userAgent)
    }

    private func startServer(script: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
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
        throw XCTSkip("redirect fixture server did not start")
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
}
