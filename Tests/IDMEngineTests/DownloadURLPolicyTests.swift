import XCTest

@testable import IDMEngine

/// Shared URL persistence policy: the CLI and the App previously kept
/// drifting copies. The key regression protected here is that a fragment
/// (page anchor) is NOT transient material — it never reaches the server.
final class DownloadURLPolicyTests: XCTestCase {
    func testFragmentOnlyURLIsNotTransient() {
        XCTAssertFalse(DownloadURLPolicy.hasTransientMaterial("https://example.com/guide#section-2"))
    }

    func testQueryAndCredentialsAreTransient() {
        XCTAssertTrue(DownloadURLPolicy.hasTransientMaterial("https://example.com/file.zip?token=abc"))
        XCTAssertTrue(DownloadURLPolicy.hasTransientMaterial("https://user:pass@example.com/file.zip"))
        XCTAssertTrue(DownloadURLPolicy.hasTransientMaterial("https://example.com/a?q=1#frag"))
    }

    func testUnparseableURLIsNotTransientButRedactsToPlaceholder() {
        XCTAssertFalse(DownloadURLPolicy.hasTransientMaterial("not a url"))
        XCTAssertEqual(DownloadURLPolicy.redactedForStorage("not a url"), "https://invalid/")
    }

    func testRedactionStripsCredentialsQueryAndFragmentButKeepsPath() {
        XCTAssertEqual(
            DownloadURLPolicy.redactedForStorage("https://user:pw@example.com/a/b.zip?sig=x#top"),
            "https://example.com/a/b.zip"
        )
        XCTAssertEqual(
            DownloadURLPolicy.redactedForStorage("https://example.com/plain.zip"),
            "https://example.com/plain.zip"
        )
    }

    func testPartialArtifactURLsMatchEngineNamingContract() {
        let destination = URL(fileURLWithPath: "/dl/Show/video.mp4")
        let id = UUID(uuidString: "AB4B4230-C0DF-4A62-A47C-FE4A8DD97E6A")!
        let urls = DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id)
        let names = urls.map(\.lastPathComponent)
        XCTAssertEqual(
            names,
            [
                ".video.mp4.\(id.uuidString).macidm.download",
                ".video.mp4.\(id.uuidString).macidm",
                ".\(id.uuidString).macidm.hls-input.ts",
                ".\(id.uuidString).macidm.dash-pair",
                ".\(id.uuidString).macidm.youtube",
            ]
        )
        XCTAssertTrue(urls.allSatisfy { $0.deletingLastPathComponent().path == "/dl/Show" })
    }
}
