import XCTest

@testable import IDMEngine

final class InputValidatorTests: XCTestCase {
    func testFilenameSanitizationRemovesPathAndControls() {
        XCTAssertEqual(InputValidator.safeFilename("../../hello\u{0}.zip"), "hello.zip")
        XCTAssertEqual(InputValidator.safeFilename(".."), "download")
        XCTAssertEqual(InputValidator.safeFilename(""), "download")
    }

    func testSafeFilenameStripsLeadingDotSoFileIsNotHidden() {
        // A leading dot makes the file hidden on macOS. The sanitiser must
        // strip it so a downloaded file is always visible to the user.
        XCTAssertEqual(InputValidator.safeFilename(".hidden"), "hidden")
        XCTAssertEqual(InputValidator.safeFilename(".gitignore"), "gitignore")
        XCTAssertEqual(InputValidator.safeFilename("...config"), "config")
    }

    func testSafeFilenameStripsLeadingAndTrailingWhitespaceAndDots() {
        // Trailing dots collide with Windows/legacy tooling; leading/trailing
        // spaces are almost always accidental. Trim repeatedly so mixed
        // prefixes/suffixes collapse cleanly.
        XCTAssertEqual(InputValidator.safeFilename("  file.  "), "file")
        XCTAssertEqual(InputValidator.safeFilename(" . . name . "), "name")
        XCTAssertEqual(InputValidator.safeFilename("report.pdf."), "report.pdf")
        XCTAssertEqual(InputValidator.safeFilename(" report.pdf "), "report.pdf")
    }

    func testSafeFilenameStripsPathSeparators() {
        // Path separators must be collapsed so a server-supplied "a/b/c" can
        // never escape the destination directory.
        XCTAssertEqual(InputValidator.safeFilename("a/b/c"), "c")
        XCTAssertEqual(InputValidator.safeFilename("/etc/passwd"), "passwd")
        XCTAssertEqual(InputValidator.safeFilename("dir/sub/file.zip"), "file.zip")
    }

    func testSafeFilenameTruncationPreservesTheExtension() {
        // 长 CJK 标题超过 255 字节时，截断只缩短词干，扩展名必须存活；
        // 旧实现从尾部砍字符会把 ".mp4" 一起砍掉。
        let longTitle = String(repeating: "长", count: 120) + ".mp4"
        let truncated = InputValidator.safeFilename(longTitle)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 255)
        XCTAssertTrue(truncated.hasSuffix(".mp4"))
        XCTAssertGreaterThan(truncated.utf8.count, 250)
        // 扩展名自身超长时仍须安全终止且不超限。
        let hugeExtension = "file." + String(repeating: "x", count: 300)
        let clipped = InputValidator.safeFilename(hugeExtension)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 255)
        XCTAssertFalse(clipped.isEmpty)
    }

    func testRequestContextRejectsHeaderInjection() throws {
        let directory = FileManager.default.temporaryDirectory
        let request = DownloadRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/file.zip")),
            destination: directory.appendingPathComponent(UUID().uuidString),
            requestContext: DownloadRequestContext(cookie: "session=ok\r\nX-Evil: yes")
        )

        XCTAssertThrowsError(try InputValidator.validate(request))
    }

    func testCookieContextIsNotAppliedAcrossOrigins() throws {
        let context = DownloadRequestContext(
            cookie: "session=secret",
            referer: "https://example.com/account",
            userAgent: "MacIDM-Test"
        )
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.net/file")))

        context.apply(
            to: &request,
            boundTo: try XCTUnwrap(URL(string: "https://example.com/file"))
        )

        // Cookies are sensitive: still stripped cross-origin.
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        // Referer/UA are not sensitive and media CDNs require them cross-origin.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MacIDM-Test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://example.com")
    }

    func testRefererIsNotSentOnHTTPSDowngrade() throws {
        let context = DownloadRequestContext(
            cookie: "session=secret",
            referer: "https://example.com/account",
            userAgent: "MacIDM-Test"
        )
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example.net/file")))

        context.apply(
            to: &request,
            boundTo: try XCTUnwrap(URL(string: "https://example.com/file"))
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MacIDM-Test")
    }

    func testGoogleVideoContextUsesBrowserMediaRequestHeaders() throws {
        let context = DownloadRequestContext(
            referer: "https://www.youtube.com/watch?v=test",
            userAgent: "Chrome-Test"
        )
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://rr1---sn.example.googlevideo.com/videoplayback"))
        )

        context.apply(
            to: &request,
            boundTo: try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=test"))
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Dest"), "video")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Mode"), "cors")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "cross-site")
    }
}
