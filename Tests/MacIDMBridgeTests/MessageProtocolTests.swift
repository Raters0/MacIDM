import Foundation
import XCTest

@testable import MacIDMBridge

final class MessageProtocolTests: XCTestCase {
    func testNativeMessagingFrameUsesLittleEndianLength() throws {
        let fileURL = shortTemporaryDirectory(prefix: "midm-framing")
            .appendingPathComponent("message.bin")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: fileURL)
        try NativeMessagingFraming.writeMessage(Data("x".utf8), to: writer)
        try writer.close()

        let encoded = try Data(contentsOf: fileURL)
        XCTAssertEqual(Array(encoded.prefix(4)), [1, 0, 0, 0])
    }

    func testValidDownloadCreateRoundTrips() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:download-42",
            type: "download.create",
            payload: [
                "browserDownloadId": .number(42),
                "url": .string("https://example.com/file.zip"),
                "filenameHint": .string("file.zip"),
                "pageTitle": .string("课程下载"),
                "totalBytes": .number(1_024),
            ]
        )

        let decoded = try MessageCodec.decodeRequest(MessageCodec.encode(request))

        XCTAssertEqual(decoded, request)
    }

    func testPathTraversalFilenameIsRejected() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:download-42",
            type: "download.create",
            payload: [
                "browserDownloadId": .number(42),
                "url": .string("https://example.com/file.zip"),
                "filenameHint": .string("../file.zip"),
            ]
        )

        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    func testFilenameHintSourceAcceptsTrustModelValues() throws {
        for source in ["browserResolved", "titleDerived", "urlPath"] {
            let request = MessageRequest(
                requestId: UUID().uuidString,
                idempotencyKey: "profile:download-42",
                type: "download.create",
                payload: [
                    "browserDownloadId": .number(42),
                    "url": .string("https://example.com/file.zip"),
                    "filenameHint": .string("file.zip"),
                    "filenameHintSource": .string(source),
                ]
            )
            let decoded = try MessageCodec.decodeRequest(MessageCodec.encode(request))
            XCTAssertEqual(decoded.payload["filenameHintSource"]?.stringValue, source)
        }
    }

    func testUnknownFilenameHintSourceIsRejected() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:download-42",
            type: "download.create",
            payload: [
                "browserDownloadId": .number(42),
                "url": .string("https://example.com/file.zip"),
                "filenameHint": .string("file.zip"),
                "filenameHintSource": .string("contentDisposition"),
            ]
        )

        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    func testValidDownloadEnqueueDoesNotRequireBrowserDownloadID() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:explicit-media-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/media.mp4"),
                "filenameHint": .string("media.mp4"),
                "requestContext": .object([
                    "cookie": .string("session=fixture-secret"),
                    "referer": .string("https://example.com/watch"),
                ]),
            ]
        )

        let decoded = try MessageCodec.decodeRequest(MessageCodec.encode(request))

        XCTAssertEqual(decoded, request)
        XCTAssertNil(decoded.payload["browserDownloadId"])
    }

    func testExplicitStreamMediaKindsAreValidated() throws {
        let valid = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:explicit-hls-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/master.m3u8"),
                "filenameHint": .string("master.m3u8"),
                "mediaKind": .string("hls"),
            ]
        )
        let invalid = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:explicit-dash-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/manifest.mpd"),
                "mediaKind": .string("dash"),
            ]
        )

        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(valid)))
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(invalid)))

        let youtube = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:explicit-youtube-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://www.youtube.com/watch?v=fixture"),
                "filenameHint": .string("fixture.mp4"),
                "mediaKind": .string("youtube"),
            ]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(youtube)))
    }

    func testDASHPairFieldsRoundTripAndRequireBothTracks() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:pair-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://cdn.example/video.m4s"),
                "mediaKind": .string("dash"),
                "pairVideoUrl": .string("https://cdn.example/video.m4s"),
                "pairAudioUrl": .string("https://cdn.example/audio.m4s"),
                "pairCid": .string("1550776785"),
                "pairNote": .string("含音视频，需 FFmpeg 合并"),
            ]
        )
        let decoded = try MessageCodec.decodeRequest(MessageCodec.encode(request))
        XCTAssertEqual(decoded, request)

        let missingAudio = MessageRequest(
            requestId: request.requestId,
            idempotencyKey: request.idempotencyKey,
            type: request.type,
            payload: request.payload.filter { $0.key != "pairAudioUrl" }
        )
        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(missingAudio)))
    }

    func testAbandonMessageIsValidatedAndRejectsUnknownFields() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:abandon-42",
            type: "download.abandon",
            payload: [
                "browserDownloadId": .number(42),
                "originalIdempotencyKey": .string("profile:download-42"),
            ]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(request)))

        var invalidPayload = request.payload
        invalidPayload["takeoverToken"] = .string("must-not-be-sent")
        let invalid = MessageRequest(
            requestId: request.requestId,
            idempotencyKey: request.idempotencyKey,
            type: request.type,
            payload: invalidPayload
        )
        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(invalid)))
    }

    func testInteractiveEnqueueFieldsAreValidated() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:interactive-media-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/video.mp4"),
                "filenameHint": .string("课程标题.mp4"),
                "interactive": .bool(true),
                "pageTitle": .string("课程标题"),
            ]
        )

        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    func testDownloadEnqueueAcceptsDurationAndEstimatedSize() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:media-with-size-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://cdn.example/video.mp4"),
                "filenameHint": .string("video.mp4"),
                "duration": .number(3600.5),
                "estimatedSize": .number(1_073_741_824),
            ]
        )

        let decoded = try MessageCodec.decodeRequest(MessageCodec.encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testHLSMediaInspectionRequestIsValidated() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:inspect-hls-1",
            type: "media.inspect",
            payload: [
                "url": .string("https://example.com/master.m3u8"),
                "mediaKind": .string("hls"),
                "referrer": .string("https://example.com/watch"),
            ]
        )

        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(request)))

        let dash = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:inspect-dash-1",
            type: "media.inspect",
            payload: [
                "url": .string("https://example.com/manifest.mpd"),
                "mediaKind": .string("dash"),
            ]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(dash)))
    }

    func testOuterRefererLimitMatchesEngineContextLimit() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:long-referer",
            type: "download.enqueue",
            payload: [
                "url": .string("https://cdn.example/media.mp4"),
                "referrer": .string("https://page.example/" + String(repeating: "r", count: 4_100)),
            ]
        )

        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    func testDownloadURLLongerThanProductLimitIsRejected() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:oversized-url",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/" + String(repeating: "a", count: 8_192))
            ]
        )

        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    func testUDSRoundTripAuthenticatesAndPreservesRequestID() throws {
        let directory = shortTemporaryDirectory(prefix: "midm-roundtrip")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let secret = Data(repeating: 7, count: 32)
        let server = UDSBridgeServer(
            socketURL: socket,
            secret: secret,
            expectedClientExecutablePaths: [CommandLine.arguments[0]]
        ) { request, clientID in
            XCTAssertEqual(clientID, "test-client")
            return .ok(requestId: request.requestId, type: "pong")
        }
        try server.start()
        defer { server.stop() }

        let client = UDSBridgeClient(
            socketURL: socket,
            clientInstanceID: "test-client"
        )
        try client.connect()
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test:ping",
            type: "ping",
            payload: [:]
        )
        let response = try client.send(request)

        XCTAssertEqual(response.requestId, request.requestId)
        XCTAssertEqual(response.type, "pong")
        XCTAssertEqual(response.status, "ok")
    }

    func testWrongUDSSecretIsRejected() throws {
        let directory = shortTemporaryDirectory(prefix: "midm-auth")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let server = UDSBridgeServer(
            socketURL: socket,
            secret: Data(repeating: 1, count: 32)
        ) { request, _ in
            .ok(requestId: request.requestId, type: "pong")
        }
        try server.start()
        defer { server.stop() }

        let client = UDSBridgeClient(
            socketURL: socket,
            secret: Data(repeating: 2, count: 32),
            clientInstanceID: "forged-client"
        )

        XCTAssertThrowsError(try client.connect())
    }

    func testUnexpectedPeerExecutableIsRejectedBeforeAuthentication() throws {
        let directory = shortTemporaryDirectory(prefix: "midm-peer")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let server = UDSBridgeServer(
            socketURL: socket,
            secret: Data(repeating: 3, count: 32),
            expectedClientExecutablePaths: ["/usr/bin/false"]
        ) { request, _ in
            .ok(requestId: request.requestId, type: "pong")
        }
        try server.start()
        defer { server.stop() }
        let client = UDSBridgeClient(
            socketURL: socket,
            clientInstanceID: "unexpected-peer"
        )

        XCTAssertThrowsError(try client.connect())
    }

    func testSecondServerOnLiveSocketFailsWithoutRemovingTheFile() throws {
        let directory = shortTemporaryDirectory(prefix: "midm-live-socket")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let secret = Data(repeating: 9, count: 32)
        let first = UDSBridgeServer(
            socketURL: socket,
            secret: secret,
            expectedClientExecutablePaths: [CommandLine.arguments[0]]
        ) { request, _ in
            .ok(requestId: request.requestId, type: "pong")
        }
        try first.start()
        defer { first.stop() }

        // A second instance (e.g. a transient .build/debug bundle launched
        // over a running Debug app — both share com.macidm.app) must not
        // delete the live socket file while probing for a stale leftover.
        let second = UDSBridgeServer(
            socketURL: socket,
            secret: secret
        ) { request, _ in
            .ok(requestId: request.requestId, type: "pong")
        }
        XCTAssertThrowsError(try second.start())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socket.path),
            "live socket file must survive a second instance's startup"
        )

        // The surviving instance still accepts new clients on the path.
        let client = UDSBridgeClient(
            socketURL: socket,
            clientInstanceID: "after-duplicate"
        )
        try client.connect()
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test:after-duplicate",
            type: "ping",
            payload: [:]
        )
        XCTAssertEqual(try client.send(request).type, "pong")
    }

    func testAppActivateValidatesAndRejectsUnknownFields() throws {
        let bare = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:activate-1",
            type: "app.activate",
            payload: [:]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(bare)))

        let withFlag = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:activate-2",
            type: "app.activate",
            payload: ["userInitiated": .bool(true)]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(withFlag)))

        let invalid = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:activate-3",
            type: "app.activate",
            payload: ["url": .string("https://example.com")]
        )
        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(invalid)))
    }

    func testUserInitiatedFlagIsAcceptedOnDownloadAndInspect() throws {
        let enqueue = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:enqueue-ui",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/media.mp4"),
                "userInitiated": .bool(true),
            ]
        )
        let decodedEnqueue = try MessageCodec.decodeRequest(MessageCodec.encode(enqueue))
        XCTAssertEqual(decodedEnqueue.payload["userInitiated"]?.boolValue, true)

        let inspect = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:inspect-ui",
            type: "media.inspect",
            payload: [
                "url": .string("https://example.com/master.m3u8"),
                "mediaKind": .string("hls"),
                "userInitiated": .bool(true),
            ]
        )
        XCTAssertNoThrow(try MessageCodec.decodeRequest(MessageCodec.encode(inspect)))
    }

    func testNonBooleanUserInitiatedIsRejected() throws {
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:enqueue-bad-ui",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/media.mp4"),
                "userInitiated": .string("yes"),
            ]
        )
        XCTAssertThrowsError(try MessageCodec.decodeRequest(MessageCodec.encode(request)))
    }

    private func shortTemporaryDirectory(prefix: String) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}
