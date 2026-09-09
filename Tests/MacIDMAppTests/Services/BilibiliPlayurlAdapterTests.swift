import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

final class BilibiliPlayurlAdapterTests: XCTestCase {
    func testSupportsBilibiliVideoURLsOnly() {
        XCTAssertTrue(BilibiliPlayurlAdapter.supports(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!))
        XCTAssertTrue(BilibiliPlayurlAdapter.supports(URL(string: "https://bilibili.com/video/av12345?p=2")!))
        XCTAssertFalse(BilibiliPlayurlAdapter.supports(URL(string: "https://www.bilibili.com/space/1")!))
        XCTAssertFalse(BilibiliPlayurlAdapter.supports(URL(string: "https://example.com/video/BV123")!))
    }

    func testSupportsWatchlaterListPageOnlyWithResolvableVideoIdentity() {
        // 稍后再看列表页内嵌同一个播放器，当前视频身份在 bvid/oid 查询参数里。
        XCTAssertTrue(
            BilibiliPlayurlAdapter.supports(
                URL(
                    string:
                        "https://www.bilibili.com/list/watchlater/?bvid=BV1xx411c7mD&oid=1954947383&spm_id_from=333.881.0.0"
                )!
            )
        )
        // bvid 缺失时退回把 oid 当作 avid。
        XCTAssertTrue(
            BilibiliPlayurlAdapter.supports(
                URL(string: "https://www.bilibili.com/list/watchlater/?oid=1954947383")!
            )
        )
        // 裸列表页、非法身份与其他列表类型都没有单视频身份，不得当成一个视频。
        XCTAssertFalse(
            BilibiliPlayurlAdapter.supports(URL(string: "https://www.bilibili.com/list/watchlater/")!)
        )
        XCTAssertFalse(
            BilibiliPlayurlAdapter.supports(
                URL(string: "https://www.bilibili.com/list/watchlater/?bvid=not-a-bvid")!
            )
        )
        XCTAssertFalse(
            BilibiliPlayurlAdapter.supports(
                URL(string: "https://www.bilibili.com/list/ml/?bvid=BV1xx411c7mD")!
            )
        )
        XCTAssertFalse(
            BilibiliPlayurlAdapter.supports(
                URL(string: "https://example.com/list/watchlater/?bvid=BV1xx411c7mD")!
            )
        )
    }

    func testM4sFormatIDParsesBilibiliTrackFilename() {
        // 标准 `{cid}-1-{format_id}.m4s` 轨名：取出 format_id（画质/编码标识）。
        XCTAssertEqual(
            BilibiliPlayurlAdapter.m4sFormatID(
                in: URL(string: "https://upos.bilivideo.com/x/12345678-1-30080.m4s?deadline=9&gen=play")!
            ),
            30080
        )
        XCTAssertEqual(
            BilibiliPlayurlAdapter.m4sFormatID(in: URL(string: "https://upos.bilivideo.com/x/900000-1-30280.m4s")!),
            30280
        )
        // 非 m4s、中段不是 1、非数字、段数不对都返回 nil。
        XCTAssertNil(BilibiliPlayurlAdapter.m4sFormatID(in: URL(string: "https://x.com/a.mp4")!))
        XCTAssertNil(BilibiliPlayurlAdapter.m4sFormatID(in: URL(string: "https://x.com/123-2-30080.m4s")!))
        XCTAssertNil(BilibiliPlayurlAdapter.m4sFormatID(in: URL(string: "https://x.com/abc-1-xyz.m4s")!))
        XCTAssertNil(BilibiliPlayurlAdapter.m4sFormatID(in: URL(string: "https://x.com/123-1-30080-extra.m4s")!))
    }

    func testResolveWatchlaterListPageUsesQueryIdentityAndCanonicalVideoReferer() async throws {
        let client = BilibiliFixtureClient(
            responses: [
                "/x/web-interface/view": try loadData("view"),
                "/x/web-interface/nav": Data("{\"code\":0,\"data\":{}}".utf8),
                "/x/player/wbi/playurl": try loadData("playurl"),
            ]
        )
        let adapter = BilibiliPlayurlAdapter(
            client: client,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let pageURL = URL(
            string:
                "https://www.bilibili.com/list/watchlater/?bvid=BV1xx411c7mD&oid=1954947383&vd_source=tracking"
        )!

        let options = try await adapter.resolve(pageURL: pageURL)

        XCTAssertEqual(options.first?.height, 1_080)
        let requests = await client.requests
        let viewRequest = try XCTUnwrap(
            requests.first(where: { $0.url.path == "/x/web-interface/view" })
        )
        // 身份取自查询参数，接口口径与 /video/ 页一致（bvid 查 view，aid 查 playurl）。
        XCTAssertEqual(viewRequest.url.query, "bvid=BV1xx411c7mD")
        let playurlRequest = try XCTUnwrap(
            requests.first(where: { $0.url.path == "/x/player/wbi/playurl" })
        )
        let playurlQuery = try XCTUnwrap(
            URLComponents(url: playurlRequest.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(playurlQuery.first(where: { $0.name == "cid" })?.value, "1550776785")
        // 手动粘贴的列表页没有浏览器上下文：兜底 Referer 必须是规范视频页，
        // 而不是去掉查询参数后剩下的裸列表路径。
        XCTAssertEqual(
            options.first?.requestContext?.referer,
            "https://www.bilibili.com/video/BV1xx411c7mD/"
        )

        // 浏览器上下文优先：扩展带来的实际页面 Referer 不被覆盖。
        let browserOptions = try await adapter.resolve(
            pageURL: pageURL,
            requestContext: DownloadRequestContext(
                cookie: "SESSDATA=short-lived",
                referer: pageURL.absoluteString,
                userAgent: "MacIDM-Test"
            )
        )
        XCTAssertEqual(browserOptions.first?.requestContext?.referer, pageURL.absoluteString)
    }

    func testParseOptionsPairsHighestAudioAndSortsVideoQuality() throws {
        let object = try loadObject("playurl")
        let options = try BilibiliPlayurlAdapter.parseOptions(object, title: "B站测试视频")

        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.first?.height, 1_080)
        XCTAssertEqual(options.first?.videoURL.lastPathComponent, "1550776785-1-100116.m4s")
        XCTAssertEqual(options.first?.audioURL.lastPathComponent, "1550776785-1-30280.m4s")
        XCTAssertEqual(options.first?.title, "B站测试视频")
    }

    func testParseOptionsExposesDurationAndEstimatedSize() throws {
        let object = try loadObject("playurl")
        let options = try BilibiliPlayurlAdapter.parseOptions(object, title: "B站测试视频")

        XCTAssertEqual(options.count, 2)
        // dash.duration = 120s；预估大小 =（视频+最高音频轨）码率 × 时长 / 8。
        for option in options {
            XCTAssertEqual(option.duration, 120)
        }
        let top = try XCTUnwrap(options.first)  // 1080P, 视频 1_600_000 bit/s
        XCTAssertEqual(top.estimatedSize, (1_600_000 + 192_000) * 120 / 8)
        let lower = try XCTUnwrap(options.last)  // 720P, 视频 800_000 bit/s
        XCTAssertEqual(lower.estimatedSize, (800_000 + 192_000) * 120 / 8)
    }

    func testParseOptionsLeavesSizeUnknownWithoutDurationFields() throws {
        var object = try loadObject("playurl")
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        data.removeValue(forKey: "time_length")
        var dash = try XCTUnwrap(data["dash"] as? [String: Any])
        dash.removeValue(forKey: "duration")
        data["dash"] = dash
        object["data"] = data

        let options = try BilibiliPlayurlAdapter.parseOptions(object, title: "B站测试视频")

        XCTAssertEqual(options.count, 2)
        for option in options {
            XCTAssertNil(option.duration)
            XCTAssertNil(option.estimatedSize)
        }
    }

    func testNormalizedDurationHandlesSecondsAndPGCMilliseconds() {
        // dash.duration 优先（秒）。
        XCTAssertEqual(
            BilibiliPlayurlAdapter.normalizedDuration(dashSeconds: 121.5, timeLength: 120),
            121.5
        )
        // 常规接口 time_length 单位为秒。
        XCTAssertEqual(
            BilibiliPlayurlAdapter.normalizedDuration(dashSeconds: nil, timeLength: 120),
            120
        )
        // 番剧 PGC 接口 time_length 单位为毫秒，归一化为秒。
        XCTAssertEqual(
            BilibiliPlayurlAdapter.normalizedDuration(dashSeconds: nil, timeLength: 1_425_000),
            1_425
        )
        XCTAssertNil(BilibiliPlayurlAdapter.normalizedDuration(dashSeconds: nil, timeLength: nil))
        XCTAssertNil(BilibiliPlayurlAdapter.normalizedDuration(dashSeconds: 0, timeLength: -1))
    }

    func testParseOptionsKeepsDistinctCodecsAndDeduplicatesRepeatedRepresentation() throws {
        var object = try loadObject("playurl")
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        var dash = try XCTUnwrap(data["dash"] as? [String: Any])
        var videos = try XCTUnwrap(dash["video"] as? [[String: Any]])
        videos.append(videos[0])
        var alternateCodec = videos[0]
        alternateCodec["baseUrl"] = "https://video.example.test/1550776785-1-100022-hevc.m4s"
        alternateCodec["codecs"] = "hev1.2.4.L120.B0"
        videos.append(alternateCodec)
        dash["video"] = videos
        data["dash"] = dash
        object["data"] = data

        let options = try BilibiliPlayurlAdapter.parseOptions(object, title: "B站测试视频")

        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options.filter { $0.height == 720 }.count, 2)
        XCTAssertEqual(
            Set(options.compactMap(\.codecs)),
            Set(["avc1.64001f", "hev1.2.4.L120.B0", "hev1.2.4.L153.B0"])
        )
    }

    func testDisplayCodecProvidesAUserSelectableEncodingLabel() {
        // 只展示编码族名：avc1.64001f 这类 FourCC 细节不进展示层。
        XCTAssertEqual(
            BilibiliPlayurlAdapter.displayCodec("avc1.64001f"),
            "H.264"
        )
        XCTAssertEqual(
            BilibiliPlayurlAdapter.displayCodec("hev1.2.4.L153.B0"),
            "H.265"
        )
        XCTAssertNil(BilibiliPlayurlAdapter.displayCodec("vp8"))
        XCTAssertNil(BilibiliPlayurlAdapter.displayCodec(" "))
    }

    func testResolveUsesViewCIDAndPlayurlAdapterWithoutPersistingCredentials() async throws {
        let viewObject = try loadObject("view")
        XCTAssertEqual((viewObject["code"] as? NSNumber)?.intValue, 0)
        let client = BilibiliFixtureClient(
            responses: [
                "/x/web-interface/view": try loadData("view"),
                "/x/web-interface/nav": Data("{\"code\":0,\"data\":{}}".utf8),
                "/x/player/wbi/playurl": try loadData("playurl"),
            ]
        )
        let adapter = BilibiliPlayurlAdapter(client: client, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let pageURL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!
        let options: [BilibiliPlayurlOption]
        options = try await adapter.resolve(
            pageURL: pageURL,
            requestContext: DownloadRequestContext(
                cookie: "SESSDATA=short-lived",
                referer: pageURL.absoluteString,
                userAgent: "MacIDM-Test"
            )
        )

        XCTAssertEqual(options.first?.height, 1_080)
        let requests = await client.requests
        XCTAssertTrue(requests.contains { $0.url.path == "/x/web-interface/view" })
        XCTAssertTrue(requests.contains { $0.url.path == "/x/player/wbi/playurl" })
        XCTAssertTrue(
            requests
                .filter { $0.url.host == "api.bilibili.com" }
                .allSatisfy { $0.contextOriginURL.host == "api.bilibili.com" }
        )
        let apiRequest = try XCTUnwrap(
            requests.first(where: { $0.url.path == "/x/player/wbi/playurl" })
        )
        XCTAssertEqual(apiRequest.requestContext?.cookie, "SESSDATA=short-lived")
        XCTAssertEqual(options.first?.requestContext?.referer, pageURL.absoluteString)
        XCTAssertFalse(options.first?.requestContext?.userAgent?.isEmpty ?? true)
    }

    func testResolveUsesAvidAndGuestWBIImageWhenNavReportsLoggedOut() async throws {
        let client = BilibiliFixtureClient(
            responses: [
                "/x/web-interface/view": try loadData("view"),
                "/x/web-interface/nav": Data(
                    """
                    {"code":-101,"message":"账号未登录","data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}
                    """.utf8
                ),
                "/x/player/wbi/playurl": try loadData("playurl"),
            ]
        )
        let adapter = BilibiliPlayurlAdapter(
            client: client,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        _ = try await adapter.resolve(
            pageURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!
        )

        let requests = await client.requests
        let request = try XCTUnwrap(
            requests.first(where: { $0.url.path == "/x/player/wbi/playurl" })
        )
        let queryItems = try XCTUnwrap(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.first(where: { $0.name == "avid" })?.value, "1954947383")
        XCTAssertNil(queryItems.first(where: { $0.name == "bvid" }))
        XCTAssertEqual(queryItems.first(where: { $0.name == "platform" })?.value, "pc")
        XCTAssertEqual(queryItems.first(where: { $0.name == "qn" })?.value, "120")
        XCTAssertNotNil(queryItems.first(where: { $0.name == "w_rid" })?.value)
    }

    func testLivePublicBilibiliSampleResolvesAndAcceptsAProtectedTrack() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["MACIDM_BILIBILI_LIVE_URL"],
            let pageURL = URL(string: rawURL)
        else {
            throw XCTSkip("set MACIDM_BILIBILI_LIVE_URL to run the public Bilibili smoke test")
        }

        let options = try await BilibiliPlayurlAdapter().resolve(pageURL: pageURL)
        let option = try XCTUnwrap(options.first)
        let context = try XCTUnwrap(option.requestContext)
        let response = try await URLSessionHLSResourceClient().fetch(
            HLSFetchRequest(
                url: option.videoURL,
                byteRange: HLSByteRange(length: 1_024, offset: 0),
                requestContext: context,
                contextOriginURL: pageURL
            )
        )

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertGreaterThan(response.data.count, 0)
        XCTAssertEqual(response.contentRange?.start, 0)
    }

    func testResolvePrefersUposMirrorOverMcdnBaseUrl() async throws {
        // Bilibili's default baseUrl is an mcdn/PCDN edge that only serves
        // single streams without a strong ETag; the upos mirror in backupUrl
        // supports the verified-resume range dialect and must be preferred.
        let playurl = """
            {"code":0,"data":{"dash":{"duration":60,"video":[
            {"id":80,"baseUrl":"https://xy122x227x185x45xy.mcdn.bilivideo.cn:8082/v1/x/41488810129-1-30080.m4s",
            "backupUrl":["https://edge.mountaintoys.cn/v1/x/41488810129-1-30080.m4s","https://upos-sz-estgoss.bilivideo.com/upgcxcode/x/41488810129-1-30080.m4s"],
            "bandwidth":2000000}],
            "audio":[{"id":30280,"baseUrl":"https://xy218x60x32x11xy.mcdn.bilivideo.cn:8082/v1/x/41488810129-1-30280.m4s",
            "backupUrl":["https://upos-sz-estgoss.bilivideo.com/upgcxcode/x/41488810129-1-30280.m4s"],"bandwidth":320000}]}}}
            """
        let client = BilibiliFixtureClient(responses: [
            "/x/web-interface/view": Data(#"{"code":0,"data":{"title":"T","cid":41488810129,"aid":999}}"#.utf8),
            "/x/web-interface/nav": Data(#"{"code":-101,"data":{}}"#.utf8),
            "/x/player/wbi/playurl": Data(playurl.utf8),
        ])
        let adapter = BilibiliPlayurlAdapter(client: client)
        let options = try await adapter.resolve(
            pageURL: URL(string: "https://www.bilibili.com/video/BV1G7tG6tEwL")!
        )

        XCTAssertEqual(options.first?.videoURL.host, "upos-sz-estgoss.bilivideo.com")
        XCTAssertEqual(options.first?.audioURL.host, "upos-sz-estgoss.bilivideo.com")
    }

    func testResolveKeepsOriginalMirrorOrderWithoutUposCandidate() async throws {
        // No upos mirror in the backup list: keep the original baseUrl so the
        // preference never invents a host the playurl did not offer.
        let playurl = """
            {"code":0,"data":{"dash":{"duration":60,"video":[
            {"id":80,"baseUrl":"https://xy122x227x185x45xy.mcdn.bilivideo.cn:8082/v1/x/41488810129-1-30080.m4s",
            "backupUrl":["https://edge.mountaintoys.cn/v1/x/41488810129-1-30080.m4s"],
            "bandwidth":2000000}],
            "audio":[{"id":30280,"baseUrl":"https://xy218x60x32x11xy.mcdn.bilivideo.cn:8082/v1/x/41488810129-1-30280.m4s","bandwidth":320000}]}}}
            """
        let client = BilibiliFixtureClient(responses: [
            "/x/web-interface/view": Data(#"{"code":0,"data":{"title":"T","cid":41488810129,"aid":999}}"#.utf8),
            "/x/web-interface/nav": Data(#"{"code":-101,"data":{}}"#.utf8),
            "/x/player/wbi/playurl": Data(playurl.utf8),
        ])
        let adapter = BilibiliPlayurlAdapter(client: client)
        let options = try await adapter.resolve(
            pageURL: URL(string: "https://www.bilibili.com/video/BV1G7tG6tEwL")!
        )

        XCTAssertEqual(options.first?.videoURL.host, "xy122x227x185x45xy.mcdn.bilivideo.cn")
        XCTAssertEqual(options.first?.audioURL.host, "xy218x60x32x11xy.mcdn.bilivideo.cn")
    }

    func testSecondPageRequestsItsOwnCIDAndRejectsMissingPage() async throws {
        let client = BilibiliFixtureClient(responses: [
            "/x/web-interface/view": Data(
                #"{"code":0,"data":{"title":"T","cid":111,"aid":1,"pages":[{"page":1,"cid":111},{"page":2,"cid":222}]}}"#
                    .utf8),
            "/x/web-interface/nav": Data(#"{"code":-101,"data":{}}"#.utf8),
            "/x/player/wbi/playurl": try loadData("playurl"),
        ])
        let adapter = BilibiliPlayurlAdapter(client: client)
        let selectedOptions = try await adapter.resolve(
            pageURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2")!)
        XCTAssertEqual(
            selectedOptions.first?.requestContext?.referer, "https://www.bilibili.com/video/BV1xx411c7mD?p=2")
        let requests = await client.requests
        let playurl = try XCTUnwrap(requests.first { $0.url.path == "/x/player/wbi/playurl" })
        XCTAssertEqual(
            URLComponents(url: playurl.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cid" }?
                .value, "222")
        do {
            _ = try await adapter.resolve(pageURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=3")!)
            XCTFail("missing page must not silently select first page")
        } catch BilibiliPlayurlError.invalidResponse {}
    }

    private func loadData(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Bilibili/" + name + ".json"))
    }

    private func loadObject(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: loadData(name)) as? [String: Any])
    }
}

private actor BilibiliFixtureClient: HLSResourceClient {
    let responses: [String: Data]
    private(set) var requests: [HLSFetchRequest] = []

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        requests.append(request)
        guard let data = responses[request.url.path] else {
            return HLSFetchResponse(data: Data(), finalURL: request.url, statusCode: 404)
        }
        return HLSFetchResponse(data: data, finalURL: request.url, statusCode: 200)
    }
}
