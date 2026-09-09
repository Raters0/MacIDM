import XCTest

@testable import MacIDMApp

/// Dual-channel log acceptance (docs/AI交接.md §3): the regular line and the private
/// record derived from the same event share an event id; the regular line carries only
/// structured fields and a sanitized summary; the private record keeps the full
/// URL/paths/raw output without credential values.
final class YouTubeDiagnosticsTests: XCTestCase {
    /// Forged yt-dlp output covering sensitive titles, signed URLs, cookies,
    /// Authorization, local paths, temp paths, newlines, and control characters.
    /// Sensitive content sits on stable `ERROR:` lines, mirroring the shape of
    /// real yt-dlp error output.
    private let forgedOutput = """
        [youtube] Extracting URL: https://www.youtube.com/watch?v=abc123
        [youtube] abc123: Downloading 绝密视频标题不应进入常规日志
        ERROR: [youtube] abc123: 绝密视频标题不应进入常规日志
        ERROR: unable to download video data: https://rr4.example.googlevideo.com/videoplayback?id=abc&signature=SECRETSIG&expire=999
        ERROR: Authorization: Bearer SECRETTOKEN
        ERROR: Cookie: VISITOR_INFO1_LIVE=SECRETCOOKIE; SID=SECRETSID
        ERROR: saved fragment to /Users/example/Downloads/video.mp4
        ERROR: temp file at /var/folders/xy/video.f137.mp4
        injected\nfake\rline\u{1b}[31mcolored
        """

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMDiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Sanitizer

    func testSanitizedExcerptStripsSensitiveValues() throws {
        let excerpt = try XCTUnwrap(
            YouTubeOutputSanitizer.sanitizedExcerpt(from: forgedOutput))
        // Single line, with a length cap.
        XCTAssertFalse(excerpt.contains("\n"))
        XCTAssertFalse(excerpt.contains("\r"))
        XCTAssertLessThanOrEqual(excerpt.count, YouTubeOutputSanitizer.excerptLimit + 1)
        // Stable error lines are retained.
        XCTAssertTrue(excerpt.contains("ERROR"))
        // Credential values, query values, local paths, and ANSI sequences are all removed.
        XCTAssertFalse(excerpt.contains("SECRETSIG"))
        XCTAssertFalse(excerpt.contains("SECRETTOKEN"))
        XCTAssertFalse(excerpt.contains("SECRETCOOKIE"))
        XCTAssertFalse(excerpt.contains("SECRETSID"))
        XCTAssertFalse(excerpt.contains("Bearer "))
        XCTAssertFalse(excerpt.contains("/Users/"))
        XCTAssertFalse(excerpt.contains("/var/folders"))
        XCTAssertFalse(excerpt.contains("\u{1b}"))
        // Key names and presence are retained (query key, credential key=<redacted>).
        XCTAssertTrue(excerpt.contains("signature=…"))
        XCTAssertTrue(excerpt.contains("<redacted>"))
    }

    func testSanitizedExcerptFailClosedOnEmptyOutput() {
        XCTAssertNil(YouTubeOutputSanitizer.sanitizedExcerpt(from: "  \n \r "))
    }

    func testPrivateRedactionKeepsContextButNeverCredentials() throws {
        let redacted = try XCTUnwrap(
            YouTubeOutputSanitizer.redactCredentials(in: forgedOutput))
        // The private log may keep full URLs (including signed queries) and titles,
        // to reproduce the scene.
        XCTAssertTrue(redacted.contains("signature=SECRETSIG"))
        XCTAssertTrue(redacted.contains("绝密视频标题"))
        XCTAssertTrue(redacted.contains("/Users/example/Downloads/video.mp4"))
        // Credential values still must not appear.
        XCTAssertFalse(redacted.contains("SECRETTOKEN"))
        XCTAssertFalse(redacted.contains("SECRETCOOKIE"))
        XCTAssertFalse(redacted.contains("SECRETSID"))
    }

    /// docs/AI交接.md §4.1: the private log must not rewrite a full signed URL
    /// merely because a URL query key is named token/sid/session.
    func testPrivateRedactionPreservesSignedURLQueryValues() throws {
        let output = """
            ERROR: unable to download: https://cdn.example.com/media.mp4?token=SIGNEDTOKEN&expire=99
            ERROR: retry https://cdn.example.com/media.mp4?sid=SIGNEDSID&session=SIGNEDSESSION
            """
        let redacted = try XCTUnwrap(YouTubeOutputSanitizer.redactCredentials(in: output))
        XCTAssertTrue(redacted.contains("token=SIGNEDTOKEN"))
        XCTAssertTrue(redacted.contains("sid=SIGNEDSID"))
        XCTAssertTrue(redacted.contains("session=SIGNEDSESSION"))
    }

    /// Explicit credential-class fields (Authorization/proxy auth/API key/
    /// Bridge token/password) must still be scrubbed in the private log.
    func testPrivateRedactionStillScrubsExplicitCredentialHeaders() throws {
        let output = """
            ERROR: Authorization: Bearer HEADERTOKEN
            ERROR: Proxy-Authorization: Basic PROXYSECRET
            ERROR: X-API-Key: APIKEYSECRET
            ERROR: X-MacIDM-Token: BRIDGETOKENSECRET
            ERROR: password = P4SSSECRET
            """
        let redacted = try XCTUnwrap(YouTubeOutputSanitizer.redactCredentials(in: output))
        for secret in [
            "HEADERTOKEN", "PROXYSECRET", "APIKEYSECRET", "BRIDGETOKENSECRET", "P4SSSECRET",
        ] {
            XCTAssertFalse(redacted.contains(secret), "private log leaked \(secret)")
        }
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    /// §3.4: proxy account passwords in URL userinfo must not be written to disk;
    /// ordinary media URL signed queries (token/sid/session) stay intact, and
    /// usernames and hosts are kept so the proxy can be located.
    func testPrivateRedactionScrubsURLUserInfoButKeepsSignedQuery() throws {
        let output = """
            ERROR: unable to connect to proxy http://proxyuser:PROXYPASS@proxy.example.com:8080/tunnel
            ERROR: retry https://cdn.example.com/media.mp4?token=SIGNEDTOKEN&sid=SIGNEDSID&session=SIGNEDSESSION
            """
        let redacted = try XCTUnwrap(YouTubeOutputSanitizer.redactCredentials(in: output))
        XCTAssertFalse(redacted.contains("PROXYPASS"), "userinfo password leaked")
        XCTAssertTrue(redacted.contains("proxyuser:<redacted>@proxy.example.com:8080/tunnel"))
        // Signed queries are unaffected.
        XCTAssertTrue(redacted.contains("token=SIGNEDTOKEN"))
        XCTAssertTrue(redacted.contains("sid=SIGNEDSID"))
        XCTAssertTrue(redacted.contains("session=SIGNEDSESSION"))
    }

    /// Round 4 R2: regular-log URL masking must cover socks5/socks5h; proxy userinfo
    /// account passwords must not sneak into the regular summary through URL
    /// reconstruction; http/https behavior does not regress.
    func testRegularSummaryMasksSocksURLUserInfo() throws {
        let socks = try XCTUnwrap(
            YouTubeOutputSanitizer.sanitizedErrorSummary(
                "无法连接 socks5://proxyuser:SOCKSPASS@socks.example.com:1080/tunnel"))
        XCTAssertFalse(socks.contains("SOCKSPASS"))
        XCTAssertFalse(socks.contains("proxyuser"))
        XCTAssertTrue(socks.contains("socks5://socks.example.com"))

        let socksH = try XCTUnwrap(
            YouTubeOutputSanitizer.sanitizedErrorSummary(
                "代理 socks5h://u:P%40SS@relay.example.com:1080 拒绝"))
        XCTAssertFalse(socksH.contains("P%40SS"))
        XCTAssertTrue(socksH.contains("socks5h://relay.example.com"))

        // HTTP(S) does not regress: signed query values stay masked; host/path retained.
        let https = try XCTUnwrap(
            YouTubeOutputSanitizer.sanitizedErrorSummary(
                "下载失败 https://cdn.example.com/v.mp4?token=SIGVALUE&expire=9"))
        XCTAssertFalse(https.contains("SIGVALUE"))
        XCTAssertTrue(https.contains("https://cdn.example.com/v.mp4"))
    }

    /// §4.2: paths containing spaces/Chinese-English/quotes/parens must be replaced
    /// wholesale, leaving no title fragments; mixed multi-path and URL cases are
    /// covered as well.
    func testSanitizedErrorSummaryCoversPathsWithSpacesAndQuotes() throws {
        let cases: [(input: String, forbidden: [String], required: [String])] = [
            (
                "无法写入 /Users/example/Downloads/Secret Video Title.mp4",
                ["Secret", "Video", "Title", "/Users/"],
                ["<home>/…"]
            ),
            (
                "无法写入 “/Users/example/Downloads/机密 直播 回放(第3集).mp4”",
                ["机密", "回放", "/Users/"],
                ["<home>/…"]
            ),
            (
                "rename failed: /Users/a/My Clip.mp4 -> /Users/a/My Clip (1).mp4",
                ["My Clip", "/Users/"],
                ["<home>/…"]
            ),
            (
                "tmp file /var/folders/xy/T/Temp Export 2026.mp4 vanished",
                ["Temp Export", "/var/folders"],
                ["<tmp>/…"]
            ),
            (
                "failed https://cdn.example.com/v.mp4?token=SIG then /Users/example/Movies/A B.mp4",
                ["SIG", "/Users/"],
                ["token=", "<home>/…"]
            ),
        ]
        for item in cases {
            let summary = try XCTUnwrap(
                YouTubeOutputSanitizer.sanitizedErrorSummary(item.input),
                "summary missing for: \(item.input)")
            for fragment in item.forbidden {
                XCTAssertFalse(
                    summary.contains(fragment),
                    "regular summary leaked '\(fragment)' from: \(item.input) → \(summary)")
            }
            for fragment in item.required {
                XCTAssertTrue(
                    summary.contains(fragment),
                    "regular summary missing '\(fragment)' from: \(item.input) → \(summary)")
            }
        }
    }

    // MARK: - Fingerprints

    func testURLExactFingerprintIsStableAndSignatureSensitive() throws {
        let signedA =
            "https://rr4.example.com/videoplayback?id=abc&signature=AAA&expire=1"
        let signedB =
            "https://rr4.example.com/videoplayback?id=abc&signature=BBB&expire=2"
        let fpA = try XCTUnwrap(DiagnosticFingerprint.urlExact(signedA))
        XCTAssertEqual(fpA, DiagnosticFingerprint.urlExact(signedA))
        XCTAssertNotEqual(fpA, DiagnosticFingerprint.urlExact(signedB))
        // The short fingerprint has a fixed length and exposes no original value.
        XCTAssertEqual(fpA.count, 16)
    }

    func testResourceFingerprintSurvivesSignatureRotation() throws {
        // Signature/expiry changes only affect the exact fingerprint; the resource
        // fingerprint for the same video+itag is unchanged.
        let fp = try XCTUnwrap(DiagnosticFingerprint.resource(videoID: "abc123", itag: 137))
        XCTAssertEqual(fp, DiagnosticFingerprint.resource(videoID: "abc123", itag: 137))
        XCTAssertNotEqual(fp, DiagnosticFingerprint.resource(videoID: "abc123", itag: 248))
        XCTAssertNotEqual(fp, DiagnosticFingerprint.resource(videoID: "other", itag: 137))
        XCTAssertNil(DiagnosticFingerprint.resource(videoID: nil, itag: 137))
        XCTAssertNil(DiagnosticFingerprint.resource(videoID: "", itag: 137))
    }

    func testTitleFingerprintIgnoresWhitespaceOnlyTitles() throws {
        XCTAssertNotNil(DiagnosticFingerprint.title("普通标题"))
        XCTAssertEqual(
            DiagnosticFingerprint.title("普通标题"), DiagnosticFingerprint.title("普通标题"))
        XCTAssertNil(DiagnosticFingerprint.title("  \n "))
    }

    // MARK: - Dual-channel event log

    private func makeEvent(id: String, output: String) -> YouTubeDiagnosticEvent {
        YouTubeDiagnosticEvent(
            id: id,
            timestamp: Date(),
            event: "ytdlp.processFailed",
            stage: "download",
            taskID: "task-1",
            category: "YTDLP_VIDEO_UNAVAILABLE",
            exitStatus: 1,
            attempt: 2,
            durationMs: 1234,
            ytDlpVersion: "2026.08.01",
            cookieSupplied: true,
            cookieCount: 3,
            cookieFileCreated: true,
            proxyConfigured: false,
            urlExactFingerprint: "feedface0000beef",
            resourceFingerprint: "0123456789abcdef",
            sanitizedExcerpt: YouTubeOutputSanitizer.sanitizedExcerpt(from: output),
            fullURL: "https://www.youtube.com/watch?v=abc123#height=1080&itag=137",
            cookieFilePath: "/private/var/folders/xy/cookies.txt",
            rawOutput: YouTubeOutputSanitizer.redactCredentials(in: output)
        )
    }

    func testBothSinksShareEventIDAndSplitFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let regularLines = RegularSinkCapture()
        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: true
        )
        log.record(makeEvent(id: "evt-1", output: forgedOutput))

        // Regular line: structured fields complete; no full URLs/paths/raw output.
        let regular = try XCTUnwrap(regularLines.values.last)
        for expected in [
            "eventId=evt-1", "task=task-1", "stage=download",
            "category=YTDLP_VIDEO_UNAVAILABLE", "exit=1", "attempt=2",
            "cookieSupplied=true", "cookieCount=3", "cookieFileCreated=true",
            "urlExactFingerprint=feedface0000beef",
            "resourceFingerprint=0123456789abcdef",
            "privateDetailAvailable=true",
        ] {
            XCTAssertTrue(regular.contains(expected), "regular line missing \(expected)")
        }
        XCTAssertFalse(regular.contains("watch?v=abc123"))
        XCTAssertFalse(regular.contains("cookies.txt"))
        XCTAssertFalse(regular.contains("SECRETSIG"))

        // Private record: full URL, paths, and raw output retained under the same event id.
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("eventId=evt-1"))
        XCTAssertTrue(privateText.contains("url: https://www.youtube.com/watch?v=abc123#height=1080&itag=137"))
        XCTAssertTrue(privateText.contains("cookieFile: /private/var/folders/xy/cookies.txt"))
        XCTAssertTrue(privateText.contains("signature=SECRETSIG"))
        XCTAssertFalse(privateText.contains("SECRETTOKEN"))
        XCTAssertFalse(privateText.contains("SECRETCOOKIE"))
    }

    func testPrivateLogFileUsesOwnerOnlyPermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true
        )
        log.record(makeEvent(id: "evt-perm", output: "ERROR: x"))
        let attributes = try FileManager.default.attributesOfItem(atPath: privateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0, 0o600)
    }

    func testPrivateLogRotatesAndEnforcesArchiveCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true,
            maximumBytes: 400,
            archiveCount: 2,
            retentionInterval: 3600
        )
        // Write several over-limit events to trigger rotation; generations are capped
        // by archiveCount.
        for index in 0..<6 {
            log.record(
                makeEvent(
                    id: "evt-\(index)",
                    output: String(repeating: "ERROR: padding ", count: 60)
                ))
        }
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: privateURL.path))
        let archives = (1...2)
            .map { privateURL.appendingPathExtension("\($0)") }
            .filter { fileManager.fileExists(atPath: $0.path) }
        XCTAssertFalse(archives.isEmpty, "expected rotation to produce an archive")
        XCTAssertFalse(
            fileManager.fileExists(atPath: privateURL.appendingPathExtension("3").path),
            "archive generations must be capped at archiveCount")
    }

    func testPrivateLogRetentionDeletesExpiredArchives() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        // Pre-seed an expired rotation archive; the next write must clean it up per the
        // retention interval.
        let expired = privateURL.appendingPathExtension("1")
        try Data("stale archive".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 3600)],
            ofItemAtPath: expired.path
        )

        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { _ in },
            enabled: true,
            retentionInterval: 24 * 3600
        )
        log.record(makeEvent(id: "evt-retain", output: "ERROR: x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateURL.path))
    }

    /// docs/AI交接.md §4.2: with the private log disabled, regular structured events
    /// must still be written to the regular sink; the private file must produce no
    /// corresponding record.
    func testDisabledPrivateLogKeepsRegularSummary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("macidm-private.log")

        let regularLines = RegularSinkCapture()
        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: false
        )
        log.record(makeEvent(id: "evt-off", output: "ERROR: x"))
        // 常规行：摘要与关联字段齐全。
        let regular = try XCTUnwrap(regularLines.values.last)
        XCTAssertTrue(regular.contains("eventId=evt-off"))
        XCTAssertTrue(regular.contains("category=YTDLP_VIDEO_UNAVAILABLE"))
        XCTAssertTrue(regular.contains("privateDetailAvailable=true"))
        // 私密文件：没有任何记录。
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateURL.path))
    }
}

private final class RegularSinkCapture: @unchecked Sendable {
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
