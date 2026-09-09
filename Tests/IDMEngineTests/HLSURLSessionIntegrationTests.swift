import Foundation
import XCTest

@testable import IDMEngine

final class HLSURLSessionIntegrationTests: XCTestCase {
    func testDownloadsVODThroughExplicitEngineRoute() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("vod.ts")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await DownloadEngine().download(
            request("hls/vod.m3u8", destination: destination, baseURL: fixture.baseURL)
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("vod-one-vod-two".utf8))
        XCTAssertEqual(result.byteCount, 15)
    }

    func testDownloadsAndDecryptsAES128Segments() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("aes.ts")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await DownloadEngine().download(
            request("hls/aes.m3u8", destination: destination, baseURL: fixture.baseURL)
        )

        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("MacIDM AES testsegment two".utf8)
        )
    }

    func testDownloadsValidatedByteRanges() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("ranged.bin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await DownloadEngine().download(
            request("hls/ranged.m3u8", destination: destination, baseURL: fixture.baseURL)
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("initdata".utf8))
    }

    func testResumesAfterTruncatedSegmentResponse() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("resumed.ts")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let taskID = UUID()
        let downloadRequest = request(
            "hls/disconnect.m3u8",
            destination: destination,
            baseURL: fixture.baseURL,
            taskID: taskID,
            maximumParallelRequests: 1
        )

        let engine = DownloadEngine(
            hlsExecutor: HLSDownloadExecutor(groupCommitBytesThreshold: 1)
        )
        let result = try await engine.download(downloadRequest)

        XCTAssertTrue(result.resumed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("stable-recovered".utf8))
    }

    func testRedirectStripsCrossOriginCookieButPreservesReferer() async throws {
        let fixture = try fixture()
        let destination = fixture.directory.appendingPathComponent("context.ts")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = DownloadRequestContext(
            cookie: "session=hls-fixture",
            referer: "http://127.0.0.1/watch",
            userAgent: "MacIDM-HLS-Integration"
        )

        _ = try await DownloadEngine().download(
            request(
                "hls/context.m3u8",
                destination: destination,
                baseURL: fixture.baseURL,
                requestContext: context,
                maximumParallelRequests: 1
            )
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("same-clean".utf8))
    }

    private func fixture() throws -> (baseURL: URL, directory: URL) {
        guard let rawURL = ProcessInfo.processInfo.environment["MACIDM_HLS_FIXTURE_URL"],
            let baseURL = URL(string: rawURL)
        else {
            throw XCTSkip("MACIDM_HLS_FIXTURE_URL is not set")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-hls-urlsession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (baseURL, directory)
    }

    private func request(
        _ path: String,
        destination: URL,
        baseURL: URL,
        taskID: UUID = UUID(),
        requestContext: DownloadRequestContext? = nil,
        maximumParallelRequests: Int = 2
    ) -> DownloadRequest {
        DownloadRequest(
            url: baseURL.appendingPathComponent(path),
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: maximumParallelRequests,
            taskID: taskID,
            requestContext: requestContext
        )
    }
}
