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
            verification: "segments-and-size"
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
    private(set) var calls: [FFmpegRemuxRequest] = []

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
                streams: [
                    FFmpegStreamInfo(
                        index: 0,
                        codecName: "h264",
                        codecType: "video",
                        width: 32,
                        height: 32,
                        duration: 1
                    )
                ]
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
