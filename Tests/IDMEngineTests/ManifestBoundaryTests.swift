import XCTest

@testable import IDMEngine

/// Malicious/malformed manifests must never trap the parser: Int64 overflow
/// and Int64(Double) range errors are runtime crashes, and manifests come
/// from the network (sniffing), so they are attacker-controlled input.
final class ManifestBoundaryTests: XCTestCase {
    private let baseURL = URL(string: "https://cdn.example.test/manifest.mpd")!

    private func dashXML(_ body: String, duration: String = "PT6S") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="\(duration)">
          <BaseURL>https://cdn.example.test/vod/</BaseURL>
          <Period id="p0">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="video-720" bandwidth="1500000" width="1280" height="720" codecs="avc1.4d401f">
                \(body)
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    private func parseDASH(_ body: String, duration: String = "PT6S") throws {
        _ = try parseDASHReturning(body, duration: duration)
    }

    private func parseDASHReturning(
        _ body: String,
        duration: String = "PT6S"
    ) throws -> DASHManifest {
        let parser = DASHParser()
        return try parser.parse(dashXML(body, duration: duration), baseURL: baseURL)
    }

    // MARK: - R9-2: duration/timescale/startNumber boundaries

    func testHugePresentationDurationDoesNotTrap() {
        // P3e9D days-worth of seconds × timescale 90000 overflows Int64 in
        // the naive conversion; the parser must throw, not trap.
        XCTAssertThrowsError(
            try parseDASH(
                """
                <SegmentTemplate timescale="90000" duration="2" startNumber="1" \
                media="$RepresentationID$-$Number%05d$.m4s" \
                initialization="$RepresentationID$-init.m4s" />
                """,
                duration: "P1000000000000D"
            )
        )
    }

    func testOverflowTimescaleIsRejected() {
        XCTAssertThrowsError(
            try parseDASH(
                """
                <SegmentTemplate timescale="9223372036854775807" duration="2" startNumber="1" \
                media="$RepresentationID$-$Number%05d$.m4s" \
                initialization="$RepresentationID$-init.m4s" />
                """
            )
        )
    }

    func testNegativeHugeStartNumberIsRejected() {
        XCTAssertThrowsError(
            try parseDASH(
                """
                <SegmentTemplate timescale="1" duration="2" startNumber="-5" \
                media="$RepresentationID$-$Number%05d$.m4s" \
                initialization="$RepresentationID$-init.m4s" />
                """
            )
        )
    }

    func testNearMaxDurationWithTimescaleThrowsInsteadOfTrapping() {
        // PT2000000000S × timescale 4e9 overflows Int64 in the naive
        // Int64(duration * timescale) conversion.
        XCTAssertThrowsError(
            try parseDASH(
                """
                <SegmentTemplate timescale="4000000000" duration="2" startNumber="1" \
                media="$RepresentationID$-$Number%05d$.m4s" \
                initialization="$RepresentationID$-init.m4s" />
                """,
                duration: "PT2000000000S"
            )
        )
    }

    func testSegmentTimelineHugeRepeatCountIsRejected() {
        XCTAssertThrowsError(
            try parseDASHReturning(
                """
                <SegmentTemplate timescale="1" media="$Number$.m4s" initialization="init.m4s">
                  <SegmentTimeline><S d="1000" r="9223372036854775807"/></SegmentTimeline>
                </SegmentTemplate>
                """
            )
        ) { error in
            XCTAssertEqual(error as? DASHParserError, .segmentLimitExceeded)
        }
    }

    func testTimelineCapRejectsExcessWithoutTruncating() throws {
        func xml(_ timeline: String) -> String {
            dashXML(
                "<SegmentTemplate media=\"$Number$.m4s\"><SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate>"
            )
        }
        let parser = DASHParser(maximumSegmentsPerRepresentation: 3)
        let accepted = try parser.parse(xml("<S d=\"1\" r=\"2\"/>"), baseURL: baseURL)
        XCTAssertEqual(accepted.representations[0].segments.count, 3)
        for body in ["<S d=\"1\" r=\"3\"/>", "<S d=\"1\"/><S d=\"1\" r=\"2\"/>"] {
            XCTAssertThrowsError(try parser.parse(xml(body), baseURL: baseURL)) { error in
                XCTAssertEqual(error as? DASHParserError, .segmentLimitExceeded)
            }
        }
    }

    func testSegmentTimelineNegativeTIsRejected() {
        XCTAssertThrowsError(
            try parseDASH(
                """
                <SegmentTemplate timescale="1" media="$RepresentationID$-$Number%05d$.m4s" \
                initialization="$RepresentationID$-init.m4s">
                  <SegmentTimeline><S t="-4" d="1000"/></SegmentTimeline>
                </SegmentTemplate>
                """
            )
        )
    }

    // MARK: - R9-3: byte range length saturation

    func testUnrepresentableRangeLengthIsInvalidInsteadOfTrapping() {
        let range = DASHByteRange(start: 0, endInclusive: Int64.max)
        XCTAssertEqual(range.length, 0)
        XCTAssertEqual(DASHByteRange(start: 10, endInclusive: 19).length, 10)
    }

    // MARK: - R9-5: template width clamp

    func testTemplateWidthIsClamped() throws {
        let manifest = try parseDASHReturning(
            """
            <SegmentTemplate timescale="1" duration="5" startNumber="1" \
            media="s$Number%010000000000d$.m4s" \
            initialization="$RepresentationID$-init.m4s" />
            """
        )
        let url = manifest.representations[0].segments[0].url.absoluteString
        // The oversized width must not be honored: no billion-zero padding.
        XCTAssertFalse(url.contains("0000000000000"))
        XCTAssertTrue(url.contains(".m4s"))
    }
}

/// R10-1 regression: Double(Int64.max) IS 2^63 — a scaled product landing
/// exactly on 2^63 must throw, not trap the Int64 conversion.
final class DASHDurationExactBoundaryTests: XCTestCase {
    private let baseURL = URL(string: "https://cdn.example.test/manifest.mpd")!

    func testScaledDurationLandingExactlyOn2ToThe63Throws() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT9223372036.854776S">
              <BaseURL>https://cdn.example.test/vod/</BaseURL>
              <Period id="p0">
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="video-720" bandwidth="1500000" width="1280" height="720" codecs="avc1.4d401f">
                    <SegmentTemplate timescale="1000000000" duration="1" startNumber="1" media="s$Number$.m4s" initialization="i.m4s" />
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        XCTAssertThrowsError(try DASHParser().parse(xml, baseURL: baseURL))
    }
}
