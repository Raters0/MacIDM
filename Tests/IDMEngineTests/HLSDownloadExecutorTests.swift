import CryptoKit
import Foundation
import XCTest

@testable import IDMEngine

final class HLSDownloadExecutorTests: XCTestCase {
    func testDownloadsAndDecryptsVODSegmentsWithBoundedConcurrency() async throws {
        let fixture = makeFixture()
        let client = ScriptedHLSClient(responses: fixture.responses)
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let context = DownloadRequestContext(
            cookie: "session=short-lived",
            referer: "https://cdn.example.test/watch",
            userAgent: "MacIDM-Test"
        )
        let request = DownloadRequest(
            url: fixture.playlistURL,
            destination: destination,
            maximumParallelRequests: 2,
            expectedSHA256: sha256(Data("MacIDM AES testsegment two".utf8)),
            taskID: fixture.taskID,
            requestContext: context
        )

        let result = try await HLSDownloadExecutor(client: client).download(request)

        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("MacIDM AES testsegment two".utf8)
        )
        XCTAssertEqual(result.byteCount, 26)
        XCTAssertFalse(result.resumed)
        let requests = await client.requests
        let maximumActiveRequests = await client.maximumActiveRequests
        XCTAssertEqual(maximumActiveRequests, 2)
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.requestContext == context })
        XCTAssertEqual(result.sha256, sha256(Data("MacIDM AES testsegment two".utf8)))
    }

    func testPersistsOnlySafeResumeRecordAndRedownloadsUncommittedSegment() async throws {
        let fixture = makeFixture()
        let firstClient = ScriptedHLSClient(
            responses: fixture.responses,
            failingURLs: [fixture.segmentTwoURL]
        )
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = DownloadRequest(
            url: fixture.playlistURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: fixture.taskID
        )

        do {
            _ = try await HLSDownloadExecutor(client: firstClient, groupCommitBytesThreshold: 1).download(request)
            XCTFail("first attempt should fail")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.httpStatus(503).code)
        }

        let sidecar = directory.appendingPathComponent(
            ".video.mp4.\(fixture.taskID.uuidString).macidm.hls"
        )
        let sidecarJSON = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertFalse(sidecarJSON.contains("master.m3u8"))
        XCTAssertFalse(sidecarJSON.contains("one.ts"))
        XCTAssertFalse(sidecarJSON.contains("key.bin"))

        let temporary = directory.appendingPathComponent(
            ".video.mp4.\(fixture.taskID.uuidString).macidm.hls.download"
        )
        let staleHandle = try FileHandle(forWritingTo: temporary)
        try staleHandle.seekToEnd()
        try staleHandle.write(contentsOf: Data("stale-uncommitted-tail".utf8))
        try staleHandle.close()

        let secondClient = ScriptedHLSClient(responses: fixture.responses)
        let result = try await HLSDownloadExecutor(client: secondClient, groupCommitBytesThreshold: 1).download(request)
        XCTAssertTrue(result.resumed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("MacIDM AES testsegment two".utf8))
        let secondRequests = await secondClient.requests
        let secondURLs = secondRequests.map(\.url)
        XCTAssertFalse(secondURLs.contains(fixture.segmentOneURL))
        XCTAssertTrue(secondURLs.contains(fixture.segmentTwoURL))
    }

    func testCheckpointFailureAfterWriteRollsBackToDurableBoundary() async throws {
        let fixture = makeFixture()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        let fault = HLSCheckpointFaultBox()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let request = DownloadRequest(
            url: fixture.playlistURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: fixture.taskID
        )

        var didFail = false
        do {
            _ = try await HLSDownloadExecutor(
                client: ScriptedHLSClient(responses: fixture.responses),
                groupCommitBytesThreshold: 1
            ).download(
                request,
                progress: { progress in
                    guard progress.receivedBytes > 0, fault.claim() else { return }
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o500],
                        ofItemAtPath: directory.path
                    )
                }
            )
        } catch {
            didFail = true
        }
        XCTAssertTrue(didFail)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let secondClient = ScriptedHLSClient(responses: fixture.responses)
        let result = try await HLSDownloadExecutor(client: secondClient, groupCommitBytesThreshold: 1).download(request)
        XCTAssertTrue(result.resumed)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("MacIDM AES testsegment two".utf8)
        )
        let secondURLs = await secondClient.requests.map(\.url)
        XCTAssertFalse(secondURLs.contains(fixture.segmentOneURL))
        XCTAssertTrue(secondURLs.contains(fixture.segmentTwoURL))
    }

    func testPauseLeavesResumeArtifactsForLaterContinuation() async throws {
        let fixture = makeFixture()
        let client = ScriptedHLSClient(responses: fixture.responses)
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = DownloadRequest(
            url: fixture.playlistURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: fixture.taskID
        )
        let control = ControlBox()

        do {
            _ = try await HLSDownloadExecutor(client: client).download(
                request,
                control: { control.isPaused },
                progress: { _ in control.pause() }
            )
            XCTFail("paused download should not publish")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.paused.code)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    directory
                    .appendingPathComponent(".video.mp4.\(fixture.taskID.uuidString).macidm.hls")
                    .path
            ))
    }

    private func makeDestination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("video.mp4")
    }

    private func makeFixture() -> Fixture {
        let playlistURL = URL(string: "https://cdn.example.test/master.m3u8")!
        let segmentOneURL = URL(string: "https://cdn.example.test/one.ts")!
        let segmentTwoURL = URL(string: "https://cdn.example.test/two.ts")!
        let keyURL = URL(string: "https://cdn.example.test/key.bin")!
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let segmentOne = Data(hex: "dd39ef9513e08751d92de70c7e1da645")
        let segmentTwo = Data(hex: "336ef86e0be8c536f41c6171883557f9")
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0000000000000000000000000000002a
            #EXTINF:4,
            one.ts
            #EXTINF:4,
            two.ts
            #EXT-X-ENDLIST
            """
        let responses = [
            playlistURL.absoluteString: HLSFetchResponse(
                data: Data(playlist.utf8),
                finalURL: playlistURL
            ),
            keyURL.absoluteString: HLSFetchResponse(data: key, finalURL: keyURL),
            segmentOneURL.absoluteString: HLSFetchResponse(data: segmentOne, finalURL: segmentOneURL),
            segmentTwoURL.absoluteString: HLSFetchResponse(data: segmentTwo, finalURL: segmentTwoURL),
        ]
        return Fixture(
            playlistURL: playlistURL,
            segmentOneURL: segmentOneURL,
            segmentTwoURL: segmentTwoURL,
            responses: responses,
            taskID: UUID(uuidString: "AB4B4230-C0DF-4A62-A47C-FE4A8DD97E6A")!
        )
    }

    func testValidatesAndDownloadsHLSByteRanges() async throws {
        let playlistURL = URL(string: "https://cdn.example.test/ranged.m3u8")!
        let mediaURL = URL(string: "https://cdn.example.test/media.mp4")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="media.mp4",BYTERANGE="4@0"
            #EXTINF:4,
            #EXT-X-BYTERANGE:4@4
            media.mp4
            #EXT-X-ENDLIST
            """
        let client = RangedHLSClient(
            playlistURL: playlistURL,
            mediaURL: mediaURL,
            playlist: Data(playlist.utf8)
        )
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = DownloadRequest(
            url: playlistURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        _ = try await HLSDownloadExecutor(client: client).download(request)

        XCTAssertEqual(try Data(contentsOf: destination), Data("initdata".utf8))
    }

    func testSelectsHighestBandwidthMasterVariant() async throws {
        let masterURL = URL(string: "https://cdn.example.test/master.m3u8")!
        let lowURL = URL(string: "https://cdn.example.test/low.m3u8")!
        let highURL = URL(string: "https://cdn.example.test/high.m3u8")!
        let lowSegmentURL = URL(string: "https://cdn.example.test/low.ts")!
        let highSegmentURL = URL(string: "https://cdn.example.test/high.ts")!
        let master = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=100
            low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=200
            high.m3u8
            """
        let media = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:4,
            high.ts
            #EXT-X-ENDLIST
            """
        let client = ScriptedHLSClient(
            responses: [
                masterURL.absoluteString: HLSFetchResponse(data: Data(master.utf8), finalURL: masterURL),
                lowURL.absoluteString: HLSFetchResponse(data: Data("#EXTM3U\n".utf8), finalURL: lowURL),
                highURL.absoluteString: HLSFetchResponse(data: Data(media.utf8), finalURL: highURL),
                lowSegmentURL.absoluteString: HLSFetchResponse(data: Data("low".utf8), finalURL: lowSegmentURL),
                highSegmentURL.absoluteString: HLSFetchResponse(data: Data("high".utf8), finalURL: highSegmentURL),
            ]
        )
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        _ = try await HLSDownloadExecutor(client: client).download(request)

        XCTAssertEqual(try Data(contentsOf: destination), Data("high".utf8))
        let requestedRequests = await client.requests
        let requestedURLs = requestedRequests.map(\.url)
        XCTAssertTrue(requestedURLs.contains(highURL))
        XCTAssertFalse(requestedURLs.contains(lowURL))
    }

    func testRejectsOversizedMediaResourceBeforePublishing() async throws {
        let playlistURL = URL(string: "https://cdn.example.test/large.m3u8")!
        let segmentURL = URL(string: "https://cdn.example.test/large.ts")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:4,
            large.ts
            #EXT-X-ENDLIST
            """
        let client = ScriptedHLSClient(
            responses: [
                playlistURL.absoluteString: HLSFetchResponse(
                    data: Data(playlist.utf8),
                    finalURL: playlistURL
                ),
                segmentURL.absoluteString: HLSFetchResponse(
                    data: Data(
                        repeating: 0,
                        count: Int(DownloadResourceLimits.maximumBufferedResourceBytes) + 1
                    ),
                    finalURL: segmentURL
                ),
            ]
        )
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = DownloadRequest(
            url: playlistURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        do {
            _ = try await HLSDownloadExecutor(client: client).download(request)
            XCTFail("oversized media resource should be rejected")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.resourceTooLarge(1).code)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Fixture: Sendable {
    let playlistURL: URL
    let segmentOneURL: URL
    let segmentTwoURL: URL
    let responses: [String: HLSFetchResponse]
    let taskID: UUID
}

private actor ScriptedHLSClient: HLSResourceClient {
    let responses: [String: HLSFetchResponse]
    let failingURLs: Set<URL>
    private(set) var requests: [HLSFetchRequest] = []
    private(set) var activeRequests = 0
    private(set) var maximumActiveRequests = 0

    init(responses: [String: HLSFetchResponse], failingURLs: Set<URL> = []) {
        self.responses = responses
        self.failingURLs = failingURLs
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        requests.append(request)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        try await Task.sleep(nanoseconds: 5_000_000)
        if failingURLs.contains(request.url) {
            throw IDMError.httpStatus(503)
        }
        guard let response = responses[request.url.absoluteString] else {
            throw IDMError.httpStatus(404)
        }
        return response
    }
}

private actor RangedHLSClient: HLSResourceClient {
    let playlistURL: URL
    let mediaURL: URL
    let playlist: Data

    init(playlistURL: URL, mediaURL: URL, playlist: Data) {
        self.playlistURL = playlistURL
        self.mediaURL = mediaURL
        self.playlist = playlist
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        if request.url == playlistURL {
            return HLSFetchResponse(data: playlist, finalURL: playlistURL)
        }
        guard request.url == mediaURL, let range = request.byteRange else {
            throw IDMError.httpStatus(404)
        }
        let payload: Data
        switch range.offset {
        case 0 where range.length == 4: payload = Data("init".utf8)
        case 4 where range.length == 4: payload = Data("data".utf8)
        default: throw IDMError.invalidContentRange
        }
        return HLSFetchResponse(
            data: payload,
            finalURL: mediaURL,
            statusCode: 206,
            contentRange: ParsedContentRange(start: range.offset, endInclusive: range.offset + 3, total: 8)
        )
    }
}

private final class ControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isPaused: DownloadControl {
        lock.lock()
        defer { lock.unlock() }
        return value ? .pause : .continue
    }

    func pause() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class HLSCheckpointFaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

private extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
