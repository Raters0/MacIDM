import CryptoKit
import Foundation
import XCTest

@testable import IDMEngine

final class DASHDownloadExecutorTests: XCTestCase {
    func testSelectsHighestVideoAndAudioRepresentationsAndMerges() async throws {
        let fixture = makeFixture()
        let client = DASHScriptedClient(responses: fixture.responses)
        let merger = RecordingDASHMerger()
        let progress = DASHProgressRecorder()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let result = try await DASHDownloadExecutor(
            client: client,
            merger: merger
        ).download(
            DASHDownloadRequest(
                url: fixture.manifestURL,
                destination: destination,
                maximumParallelRequests: 2,
                taskID: fixture.taskID
            ),
            progress: { value in progress.append(value) }
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("initvv1v2audio-inita1a2".utf8))
        XCTAssertEqual(result.verification, "dash-ffmpeg-ffprobe")
        XCTAssertEqual(result.usedParallelRequests, 2)
        let requests = await client.requests
        XCTAssertTrue(requests.contains { $0.url == fixture.videoHighInitURL })
        XCTAssertTrue(requests.contains { $0.url == fixture.videoHighSegmentTwoURL })
        XCTAssertFalse(requests.contains { $0.url == fixture.videoLowInitURL })
        XCTAssertFalse(requests.contains { $0.url == fixture.videoLowSegmentOneURL })
        let mergeRequest = await merger.request
        XCTAssertEqual(mergeRequest?.videoURL?.lastPathComponent, "video.m4s")
        XCTAssertEqual(mergeRequest?.audioURL?.lastPathComponent, "audio.m4s")
        XCTAssertEqual(mergeRequest?.expectedDuration, 2)
        XCTAssertFalse(progress.values.isEmpty)
        // Non-ranged segments start with unknown total (nil), but after the
        // first batch the executor estimates totalBytes from average segment
        // size so the UI can show a meaningful progress bar.
        let lastProgress = progress.values.last
        XCTAssertNotNil(lastProgress?.totalBytes)
    }

    func testRejectsRangedResponseThatDoesNotMatchMPD() async throws {
        let manifestURL = URL(string: "https://media.example.test/ranged.mpd")!
        let mediaURL = URL(string: "https://media.example.test/media.m4s")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT1S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v" bandwidth="1">
                    <SegmentList>
                      <Initialization sourceURL="media.m4s" range="0-3"/>
                      <SegmentURL media="media.m4s" mediaRange="4-7"/>
                    </SegmentList>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let client = DASHScriptedClient(
            responses: [
                manifestURL.absoluteString: HLSFetchResponse(
                    data: Data(manifest.utf8),
                    finalURL: manifestURL
                ),
                mediaURL.absoluteString: HLSFetchResponse(
                    data: Data("bad".utf8),
                    finalURL: mediaURL,
                    statusCode: 206,
                    contentRange: ParsedContentRange(start: 0, endInclusive: 2, total: 8)
                ),
            ]
        )
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        do {
            _ = try await DASHDownloadExecutor(
                client: client,
                merger: RecordingDASHMerger()
            ).download(
                DASHDownloadRequest(url: manifestURL, destination: destination)
            )
            XCTFail("invalid Content-Range should be rejected")
        } catch let error as DASHDownloadError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRequiresMergerBeforeFetchingManifest() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let client = DASHScriptedClient(responses: [:])

        do {
            _ = try await DASHDownloadExecutor(client: client).download(
                DASHDownloadRequest(
                    url: URL(string: "https://media.example.test/video.mpd")!,
                    destination: destination
                )
            )
            XCTFail("DASH without FFmpeg merger should fail")
        } catch let error as DASHDownloadError {
            XCTAssertEqual(error, .mergerUnavailable)
        }
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPausePersistsSafeUnitProgressAndResumesOnlyRemainingUnits() async throws {
        let fixture = makeFixture()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstClient = DASHScriptedClient(responses: fixture.responses)
        let firstControl = DASHControlBox()

        do {
            _ = try await DASHDownloadExecutor(
                client: firstClient,
                merger: RecordingDASHMerger()
            ).download(
                DASHDownloadRequest(
                    url: fixture.manifestURL,
                    destination: destination,
                    maximumParallelRequests: 1,
                    taskID: fixture.taskID
                ),
                control: { firstControl.read() },
                progress: { _ in firstControl.pause() }
            )
            XCTFail("paused DASH download should not publish")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.paused.code)
        }

        let sidecar = directory.appendingPathComponent(
            ".\(fixture.taskID.uuidString).macidm.dash.resume"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let sidecarJSON = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertFalse(sidecarJSON.contains("manifest.mpd"))
        XCTAssertFalse(sidecarJSON.contains("video-high"))
        let videoTemporary =
            directory
            .appendingPathComponent(".\(fixture.taskID.uuidString).macidm.dash", isDirectory: true)
            .appendingPathComponent("video.m4s")
        let staleHandle = try FileHandle(forWritingTo: videoTemporary)
        try staleHandle.seekToEnd()
        try staleHandle.write(contentsOf: Data("stale-uncommitted-tail".utf8))
        try staleHandle.close()
        let secondClient = DASHScriptedClient(responses: fixture.responses)
        let result = try await DASHDownloadExecutor(
            client: secondClient,
            merger: RecordingDASHMerger()
        ).download(
            DASHDownloadRequest(
                url: fixture.manifestURL,
                destination: destination,
                maximumParallelRequests: 1,
                taskID: fixture.taskID
            )
        )

        XCTAssertTrue(result.resumed)
        let secondURLs = await secondClient.requests.map(\.url)
        XCTAssertFalse(secondURLs.contains(fixture.videoHighInitURL))
        XCTAssertTrue(secondURLs.contains(fixture.videoHighSegmentTwoURL))
    }

    func testCheckpointFailureAfterWriteRollsBackToDurableBoundary() async throws {
        let fixture = makeFixture()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        let fault = DASHCheckpointFaultBox()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let request = DASHDownloadRequest(
            url: fixture.manifestURL,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: fixture.taskID
        )

        var didFail = false
        do {
            _ = try await DASHDownloadExecutor(
                client: DASHScriptedClient(responses: fixture.responses),
                merger: RecordingDASHMerger(),
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

        // Directly inspect sidecar completed units and main track file size on disk after fault
        let sidecarURL = directory.appendingPathComponent(".\(fixture.taskID.uuidString).macidm.dash.resume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path), "Sidecar must exist after fault")
        let envelope = try JSONDecoder().decode(
            DASHResumeEnvelope.self,
            from: Data(contentsOf: sidecarURL)
        )
        let videoRep = envelope.record.representations.first { $0.id == "video:high" }
        XCTAssertEqual(videoRep?.units.filter { $0.byteCount != nil }.count, 1)
        let committedBytes: Int64 = videoRep?.units.compactMap { $0.byteCount }.reduce(0, +) ?? 0
        XCTAssertGreaterThan(committedBytes, 0)

        // Inspect track temporary download file size
        let tempDir = directory.appendingPathComponent(".\(fixture.taskID.uuidString).macidm.dash", isDirectory: true)
        let trackURL = tempDir.appendingPathComponent("video.m4s")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackURL.path), "Track download file must exist")
        let attr = try FileManager.default.attributesOfItem(atPath: trackURL.path)
        let fileSize = (attr[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(fileSize, committedBytes, "Physical file size must match durable committed boundary")

        let secondClient = DASHScriptedClient(responses: fixture.responses)
        let result = try await DASHDownloadExecutor(
            client: secondClient,
            merger: RecordingDASHMerger(),
            groupCommitBytesThreshold: 1
        ).download(request)

        XCTAssertTrue(result.resumed)
        let secondURLs = await secondClient.requests.map(\.url)
        XCTAssertFalse(secondURLs.contains(fixture.videoHighInitURL))
        XCTAssertTrue(secondURLs.contains(fixture.videoHighSegmentOneURL))
        XCTAssertTrue(secondURLs.contains(fixture.videoHighSegmentTwoURL))
    }

    func testDownloadsVideoAudioPairAndMergesToMP4() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let merger = RecordingDASHMerger()
        let taskID = UUID()
        let videoURL = URL(string: "https://video.example.test/100116.m4s")!
        let audioURL = URL(string: "https://audio.example.test/30280.m4s")!
        let result = try await DASHDownloadExecutor(
            client: DASHScriptedClient(responses: [:]),
            merger: merger
        ).downloadPair(
            DASHPairDownloadRequest(
                videoURL: videoURL,
                audioURL: audioURL,
                destination: destination,
                taskID: taskID
            ),
            directDownload: { request, _, progress in
                let bytes = request.url == videoURL ? Data("video-track".utf8) : Data("audio-track".utf8)
                try FileManager.default.createDirectory(
                    at: request.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: request.destination, options: .atomic)
                progress(
                    DownloadProgress(
                        receivedBytes: Int64(bytes.count),
                        totalBytes: Int64(bytes.count)
                    )
                )
                return DownloadResult(
                    destination: request.destination,
                    byteCount: Int64(bytes.count),
                    sha256: "pair",
                    usedParallelRequests: 1,
                    resumed: false,
                    verification: "range-and-size"
                )
            }
        )

        XCTAssertEqual(result.verification, "dash-pair-ffmpeg-ffprobe")
        XCTAssertEqual(try Data(contentsOf: destination), Data("video-trackaudio-track".utf8))
        let mergeRequest = await merger.request
        XCTAssertEqual(mergeRequest?.videoURL?.lastPathComponent, "video.m4s")
        XCTAssertEqual(mergeRequest?.audioURL?.lastPathComponent, "audio.m4s")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent()
                    .appendingPathComponent("." + taskID.uuidString + ".macidm.dash-pair")
                    .path
            )
        )
    }

    func testTaskCancellationWithPauseIntentPreservesDASHResumeArtifacts() async throws {
        let fixture = makeFixture()
        let manifest = try XCTUnwrap(fixture.responses[fixture.manifestURL.absoluteString])
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = DASHControlBox()
        let client = DASHCancellationClient(
            manifestURL: fixture.manifestURL,
            manifestResponse: manifest
        )
        let task = Task { () -> DownloadResult in
            try await DASHDownloadExecutor(
                client: client,
                merger: RecordingDASHMerger()
            ).download(
                DASHDownloadRequest(
                    url: fixture.manifestURL,
                    destination: destination,
                    maximumParallelRequests: 1,
                    taskID: fixture.taskID
                ),
                control: { control.read() }
            )
        }

        await client.waitUntilMediaFetchStarted()
        control.pause()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled DASH task should not publish")
        } catch {
            // The exact cancellation error is implementation-defined; the
            // durable artifact rule is what this fault injection verifies.
        }

        let resumeSidecar = directory.appendingPathComponent(
            ".\(fixture.taskID.uuidString).macidm.dash.resume"
        )
        let temporaryDirectory = directory.appendingPathComponent(
            ".\(fixture.taskID.uuidString).macidm.dash",
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeSidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    private enum PairResumeScenario { case unchanged, changedAudio, corruptedVideo, legacyCheckpoint }

    func testPairRetryReusesCompletedTrackAfterOtherTrackFails() async throws {
        try await assertPairRetry(.unchanged)
    }
    func testPairRetryInvalidatesBothTracksWhenOnlyAudioURLChanges() async throws {
        try await assertPairRetry(.changedAudio)
    }
    func testPairRetryRejectsSameSizeCorruptedCompletedVideo() async throws {
        try await assertPairRetry(.corruptedVideo)
    }
    func testLegacyPairWithoutIdentityCheckpointRestartsSafely() async throws {
        try await assertPairRetry(.legacyCheckpoint)
    }

    private func assertPairRetry(_ scenario: PairResumeScenario) async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let taskID = UUID()
        let videoURL = URL(string: "https://video.example.test/100116.m4s")!
        let audioURL = URL(string: "https://audio.example.test/30280.m4s")!
        let state = PairRetryState()
        let directDownload:
            @Sendable (
                DownloadRequest,
                @escaping @Sendable () -> DownloadControl,
                @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> DownloadResult = { request, _, progress in
                if request.url == videoURL { await state.recordVideoCall() }
                if request.url == audioURL {
                    await state.recordAudioCall()
                    if await state.claimFirstAudioFailure() {
                        throw IDMError.httpStatus(503)
                    }
                }
                let bytes =
                    request.url == videoURL
                    ? Data("video-track".utf8)
                    : Data("audio-track".utf8)
                try FileManager.default.createDirectory(
                    at: request.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: request.destination, options: .atomic)
                progress(
                    DownloadProgress(
                        receivedBytes: Int64(bytes.count),
                        totalBytes: Int64(bytes.count)
                    )
                )
                return DownloadResult(
                    destination: request.destination,
                    byteCount: Int64(bytes.count),
                    sha256: "pair",
                    usedParallelRequests: 1,
                    resumed: false,
                    verification: "range-and-size"
                )
            }
        let pairRequest = DASHPairDownloadRequest(
            videoURL: videoURL,
            audioURL: audioURL,
            destination: destination,
            taskID: taskID
        )

        do {
            _ = try await DASHDownloadExecutor(
                client: DASHScriptedClient(responses: [:]),
                merger: RecordingDASHMerger()
            ).downloadPair(pairRequest, directDownload: directDownload)
            XCTFail("the first audio attempt should fail")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.httpStatus(503).code)
        }

        let pairDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(taskID.uuidString).macidm.dash-pair")
        if scenario == .corruptedVideo {
            try Data("wrong-track".utf8).write(to: pairDirectory.appendingPathComponent("video.m4s"))
        }
        if scenario == .legacyCheckpoint {
            try FileManager.default.removeItem(at: pairDirectory.appendingPathComponent("checkpoint.json"))
        }
        let retryRequest = DASHPairDownloadRequest(
            videoURL: videoURL,
            audioURL: scenario == .changedAudio
                ? URL(string: "https://other.example.test/30280.m4s?signature=new")! : audioURL,
            destination: destination, taskID: taskID)
        let result = try await DASHDownloadExecutor(
            client: DASHScriptedClient(responses: [:]),
            merger: RecordingDASHMerger()
        ).downloadPair(retryRequest, directDownload: directDownload)

        XCTAssertEqual(result.verification, "dash-pair-ffmpeg-ffprobe")
        XCTAssertEqual(try Data(contentsOf: destination), Data("video-trackaudio-track".utf8))
        let videoCalls = await state.videoCalls
        let audioCalls = await state.audioCalls
        XCTAssertEqual(videoCalls, scenario == .unchanged ? 1 : 2)
        XCTAssertEqual(audioCalls, scenario == .changedAudio ? 1 : 2)
    }

    private func makeDestination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-dash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("output.mp4")
    }

    private func makeFixture() -> Fixture {
        let manifestURL = URL(string: "https://media.example.test/vod/manifest.mpd")!
        let videoLowInitURL = URL(string: "https://media.example.test/vod/v-low-init.m4s")!
        let videoLowSegmentOneURL = URL(string: "https://media.example.test/vod/v-low-1.m4s")!
        let videoHighInitURL = URL(string: "https://media.example.test/vod/v-high-init.m4s")!
        let videoHighSegmentOneURL = URL(string: "https://media.example.test/vod/v-high-1.m4s")!
        let videoHighSegmentTwoURL = URL(string: "https://media.example.test/vod/v-high-2.m4s")!
        let audioInitURL = URL(string: "https://media.example.test/vod/a-main-init.m4s")!
        let audioSegmentOneURL = URL(string: "https://media.example.test/vod/a-main-1.m4s")!
        let audioSegmentTwoURL = URL(string: "https://media.example.test/vod/a-main-2.m4s")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT2S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="v-$RepresentationID$-init.m4s" media="v-$RepresentationID$-$Number$.m4s"/>
                  <Representation id="low" bandwidth="100" width="640" height="360"/>
                  <Representation id="high" bandwidth="900" width="1280" height="720"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="a-$RepresentationID$-init.m4s" media="a-$RepresentationID$-$Number$.m4s"/>
                  <Representation id="main" bandwidth="200"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let responses: [String: HLSFetchResponse] = [
            manifestURL.absoluteString: HLSFetchResponse(data: Data(manifest.utf8), finalURL: manifestURL),
            videoLowInitURL.absoluteString: response(videoLowInitURL, "low-init"),
            videoLowSegmentOneURL.absoluteString: response(videoLowSegmentOneURL, "low-1"),
            videoHighInitURL.absoluteString: response(videoHighInitURL, "initv"),
            videoHighSegmentOneURL.absoluteString: response(videoHighSegmentOneURL, "v1"),
            videoHighSegmentTwoURL.absoluteString: response(videoHighSegmentTwoURL, "v2"),
            audioInitURL.absoluteString: response(audioInitURL, "audio-init"),
            audioSegmentOneURL.absoluteString: response(audioSegmentOneURL, "a1"),
            audioSegmentTwoURL.absoluteString: response(audioSegmentTwoURL, "a2"),
        ]
        return Fixture(
            manifestURL: manifestURL,
            videoLowInitURL: videoLowInitURL,
            videoLowSegmentOneURL: videoLowSegmentOneURL,
            videoHighInitURL: videoHighInitURL,
            videoHighSegmentOneURL: videoHighSegmentOneURL,
            videoHighSegmentTwoURL: videoHighSegmentTwoURL,
            responses: responses,
            taskID: UUID(uuidString: "F0D1A3E0-0A6D-4EF8-9CB6-BB2D7C0F3CE4")!
        )
    }

    private func response(_ url: URL, _ value: String) -> HLSFetchResponse {
        return HLSFetchResponse(data: Data(value.utf8), finalURL: url)
    }
}

private struct Fixture: Sendable {
    let manifestURL: URL
    let videoLowInitURL: URL
    let videoLowSegmentOneURL: URL
    let videoHighInitURL: URL
    let videoHighSegmentOneURL: URL
    let videoHighSegmentTwoURL: URL
    let responses: [String: HLSFetchResponse]
    let taskID: UUID
}

private actor DASHScriptedClient: HLSResourceClient {
    let responses: [String: HLSFetchResponse]
    private(set) var requests: [HLSFetchRequest] = []

    init(responses: [String: HLSFetchResponse]) {
        self.responses = responses
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        requests.append(request)
        guard let response = responses[request.url.absoluteString] else {
            throw IDMError.httpStatus(404)
        }
        return response
    }
}

private actor DASHCancellationClient: HLSResourceClient {
    private let manifestURL: URL
    private let manifestResponse: HLSFetchResponse
    private var mediaFetchStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(manifestURL: URL, manifestResponse: HLSFetchResponse) {
        self.manifestURL = manifestURL
        self.manifestResponse = manifestResponse
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        if request.url == manifestURL { return manifestResponse }
        mediaFetchStarted = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return HLSFetchResponse(data: Data("segment".utf8), finalURL: request.url)
    }

    func waitUntilMediaFetchStarted() async {
        if mediaFetchStarted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}

private final class DASHProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DownloadProgress] = []

    func append(_ value: DownloadProgress) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor RecordingDASHMerger: FFmpegMerging {
    private(set) var request: FFmpegMergeRequest?

    func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
        self.request = request
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
            sha256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined(),
            probe: FFmpegProbeResult(
                formatName: "mp4",
                duration: request.expectedDuration,
                streams: [
                    FFmpegStreamInfo(
                        index: 0,
                        codecName: "h264",
                        codecType: "video",
                        width: 1280,
                        height: 720,
                        duration: request.expectedDuration
                    ),
                    FFmpegStreamInfo(
                        index: 1,
                        codecName: "aac",
                        codecType: "audio",
                        width: nil,
                        height: nil,
                        duration: request.expectedDuration
                    ),
                ]
            )
        )
    }
}

private actor PairRetryState {
    private(set) var videoCalls = 0
    private(set) var audioCalls = 0
    private var shouldFailAudio = true

    func recordVideoCall() {
        videoCalls += 1
    }

    func recordAudioCall() {
        audioCalls += 1
    }

    func claimFirstAudioFailure() -> Bool {
        guard shouldFailAudio else { return false }
        shouldFailAudio = false
        return true
    }
}

private final class DASHCheckpointFaultBox: @unchecked Sendable {
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

private final class DASHControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    func read() -> DownloadControl {
        lock.lock()
        defer { lock.unlock() }
        return paused ? .pause : .continue
    }

    func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }
}
