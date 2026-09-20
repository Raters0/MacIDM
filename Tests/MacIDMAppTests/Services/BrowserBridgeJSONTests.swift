import Foundation
import IDMEngine
import MacIDMBridge
import XCTest

@testable import MacIDMApp

@MainActor
final class BrowserBridgeJSONTests: XCTestCase {
    func testJSONDownloadCreateIsProbedPersistedOnceAndRedacted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMBridgeJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { request in
                ResourceInfo(
                    finalURL: request.url,
                    size: 10_485_760,
                    supportsRange: true,
                    mimeType: "application/zip",
                    suggestedFilename: "archive.zip",
                    strongETag: "\"fixture\""
                )
            }
        )
        let request = try loadFixture("download-create.json")
        let secret = Data(repeating: 9, count: 32)

        let first = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: secret
        )
        let duplicate = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: secret
        )

        XCTAssertEqual(first.status, "ok")
        XCTAssertEqual(first.type, "download.readyForTakeover")
        XCTAssertEqual(duplicate.payload?["taskId"], first.payload?["taskId"])
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.tasks.first?.status, .takeoverPending)
        XCTAssertEqual(model.tasks.first?.sourceURL, "https://example.com/archive.zip")
        let storedBytes = try Data(
            contentsOf: directory.appendingPathComponent("state/tasks.sqlite3")
        )
        XCTAssertFalse(String(decoding: storedBytes, as: UTF8.self).contains("temporary-token"))

        let taskID = try XCTUnwrap(first.payload?["taskId"]?.stringValue)
        let token = try XCTUnwrap(first.payload?["takeoverToken"]?.stringValue)
        let cancellationFailure = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "\(request.idempotencyKey):cancel-failed",
            type: "download.browserCancelFailed",
            payload: [
                "taskId": .string(taskID),
                "browserDownloadId": .number(42),
                "takeoverToken": .string(token),
                "errorCode": .string("BROWSER_CANCEL_FAILED"),
            ]
        )
        let conflict = await model.handleBrowserBridgeRequest(
            cancellationFailure,
            clientID: "chrome:test",
            secret: secret
        )
        let retryAfterConflict = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: secret
        )

        XCTAssertEqual(conflict.type, "download.conflictRecorded")
        XCTAssertEqual(model.tasks.first?.status, .takeoverConflict)
        XCTAssertEqual(retryAfterConflict.error?.code, "TAKEOVER_CONFLICT")
    }

    func testPingFixtureReturnsPong() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPingJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )
        let request = try loadFixture("ping.json")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.type, "pong")
        XCTAssertEqual(response.requestId, request.requestId)
    }

    func testAppActivateReturnsActivated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMActivateJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test:activate-1",
            type: "app.activate",
            payload: [:]
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.type, "app.activated")
        XCTAssertEqual(response.requestId, request.requestId)
    }

    /// The menu-bar quit must leave a durable "user quit on purpose" marker
    /// so the Native Messaging Host — which outlives the App — does not
    /// relaunch it on the next background extension message. This is the
    /// regression guard for the "closes then restarts itself" bug.
    func testShutdownRecordsQuitIntentForHost() async throws {
        let support = AppSupportPaths.supportDirectory()
        // Start clean regardless of prior activity in the shared test dir.
        BridgeLaunchIntent.clearQuitIntent(in: support)
        XCTAssertFalse(BridgeLaunchIntent.hasQuitIntent(in: support))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMQuitIntent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )

        model.shutdown()

        XCTAssertTrue(
            BridgeLaunchIntent.hasQuitIntent(in: support),
            "graceful shutdown must record the quit intent for the Host"
        )
        // Leave the shared test-support directory clean for other tests.
        BridgeLaunchIntent.clearQuitIntent(in: support)
    }

    func testTimedOutTakeoverCompensationRemovesPendingTaskIdempotently() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAbandonJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { request in
                ResourceInfo(
                    finalURL: request.url,
                    size: 10_485_760,
                    supportsRange: true,
                    suggestedFilename: "archive.zip",
                    strongETag: "\"fixture\""
                )
            }
        )
        let create = try loadFixture("download-create.json")
        let secret = Data(repeating: 6, count: 32)
        let ready = await model.handleBrowserBridgeRequest(
            create,
            clientID: "chrome:test",
            secret: secret
        )
        XCTAssertEqual(ready.type, "download.readyForTakeover")
        XCTAssertEqual(model.tasks.count, 1)

        let abandon = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "\(create.idempotencyKey):abandon",
            type: "download.abandon",
            payload: [
                "browserDownloadId": .number(42),
                "originalIdempotencyKey": .string(create.idempotencyKey),
            ]
        )
        let first = await model.handleBrowserBridgeRequest(
            abandon,
            clientID: "chrome:test",
            secret: secret
        )
        XCTAssertEqual(first.type, "download.abandoned")
        XCTAssertTrue(model.tasks.isEmpty)

        let second = await model.handleBrowserBridgeRequest(
            abandon,
            clientID: "chrome:test",
            secret: secret
        )
        XCTAssertEqual(second.type, "download.abandoned")
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testAbandonBeforeCreatePersistsBarrierAndRejectsLateCreate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMLateCreateJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let stateDirectory = directory.appendingPathComponent("state")
        let create = try loadFixture("download-create.json")
        let secret = Data(repeating: 8, count: 32)
        let model = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("a late create must be rejected before probing")
                throw IDMError.authenticationRequired
            }
        )
        let abandon = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "\(create.idempotencyKey):abandon-before-create",
            type: "download.abandon",
            payload: [
                "browserDownloadId": .number(42),
                "originalIdempotencyKey": .string(create.idempotencyKey),
            ]
        )

        let abandoned = await model.handleBrowserBridgeRequest(
            abandon,
            clientID: "chrome:test",
            secret: secret
        )
        XCTAssertEqual(abandoned.type, "download.abandoned")
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateDirectory.appendingPathComponent("abandoned-browser-takeovers.json").path
            )
        )

        // Recreate the App to prove the compensation barrier is durable, not
        // merely an in-memory guard in the process that sent abandon.
        let restarted = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("a persisted late create must be rejected before probing")
                throw IDMError.authenticationRequired
            }
        )
        let late = await restarted.handleBrowserBridgeRequest(
            create,
            clientID: "chrome:test",
            secret: secret
        )

        XCTAssertEqual(late.status, "error")
        XCTAssertEqual(late.error?.code, "TAKEOVER_ABANDONED")
        XCTAssertTrue(restarted.tasks.isEmpty)
    }

    func testAbandonWhileProbeIsSuspendedRejectsLateProbeCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMProbeRaceJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let gate = BrowserProbeGate()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { request in
                await gate.markStarted()
                await gate.waitForRelease()
                return ResourceInfo(
                    finalURL: request.url,
                    size: 10_485_760,
                    supportsRange: true,
                    mimeType: "application/zip",
                    suggestedFilename: "archive.zip",
                    strongETag: "\"fixture\""
                )
            }
        )
        let create = try loadFixture("download-create.json")
        let secret = Data(repeating: 7, count: 32)
        let createTask = Task { @MainActor in
            await model.handleBrowserBridgeRequest(
                create,
                clientID: "chrome:test",
                secret: secret
            )
        }
        await gate.waitUntilStarted()

        let abandon = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "\(create.idempotencyKey):abandon-during-probe",
            type: "download.abandon",
            payload: [
                "browserDownloadId": .number(42),
                "originalIdempotencyKey": .string(create.idempotencyKey),
            ]
        )
        let abandoned = await model.handleBrowserBridgeRequest(
            abandon,
            clientID: "chrome:test",
            secret: secret
        )
        XCTAssertEqual(abandoned.type, "download.abandoned")

        await gate.open()
        let late = await createTask.value
        XCTAssertEqual(late.status, "error")
        XCTAssertEqual(late.error?.code, "TAKEOVER_ABANDONED")
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testCookieContextReachesProbeButNeverTaskPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCookieJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { request in
                guard request.requestContext?.cookie == "session=top-secret",
                    request.requestContext?.referer == "https://example.com/account"
                else { throw IDMError.authenticationRequired }
                return ResourceInfo(
                    finalURL: request.url,
                    size: 10_485_760,
                    supportsRange: true,
                    suggestedFilename: "private.zip",
                    strongETag: "\"fixture\""
                )
            }
        )
        let fixture = try loadFixture("download-create.json")
        var payload = fixture.payload
        payload["requestContext"] = .object([
            "cookie": .string("session=top-secret"),
            "referer": .string("https://example.com/account"),
            "userAgent": .string("MacIDM-Test"),
        ])
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test-profile:cookie-download",
            type: "download.create",
            payload: payload
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 7, count: 32)
        )

        XCTAssertEqual(response.status, "ok")
        let persisted = try Data(
            contentsOf: directory.appendingPathComponent("state/tasks.sqlite3")
        )
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("top-secret"))
        XCTAssertFalse(persistedText.contains("MacIDM-Test"))
    }

    func testExplicitEnqueuePersistsOneQueuedTaskAcrossRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMEnqueueJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { request in
                XCTAssertEqual(request.requestContext?.cookie, "session=fixture-secret")
                return ResourceInfo(
                    finalURL: request.url,
                    size: 4_096,
                    supportsRange: true,
                    mimeType: "video/mp4",
                    suggestedFilename: "media.mp4",
                    strongETag: "\"fixture\""
                )
            }
        )
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test-profile:explicit-media-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.invalid/media.mp4?temporary-token=secret"),
                "filenameHint": .string("media.mp4"),
                "pageTitle": .string("课程标题"),
                "requestContext": .object([
                    "cookie": .string("session=fixture-secret")
                ]),
            ]
        )

        let first = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 4, count: 32)
        )
        let retry = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 4, count: 32)
        )

        XCTAssertEqual(first.type, "download.accepted")
        XCTAssertEqual(retry.payload?["taskId"], first.payload?["taskId"])
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.tasks.first?.browserSubmissionType, "download.enqueue")
        XCTAssertEqual(model.tasks.first?.browserSubmissionKey, request.idempotencyKey)
        XCTAssertEqual(model.tasks.first?.filename, "课程标题.mp4")
        let persisted = try Data(
            contentsOf: directory.appendingPathComponent("state/tasks.sqlite3")
        )
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("temporary-token"))
        XCTAssertFalse(persistedText.contains("fixture-secret"))
    }

    func testExplicitHLSEnqueueSkipsHTTPProbeAndPersistsSourceKind() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHLSJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("explicit HLS requests must not use the HTTP probe")
                throw IDMError.unsupportedScheme
            }
        )
        let request = try loadFixture("hls-enqueue.json")

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 5, count: 32)
        )

        XCTAssertEqual(response.type, "download.accepted")
        XCTAssertEqual(model.tasks.first?.sourceKind, .hls)
        XCTAssertEqual(model.tasks.first?.filename, "master.mp4")
        let persisted = try AppTaskStore(
            directory: directory.appendingPathComponent("state")
        ).load()
        XCTAssertEqual(persisted.first?.sourceKind, .hls)
        XCTAssertFalse(persisted.first?.sourceURL.contains("fixture-secret") == true)
    }

    func testYouTubeEnqueueUsesTheExtractorRouteWithoutHTTPProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        defaults.set(false, forKey: "autoStartDownloads")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("YouTube page tasks must use the extractor route instead of an HTTP probe")
                throw IDMError.unsupportedScheme
            }
        )
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test-profile:youtube-page",
            type: "download.enqueue",
            payload: [
                "url": .string("https://www.youtube.com/watch?v=fixture"),
                "filenameHint": .string("fixture.mp4"),
                "mediaKind": .string("youtube"),
                "pageTitle": .string("YouTube 课程标题"),
            ]
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 8, count: 32)
        )

        XCTAssertEqual(response.type, "download.accepted")
        XCTAssertEqual(model.tasks.first?.sourceKind, .http)
        XCTAssertEqual(model.tasks.first?.browserSubmissionType, "youtube.extractor")
        XCTAssertEqual(model.tasks.first?.filename, "YouTube 课程标题.mp4")
        XCTAssertEqual(model.tasks.first?.sourceURL, "https://www.youtube.com/watch")
    }

    func testPlaylistURLWithoutMediaKindCannotBeQueuedAsRawMP4() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPlaylistInferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(directory.path, forKey: "downloadDirectory")
        defaults.set(false, forKey: "autoStartDownloads")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("a playlist URL must not use the ordinary HTTP probe")
                throw IDMError.unsupportedScheme
            }
        )
        let original = try loadFixture("hls-enqueue.json")
        let request = MessageRequest(
            protocolVersion: original.protocolVersion,
            requestId: UUID().uuidString,
            idempotencyKey: "test-profile:playlist-inference",
            type: original.type,
            payload: original.payload.filter { $0.key != "mediaKind" }
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 7, count: 32)
        )

        XCTAssertEqual(response.type, "download.accepted")
        XCTAssertEqual(model.tasks.first?.sourceKind, .hls)
        XCTAssertEqual(model.tasks.first?.filename, "master.mp4")
        let persisted = try AppTaskStore(directory: directory.appendingPathComponent("state")).load()
        XCTAssertEqual(persisted.first?.sourceKind, .hls)
    }

    func testBilibiliPageWithoutMediaKindUsesTheDASHAdapterInInteractiveFlow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMBilibiliBridgeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let captured = BridgeDraftBox()
        // Interactive drafts open in standalone confirmation windows; the
        // presenter seam captures the draft without creating a window.
        model.newDownloadPresenter = { captured.value = $0 }

        let pageURL = "https://www.bilibili.com/video/BV16KM46aEf2/"
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:bilibili-interactive-1",
            type: "download.enqueue",
            payload: [
                "url": .string(pageURL),
                "filenameHint": .string("Bilibili 测试视频.mp4"),
                "mediaKind": .string("http"),
                "interactive": .bool(true),
                "pageTitle": .string("Bilibili 测试视频"),
            ]
        )

        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.type, "media.downloadRequested")
        XCTAssertEqual(captured.value?.sourceKind, .dash)
        XCTAssertEqual(captured.value?.url.absoluteString, pageURL)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testInvalidJSONFixtureIsRejectedBeforeAppHandling() throws {
        let data = try Data(contentsOf: fixtureURL("path-traversal.json"))
        XCTAssertThrowsError(try MessageCodec.decodeRequest(data))
    }

    private func loadFixture(_ name: String) throws -> MessageRequest {
        try MessageCodec.decodeRequest(Data(contentsOf: fixtureURL(name)))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BrowserBridge/\(name)")
    }
}

private actor BrowserProbeGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startedWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
    }

    func open() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class BridgeDraftBox: @unchecked Sendable {
    var value: DownloadDraft?
}
