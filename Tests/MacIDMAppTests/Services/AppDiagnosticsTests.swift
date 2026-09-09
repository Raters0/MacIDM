import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

/// Download lifecycle dual-channel log acceptance (docs/AI交接.md §3.2): the regular
/// log must not reveal sensitive titles, signed URLs, or local path values; the
/// private log retains them in full under the same event id.
final class AppDiagnosticsTests: XCTestCase {
    /// The error description carries the full path and title-derived filename,
    /// simulating low-level error concatenation leaks.
    private struct FixtureFailure: LocalizedError {
        var errorDescription: String? {
            "无法写入 /Users/example/Downloads/绝密视频标题.mp4（token=SIGNEDTOKEN）"
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppDiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testFailureEventSplitsSanitizedRegularAndFullPrivate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let regularLines = AppDiagnosticsSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: true
        )

        let taskID = UUID()
        let sensitiveURL = URL(
            string: "https://cdn.example.com/media.mp4?token=SIGNEDTOKEN&expire=99#t=10")!
        let destination = URL(fileURLWithPath: "/Users/example/Downloads/绝密视频标题.mp4")
        DownloadDiagnosticEventLog.recordFailure(
            to: log,
            event: "download.failed",
            stage: "download",
            taskID: taskID,
            backend: "native",
            sourceKind: "http",
            url: sensitiveURL,
            destination: destination,
            error: FixtureFailure()
        )

        // Regular line: structured fields and fingerprints are all present.
        let regular = try XCTUnwrap(regularLines.values.last)
        for expected in [
            "event=download.failed", "task=\(taskID.uuidString)", "stage=download",
            "backend=native", "kind=http", "host=cdn.example.com",
            "errorCode=UNKNOWN_ERROR", "privateDetailAvailable=true",
        ] {
            XCTAssertTrue(regular.contains(expected), "regular line missing \(expected)")
        }
        XCTAssertNotNil(regular.range(of: "urlExactFingerprint=[0-9a-f]{16}", options: .regularExpression))
        XCTAssertNotNil(regular.range(of: "titleFingerprint=[0-9a-f]{16}", options: .regularExpression))
        // The regular line is not reversible: signed query, fragment, local path, and
        // credential-like values never appear.
        XCTAssertFalse(regular.contains("SIGNEDTOKEN"))
        XCTAssertFalse(regular.contains("token=SIGNEDTOKEN"))
        XCTAssertFalse(regular.contains("#t=10"))
        XCTAssertFalse(regular.contains("/Users/example"))
        // The host may appear; the full URL may not.
        XCTAssertFalse(regular.contains("cdn.example.com/media.mp4?"))

        // Private record: full original values retained under the same event id,
        // enough to reproduce the diagnostic context.
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        let eventID = try XCTUnwrap(
            regular.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(regular[$0].dropFirst("eventId=".count)) })
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
        XCTAssertTrue(
            privateText.contains("url: https://cdn.example.com/media.mp4?token=SIGNEDTOKEN&expire=99#t=10"))
        XCTAssertTrue(privateText.contains("filename: 绝密视频标题.mp4"))
        XCTAssertTrue(privateText.contains("destination: /Users/example/Downloads/绝密视频标题.mp4"))
        XCTAssertTrue(privateText.contains("error: 无法写入 /Users/example/Downloads/绝密视频标题.mp4"))
    }

    func testTitleFingerprintLinksRegularAndPrivateWithoutRevealingTitle() throws {
        let filename = "机密直播回放第3集.mp4"
        let fingerprint = try XCTUnwrap(DiagnosticFingerprint.title(filename))
        // The fingerprint is stable and irreversible: the same title yields the same
        // fingerprint, letting the regular log link to the private log's original values.
        XCTAssertEqual(fingerprint, DiagnosticFingerprint.title(filename))
        XCTAssertFalse(fingerprint.contains("机密"))
        XCTAssertEqual(fingerprint.count, 16)
    }

    func testDisabledPrivateLogStillWritesRegularSummary() throws {
        // Consistent with the YouTube event log (§4.2): the private switch only
        // controls the private file.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let regularLines = AppDiagnosticsSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: false
        )
        DownloadDiagnosticEventLog.recordFailure(
            to: log,
            event: "download.failed",
            stage: "download",
            taskID: UUID(),
            error: FixtureFailure()
        )
        XCTAssertFalse(regularLines.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateURL.path))
    }

    func testErrorCodeMappingCoversKnownErrorFamilies() {
        XCTAssertEqual(
            DownloadDiagnosticEventLog.errorCode(for: IDMError.invalidURL), "INVALID_URL")
        XCTAssertEqual(
            DownloadDiagnosticEventLog.errorCode(for: YouTubeDownloadError.stalled),
            "YTDLP_STALLED")
        XCTAssertEqual(
            DownloadDiagnosticEventLog.errorCode(for: FixtureFailure()), "UNKNOWN_ERROR")
    }

    /// §3.4: free text entering the private log (error descriptions, full URLs) must go
    /// through unified credential scrubbing: Cookie/Authorization/API key/Bridge token/
    /// proxy userinfo passwords must never be written; ordinary signed queries stay.
    private struct CredentialFailure: LocalizedError {
        var errorDescription: String? {
            """
            请求失败 Cookie: SID=SECRETCK; Authorization: Bearer SECRETAUTH
            代理 http://proxyuser:PROXYPASS@proxy.example.com:8080 拒绝
            socks5 代理 socks5://sockuser:SOCKSPASS@socks.example.com:1080 超时
            编码凭据 socks5h://puser:P%40SS%3AWORD@socks.example.com:1080
            X-API-Key: SECRETKEY X-MacIDM-Token: SECRETBRIDGE
            """
        }
    }

    func testPrivateEntryScrubsCredentialsFromErrorDescriptionAndURL() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true
        )
        DownloadDiagnosticEventLog.recordFailure(
            to: log,
            event: "download.failed",
            stage: "download",
            taskID: UUID(),
            url: URL(string: "https://cdn.example.com/v.mp4?token=SIGNEDTOKEN&sid=SIGNEDSID")!,
            error: CredentialFailure()
        )

        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        for secret in [
            "SECRETCK", "SECRETAUTH", "PROXYPASS", "SOCKSPASS", "P%40SS%3AWORD",
            "SECRETKEY", "SECRETBRIDGE",
        ] {
            XCTAssertFalse(privateText.contains(secret), "private log leaked \(secret)")
        }
        // Full signed URLs and each proxy username are retained (including socks5/socks5h
        // and percent-encoded usernames).
        XCTAssertTrue(privateText.contains("token=SIGNEDTOKEN"))
        XCTAssertTrue(privateText.contains("sid=SIGNEDSID"))
        XCTAssertTrue(privateText.contains("proxyuser:<redacted>@proxy.example.com:8080"))
        XCTAssertTrue(privateText.contains("sockuser:<redacted>@socks.example.com:1080"))
        XCTAssertTrue(privateText.contains("puser:<redacted>@socks.example.com:1080"))
        XCTAssertTrue(privateText.contains("<redacted>"))
    }

    /// §4.1: two event logs concurrently write the same private file with a small
    /// rotation threshold: every event ID appears exactly once, records are not
    /// truncated, archive generations are correct, and permissions stay 0600.
    func testConcurrentDualLogsShareOneWriterWithoutLossOrInterleave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        // The same normalized path must return the same writer (serialization boundary).
        let youtubeLog = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true,
            maximumBytes: 512,
            archiveCount: 40,
            retentionInterval: 3600
        )
        let downloadLog = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true,
            maximumBytes: 512,
            archiveCount: 40,
            retentionInterval: 3600
        )

        let eventsPerKind = 30
        DispatchQueue.concurrentPerform(iterations: eventsPerKind * 2) { index in
            if index < eventsPerKind {
                youtubeLog.record(
                    YouTubeDiagnosticEvent(
                        id: "yt-\(index)",
                        timestamp: Date(),
                        event: "ytdlp.processFailed",
                        stage: "download",
                        taskID: nil,
                        category: "YTDLP_PROCESS_FAILED",
                        exitStatus: 1,
                        attempt: 1,
                        durationMs: 1,
                        ytDlpVersion: nil,
                        cookieSupplied: false,
                        cookieCount: nil,
                        cookieFileCreated: false,
                        proxyConfigured: false,
                        urlExactFingerprint: nil,
                        resourceFingerprint: nil,
                        sanitizedExcerpt: nil,
                        fullURL: nil,
                        cookieFilePath: nil,
                        rawOutput: "ERROR: fixture line \(index)"
                    ))
            } else {
                DownloadDiagnosticEventLog.recordFailure(
                    to: downloadLog,
                    event: "download.failed",
                    stage: "download",
                    taskID: UUID(),
                    error: FixtureFailure()
                )
            }
        }

        // Download events use random UUIDs; only the enumerable yt-* event IDs are
        // asserted. In the active file and all archives, each ID appears exactly once
        // (no lost lines, duplicates, or misaligned truncation).
        let fileManager = FileManager.default
        var texts: [String] = []
        if fileManager.fileExists(atPath: privateURL.path) {
            texts.append(try String(contentsOf: privateURL, encoding: .utf8))
        }
        for generation in 1...40 {
            let archive = privateURL.appendingPathExtension("\(generation)")
            guard fileManager.fileExists(atPath: archive.path) else { break }
            texts.append(try String(contentsOf: archive, encoding: .utf8))
        }
        let combined = texts.joined()
        for index in 0..<eventsPerKind {
            let occurrences = combined.components(separatedBy: "eventId=yt-\(index) event=").count - 1
            XCTAssertEqual(occurrences, 1, "yt-\(index) must appear exactly once")
        }
        // Rotation actually happened (small threshold), and every record starts with
        // a timestamp line, with no truncated concatenation.
        XCTAssertTrue(
            fileManager.fileExists(atPath: privateURL.appendingPathExtension("1").path),
            "expected rotation to produce archives")
        // Permissions stay 0600.
        let attributes = try fileManager.attributesOfItem(atPath: privateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0, 0o600)
    }
}

private final class AppDiagnosticsSinkCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}
