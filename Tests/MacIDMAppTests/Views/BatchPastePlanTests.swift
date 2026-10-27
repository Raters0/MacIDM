import IDMEngine
import XCTest

@testable import MacIDMApp

final class BatchPastePlanTests: XCTestCase {
    func testStreamManifestsRunThroughTheStreamPipelineAsMP4() throws {
        let hls = NewDownloadView.batchPlan(for: try XCTUnwrap(URL(string: "https://cdn.example.com/live/master.m3u8")))
        XCTAssertEqual(hls.sourceKind, .hls)
        XCTAssertEqual(hls.filename, "master.mp4")

        let dash = NewDownloadView.batchPlan(for: try XCTUnwrap(URL(string: "https://cdn.example.com/v/manifest.mpd")))
        XCTAssertEqual(dash.sourceKind, .dash)
        XCTAssertEqual(dash.filename, "manifest.mp4")
    }

    func testPlainFilesKeepTheirOwnNameAsHTTP() throws {
        let plan = NewDownloadView.batchPlan(for: try XCTUnwrap(URL(string: "https://example.com/files/report.pdf")))
        XCTAssertEqual(plan.sourceKind, .http)
        XCTAssertEqual(plan.filename, "report.pdf")
    }
}
