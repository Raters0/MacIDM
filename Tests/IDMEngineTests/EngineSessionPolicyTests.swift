import Foundation
import XCTest

@testable import IDMEngine

final class EngineSessionPolicyTests: XCTestCase {
    func testMakeConfigurationAppliesRequiredInvariants() {
        let config = EngineSessionPolicy.makeConfiguration(
            requestTimeout: 15,
            resourceTimeout: 30,
            proxyDictionary: ["testProxyKey": "testProxyVal"]
        )

        // Ephemeral in-memory configuration invariants
        XCTAssertNil(config.urlCache, "urlCache must strictly be nil")
        XCTAssertEqual(
            config.requestCachePolicy,
            .reloadIgnoringLocalCacheData,
            "requestCachePolicy must reloadIgnoringLocalCacheData"
        )
        XCTAssertFalse(
            config.httpShouldSetCookies,
            "httpShouldSetCookies must be false to prevent system cookie store contamination"
        )
        XCTAssertEqual(config.timeoutIntervalForRequest, 15)
        XCTAssertEqual(config.timeoutIntervalForResource, 30)
        XCTAssertEqual(
            config.connectionProxyDictionary?["testProxyKey"] as? String,
            "testProxyVal"
        )
    }

    func testMakeConfigurationDefaultValues() {
        let config = EngineSessionPolicy.makeConfiguration()

        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.timeoutIntervalForRequest, EngineSessionPolicy.defaultRequestTimeout)
        XCTAssertEqual(config.timeoutIntervalForResource, EngineSessionPolicy.defaultResourceTimeout)
    }

    func testSanitizeRedirectRequestSameOriginPreservesCredentials() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/stream/index.m3u8"))
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/stream/segment-1.ts"))

        var request = URLRequest(url: targetURL)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("session=123", forHTTPHeaderField: "Cookie")
        request.setValue("https://example.com/player", forHTTPHeaderField: "Referer")

        EngineSessionPolicy.sanitizeRedirectRequest(
            &request,
            originalURL: originalURL,
            targetURL: targetURL
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/player")
    }

    func testSanitizeRedirectRequestCrossOriginStripsAuthorizationAndCookie() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/video/page"))
        let targetURL = try XCTUnwrap(URL(string: "https://cdn.example.org/video.mp4"))

        var request = URLRequest(url: targetURL)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("session=123", forHTTPHeaderField: "Cookie")
        request.setValue("https://example.com/video/page", forHTTPHeaderField: "Referer")

        // Default: preserveReferer = true for media CDN playback
        EngineSessionPolicy.sanitizeRedirectRequest(
            &request,
            originalURL: originalURL,
            targetURL: targetURL,
            preserveReferer: true
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/video/page")

        // If preserveReferer = false, Referer is also stripped
        var strictRequest = URLRequest(url: targetURL)
        strictRequest.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        strictRequest.setValue("session=123", forHTTPHeaderField: "Cookie")
        strictRequest.setValue("https://example.com/video/page", forHTTPHeaderField: "Referer")

        EngineSessionPolicy.sanitizeRedirectRequest(
            &strictRequest,
            originalURL: originalURL,
            targetURL: targetURL,
            preserveReferer: false
        )

        XCTAssertNil(strictRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(strictRequest.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(strictRequest.value(forHTTPHeaderField: "Referer"))
    }

    func testSanitizeRedirectRequestHTTPSDowngradeStripsReferer() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://secure.example.com/watch"))
        let targetURL = try XCTUnwrap(URL(string: "http://secure.example.com/fallback"))

        var request = URLRequest(url: targetURL)
        request.setValue("https://secure.example.com/watch", forHTTPHeaderField: "Referer")

        EngineSessionPolicy.sanitizeRedirectRequest(
            &request,
            originalURL: originalURL,
            targetURL: targetURL,
            preserveReferer: true
        )

        XCTAssertNil(
            request.value(forHTTPHeaderField: "Referer"),
            "HTTPS -> HTTP downgrade must strictly strip Referer to prevent plaintext URL leakage"
        )
    }

    func testMakeConfigurationExplicitNilProxyDoesNotInjectDownloadProxy() {
        let config = EngineSessionPolicy.makeConfiguration(
            requestTimeout: 15,
            resourceTimeout: 30,
            proxyDictionary: nil
        )

        XCTAssertNil(
            config.connectionProxyDictionary,
            "Passing explicit nil proxyDictionary must NOT inject default DownloadProxyPolicy dictionary"
        )
    }
}
