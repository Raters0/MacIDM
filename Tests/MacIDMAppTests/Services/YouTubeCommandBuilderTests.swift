import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

final class YouTubeCommandBuilderTests: XCTestCase {
    func testParseMacIDMFragment() {
        let empty = YouTubeCommandBuilder.parseMacIDMFragment("")
        XCTAssertNil(empty.height)
        XCTAssertNil(empty.itag)
        XCTAssertFalse(empty.hasAudio)

        let simpleHeight = YouTubeCommandBuilder.parseMacIDMFragment("height=1080")
        XCTAssertEqual(simpleHeight.height, 1080)
        XCTAssertNil(simpleHeight.itag)
        XCTAssertFalse(simpleHeight.hasAudio)

        let combined = YouTubeCommandBuilder.parseMacIDMFragment("height=720&itag=136&a=1")
        XCTAssertEqual(combined.height, 720)
        XCTAssertEqual(combined.itag, 136)
        XCTAssertTrue(combined.hasAudio)

        let malformed = YouTubeCommandBuilder.parseMacIDMFragment("height=invalid&itag=99999999&unknown=foo")
        XCTAssertNil(malformed.height)
        XCTAssertNil(malformed.itag)
        XCTAssertFalse(malformed.hasAudio)
    }

    func testFormatSelector() {
        // itag with audio
        XCTAssertEqual(
            YouTubeCommandBuilder.formatSelector(itag: 18, hasAudio: true, heightConstraint: ""),
            "18"
        )
        // itag without audio (pairs with best audio)
        XCTAssertEqual(
            YouTubeCommandBuilder.formatSelector(itag: 137, hasAudio: false, heightConstraint: ""),
            "137+ba[ext=m4a]/137"
        )
        // No itag, default selector
        XCTAssertEqual(
            YouTubeCommandBuilder.formatSelector(itag: nil, hasAudio: false, heightConstraint: ""),
            "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
        )
        // No itag, with height constraint
        XCTAssertEqual(
            YouTubeCommandBuilder.formatSelector(itag: nil, hasAudio: false, heightConstraint: "[height<=1080]"),
            "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b"
        )
    }

    func testYouTubeVideoID() throws {
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s"))
        XCTAssertEqual(YouTubeCommandBuilder.youTubeVideoID(from: watchURL), "dQw4w9WgXcQ")

        let shortsURL = try XCTUnwrap(URL(string: "https://youtube.com/shorts/abc12345"))
        XCTAssertEqual(YouTubeCommandBuilder.youTubeVideoID(from: shortsURL), "abc12345")

        let liveURL = try XCTUnwrap(URL(string: "https://www.youtube.com/live/liveVideoId"))
        XCTAssertEqual(YouTubeCommandBuilder.youTubeVideoID(from: liveURL), "liveVideoId")

        let shortDomainURL = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeCommandBuilder.youTubeVideoID(from: shortDomainURL), "dQw4w9WgXcQ")

        let nonYT = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        XCTAssertNil(YouTubeCommandBuilder.youTubeVideoID(from: nonYT))
    }

    func testWriteCookieFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cookieString = "SID=abc123xyz; HSID=def456uvw; expires=Wed, 21 Oct 2026 07:28:00 GMT"
        let cookieURL = try YouTubeCommandBuilder.writeCookieFile(cookieString, domain: ".youtube.com", in: tempDir)
        let resolvedURL = try XCTUnwrap(cookieURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.path))
        let content = try String(contentsOf: resolvedURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Netscape HTTP Cookie File\n"))
        XCTAssertTrue(content.contains(".youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc123xyz"))
        XCTAssertTrue(content.contains(".youtube.com\tTRUE\t/\tTRUE\t0\tHSID\tdef456uvw"))
    }

    // MARK: - Cookie argument selection (authorization-driven, no Chrome DB)

    /// Cookie supply is authorization-driven: an explicit Netscape cookie file
    /// (extension-granted or pasted session) is passed when present. Reading
    /// Chrome's on-disk Cookies DB (`--cookies-from-browser`) is never used —
    /// it requires Full Disk Access on macOS Sonoma+ and every ad-hoc rebuild
    /// invalidates the grant. This test locks the cookie-file branch.
    func testBuildDownloadArgumentsUsesCookieFileWhenSupplied() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cookieFile = tempDir.appendingPathComponent("cookies.txt")
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: cookieFile)

        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: tempDir.appendingPathComponent("video.mp4"),
            backend: .youtubeExtractor
        )
        let arguments = YouTubeCommandBuilder.buildDownloadArguments(
            downloadURL: request.url,
            formatString: "bv*+ba/b",
            workingDirectory: tempDir,
            cookieFile: cookieFile,
            request: request
        )

        // The explicit cookie file must be present exactly once…
        let cookiesFlagIndices = arguments.indices.filter { arguments[$0] == "--cookies" }
        XCTAssertEqual(cookiesFlagIndices.count, 1)
        XCTAssertEqual(arguments[cookiesFlagIndices[0] + 1], cookieFile.path)
        // …and the Chrome-DB read must never appear.
        XCTAssertFalse(
            arguments.contains("--cookies-from-browser"),
            "--cookies-from-browser must never be passed; it triggers macOS TCC EPERM on Chrome's Cookies DB"
        )
    }

    /// With no authorized cookie the runner must degrade to an anonymous
    /// yt-dlp run (public videos still work) rather than attempting to read
    /// Chrome's protected Cookies DB.
    func testBuildDownloadArgumentsRunsAnonymouslyWhenNoCookieFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = DownloadRequest(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            destination: tempDir.appendingPathComponent("video.mp4"),
            backend: .youtubeExtractor
        )
        let arguments = YouTubeCommandBuilder.buildDownloadArguments(
            downloadURL: request.url,
            formatString: "bv*+ba/b",
            workingDirectory: tempDir,
            cookieFile: nil,
            request: request
        )

        // Anonymous: neither an explicit cookie file nor a browser-DB read.
        XCTAssertFalse(arguments.contains("--cookies"))
        XCTAssertFalse(arguments.contains("--cookies-from-browser"))
    }
}
