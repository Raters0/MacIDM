import Foundation
import IDMEngine
import MacIDMBridge
import XCTest

@testable import MacIDMApp

@MainActor
final class HLSAppPipelineTests: XCTestCase {
    func testHLSFailsClearlyWhenFFmpegIsNotConfigured() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            useEnvironmentFFmpeg: false
        )
        let request = enqueueRequest(filename: "missing-toolchain.m3u8")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )
        let taskIDString = try XCTUnwrap(response.payload?["taskId"]?.stringValue)
        let taskID = try XCTUnwrap(UUID(uuidString: taskIDString))

        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .failed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.errorCode, "FFMPEG_UNAVAILABLE")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.settings.downloadDirectory + "/missing-toolchain.mp4"))
    }

    func testHLSDownloadsRawSegmentsThenPublishesFFmpegOutput() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remuxer = TestRemuxer()
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubHLSDownloadRunner(),
            ffmpegRemuxer: remuxer
        )
        let request = enqueueRequest(filename: "fixture.m3u8")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 2, count: 32)
        )
        let taskIDString = try XCTUnwrap(response.payload?["taskId"]?.stringValue)
        let taskID = try XCTUnwrap(UUID(uuidString: taskIDString))

        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.filename, "fixture.mp4")
        XCTAssertEqual(task.verification, "ffmpeg-ffprobe")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: task.destinationPath)),
            Data("final-mp4".utf8)
        )
        let calls = await remuxer.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].inputURL.pathExtension, "ts")
        XCTAssertEqual(calls[0].outputURL.pathExtension, "mp4")
        XCTAssertNotNil(calls[0].control)
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls[0].inputURL.path))
    }

    // A video-only source playlist (X/Twitter `/pl/avc1/*` without its audio
    // rendition) remuxes into a playable but silent MP4. The transfer
    // succeeded, so the task completes and is annotated instead of silently
    // passing as clean (technical-spec §3.3 「无音轨告警」).
    func testVideoOnlyHLSProductCompletesWithNoAudioTrackWarning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubHLSDownloadRunner(),
            ffmpegRemuxer: TestRemuxer(videoOnly: true)
        )
        let response = await model.handleBrowserBridgeRequest(
            enqueueRequest(filename: "silent.m3u8"), clientID: "chrome:test",
            secret: Data(repeating: 2, count: 32))
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(response.payload?["taskId"]?.stringValue)))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(task.errorCode)
        XCTAssertEqual(task.mediaWarning, .noAudioTrack)
    }

    func testMuxedHLSProductCompletesWithoutMediaWarning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubHLSDownloadRunner(),
            ffmpegRemuxer: TestRemuxer()
        )
        let response = await model.handleBrowserBridgeRequest(
            enqueueRequest(filename: "muxed.m3u8"), clientID: "chrome:test",
            secret: Data(repeating: 2, count: 32))
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(response.payload?["taskId"]?.stringValue)))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertNil(task.mediaWarning, "带音轨的产物不得被标注无音轨")
    }

    func testAlreadyMergedHLSIsPublishedWithoutAnotherRemux() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remuxer = TestRemuxer()
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubHLSDownloadRunner(artifactFormat: .mp4),
            ffmpegRemuxer: remuxer
        )
        let response = await model.handleBrowserBridgeRequest(
            enqueueRequest(filename: "merged.m3u8"), clientID: "chrome:test",
            secret: Data(repeating: 2, count: 32))
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(response.payload?["taskId"]?.stringValue)))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }
        let calls = await remuxer.calls
        XCTAssertTrue(calls.isEmpty)
        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.destinationPath)), Data("raw-ts".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.hlsInputURL(for: task).path))
        XCTAssertNil(task.mediaWarning, "引擎已合并的清单不重新探测，不得凭空告警")
    }

    func testHLSKeepsRawInputWhenRemuxFailsForRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubHLSDownloadRunner(),
            ffmpegRemuxer: FailingRemuxer()
        )
        let request = enqueueRequest(filename: "remux-retry.m3u8")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 7, count: 32)
        )
        let taskID = try XCTUnwrap(UUID(uuidString: response.payload?["taskId"]?.stringValue ?? ""))

        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .failed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        let rawInput = URL(fileURLWithPath: task.destinationPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".\(taskID.uuidString).macidm.hls-input.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawInput.path))
    }

    func testHLSResumesPublishedRawInputAfterAppRestart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let taskID = UUID()
        let destination = URL(fileURLWithPath: fixture.settings.downloadDirectory)
            .appendingPathComponent("recovered.mp4")
        let rawInput = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(taskID.uuidString).macidm.hls-input.ts")
        try Data("raw-ts-from-before-crash".utf8).write(to: rawInput, options: .atomic)

        let now = Date()
        let task = AppTask(
            id: taskID,
            sourceURL: "https://example.invalid/recovered.m3u8",
            destinationPath: destination.path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            sourceKind: .hls,
            browserClientID: nil,
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: "recovery",
            createdAt: now,
            updatedAt: now,
            status: .paused,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: "INTERRUPTED",
            errorMessage: "模拟 App 在分片发布后退出",
            segments: []
        )
        let storeDirectory = fixture.directory.appendingPathComponent("state")
        let store = try AppTaskStore(directory: storeDirectory)
        try store.save([task])

        let runner = CountingHLSDownloadRunner()
        let remuxer = TestRemuxer()
        let model = AppModel(
            storeDirectory: storeDirectory,
            settings: fixture.settings,
            downloadRunner: runner,
            ffmpegRemuxer: remuxer
        )
        model.resume(taskID)
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }

        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("final-mp4".utf8)
        )
    }

    // 手动粘贴分离音轨 master（X/Twitter 形状）：解析出的每个画质都必须带上
    // 自己的 EXT-X-MEDIA 音频 rendition，否则选中的画质清单单独下载就是无声
    // 文件（technical-spec §3.3）。
    func testManuallyResolvedMasterKeepsAudioRenditionPerQuality() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            mediaInspector: SeparateAudioStubInspector()
        )

        let options = try await model.resolveDownloadOptions(
            urlString: "https://video.twimg.com/amplify_video/1/pl/master.m3u8",
            sourceKind: .hls
        )

        XCTAssertEqual(options.count, 2)
        for option in options {
            XCTAssertNotNil(option.pairAudioURL, "\(option.label) 丢失了音频 rendition")
        }
        XCTAssertEqual(
            options.first?.pairAudioURL?.absoluteString,
            "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/audio.m3u8"
        )
    }

    func testDASHTaskUsesTheEngineRouteAndPublishesMergedResult() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let merger = TestMerger()
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            downloadRunner: StubDASHDownloadRunner(),
            ffmpegMerger: merger,
            useEnvironmentFFmpeg: false
        )
        let request = enqueueRequest(filename: "fixture.mpd", mediaKind: "dash")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:dash",
            secret: Data(repeating: 9, count: 32)
        )
        let taskID = try XCTUnwrap(UUID(uuidString: response.payload?["taskId"]?.stringValue ?? ""))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status == .completed }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.sourceKind, .dash)
        XCTAssertEqual(task.filename, "fixture.mp4")
        XCTAssertEqual(task.verification, "dash-ffmpeg-ffprobe")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.destinationPath)), Data("dash-output".utf8))
    }

    func testMediaInspectionReturnsHLSVariantsWithoutPersistingContext() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings,
            mediaInspector: StubMediaInspector()
        )
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:inspect-hls",
            type: "media.inspect",
            payload: [
                "url": .string("https://example.invalid/master.m3u8?token=secret"),
                "mediaKind": .string("hls"),
                "requestContext": .object(["cookie": .string("session=secret")]),
            ]
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 3, count: 32)
        )

        XCTAssertEqual(response.type, "media.inspected")
        XCTAssertEqual(response.payload?["mediaKind"]?.stringValue, "hls")
        guard case .array(let variants)? = response.payload?["variants"],
            case .object(let first)? = variants.first
        else {
            return XCTFail("expected one HLS variant")
        }
        XCTAssertEqual(first["label"]?.stringValue, "720p · 码率：1.5 Mbps")
        XCTAssertEqual(model.tasks.count, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent("state/tasks.json").path
            )
        )
    }

    func testAppHLSRouteProducesPlayableMP4FromLocalFixture() async throws {
        guard let rawFixtureURL = ProcessInfo.processInfo.environment["MACIDM_APP_HLS_FIXTURE_URL"],
            let fixtureURL = URL(string: rawFixtureURL),
            let toolchain = FFmpegToolchain.fromEnvironment()
        else {
            throw XCTSkip("App HLS FFmpeg integration environment is not configured")
        }
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings
        )
        let request = enqueueRequest(
            filename: "fixture.m3u8",
            url: fixtureURL.appendingPathComponent("master.m3u8")
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:integration",
            secret: Data(repeating: 4, count: 32)
        )
        let taskID = try XCTUnwrap(UUID(uuidString: response.payload?["taskId"]?.stringValue ?? ""))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status.isTerminal == true }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.status, .completed, task.errorMessage ?? "App HLS task failed")
        XCTAssertEqual(task.verification, "ffmpeg-ffprobe")
        let probe = try await FFmpegService(toolchain: toolchain).probe(
            URL(fileURLWithPath: task.destinationPath)
        )
        XCTAssertTrue(probe.hasVideo)
        XCTAssertTrue(probe.hasAudio)
        XCTAssertGreaterThan(probe.duration ?? 0, 0)
    }

    func testAppDASHRouteProducesPlayableMP4FromLocalFixture() async throws {
        guard let rawFixtureURL = ProcessInfo.processInfo.environment["MACIDM_APP_DASH_FIXTURE_URL"],
            let fixtureURL = URL(string: rawFixtureURL),
            let toolchain = FFmpegToolchain.fromEnvironment()
        else {
            throw XCTSkip("App DASH FFmpeg integration environment is not configured")
        }
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AppModel(
            storeDirectory: fixture.directory.appendingPathComponent("state"),
            settings: fixture.settings
        )
        let request = enqueueRequest(
            filename: "fixture.mpd",
            url: fixtureURL.appendingPathComponent("manifest.mpd"),
            mediaKind: "dash"
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:dash-integration",
            secret: Data(repeating: 6, count: 32)
        )
        let taskID = try XCTUnwrap(UUID(uuidString: response.payload?["taskId"]?.stringValue ?? ""))
        try await waitUntil { model.tasks.first(where: { $0.id == taskID })?.status.isTerminal == true }

        let task = try XCTUnwrap(model.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.status, .completed, task.errorMessage ?? "App DASH task failed")
        XCTAssertEqual(task.verification, "dash-ffmpeg-ffprobe")
        let probe = try await FFmpegService(toolchain: toolchain).probe(
            URL(fileURLWithPath: task.destinationPath)
        )
        XCTAssertTrue(probe.hasVideo)
        XCTAssertTrue(probe.hasAudio)
        XCTAssertGreaterThan(probe.duration ?? 0, 0)
    }

    private func makeFixture() throws -> (directory: URL, settings: AppSettings) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-hls-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.appendingPathComponent("Downloads").path, forKey: "downloadDirectory")
        let settings = AppSettings(defaults: defaults)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: settings.downloadDirectory),
            withIntermediateDirectories: true
        )
        return (directory, settings)
    }

    private func enqueueRequest(
        filename: String,
        url: URL? = nil,
        mediaKind: String = "hls"
    ) -> MessageRequest {
        let resolvedURL = url ?? URL(string: "https://example.invalid/\(filename)?token=secret")!
        return MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test-profile:" + filename,
            type: "download.enqueue",
            payload: [
                "url": .string(resolvedURL.absoluteString),
                "filenameHint": .string(filename),
                "mediaKind": .string(mediaKind),
            ]
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for App task state")
    }
}

private struct StubHLSDownloadRunner: AppDownloadRunning {
    var artifactFormat: DownloadArtifactFormat = .unprocessed
    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        XCTAssertEqual(request.sourceKind, .hls)
        try Data("raw-ts".utf8).write(to: request.destination, options: .atomic)
        progress(DownloadProgress(receivedBytes: 6, totalBytes: 6))
        return DownloadResult(
            destination: request.destination,
            byteCount: 6,
            sha256: "raw",
            usedParallelRequests: 1,
            resumed: false,
            verification: "segments-and-size",
            artifactFormat: artifactFormat
        )
    }
}

private struct StubDASHDownloadRunner: AppDownloadRunning {
    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        XCTAssertEqual(request.sourceKind, .dash)
        try Data("dash-output".utf8).write(to: request.destination, options: .atomic)
        progress(DownloadProgress(receivedBytes: 11, totalBytes: 11))
        return DownloadResult(
            destination: request.destination,
            byteCount: 11,
            sha256: "dash",
            usedParallelRequests: 2,
            resumed: false,
            verification: "dash-ffmpeg-ffprobe"
        )
    }
}

private struct StubMediaInspector: MediaInspecting {
    func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        XCTAssertEqual(requestContext?.cookie, "session=secret")
        XCTAssertEqual(mediaKind, .hls)
        return MediaInspection(
            mediaKind: .hls,
            variants: [
                MediaVariant(
                    url: URL(string: "https://example.invalid/720.m3u8")!,
                    label: "720p · 码率：1.5 Mbps",
                    bandwidth: 1_500_000,
                    width: 1280,
                    height: 720,
                    codecs: "avc1.64001f"
                )
            ]
        )
    }
}

private struct SeparateAudioStubInspector: MediaInspecting {
    func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        MediaInspection(
            mediaKind: .hls,
            variants: [
                MediaVariant(
                    url: URL(string: "https://video.twimg.com/amplify_video/1/pl/avc1/1080x1080/video.m3u8")!,
                    label: "1080P · AAC · 3.2 Mbps",
                    bandwidth: 3_222_206,
                    width: 1080,
                    height: 1080,
                    codecs: "mp4a.40.2,avc1.640028",
                    pairAudioURL: URL(string: "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/audio.m3u8")!
                ),
                MediaVariant(
                    url: URL(string: "https://video.twimg.com/amplify_video/1/pl/avc1/720x720/video.m3u8")!,
                    label: "720P · AAC · 981 kbps",
                    bandwidth: 981_246,
                    width: 720,
                    height: 720,
                    codecs: "mp4a.40.2,avc1.64001F",
                    pairAudioURL: URL(string: "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/audio.m3u8")!
                ),
            ]
        )
    }
}

private actor CountingHLSDownloadRunner: AppDownloadRunning {
    private(set) var calls = 0

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        calls += 1
        throw IDMError.httpStatus(599)
    }
}

private actor TestRemuxer: FFmpegRemuxing {
    private let streams: [FFmpegStreamInfo]
    private(set) var calls: [FFmpegRemuxRequest] = []

    /// `videoOnly` reproduces a single-track (video-only) HLS playlist product:
    /// remux succeeds, and the file has no audio stream.
    init(videoOnly: Bool = false) {
        var streams = [
            FFmpegStreamInfo(
                index: 0,
                codecName: "h264",
                codecType: "video",
                width: 32,
                height: 32,
                duration: 1
            )
        ]
        if !videoOnly {
            streams.append(
                FFmpegStreamInfo(
                    index: 1,
                    codecName: "aac",
                    codecType: "audio",
                    width: nil,
                    height: nil,
                    duration: 1
                )
            )
        }
        self.streams = streams
    }

    func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        calls.append(request)
        try Data("final-mp4".utf8).write(to: request.outputURL, options: .atomic)
        return FFmpegRemuxResult(
            destination: request.outputURL,
            byteCount: 9,
            sha256: "final",
            probe: FFmpegProbeResult(
                formatName: "mov,mp4",
                duration: 1,
                streams: streams
            )
        )
    }
}

private struct FailingRemuxer: FFmpegRemuxing {
    func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        throw FFmpegError.invalidOutput
    }
}

private actor TestMerger: FFmpegMerging {
    func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
        throw FFmpegError.invalidInputSet
    }
}
