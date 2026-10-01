import IDMEngine
import XCTest

@testable import MacIDMApp

/// chrome-extension-spec/technical-spec §3.1 的直播不变量在缓存上必须保持
/// fail-closed：只有「明确可下载」的判定可被复用，凭据形态不同不得互用，
/// 原始 Cookie 绝不进缓存键，表有上限且会过期。
final class YouTubeLiveStatusCacheTests: XCTestCase {
    private let watchURL = URL(string: "https://www.youtube.com/watch?v=abcdef12345")!

    private func key(cookie: String?) -> YouTubeLiveStatusCache.Key? {
        YouTubeLiveStatusCache.key(url: watchURL, cookie: cookie)
    }

    func testKeyUsesVideoIDSoQueryAndQualitySelectionShareOneVerdict() throws {
        let plain = try XCTUnwrap(key(cookie: nil))
        let withParams = try XCTUnwrap(
            YouTubeLiveStatusCache.key(
                url: URL(string: "https://www.youtube.com/watch?v=abcdef12345&t=60s#height=1080&itag=137")!,
                cookie: nil
            ))
        XCTAssertEqual(plain, withParams, "同一视频的不同参数/画质选择必须复用同一判定")
    }

    func testKeyIsNilWhenTheURLCarriesNoRecognizableVideoID() {
        XCTAssertNil(YouTubeLiveStatusCache.key(url: URL(string: "https://www.youtube.com/")!, cookie: nil))
        XCTAssertNil(
            YouTubeLiveStatusCache.key(url: URL(string: "https://example.com/watch?v=abcdef12345")!, cookie: nil),
            "非 YouTube 主机不得进入缓存键"
        )
    }

    func testCookieShapeIsPartOfTheKeyAndRawCookieIsNeverStored() throws {
        let anonymous = try XCTUnwrap(key(cookie: nil))
        let authorized = try XCTUnwrap(key(cookie: "SID=secret-value"))
        let otherSession = try XCTUnwrap(key(cookie: "SID=other-secret"))
        XCTAssertNotEqual(anonymous, authorized, "匿名判定不得用于已授权请求")
        XCTAssertNotEqual(authorized, otherSession, "不同会话不得互用判定")
        XCTAssertFalse(
            authorized.cookieFingerprint?.contains("secret") ?? true,
            "键里只能存放单向指纹"
        )

        let cache = YouTubeLiveStatusCache()
        cache.confirm(authorized)
        XCTAssertTrue(cache.isConfirmed(authorized))
        XCTAssertFalse(cache.isConfirmed(anonymous))
        XCTAssertFalse(cache.isConfirmed(otherSession))
    }

    func testVerdictExpiresWhenItStaysLongerThanTheWindow() throws {
        let cache = YouTubeLiveStatusCache(ttl: 60)
        let target = try XCTUnwrap(key(cookie: nil))
        let start = Date(timeIntervalSince1970: 10_000)
        cache.confirm(target, now: start)
        XCTAssertTrue(cache.isConfirmed(target, now: start.addingTimeInterval(59)))
        XCTAssertFalse(cache.isConfirmed(target, now: start.addingTimeInterval(61)))
    }

    func testConfirmationRefreshesTheWindow() throws {
        let cache = YouTubeLiveStatusCache(ttl: 100)
        let target = try XCTUnwrap(key(cookie: nil))
        let start = Date(timeIntervalSince1970: 20_000)
        cache.confirm(target, now: start)
        cache.confirm(target, now: start.addingTimeInterval(90))
        XCTAssertTrue(
            cache.isConfirmed(target, now: start.addingTimeInterval(150)),
            "重新确认（解析→下载）应从最新证据重新计时"
        )
    }

    func testTableStaysBoundedByDroppingOldestVerdictsFirst() throws {
        let cache = YouTubeLiveStatusCache(ttl: 1_000, maxEntries: 3)
        let start = Date(timeIntervalSince1970: 50_000)
        for index in 0..<3 {
            cache.confirm(
                YouTubeLiveStatusCache.Key(videoID: "video\(index)", cookieFingerprint: nil),
                now: start.addingTimeInterval(TimeInterval(index))
            )
        }
        XCTAssertEqual(cache.count, 3)

        cache.confirm(
            YouTubeLiveStatusCache.Key(videoID: "video-extra", cookieFingerprint: nil),
            now: start.addingTimeInterval(3)
        )
        XCTAssertLessThanOrEqual(cache.count, 3)
        XCTAssertFalse(
            cache.isConfirmed(
                YouTubeLiveStatusCache.Key(videoID: "video0", cookieFingerprint: nil),
                now: start.addingTimeInterval(4)
            ),
            "超限时先淘汰最旧的判定"
        )
        XCTAssertTrue(
            cache.isConfirmed(
                YouTubeLiveStatusCache.Key(videoID: "video-extra", cookieFingerprint: nil),
                now: start.addingTimeInterval(4)
            )
        )
    }

    // MARK: - 画质列表复用（同一判定窗口内不重复解析）

    /// 变体 URL 是页面 URL 加 MacIDM 自有选择 fragment，不含签名直链，
    /// 因此整个窗口内可安全复用。
    private func qualityList(height: Int, itag: Int) -> [MediaVariant] {
        [
            MediaVariant(
                url: URL(
                    string: "https://www.youtube.com/watch?v=abcdef12345#height=\(height)&itag=\(itag)"
                )!,
                label: "\(height)P",
                bandwidth: 1_500_000,
                width: height * 16 / 9,
                height: height,
                codecs: "avc1",
                estimatedSize: 10_000_000,
                fileExtension: "mp4",
                duration: 60
            )
        ]
    }

    func testInspectionStoresItsQualityListAlongsideTheVerdict() throws {
        let cache = YouTubeLiveStatusCache()
        let target = try XCTUnwrap(key(cookie: nil))
        XCTAssertNil(cache.cachedVariants(target), "未确认的视频不得有画质列表")

        cache.confirm(target, variants: qualityList(height: 1080, itag: 137))
        XCTAssertTrue(cache.isConfirmed(target))
        let stored = try XCTUnwrap(cache.cachedVariants(target))
        XCTAssertEqual(stored.map(\.label), ["1080P"])
        XCTAssertEqual(stored.map(\.url), qualityList(height: 1080, itag: 137).map(\.url))
    }

    func testGateOnlyConfirmationKeepsAnExistingQualityList() throws {
        let cache = YouTubeLiveStatusCache()
        let target = try XCTUnwrap(key(cookie: nil))
        cache.confirm(target, variants: qualityList(height: 720, itag: 22))

        // 下载路径只确认判定、不带画质：不得把已存的列表抹掉。
        cache.confirm(target)
        XCTAssertEqual(cache.cachedVariants(target)?.map(\.label), ["720P"])
        XCTAssertTrue(cache.isConfirmed(target))
    }

    func testQualityListExpiresWithTheVerdict() throws {
        let cache = YouTubeLiveStatusCache(ttl: 60)
        let target = try XCTUnwrap(key(cookie: nil))
        let start = Date(timeIntervalSince1970: 20_000)
        cache.confirm(target, variants: qualityList(height: 1080, itag: 137), now: start)

        XCTAssertNotNil(cache.cachedVariants(target, now: start.addingTimeInterval(59)))
        XCTAssertNil(cache.cachedVariants(target, now: start.addingTimeInterval(61)), "窗口过期后必须重新解析")
    }

    func testQualityListIsBoundToTheCredentialShape() throws {
        let cache = YouTubeLiveStatusCache()
        let authorized = try XCTUnwrap(key(cookie: "SID=secret-value"))
        let anonymous = try XCTUnwrap(key(cookie: nil))
        cache.confirm(authorized, variants: qualityList(height: 1080, itag: 137))

        XCTAssertNotNil(cache.cachedVariants(authorized))
        XCTAssertNil(cache.cachedVariants(anonymous), "已授权解析出的画质不得用于匿名请求")
    }
}
