import IDMEngine
import MacIDMBridge
import XCTest

@testable import MacIDMApp

/// Locks the naming-trust policy boundaries extracted from the AppModel
/// aggregate (technical spec §8.1): unknown or user-edited provenance never
/// gains title authority, and semantic-title inputs are unpacked defensively.
final class BrowserDownloadNamingPolicyTests: XCTestCase {
    private func payload(_ pairs: [String: JSONValue]) -> [String: JSONValue] {
        pairs
    }

    func testMissingHintSourceDegradesToURLPath() {
        let source = BrowserDownloadNamingPolicy.filenameHintSource(from: payload([:]))
        XCTAssertEqual(source, .urlPath)
    }

    func testUnknownHintSourceDegradesToURLPath() {
        let source = BrowserDownloadNamingPolicy.filenameHintSource(
            from: payload(["filenameHintSource": .string("timeMachineRestored")]))
        XCTAssertEqual(source, .urlPath)
    }

    func testUserEditedHintSourceNeverOutranksTitles() {
        let source = BrowserDownloadNamingPolicy.filenameHintSource(
            from: payload(["filenameHintSource": .string("userEdited")]))
        XCTAssertEqual(source, .urlPath)
    }

    func testRecognizedHintSourceIsHonored() {
        let source = BrowserDownloadNamingPolicy.filenameHintSource(
            from: payload(["filenameHintSource": .string("browserResolved")]))
        XCTAssertEqual(source, .browserResolved)
    }

    func testTitleCandidatesUnpacksTextAndScopeDefensively() {
        let payload = payload([
            "titleCandidates": .array([
                .object(["text": .string("  完整版《犯罪都市》天花板  "), "scope": .string("card")]),
                .object(["text": .string("x")]),
                .object(["text": .string("页级标题 — second entry")]),
                .string("not-an-object"),
            ])
        ])
        let candidates = BrowserDownloadNamingPolicy.titleCandidates(from: payload)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].text, "完整版《犯罪都市》天花板")
        XCTAssertEqual(candidates[0].scope, "card")
        XCTAssertEqual(candidates[1].scope, "page")
    }

    func testTitleCandidatesAbsentYieldsEmpty() {
        XCTAssertTrue(BrowserDownloadNamingPolicy.titleCandidates(from: payload([:])).isEmpty)
    }

    func testPositiveSizeRejectsUnknownMarkers() {
        XCTAssertNil(BrowserDownloadNamingPolicy.positiveSize(nil))
        XCTAssertNil(BrowserDownloadNamingPolicy.positiveSize(0))
        XCTAssertNil(BrowserDownloadNamingPolicy.positiveSize(-1))
        XCTAssertEqual(BrowserDownloadNamingPolicy.positiveSize(512), 512)
    }

    func testPageTitleHostsPairsResourceAndRefererHosts() {
        let hosts = BrowserDownloadNamingPolicy.pageTitleHosts(
            url: URL(string: "https://cdn.example.com/video/a.mp4")!,
            requestContext: nil)
        XCTAssertEqual(hosts[0], "cdn.example.com")
        XCTAssertNil(hosts[1])

        let context = DownloadRequestContext(
            referer: "https://www.example.com/watch")
        let paired = BrowserDownloadNamingPolicy.pageTitleHosts(
            url: URL(string: "https://cdn.example.com/video/a.mp4")!,
            requestContext: context)
        XCTAssertEqual(paired[1], "www.example.com")
    }
}
