import IDMEngine
import XCTest

@testable import MacIDMApp

final class MediaSizeProbeTests: XCTestCase {
    func testContentLengthParsing() {
        XCTAssertEqual(MediaSizeProbe.totalSize(contentLength: "12345"), 12345)
        XCTAssertEqual(MediaSizeProbe.totalSize(contentLength: " 987 "), 987)
        XCTAssertNil(MediaSizeProbe.totalSize(contentLength: nil))
        XCTAssertNil(MediaSizeProbe.totalSize(contentLength: ""))
        XCTAssertNil(MediaSizeProbe.totalSize(contentLength: "unknown"))
        XCTAssertNil(MediaSizeProbe.totalSize(contentLength: "0"))
        XCTAssertNil(MediaSizeProbe.totalSize(contentLength: "-5"))
    }

    func testContentRangeParsing() {
        XCTAssertEqual(MediaSizeProbe.totalSize(contentRange: "bytes 0-0/67890"), 67890)
        XCTAssertEqual(MediaSizeProbe.totalSize(contentRange: "bytes 0-0/ 4096 "), 4096)
        // The server admitted it does not know the total.
        XCTAssertNil(MediaSizeProbe.totalSize(contentRange: "bytes 0-0/*"))
        XCTAssertNil(MediaSizeProbe.totalSize(contentRange: nil))
        XCTAssertNil(MediaSizeProbe.totalSize(contentRange: "bytes 0-0"))
        XCTAssertNil(MediaSizeProbe.totalSize(contentRange: "bytes 0-0/abc"))
        // Round 5 P1: strictly validate unit, range, and total size.
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "garbage/67890"),
            "非法单位前缀不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "items 0-0/12345"),
            "非 bytes 单位不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "bytes 5-9/100"),
            "与探测发出的 bytes=0-0 不一致的区间不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "bytes 0-5/3"),
            "自相矛盾的区间（last ≥ total）不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "bytes 0-0/0"),
            "总大小为 0 不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "bytes -0/100"),
            "非法区间不得通过")
        XCTAssertNil(
            MediaSizeProbe.totalSize(contentRange: "bytes 0-0/67890/extra"),
            "多余分段不得通过")
        // Round 6 P2: the structured parser distinguishes unknown from invalid.
        XCTAssertEqual(MediaSizeProbe.parseContentRange("bytes 0-0/123"), .total(123))
        XCTAssertEqual(MediaSizeProbe.parseContentRange("bytes 0-0/*"), .unknownTotal)
        XCTAssertEqual(
            MediaSizeProbe.parseContentRange("items 0-0/*"), .invalid,
            "单位非法时带星号仍是非法响应")
        XCTAssertEqual(
            MediaSizeProbe.parseContentRange("garbage/*"), .invalid,
            "无单位/区间时带星号仍是非法响应")
        XCTAssertEqual(
            MediaSizeProbe.parseContentRange("bytes 5-9/*"), .invalid,
            "区间与 bytes=0-0 不一致时带星号仍是非法响应")
        XCTAssertEqual(MediaSizeProbe.parseContentRange(nil), .invalid)
    }

    func testProbeReadsContentLengthFromHEAD() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "12345"]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 12345)
    }

    func testProbeSendsContextHeaders() async {
        var seenReferer: String?
        var seenUserAgent: String?
        var seenCookie: String?
        StubURLProtocol.handler = { request in
            seenReferer = request.value(forHTTPHeaderField: "Referer")
            seenUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            seenCookie = request.value(forHTTPHeaderField: "Cookie")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1"]
            )!
            return (response, Data())
        }
        let context = DownloadRequestContext(
            cookie: "SESSDATA=abc",
            referer: "https://www.bilibili.com/video/BV1",
            userAgent: "TestAgent/1.0"
        )
        _ = await MediaSizeProbe.probe(Self.trackURL, context: context, session: Self.stubbedSession)
        XCTAssertEqual(seenReferer, "https://www.bilibili.com/video/BV1")
        XCTAssertEqual(seenUserAgent, "TestAgent/1.0")
        XCTAssertEqual(seenCookie, "SESSDATA=abc")
    }

    func testProbeFallsBackToRangedGETWhenHEADHasNoLength() async {
        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                // chunked-style answer: no Content-Length at all.
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (response, Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-0")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/67890", "Content-Length": "1"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 67890)
    }

    func testProbeAcceptsPlain200FromRangeIgnoringServer() async {
        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                throw URLError(.badServerResponse)
            }
            // Server ignores Range and answers 200 with the full length.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "555"]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 555)
    }

    func testProbeFailsSilently() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size)

        // Non-HTTP schemes never probe.
        let fileURL = await MediaSizeProbe.probe(
            URL(string: "file:///tmp/video.m4s")!, session: Self.stubbedSession)
        XCTAssertNil(fileURL)
    }

    /// Round 2 §P2-3: for external errors containing signed URLs, local paths with
    /// spaces, and title text, the regular log never shows the original values; host
    /// and probe method are retained; full context goes to the private log under the
    /// same event ID.
    func testLogFailureSplitsRegularSummaryAndPrivateContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = SizeProbeSinkCapture()
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        struct FixtureProbeError: LocalizedError {
            var errorDescription: String? {
                "无法读取 https://cdn.example.com/seg.mp4?token=SIGNEDTOKEN&expire=9 以及 /Users/example/Downloads/Secret Video.mp4"
            }
        }
        MediaSizeProbe.logFailure(
            URL(string: "https://cdn.example.com/seg.mp4?token=SIGNEDTOKEN")!,
            FixtureProbeError(),
            method: "HEAD"
        )

        // 常规行：host、探测策略与安全字段保留；签名值、标题与本机路径不得出现。
        // 第五轮 P2：策略级传输错误属于单一策略未命中（strategyMiss），不表达整次失败。
        let regular = try XCTUnwrap(capture.values.last)
        XCTAssertTrue(regular.contains("event=sizeProbe.strategyMiss"))
        XCTAssertTrue(regular.contains("stage=HEAD"))
        XCTAssertTrue(regular.contains("host=cdn.example.com"))
        XCTAssertFalse(regular.contains("SIGNEDTOKEN"))
        XCTAssertFalse(regular.contains("Secret"))
        XCTAssertFalse(regular.contains("/Users/example"))
        XCTAssertFalse(regular.contains("token=SIGNEDTOKEN"))

        // 私密记录：同一 event ID 下保留完整 URL（含签名 query）与完整底层错误。
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        let eventID = try XCTUnwrap(
            regular.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(regular[$0].dropFirst("eventId=".count)) })
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
        XCTAssertTrue(privateText.contains("url: https://cdn.example.com/seg.mp4?token=SIGNEDTOKEN"))
        XCTAssertTrue(privateText.contains("Secret Video.mp4"))
        XCTAssertTrue(privateText.contains("/Users/example/Downloads"))
    }

    /// 第四轮 R4：HTTP 403、缺少长度、非法响应等静默失败路径必须产生结构化诊断事件：
    /// 常规行只有 host/方法/reason/状态码，完整签名 URL 按同一 event ID 只进私密日志。
    func testSilentFailuresRecordStructuredDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeOutcomeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = SizeProbeSinkCapture()
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        let signedURL = URL(string: "https://cdn.example.com/clip.m4s?token=SIGNEDTOKEN")!
        let size = await MediaSizeProbe.probe(signedURL, session: Self.stubbedSession)
        XCTAssertNil(size)

        // 常规行：HEAD 与 range 各有一条策略未命中记录（含 host/策略/状态码）；
        // 签名值不出现；整次探测最终只有一条 noResult（第四轮 R4、第五轮 P2）。
        let misses = capture.values.filter { $0.contains("event=sizeProbe.strategyMiss") }
        XCTAssertTrue(misses.contains { $0.contains("stage=HEAD") && $0.contains("status=403") })
        XCTAssertTrue(misses.contains { $0.contains("stage=range") && $0.contains("status=403") })
        for line in misses {
            XCTAssertTrue(line.contains("host=cdn.example.com"))
            XCTAssertFalse(line.contains("SIGNEDTOKEN"))
        }
        let finals = capture.values.filter { $0.contains("event=sizeProbe.noResult") }
        XCTAssertEqual(finals.count, 1, "整次探测失败只允许一条最终 noResult")
        let final = try XCTUnwrap(finals.first)
        XCTAssertTrue(final.contains("HEAD=httpStatus:403"))
        XCTAssertTrue(final.contains("range=httpStatus:403"))
        XCTAssertFalse(final.contains("SIGNEDTOKEN"))

        // 关联字段：最终事件与策略事件共用同一 probeId。
        let probeID = try XCTUnwrap(
            final.range(of: #"probeId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(final[$0]) })
        for line in misses {
            XCTAssertTrue(line.contains(probeID), "策略事件必须与最终事件共享 probeId")
        }

        // 私密记录：同一 event ID 下保留完整签名 URL。
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("url: https://cdn.example.com/clip.m4s?token=SIGNEDTOKEN"))
        let eventID = try XCTUnwrap(
            final.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(final[$0].dropFirst("eventId=".count)) })
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
    }

    /// 第四轮 R4：2xx 但缺少 Content-Length 同样记录 missingLength 诊断事件。
    func testMissingLengthRecordsDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeMissingLenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = SizeProbeSinkCapture()
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size)
        // HEAD 与 range 各有一条 missingLength 策略未命中记录。
        let misses = capture.values.filter { $0.contains("event=sizeProbe.strategyMiss") }
        XCTAssertTrue(misses.contains { $0.contains("reason=missingLength") && $0.contains("status=200") })
        XCTAssertEqual(
            capture.values.filter { $0.contains("event=sizeProbe.noResult") }.count, 1)
    }

    /// 第五轮 P1：206 缺失 Content-Range 时不得用 Content-Length（部分响应正文长度）
    /// 充当总大小，必须返回 nil 并记录可区分的结构化原因。
    func testRanged206WithoutContentRangeNeverUsesContentLength() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbe206Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                throw URLError(.badServerResponse)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size, "206 缺 Content-Range 时不得把 Content-Length=1 当成总大小")
        XCTAssertNotEqual(size, 1)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("reason=missingContentRange") && $0.contains("status=206")
            })
    }

    /// 第五轮 P1：206 + 非法 Content-Range + Content-Length:1 同样返回 nil；
    /// 未知总大小 `*` 记录 unknownContentRange。
    func testRanged206WithInvalidContentRangeReturnsNil() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbe206InvalidTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                throw URLError(.badServerResponse)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "items 0-0/12345", "Content-Length": "1"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("reason=invalidContentRange") && $0.contains("status=206")
            })

        // 未知总大小 `*`：同样不得放行，原因可区分。
        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                throw URLError(.badServerResponse)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/*"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let unknownTotal = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(unknownTotal)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("reason=unknownContentRange") && $0.contains("status=206")
            })
    }

    /// 第五轮 P2：HEAD 缺长度、Range 成功 → 返回正确大小，且不得产生最终 noResult；
    /// 策略未命中记录可保留（名称不表达整次失败）。
    func testSuccessfulFallbackProducesNoFinalNoResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeFallbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/98765"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 98765)
        // 回退成功：不得出现整次失败的 noResult；HEAD 未命中仍可作为策略记录保留。
        XCTAssertTrue(capture.values.filter { $0.contains("event=sizeProbe.noResult") }.isEmpty)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("event=sizeProbe.strategyMiss") && $0.contains("reason=missingLength")
            })
    }

    /// 第五轮 P2：HEAD 403 但 Range 成功 → 同样不得产生最终失败事件。
    func testHeadForbiddenButRangeSucceedsWithoutFinalFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeHead403Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "555"]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 555)
        XCTAssertTrue(capture.values.filter { $0.contains("event=sizeProbe.noResult") }.isEmpty)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("event=sizeProbe.strategyMiss") && $0.contains("status=403")
            })
    }

    /// 第六轮 P1：HEAD 收到 206 + Content-Length: 1 时不得把部分长度当总大小，
    /// 应记为未命中并继续 Range 回退，使用 Range 的合法总大小。
    func testHead206FallsThroughToRangeAndUsesRangeTotal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeHead206Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "1"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/54321"]
            )!
            return (response, Data(repeating: 0, count: 1))
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 54321, "必须使用 Range 的合法总大小")
        XCTAssertNotEqual(size, 1)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("event=sizeProbe.strategyMiss")
                    && $0.contains("reason=unexpectedPartialResponse")
                    && $0.contains("status=206")
            })
        XCTAssertTrue(capture.values.filter { $0.contains("event=sizeProbe.noResult") }.isEmpty)
    }

    /// 第六轮 P1：HEAD 206 未命中后 Range 也失败 → 最终返回 nil，恰一条最终 noResult，
    /// 策略链中两个原因均可定位。
    func testHead206ThenRangeFailureProducesFinalNoResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeHead206FailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "1"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size)
        let finals = capture.values.filter { $0.contains("event=sizeProbe.noResult") }
        XCTAssertEqual(finals.count, 1)
        let final = try XCTUnwrap(finals.first)
        XCTAssertTrue(final.contains("HEAD=unexpectedPartialResponse:206"))
        XCTAssertTrue(final.contains("range=httpStatus:403"))
    }

    /// 第六轮 P1：正常 HEAD 200 + Content-Length 仍直接成功，不发 Range 请求。
    func testHead200SucceedsWithoutRangeRequest() async {
        var sawNonHeadRequest = false
        StubURLProtocol.handler = { request in
            guard request.httpMethod == "HEAD" else {
                sawNonHeadRequest = true
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "12345"]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 12345)
        XCTAssertFalse(sawNonHeadRequest, "HEAD 200 成功后不得再发 Range 请求")
    }

    /// 第六轮 P2：底层错误描述清洗后为空时，策略事件仍保留结构化 probeId 与稳定
    /// reason=networkError，不依赖自由文本摘要；私密日志保留完整描述并可用 event ID 关联。
    func testEmptyErrorSummaryKeepsProbeIdAndStableReason() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeEmptySummaryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let log = DownloadDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        // 描述只含控制字符：清洗后为空，摘要缺失。
        struct ControlCharError: LocalizedError {
            var errorDescription: String? { "\u{7}\u{1b}[31m" }
        }
        let fixedProbeID = UUID().uuidString
        MediaSizeProbe.logFailure(Self.trackURL, ControlCharError(), method: "HEAD", probeID: fixedProbeID)
        MediaSizeProbe.logFailure(Self.trackURL, ControlCharError(), method: "range", probeID: fixedProbeID)

        let misses = capture.values.filter { $0.contains("event=sizeProbe.strategyMiss") }
        XCTAssertEqual(misses.count, 2)
        for line in misses {
            XCTAssertTrue(line.contains("probeId=\(fixedProbeID)"), "摘要缺失时不得丢失结构化 probeId")
            XCTAssertTrue(line.contains("reason=networkError"), "稳定 reason 必须独立于摘要保留")
            XCTAssertFalse(line.contains("\u{7}"), "常规日志不得出现原始控制字符")
            XCTAssertFalse(line.contains("\u{1b}"), "常规日志不得出现原始控制字符")
        }

        // 私密日志保留完整底层错误，并可通过 event ID 与常规行关联。
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("\u{7}\u{1b}[31m"))
        let headLine = try XCTUnwrap(misses.first { $0.contains("stage=HEAD") })
        let eventID = try XCTUnwrap(
            headLine.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(headLine[$0].dropFirst("eventId=".count)) })
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
    }

    /// 第六轮 P2：两条策略都因网络错误失败时，两条策略事件与唯一最终事件仍共享结构化 probeId。
    func testNetworkFailuresShareProbeIdAcrossStrategyAndFinalEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeProbeIdTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertNil(size)

        let misses = capture.values.filter { $0.contains("event=sizeProbe.strategyMiss") }
        XCTAssertEqual(misses.count, 2)
        let finals = capture.values.filter { $0.contains("event=sizeProbe.noResult") }
        XCTAssertEqual(finals.count, 1)
        let final = try XCTUnwrap(finals.first)
        let probeID = try XCTUnwrap(
            final.range(of: #"probeId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(final[$0]) })
        for line in misses {
            XCTAssertTrue(line.contains(probeID), "策略事件必须与最终事件共享结构化 probeId")
            XCTAssertTrue(line.contains("reason=networkError"))
        }
    }

    /// 第六轮 P2：网络错误后 Range 成功 → 策略事件含稳定 reason=networkError，无最终 noResult。
    func testNetworkMissKeepsStableReasonWhenRangeSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSizeProbeNetMissTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SizeProbeSinkCapture()
        let log = DownloadDiagnosticEventLog(
            privateLogURL: directory.appendingPathComponent("macidm-private.log"),
            regularSink: { capture.append($0) },
            enabled: true
        )
        let previous = MediaSizeProbe.diagnosticLog
        MediaSizeProbe.diagnosticLog = log
        defer { MediaSizeProbe.diagnosticLog = previous }

        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "555"]
            )!
            return (response, Data())
        }
        let size = await MediaSizeProbe.probe(Self.trackURL, session: Self.stubbedSession)
        XCTAssertEqual(size, 555)
        XCTAssertTrue(
            capture.values.contains {
                $0.contains("event=sizeProbe.strategyMiss") && $0.contains("reason=networkError")
            })
        XCTAssertTrue(capture.values.filter { $0.contains("event=sizeProbe.noResult") }.isEmpty)
    }

    private static let trackURL = URL(string: "https://cdn.example.com/video.m4s")!

    private static var stubbedSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class SizeProbeSinkCapture: @unchecked Sendable {
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

/// Minimal URLProtocol stub: returns whatever the current test registered.
/// XCTest runs test methods serially, so the shared handler needs no lock.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
