import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

final class DownloadErrorAnalyzerTests: XCTestCase {

    private let context = DownloadErrorAnalyzer.Context(
        domain: "example.com",
        sourceKind: .http,
        proxyEnabled: false
    )

    // MARK: - Network layer

    func testDNSFailureIsClassifiedAsNetwork() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: URLError(.cannotFindHost),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .network)
        XCTAssertTrue(diagnosis.retryable)
        XCTAssertFalse(diagnosis.requiresSession)
    }

    func testTimeoutMentionsProxyWhenUnconfigured() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: URLError(.timedOut),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .network)
        XCTAssertTrue(diagnosis.recommendation.contains("代理"))
    }

    func testNoInternetIsNotSessionRelated() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: URLError(.notConnectedToInternet),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .network)
        XCTAssertFalse(diagnosis.requiresSession)
    }

    // MARK: - Authentication layer

    func testEngineAuthErrorRequiresSession() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.authenticationRequired,
            context: context
        )
        XCTAssertEqual(diagnosis.category, .authentication)
        XCTAssertTrue(diagnosis.requiresSession)
    }

    func testHTTP403RequiresSessionForPlainHTTP() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.httpStatus(403),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .authentication)
        XCTAssertTrue(diagnosis.requiresSession)
    }

    func testHLS403IsTreatedAsExpiredManifest() {
        let hlsContext = DownloadErrorAnalyzer.Context(domain: "example.com", sourceKind: .hls)
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.httpStatus(403),
            context: hlsContext
        )
        XCTAssertEqual(diagnosis.category, .media)
        XCTAssertFalse(diagnosis.requiresSession)
    }

    // MARK: - Resource / server layers

    func testHTTP404IsDeadLink() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.httpStatus(404),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .resource)
        XCTAssertFalse(diagnosis.retryable)
    }

    func testHTTP429IsRateLimit() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.httpStatus(429),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .rateLimit)
    }

    func testHTTP503IsServerFault() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.httpStatus(503),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .server)
        XCTAssertTrue(diagnosis.retryable)
    }

    // MARK: - Storage layer

    func testPathNotWritableIsStorage() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: IDMError.pathNotWritable("/tmp/read-only"),
            context: context
        )
        XCTAssertEqual(diagnosis.category, .storage)
    }

    // MARK: - YouTube layer

    func testBotCheckRequiresSession() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: YouTubeDownloadError.botCheckBlocked,
            context: context
        )
        XCTAssertEqual(diagnosis.category, .authentication)
        XCTAssertTrue(diagnosis.requiresSession)
    }

    func testGeoBlockIsSitePolicy() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: YouTubeDownloadError.geoBlocked,
            context: context
        )
        XCTAssertEqual(diagnosis.category, .sitePolicy)
        XCTAssertFalse(diagnosis.retryable)
    }

    func testNChallengeIsToolchain() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: YouTubeDownloadError.nChallengeFailed,
            context: context
        )
        XCTAssertEqual(diagnosis.category, .toolchain)
    }

    func testStallIsNetworkClassified() {
        let diagnosis = DownloadErrorAnalyzer.diagnose(
            error: YouTubeDownloadError.stalled,
            context: context
        )
        XCTAssertEqual(diagnosis.category, .network)
        XCTAssertTrue(diagnosis.retryable)
    }

    // MARK: - Runner signature classification

    func testClassifyProcessErrorMatchesSitePolicySignatures() {
        XCTAssertEqual(
            YouTubeDownloadRunner.classifyProcessError(
                output: "ERROR: This video is not available in your country"),
            .geoBlocked
        )
        XCTAssertEqual(
            YouTubeDownloadRunner.classifyProcessError(output: "Private video. Sign in"),
            .privateVideo
        )
        XCTAssertEqual(
            YouTubeDownloadRunner.classifyProcessError(
                output: "ERROR: Video unavailable"),
            .videoUnavailable
        )
    }

    func testClassifyProcessErrorPrefersSpecificOverGeneric() {
        // Bot-check wording must win over the generic failure bucket.
        XCTAssertEqual(
            YouTubeDownloadRunner.classifyProcessError(
                output: "Sign in to confirm you're not a bot"),
            .botCheckBlocked
        )
    }

    func testClassifyProcessErrorFallsBackToGeneric() {
        XCTAssertEqual(
            YouTubeDownloadRunner.classifyProcessError(output: "some unknown failure"),
            .processFailed
        )
    }

    // MARK: - Fallback

    func testUnknownErrorStillProducesDiagnosis() {
        struct OpaqueError: Error {}
        let diagnosis = DownloadErrorAnalyzer.diagnose(error: OpaqueError(), context: context)
        XCTAssertEqual(diagnosis.category, .unknown)
        XCTAssertFalse(diagnosis.recommendation.isEmpty)
    }
}
