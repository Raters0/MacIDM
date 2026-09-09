import Foundation
import XCTest

@testable import MacIDMApp

final class YTDlpProgressParserTests: XCTestCase {
    func testParseTemplateLine() {
        let line = "download:1048576|10485760|10485760|524288"
        let sample = YTDlpProgressParser.parseTemplateLine(line)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample?.received, 1048576)
        XCTAssertEqual(sample?.total, 10485760)
        XCTAssertEqual(sample?.speed, 524288)

        let withoutDownloadPrefix = "2097152|10485760||1048576"
        let sample2 = YTDlpProgressParser.parseTemplateLine(withoutDownloadPrefix)
        XCTAssertEqual(sample2?.received, 2097152)
        XCTAssertEqual(sample2?.total, 10485760)
        XCTAssertEqual(sample2?.speed, 1048576)

        let invalid = "download:NA|NA"
        XCTAssertNil(YTDlpProgressParser.parseTemplateLine(invalid))
    }

    func testParseDefaultProgressLine() {
        let line = "[download]  12.3% of ~28.53MiB at 499.66KiB/s ETA 00:54"
        let sample = YTDlpProgressParser.parseDefaultProgressLine(line)
        XCTAssertNotNil(sample)
        XCTAssertTrue(sample?.isEstimatedTotal == true)
        XCTAssertEqual(sample?.percent, 12.3)
        XCTAssertEqual(sample?.total, Int64(28.53 * 1024 * 1024))
        XCTAssertEqual(sample?.speed, 499.66 * 1024)

        let finishedLine = "[download] 100% of 15.00MiB at 1.20MiB/s ETA 00:00"
        let finishedSample = YTDlpProgressParser.parseDefaultProgressLine(finishedLine)
        XCTAssertNotNil(finishedSample)
        XCTAssertFalse(finishedSample?.isEstimatedTotal == true)
        XCTAssertEqual(finishedSample?.percent, 100.0)
        XCTAssertEqual(finishedSample?.total, Int64(15.0 * 1024 * 1024))

        let unknownSizeLine = "[download]   0.0% of Unknown at 50.00KiB/s"
        let unknownSample = YTDlpProgressParser.parseDefaultProgressLine(unknownSizeLine)
        XCTAssertNotNil(unknownSample)
        XCTAssertNil(unknownSample?.received)
        XCTAssertNil(unknownSample?.total)
        XCTAssertEqual(unknownSample?.speed, 50.0 * 1024)
    }

    func testByteMultiplier() {
        XCTAssertEqual(YTDlpProgressParser.byteMultiplier("B"), 1)
        XCTAssertEqual(YTDlpProgressParser.byteMultiplier("KiB"), 1024)
        XCTAssertEqual(YTDlpProgressParser.byteMultiplier("MiB"), 1024 * 1024)
        XCTAssertEqual(YTDlpProgressParser.byteMultiplier("GiB"), 1024 * 1024 * 1024)
        XCTAssertEqual(YTDlpProgressParser.byteMultiplier("TiB"), 1024 * 1024 * 1024 * 1024)
    }

    func testStagedOverallFraction() {
        var highest: Double = 0

        // Format 0 (Video track, max 82%)
        let f0Mid = YTDlpProgressParser.stagedOverallFraction(
            received: 50,
            total: 100,
            formatIndex: 0,
            highestOverallFraction: &highest
        )
        XCTAssertEqual(f0Mid, 0.41)

        let f0Done = YTDlpProgressParser.stagedOverallFraction(
            received: 100,
            total: 100,
            formatIndex: 0,
            highestOverallFraction: &highest
        )
        XCTAssertEqual(f0Done, 0.82)

        // Format 1 (Audio track, 82% -> 98%)
        let f1Mid = YTDlpProgressParser.stagedOverallFraction(
            received: 50,
            total: 100,
            formatIndex: 1,
            highestOverallFraction: &highest
        )
        XCTAssertEqual(f1Mid, 0.82 + 0.5 * 0.16)

        let f1Done = YTDlpProgressParser.stagedOverallFraction(
            received: 100,
            total: 100,
            formatIndex: 1,
            highestOverallFraction: &highest
        )
        XCTAssertEqual(f1Done, 0.98)
    }
}
