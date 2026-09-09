import Foundation
import XCTest

@testable import IDMEngine

/// Guards against regressions of the HTTP probe "download breakage matrix"
/// (review report chapter 6, gap 1 — H1/M1). Each case pins one HEAD/GET shape
/// that previously produced a wrong size or a false `supportsRange` claim.
final class HTTPHandlerProbeTests: XCTestCase {
    private var serverProcess: Process?
    private var port = 0
    private var rootURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            rootURL.appendingPathComponent("Tests/Support/http-fixture-server.py").path,
            "--port", String(port),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
        try await waitUntilServerReady(
            URL(string: "http://127.0.0.1:\(port)/range?size=1")!
        )
    }

    override func tearDown() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        super.tearDown()
    }

    func testHead405AndGet200WithNonZeroContentLengthAdoptsGetSize() async throws {
        // H1/M1 regression guard: a 405-on-HEAD server often reports
        // Content-Length: 0 on the HEAD. Trusting that would publish a 0-byte
        // "completed" file. The probe must adopt the GET's Content-Length.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/head-405-get-200?size=4096"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("nonzero.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 4096)
        XCTAssertFalse(info.supportsRange)
    }

    func testHead405AndGet200WithZeroContentLengthReportsZeroSize() async throws {
        // Only accept size==0 when the GET itself explicitly said so — never
        // inherit a 0 from a 405 HEAD.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/head-405-get-200?size=0"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("zero.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 0)
        XCTAssertFalse(info.supportsRange)
    }

    func testHead404DoesNotBlockValidRangeGet() async throws {
        // Some CDNs return 404 for HEAD but a valid 206 for GET with Range.
        // The ranged response is authoritative and must enable safe ranges.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/head-404-get-206?size=4096"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("head-404.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 4096)
        XCTAssertTrue(info.supportsRange)
        XCTAssertNotNil(info.strongETag)
    }

    func testRange403FallsBackToNormalGetWithoutClaimingRanges() async throws {
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range-403-get-200?size=4096")
        )
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("range-403.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 4096)
        XCTAssertFalse(info.supportsRange)
        XCTAssertEqual(info.mimeType, "video/mp4")
    }

    func testHead2xxAndValid206EnablesRangeWithParsedTotal() async throws {
        // Happy path: HEAD 2xx + 206 with strong ETag + valid Content-Range +
        // identity encoding → supportsRange=true, size=parsed.total.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/range?size=8192"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("ranged.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 8192)
        XCTAssertTrue(info.supportsRange)
        XCTAssertNotNil(info.strongETag)
    }

    func test206MissingETagDowngradesToSingleStream() async throws {
        // A 206 without ETag cannot be strongly validated, so the probe must
        // set supportsRange=false even though the range response itself was
        // syntactically valid.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/range-no-etag?size=2048"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("no-etag.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 2048)
        XCTAssertFalse(info.supportsRange)
        XCTAssertNil(info.strongETag)
    }

    func testContentRangeTotalConflictingWithHeadInvalidatesRange() async throws {
        // HEAD says Content-Length=5120 but the 206 Content-Range total is
        // 2048. The mismatch must invalidate the range (supportsRange=false)
        // so the downloader does not split on a contradictory size.
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range-total-conflict?size=2048&head_size=5120")
        )
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("conflict.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 2048)
        XCTAssertFalse(info.supportsRange)
        XCTAssertNil(info.strongETag)
    }

    func testRangeDialect200WithStrongETagEnablesSegmentedTransfer() async throws {
        // Bilibili CDN dialect (verified live): the range probe is answered
        // 200 with an exact-slice Content-Range and a strong ETag. This must
        // enable verified-resume segmented transfer like a proper 206.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/range-200-dialect?size=65536"))
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("dialect.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 65536)
        XCTAssertTrue(info.supportsRange)
        XCTAssertNotNil(info.strongETag)
        // The identity fingerprints the full query without persisting its secrets.
        XCTAssertEqual(
            info.identity?.effectiveURL,
            resourceLocatorString(url)
        )
    }

    func testRangeDialectWithoutETagStaysSingleStreamButReportsTotalSize() async throws {
        // mcdn behavior: 200 + Content-Range but no strong ETag. Verified
        // resume must stay disabled, yet the size must come from the
        // Content-Range total — never from the one-byte slice length.
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range-200-dialect?size=65536&variant=no-etag")
        )
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("dialect-no-etag.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 65536)
        XCTAssertFalse(info.supportsRange)
        XCTAssertNil(info.strongETag)
    }

    func testRangeDialectClaimingSliceButSendingFullBodyIsRejected() async throws {
        // A broken dialect that echoes a slice Content-Range but streams the
        // full body (Content-Length = total) fails the slice-length
        // cross-check: no segmented transfer, and the size still comes from
        // the Content-Range total instead of the slice length.
        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/range-200-dialect?size=65536&variant=full-body")
        )
        let request = DownloadRequest(
            url: url,
            destination: temporaryDestination("dialect-full-body.bin")
        )

        let info = try await HTTPHandler().probe(request)

        XCTAssertEqual(info.size, 65536)
        XCTAssertFalse(info.supportsRange)
    }

    func testResourceLocatorPreservesQueryIdentityWithoutPersistingSecrets() throws {
        let url = try XCTUnwrap(
            URL(string: "https://user:pass@cdn.example.com:8443/path/file.m4s?deadline=9&gen=play#frag")
        )
        let withoutCredentials = URL(string: "https://cdn.example.com:8443/path/file.m4s?deadline=9&gen=play")!
        XCTAssertEqual(resourceLocatorString(url), resourceLocatorString(withoutCredentials))
        XCTAssertNotEqual(
            resourceLocatorString(url),
            resourceLocatorString(URL(string: "https://cdn.example.com:8443/path/file.m4s?deadline=10&gen=play")!))
        XCTAssertFalse(resourceLocatorString(url).contains("deadline"))
    }

    private func temporaryDestination(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMProbeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func waitUntilServerReady(_ url: URL) async throws {
        for _ in 0..<60 {
            if let (_, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("fixture server did not start on port \(port)")
    }
}
