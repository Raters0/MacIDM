import Foundation
import XCTest
import os

@testable import IDMEngine

final class AdaptiveConcurrencyRetryTests: XCTestCase {

    final class TestControlBox: @unchecked Sendable {
        private let lock = NSLock()
        private var control: DownloadControl = .continue

        func set(_ value: DownloadControl) {
            lock.withLock {
                control = value
            }
        }

        func get() -> DownloadControl {
            lock.withLock {
                control
            }
        }
    }

    // MARK: - HLS Tests

    final class RecordedHLSClient: HLSResourceClient, @unchecked Sendable {
        struct CallRecord: Sendable {
            let segmentURL: URL
            let startedAt: Date
            let finishedAt: Date
        }

        private let lock = NSLock()
        private var _activeInFlight = 0
        private var _peakInFlight = 0
        private var _callCount = 0
        private var _calls: [CallRecord] = []
        private let timeoutOnConcurrency: Set<Int>
        private let alwaysTimeout: Bool
        private var _failSegmentsOnce: Set<String>

        init(
            alwaysTimeout: Bool = false,
            timeoutOnConcurrency: Set<Int> = [],
            failSegmentsOnce: Set<String> = []
        ) {
            self.alwaysTimeout = alwaysTimeout
            self.timeoutOnConcurrency = timeoutOnConcurrency
            self._failSegmentsOnce = failSegmentsOnce
        }

        var callCount: Int {
            lock.withLock { _callCount }
        }

        var peakInFlight: Int {
            lock.withLock { _peakInFlight }
        }

        var calls: [CallRecord] {
            lock.withLock { _calls }
        }

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            if request.url.pathExtension == "m3u8" {
                let lines = [
                    "#EXTM3U",
                    "#EXT-X-TARGETDURATION:4",
                    "#EXTINF:4.0,",
                    "seg0.ts",
                    "#EXTINF:4.0,",
                    "seg1.ts",
                    "#EXTINF:4.0,",
                    "seg2.ts",
                    "#EXTINF:4.0,",
                    "seg3.ts",
                    "#EXT-X-ENDLIST",
                ]
                return HLSFetchResponse(data: Data(lines.joined(separator: "\n").utf8), finalURL: request.url)
            }

            let started = Date()
            let currentActive = lock.withLock { () -> Int in
                _callCount += 1
                _activeInFlight += 1
                if _activeInFlight > _peakInFlight {
                    _peakInFlight = _activeInFlight
                }
                return _activeInFlight
            }

            defer {
                let finished = Date()
                lock.withLock {
                    _activeInFlight -= 1
                    _calls.append(CallRecord(segmentURL: request.url, startedAt: started, finishedAt: finished))
                }
            }

            // Simulate slight network delay
            try? await Task.sleep(nanoseconds: 20_000_000)

            let segName = request.url.lastPathComponent
            let shouldFailOnce = lock.withLock { () -> Bool in
                if _failSegmentsOnce.contains(segName) {
                    _failSegmentsOnce.remove(segName)
                    return true
                }
                return false
            }

            if alwaysTimeout || timeoutOnConcurrency.contains(currentActive) || shouldFailOnce {
                throw IDMError.timedOut
            }

            let content = "data-for-\(segName)"
            return HLSFetchResponse(data: Data(content.utf8), finalURL: request.url)
        }
    }

    func testHLSTimeoutRetryReducesBatchSizeBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RecordedHLSClient(alwaysTimeout: true)
        let executor = HLSDownloadExecutor(client: client)
        let request = DownloadRequest(
            url: URL(string: "https://example.com/stream.m3u8")!,
            destination: directory.appendingPathComponent("output.ts"),
            sourceKind: .hls,
            maximumParallelRequests: 4
        )

        do {
            _ = try await executor.download(request)
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertTrue(error is IDMError)
            if let idmError = error as? IDMError {
                XCTAssertEqual(idmError, IDMError.timedOut)
            }
        }

        // 4 items with concurrency 4 -> 4 items fail
        // drops to 2 -> 2 items fail
        // drops to 1 -> 1 item fails -> exits loop
        // Total = 4 + 2 + 1 = 7
        XCTAssertEqual(client.callCount, 7, "Each retry must apply the reduced concurrency: 4+2+1=7")
        XCTAssertEqual(client.peakInFlight, 4, "Peak in-flight concurrency should be 4")
    }

    func testHLSTimeoutRecoverySucceedsInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Time out when concurrency is 3 or 4; succeed when concurrency drops to 2 or 1
        let client = RecordedHLSClient(alwaysTimeout: false, timeoutOnConcurrency: [3, 4])
        let executor = HLSDownloadExecutor(client: client)
        let destination = directory.appendingPathComponent("output.ts")
        let request = DownloadRequest(
            url: URL(string: "https://example.com/stream.m3u8")!,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 4
        )

        let result = try await executor.download(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.destination, destination)

        let fileData = try Data(contentsOf: destination)
        let fileString = String(decoding: fileData, as: UTF8.self)
        XCTAssertEqual(fileString, "data-for-seg0.tsdata-for-seg1.tsdata-for-seg2.tsdata-for-seg3.ts")

        // First attempt had 4 requests (which timed out), then concurrency reduced to 2.
        // Batch 1 (seg0, seg1) succeeds with 2 requests.
        // Batch 2 (seg2, seg3) succeeds with 2 requests.
        // Total = 4 + 2 + 2 = 8
        XCTAssertEqual(client.callCount, 8)
        XCTAssertEqual(client.peakInFlight, 4)
    }

    func testHLSPauseOrCancelTerminatesRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RecordedHLSClient(alwaysTimeout: true)
        let executor = HLSDownloadExecutor(client: client)
        let request = DownloadRequest(
            url: URL(string: "https://example.com/stream.m3u8")!,
            destination: directory.appendingPathComponent("output.ts"),
            sourceKind: .hls,
            maximumParallelRequests: 4
        )

        let box = TestControlBox()

        Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            box.set(.cancel)
        }

        do {
            _ = try await executor.download(request, control: { box.get() })
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is IDMError)
            XCTAssertEqual(error as? IDMError, IDMError.cancelled)
        }

        // Did not perform all 7 retries because cancellation terminated it
        XCTAssertLessThanOrEqual(client.callCount, 4)
    }

    func testHLSPartialBatchSuccessThenTimeoutRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // seg2.ts fails on the first attempt, then recovers
        let client = RecordedHLSClient(alwaysTimeout: false, timeoutOnConcurrency: [], failSegmentsOnce: ["seg2.ts"])
        let executor = HLSDownloadExecutor(client: client)
        let destination = directory.appendingPathComponent("output.ts")
        let request = DownloadRequest(
            url: URL(string: "https://example.com/stream.m3u8")!,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 4
        )

        let result = try await executor.download(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.destination, destination)

        let fileData = try Data(contentsOf: destination)
        let fileString = String(decoding: fileData, as: UTF8.self)
        // Check exact in-order concatenation without duplicate segments or missing parts
        XCTAssertEqual(fileString, "data-for-seg0.tsdata-for-seg1.tsdata-for-seg2.tsdata-for-seg3.ts")
    }

    // MARK: - DASH Tests

    final class RecordedDASHClient: HLSResourceClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        private var _peakInFlight = 0
        private var _activeInFlight = 0
        private let alwaysTimeout: Bool
        private let timeoutOnConcurrency: Set<Int>
        private var _failSegmentsOnce: Set<String>

        init(
            alwaysTimeout: Bool = false,
            timeoutOnConcurrency: Set<Int> = [],
            failSegmentsOnce: Set<String> = []
        ) {
            self.alwaysTimeout = alwaysTimeout
            self.timeoutOnConcurrency = timeoutOnConcurrency
            self._failSegmentsOnce = failSegmentsOnce
        }

        var callCount: Int {
            lock.withLock { _callCount }
        }

        var peakInFlight: Int {
            lock.withLock { _peakInFlight }
        }

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            if request.url.pathExtension == "mpd" {
                let manifest = """
                    <MPD type="static" mediaPresentationDuration="PT4S">
                      <Period>
                        <AdaptationSet contentType="video" mimeType="video/mp4">
                          <Representation id="v1" bandwidth="1000">
                            <SegmentTemplate timescale="1" duration="1" media="seg$Number$.m4s" startNumber="0"/>
                          </Representation>
                        </AdaptationSet>
                      </Period>
                    </MPD>
                    """
                return HLSFetchResponse(data: Data(manifest.utf8), finalURL: request.url)
            }

            let currentActive = lock.withLock { () -> Int in
                _callCount += 1
                _activeInFlight += 1
                if _activeInFlight > _peakInFlight {
                    _peakInFlight = _activeInFlight
                }
                return _activeInFlight
            }

            defer {
                lock.withLock {
                    _activeInFlight -= 1
                }
            }

            try? await Task.sleep(nanoseconds: 20_000_000)

            let segName = request.url.lastPathComponent
            let shouldFailOnce = lock.withLock { () -> Bool in
                if _failSegmentsOnce.contains(segName) {
                    _failSegmentsOnce.remove(segName)
                    return true
                }
                return false
            }

            if alwaysTimeout || timeoutOnConcurrency.contains(currentActive) || shouldFailOnce {
                throw IDMError.timedOut
            }

            return HLSFetchResponse(data: Data("dash-\(segName)".utf8), finalURL: request.url)
        }
    }

    final class MockDASHMerger: FFmpegMerging, @unchecked Sendable {
        func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
            var output = Data()
            if let videoURL = request.videoURL {
                output.append(try Data(contentsOf: videoURL))
            }
            if let audioURL = request.audioURL {
                output.append(try Data(contentsOf: audioURL))
            }
            try output.write(to: request.outputURL, options: .atomic)
            return FFmpegRemuxResult(
                destination: request.outputURL,
                byteCount: Int64(output.count),
                sha256: nil,
                probe: FFmpegProbeResult(
                    formatName: "mp4",
                    duration: request.expectedDuration,
                    streams: []
                )
            )
        }
    }

    func testDASHTimeoutRetryReducesBatchSizeBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RecordedDASHClient(alwaysTimeout: true)
        let executor = DASHDownloadExecutor(client: client, merger: MockDASHMerger())
        let request = DASHDownloadRequest(
            url: URL(string: "https://example.com/manifest.mpd")!,
            destination: directory.appendingPathComponent("output.mp4"),
            maximumParallelRequests: 4
        )

        do {
            _ = try await executor.download(request)
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertTrue(error is IDMError)
            XCTAssertEqual(error as? IDMError, IDMError.timedOut)
        }

        // 4 segments with concurrency 4 -> 4 fail
        // concurrency drops to 2 -> 2 fail
        // concurrency drops to 1 -> 1 fails -> exits
        // Total = 4 + 2 + 1 = 7
        XCTAssertEqual(client.callCount, 7, "DASH timeout retry must reduce batch size: 4+2+1=7")
        XCTAssertEqual(client.peakInFlight, 4)
    }

    func testDASHTimeoutRecoverySucceedsInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RecordedDASHClient(alwaysTimeout: false, timeoutOnConcurrency: [3, 4])
        let executor = DASHDownloadExecutor(client: client, merger: MockDASHMerger())
        let destination = directory.appendingPathComponent("output.mp4")
        let request = DASHDownloadRequest(
            url: URL(string: "https://example.com/manifest.mpd")!,
            destination: destination,
            maximumParallelRequests: 4
        )

        let result = try await executor.download(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.destination, destination)

        let fileData = try Data(contentsOf: destination)
        let fileString = String(decoding: fileData, as: UTF8.self)
        XCTAssertEqual(fileString, "dash-seg0.m4sdash-seg1.m4sdash-seg2.m4sdash-seg3.m4s")

        // First attempt had 4 requests (which timed out), then concurrency reduced to 2.
        // Batch 1 (seg0, seg1) succeeds with 2 requests.
        // Batch 2 (seg2, seg3) succeeds with 2 requests.
        // Total = 4 + 2 + 2 = 8
        XCTAssertEqual(client.callCount, 8)
        XCTAssertEqual(client.peakInFlight, 4)
    }

    func testDASHPauseOrCancelTerminatesRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = RecordedDASHClient(alwaysTimeout: true)
        let executor = DASHDownloadExecutor(client: client, merger: MockDASHMerger())
        let request = DASHDownloadRequest(
            url: URL(string: "https://example.com/manifest.mpd")!,
            destination: directory.appendingPathComponent("output.mp4"),
            maximumParallelRequests: 4
        )

        let box = TestControlBox()
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            box.set(.cancel)
        }

        do {
            _ = try await executor.download(request, control: { box.get() })
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is IDMError)
            XCTAssertEqual(error as? IDMError, IDMError.cancelled)
        }

        XCTAssertLessThanOrEqual(client.callCount, 4)
    }

    func testDASHPartialBatchSuccessThenTimeoutRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // seg2.m4s fails on first attempt, then recovers
        let client = RecordedDASHClient(alwaysTimeout: false, timeoutOnConcurrency: [], failSegmentsOnce: ["seg2.m4s"])
        let executor = DASHDownloadExecutor(client: client, merger: MockDASHMerger())
        let destination = directory.appendingPathComponent("output.mp4")
        let request = DASHDownloadRequest(
            url: URL(string: "https://example.com/manifest.mpd")!,
            destination: destination,
            maximumParallelRequests: 4
        )

        let result = try await executor.download(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.destination, destination)

        let fileData = try Data(contentsOf: destination)
        let fileString = String(decoding: fileData, as: UTF8.self)
        XCTAssertEqual(fileString, "dash-seg0.m4sdash-seg1.m4sdash-seg2.m4sdash-seg3.m4s")
    }
}
