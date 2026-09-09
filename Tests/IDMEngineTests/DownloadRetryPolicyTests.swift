import Foundation
import XCTest

@testable import IDMEngine

final class DownloadRetryPolicyTests: XCTestCase {
    func testTransientHLSFailureRetriesAndResumesCommittedSegments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlistURL = URL(string: "https://cdn.example.test/video.m3u8")!
        let firstURL = URL(string: "https://cdn.example.test/one.ts")!
        let secondURL = URL(string: "https://cdn.example.test/two.ts")!
        let client = FlakyHLSClient(
            playlistURL: playlistURL,
            firstURL: firstURL,
            secondURL: secondURL
        )
        let destination = directory.appendingPathComponent("video.mp4")
        let request = DownloadRequest(
            url: playlistURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 1,
            taskID: UUID()
        )
        let engine = DownloadEngine(
            hlsExecutor: HLSDownloadExecutor(client: client, groupCommitBytesThreshold: 1),
            retryPolicy: DownloadRetryPolicy(
                maxAttempts: 3,
                baseDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0
            )
        )

        let result = try await engine.download(request)

        XCTAssertTrue(result.resumed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("onetwo".utf8))
        let requests = await client.requests
        XCTAssertEqual(requests.filter { $0 == firstURL }.count, 1)
        XCTAssertEqual(requests.filter { $0 == secondURL }.count, 2)
    }

    func testPermanentAuthenticationFailureIsNotRetryable() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 4,
            baseDelayNanoseconds: 0,
            maximumDelayNanoseconds: 0
        )

        XCTAssertFalse(policy.shouldRetry(IDMError.authenticationRequired))
        XCTAssertTrue(policy.shouldRetry(IDMError.httpStatus(503)))
        XCTAssertTrue(policy.shouldRetry(URLError(.networkConnectionLost)))
    }

    func testTransientTLSHandshakeFailureIsRetryable() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 4,
            baseDelayNanoseconds: 0,
            maximumDelayNanoseconds: 0
        )
        // Unstable proxy nodes and CDN session resets surface as TLS
        // handshake failures; they carry no committed bytes and must be
        // retried instead of failing the whole task immediately.
        XCTAssertTrue(policy.shouldRetry(URLError(.secureConnectionFailed)))
    }

    func testResumeValidationInvariantFailuresAreRetryable() {
        // A checkpoint invariant failure does not prove the on-disk resume
        // state is unusable: re-entering the normal route either resumes
        // from the last flushed checkpoint or self-heals by discarding the
        // corrupt artifacts. Failing the task on the first occurrence was
        // perceived as overly aggressive (a "resume validation info corrupt" error followed by a
        // successful manual resume).
        let policy = DownloadRetryPolicy(
            maxAttempts: 4,
            baseDelayNanoseconds: 0,
            maximumDelayNanoseconds: 0
        )

        XCTAssertTrue(policy.shouldRetry(IDMError.sidecarCorrupt))
        XCTAssertTrue(policy.shouldRetry(DASHDownloadError.resumeCorrupt))
        XCTAssertFalse(policy.shouldRetry(DASHDownloadError.resumeIncompatible))
        XCTAssertFalse(policy.shouldRetry(IDMError.resourceChanged))
    }

    func testBackoffDelayAppliesFullJitterAcrossSamples() {
        // Full jitter: the delay is `capped - random(in: 0..<capped)`, so
        // repeated samples for the same attempt must not all coincide.
        // Without jitter, concurrent retries would synchronise on the same
        // backoff slot and thunder-herd the recovering server.
        let policy = DownloadRetryPolicy(
            maxAttempts: 8,
            baseDelayNanoseconds: 1_000_000_000,
            maximumDelayNanoseconds: 8_000_000_000
        )

        // attempt 4 → base * 2^2 = 4s, capped at 8s → jitter range [0, 4s).
        var samples = Set<UInt64>()
        for _ in 0..<64 {
            samples.insert(policy.delayNanoseconds(beforeAttempt: 4))
        }

        XCTAssertGreaterThan(samples.count, 1, "backoff delay should vary due to jitter")
    }

    func testBackoffDelayStaysWithinCappedBounds() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 8,
            baseDelayNanoseconds: 1_000_000_000,
            maximumDelayNanoseconds: 4_000_000_000
        )

        // attempt 4 → base * 2^2 = 4s, capped at 4s → result in (0, 4s].
        for _ in 0..<32 {
            let delay = policy.delayNanoseconds(beforeAttempt: 4)
            XCTAssertGreaterThan(delay, 0, "jittered delay must be positive")
            XCTAssertLessThanOrEqual(delay, 4_000_000_000, "delay must not exceed the cap")
        }
    }

    func testFirstAttemptHasNoDelay() {
        let policy = DownloadRetryPolicy(
            baseDelayNanoseconds: 1_000_000_000,
            maximumDelayNanoseconds: 4_000_000_000
        )

        XCTAssertEqual(policy.delayNanoseconds(beforeAttempt: 1), 0)
    }

    func testDefaultPolicyGivesFlakyConnectionsSeveralLongerChances() {
        // The product spec's default is "retries: 5"; the engine default must
        // keep at least that many attempts with a longer backoff so a flaky
        // connection is not abandoned after one or two quick failures.
        let policy = DownloadRetryPolicy()

        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.baseDelayNanoseconds, 1_000_000_000)
        XCTAssertEqual(policy.maximumDelayNanoseconds, 8_000_000_000)
        // attempt 5 → base * 2^3 = 8s, capped at 8s → jittered into (0, 8s].
        for _ in 0..<32 {
            let delay = policy.delayNanoseconds(beforeAttempt: 5)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 8_000_000_000)
        }
    }
}

private actor FlakyHLSClient: HLSResourceClient {
    let playlistURL: URL
    let firstURL: URL
    let secondURL: URL
    private(set) var requests: [URL] = []
    private var secondAttempts = 0

    init(playlistURL: URL, firstURL: URL, secondURL: URL) {
        self.playlistURL = playlistURL
        self.firstURL = firstURL
        self.secondURL = secondURL
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        requests.append(request.url)
        if request.url == secondURL {
            secondAttempts += 1
        }
        let currentSecondAttempt = secondAttempts

        if request.url == playlistURL {
            let playlist = [
                "#EXTM3U",
                "#EXT-X-TARGETDURATION:4",
                "#EXTINF:4,",
                firstURL.absoluteString,
                "#EXTINF:4,",
                secondURL.absoluteString,
                "#EXT-X-ENDLIST",
            ].joined(separator: "\n")
            return HLSFetchResponse(data: Data(playlist.utf8), finalURL: playlistURL)
        }
        if request.url == secondURL, currentSecondAttempt == 1 {
            throw URLError(.networkConnectionLost)
        }
        if request.url == firstURL {
            return HLSFetchResponse(data: Data("one".utf8), finalURL: firstURL)
        }
        return HLSFetchResponse(data: Data("two".utf8), finalURL: secondURL)
    }
}
