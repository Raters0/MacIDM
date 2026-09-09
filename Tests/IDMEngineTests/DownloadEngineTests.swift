import Foundation
import XCTest

@testable import IDMEngine

final class DownloadEngineTests: XCTestCase {
    private var serverProcess: Process?
    private var port = 0

    override func setUp() async throws {
        try await super.setUp()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        port = Int.random(in: 40_000...50_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            root.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
        try await waitUntilReady(URL(string: "http://127.0.0.1:" + String(port) + "/range?size=1")!)
    }

    override func tearDown() {
        if let serverProcess, serverProcess.isRunning {
            serverProcess.terminate()
            serverProcess.waitUntilExit()
        }
        serverProcess = nil
        super.tearDown()
    }

    func testDifferentQueryRedirectNeverPublishesMixedResources() async throws {
        try await assertRejectedTransfer(path: "/identity-query?id=A")
    }

    func testValidProbeThenOversizedDialectNeverPublishesRepeatedBytes() async throws {
        try await assertRejectedTransfer(path: "/dialect-mismatch")
    }

    private func assertRejectedTransfer(path: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.bin")
        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:\(port)" + path)!,
            destination: destination, maximumParallelRequests: 2)
        do {
            _ = try await DownloadEngine(retryPolicy: DownloadRetryPolicy(maxAttempts: 1)).download(request)
            XCTFail("inconsistent range response must be rejected")
        } catch is IDMError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testChildRangeFailureNeverPublishesIncompleteFinalFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-failure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let destination = directory.appendingPathComponent("failure.bin")
        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:" + String(port) + "/range-failure?size=131072")!,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        do {
            _ = try await DownloadEngine(
                retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
            ).download(request)
            XCTFail("a failed range child must prevent publication")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.httpStatus(503).code)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    directory
                    .appendingPathComponent(".failure.bin." + taskID.uuidString + ".macidm.download")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    directory
                    .appendingPathComponent(".failure.bin." + taskID.uuidString + ".macidm")
                    .path
            )
        )
    }

    func testDialectRangeServerPausesAndResumesFromCheckpoint() async throws {
        // Against Bilibili's range dialect (200 + exact-slice Content-Range +
        // strong ETag), a user pause must commit a checkpoint and the next
        // download call must continue from it instead of starting over —
        // this is the regression behind "every resume restarts from zero".
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-dialect-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let destination = directory.appendingPathComponent("dialect.bin")
        // delay=0.02 per 16 KiB chunk keeps the transfer streaming long
        // enough that the pause lands mid-transfer deterministically, even
        // under full-suite load (a fast local server once delivered the
        // whole 1 MiB between two control checks and resumed with nothing
        // left to continue).
        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:" + String(port) + "/range-200-dialect?size=1048576&delay=0.02")!,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        let control = PauseAfterBytesControl(threshold: 4096)
        let engine = DownloadEngine(retryPolicy: DownloadRetryPolicy(maxAttempts: 1))
        do {
            _ = try await engine.download(
                request,
                control: { control.read() },
                progress: { progress in control.observe(received: progress.receivedBytes) }
            )
            XCTFail("the flipped pause must stop the first run")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.paused.code)
        }

        let result = try await engine.download(request, control: { .continue })
        XCTAssertEqual(result.byteCount, 1_048_576)
        XCTAssertTrue(result.resumed, "the second run must continue from the committed checkpoint")
        XCTAssertEqual(try Data(contentsOf: destination), Self.fixturePayload(1_048_576))
    }

    func testValidatorDriftOnSameURLHealsWithFreshStartInsteadOfNeedsRestart() async throws {
        // Regression for RCB540S5: Bilibili's upos mirrors serve the same
        // signed URL with a different strong ETag (per-node `-N` suffixes),
        // so a resumed run can probe a validator that disagrees with the
        // checkpoint's. The locator and total size still match — this is
        // untrustworthy validation, not a changed resource: the engine must
        // discard the checkpoint and restart cleanly instead of failing with
        // a needsRestart loop that re-probes a random node every retry.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-drift-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let size = 65_536
        let destination = directory.appendingPathComponent("dialect.bin")
        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:" + String(port) + "/range-200-dialect?size=\(size)")!,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        let probed = try await HTTPHandler().probe(request)
        let probedIdentity = try XCTUnwrap(probed.identity)
        let temporary = directory.appendingPathComponent(
            ".dialect.bin." + taskID.uuidString + ".macidm.download")
        let sidecarURL = directory.appendingPathComponent(
            ".dialect.bin." + taskID.uuidString + ".macidm")

        // Preallocate the sparse temp and capture the file identity the
        // engine's sidecar check will compare against.
        let fileIdentity: FileIdentity
        do {
            let sink = try RandomAccessSink(url: temporary, totalSize: Int64(size), create: true)
            fileIdentity = try sink.identity()
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: Data(Self.fixturePayload(size).prefix(4096)))
        try handle.close()

        // A checkpoint that agrees on locator + total size but carries a
        // drifted ETag — exactly what a re-probe of a `-N`-suffixed mirror
        // produces.
        try SidecarStore.write(
            SidecarPayload(
                formatVersion: 1,
                taskID: taskID,
                fileIdentity: fileIdentity,
                totalSize: Int64(size),
                resourceIdentity: ResourceIdentity(
                    effectiveURL: probedIdentity.effectiveURL,
                    totalSize: Int64(size),
                    strongETag: "\"drifted-node-etag-1\"",
                    contentEncoding: "identity"
                ),
                segments: [
                    SegmentCheckpoint(
                        index: 0, start: 0, endExclusive: Int64(size), nextUncommittedOffset: 4096)
                ],
                generation: 1,
                phase: "running"
            ),
            to: sidecarURL
        )

        let result = try await DownloadEngine(
            retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
        ).download(request)

        XCTAssertEqual(result.byteCount, Int64(size))
        XCTAssertFalse(result.resumed, "drifted validation must never resume on top of the old bytes")
        XCTAssertEqual(try Data(contentsOf: destination), Self.fixturePayload(size))
    }

    func testResourceLocatorChangeStillFailsWithResourceChanged() async throws {
        // Control for the drift heal: when the locator itself changes (a
        // different host or path), the resource genuinely differs and the
        // spec's needsRestart route must stay.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-locator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let size = 65_536
        let destination = directory.appendingPathComponent("dialect.bin")
        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:" + String(port) + "/range-200-dialect?size=\(size)")!,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        let probed = try await HTTPHandler().probe(request)
        let probedIdentity = try XCTUnwrap(probed.identity)
        let temporary = directory.appendingPathComponent(
            ".dialect.bin." + taskID.uuidString + ".macidm.download")
        let sidecarURL = directory.appendingPathComponent(
            ".dialect.bin." + taskID.uuidString + ".macidm")

        let fileIdentity: FileIdentity
        do {
            let sink = try RandomAccessSink(url: temporary, totalSize: Int64(size), create: true)
            fileIdentity = try sink.identity()
        }

        try SidecarStore.write(
            SidecarPayload(
                formatVersion: 1,
                taskID: taskID,
                fileIdentity: fileIdentity,
                totalSize: Int64(size),
                resourceIdentity: ResourceIdentity(
                    effectiveURL: resourceLocatorString(URL(string: "https://elsewhere.example.com/other/file.m4s")!),
                    totalSize: probedIdentity.totalSize,
                    strongETag: probedIdentity.strongETag,
                    contentEncoding: "identity"
                ),
                segments: [
                    SegmentCheckpoint(
                        index: 0, start: 0, endExclusive: Int64(size), nextUncommittedOffset: 4096)
                ],
                generation: 1,
                phase: "running"
            ),
            to: sidecarURL
        )

        do {
            _ = try await DownloadEngine(
                retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
            ).download(request)
            XCTFail("a changed locator must keep the needsRestart route")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.resourceChanged.code)
        }
    }

    private static func fixturePayload(_ size: Int) -> Data {
        // Mirrors Tests/Support/http-fixture-server.py's payload(): bytes
        // 0..255 repeated to the requested size.
        let pattern = Data((0..<256).map { UInt8($0) })
        var data = Data(capacity: size)
        while data.count < size {
            data.append(pattern)
        }
        return Data(data.prefix(size))
    }

    private func waitUntilReady(_ url: URL) async throws {
        for _ in 0..<60 {
            if let (_, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("fixture server did not start on port " + String(port))
    }

    func testCorruptRangedSidecarRecoversWithFreshStartInsteadOfFailing() async throws {
        // A corrupted sidecar used to fail the task with a "resume checkpoint corrupt" error and
        // demand a manual cancel + re-download. The engine must now discard
        // the untrusted artifacts and restart from scratch automatically.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-corrupt-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let destination = directory.appendingPathComponent("healed.bin")
        let base = ".healed.bin." + taskID.uuidString
        let sidecar = directory.appendingPathComponent(base + ".macidm")
        let temporary = directory.appendingPathComponent(base + ".macidm.download")
        try Data("not a sidecar envelope".utf8).write(to: sidecar)
        try Data(repeating: 0xAB, count: 4096).write(to: temporary)

        let request = DownloadRequest(
            url: URL(string: "http://127.0.0.1:" + String(port) + "/range?size=65536")!,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        let result = try await DownloadEngine(
            retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
        ).download(request)

        XCTAssertEqual(result.byteCount, 65_536)
        XCTAssertFalse(result.resumed, "a corrupt sidecar must never be resumed on top of")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCorruptHLSResumeRecordRecoversWithFreshStartInsteadOfFailing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-engine-hls-corrupt-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskID = UUID()
        let destination = directory.appendingPathComponent("video.mp4")
        let base = ".video.mp4." + taskID.uuidString
        let sidecar = directory.appendingPathComponent(base + ".macidm.hls")
        let temporary = directory.appendingPathComponent(base + ".macidm.hls.download")
        try Data("garbage resume record".utf8).write(to: sidecar)
        try Data(repeating: 0xCD, count: 1024).write(to: temporary)

        let playlistURL = URL(string: "https://cdn.example.test/video.m3u8")!
        let firstURL = URL(string: "https://cdn.example.test/one.ts")!
        let secondURL = URL(string: "https://cdn.example.test/two.ts")!
        let request = DownloadRequest(
            url: playlistURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 1,
            taskID: taskID
        )

        let engine = DownloadEngine(
            hlsExecutor: HLSDownloadExecutor(
                client: StaticPlaylistClient(
                    playlistURL: playlistURL,
                    segments: [(firstURL, "one"), (secondURL, "two")]
                )
            ),
            retryPolicy: DownloadRetryPolicy(maxAttempts: 1)
        )
        let result = try await engine.download(request)

        XCTAssertEqual(try Data(contentsOf: destination), Data("onetwo".utf8))
        XCTAssertFalse(result.resumed, "a corrupt resume record must never be resumed on top of")
    }
}

/// Thread-safe control that flips to `.pause` once the observed progress
/// crosses a byte threshold, so the first engine run stops mid-transfer and
/// commits a checkpoint.
private final class PauseAfterBytesControl: @unchecked Sendable {
    private let threshold: Int64
    private let lock = NSLock()
    private var state: DownloadControl = .continue

    init(threshold: Int64) {
        self.threshold = threshold
    }

    func observe(received: Int64) {
        guard received >= threshold else { return }
        lock.lock()
        state = .pause
        lock.unlock()
    }

    func read() -> DownloadControl {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

private struct StaticPlaylistClient: HLSResourceClient {
    let playlistURL: URL
    let segments: [(url: URL, body: String)]

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        if request.url == playlistURL {
            var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:4"]
            for segment in segments {
                lines.append("#EXTINF:4,")
                lines.append(segment.url.absoluteString)
            }
            lines.append("#EXT-X-ENDLIST")
            return HLSFetchResponse(data: Data(lines.joined(separator: "\n").utf8), finalURL: playlistURL)
        }
        for segment in segments where segment.url == request.url {
            return HLSFetchResponse(data: Data(segment.body.utf8), finalURL: segment.url)
        }
        throw URLError(.fileDoesNotExist)
    }
}
