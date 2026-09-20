import XCTest

@testable import MacIDMApp

final class TaskDetailPresentationTests: XCTestCase {
    func testTransferredBytesDoNotImplySuccessAfterVerificationFailure() {
        // The same 100% byte count can precede validation, failure or success.
        // Both table and inspector use this policy, without rewriting bytes.
        XCTAssertTrue(AppTaskStatus.verifying.showsTransferProgress)
        XCTAssertFalse(AppTaskStatus.failed.showsTransferProgress)
        XCTAssertFalse(AppTaskStatus.storageError.showsTransferProgress)
        XCTAssertFalse(AppTaskStatus.completed.showsTransferProgress)
        XCTAssertTrue(AppTaskStatus.paused.showsTransferProgress)
    }

    func testLongSignedLinkSummaryExcludesCredentialsQueryAndFragment() {
        let link =
            "https://user:password@example.com/video.mp4?token="
            + String(repeating: "a", count: 4000) + "#private"
        XCTAssertEqual(TaskLinkPresentation.summary(link), "example.com/video.mp4")
    }

    func testLongPathAndNonURLTextRemainBounded() {
        let path = String(repeating: "a", count: 4000)
        XCTAssertLessThanOrEqual(TaskLinkPresentation.summary("https://example.com/" + path).count, 91)
        XCTAssertLessThanOrEqual(TaskLinkPresentation.summary(path).count, 100)
    }

    func testEncodedPathIsNotDecodedIntoLayoutControlCharacters() {
        XCTAssertEqual(
            TaskLinkPresentation.summary("https://example.com/a%0Ab%2Fc?redacted"),
            "example.com/a%0Ab%2Fc"
        )
    }
}
