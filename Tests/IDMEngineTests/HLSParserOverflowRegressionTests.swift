import Foundation
import XCTest

@testable import IDMEngine

final class HLSParserOverflowRegressionTests: XCTestCase {
    func testMalformedHLSRangeMustThrowInsteadOfCrashing() throws {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:2@9223372036854775807
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)) {
            error in
            guard let parserError = error as? HLSParserError else {
                return XCTFail("Expected HLSParserError but got \(error)")
            }
            if case .invalidNumber = parserError {
                // Pass: invalidNumber error description
            } else {
                XCTFail("Expected .invalidNumber but got \(parserError)")
            }
        }
    }

    func testMultiSegmentAccumulationOverflowThrows() throws {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:5@9223372036854775800
            segment1.ts
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:10
            segment2.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)) {
            error in
            XCTAssertTrue(error is HLSParserError)
        }
    }

    func testInitializationSegmentByteRangeOverflowThrows() throws {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="2@9223372036854775807"
            #EXTINF:4.0,
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)) {
            error in
            XCTAssertTrue(error is HLSParserError)
        }
    }

    func testZeroLengthByteRangeThrows() throws {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:0@100
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!))
    }

    func testNegativeOffsetOrLengthThrows() throws {
        let textNegativeOffset = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:10@-5
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(
            try HLSParser().parse(textNegativeOffset, baseURL: URL(string: "https://example.com/a.m3u8")!))

        let textNegativeLength = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:-10@5
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(
            try HLSParser().parse(textNegativeLength, baseURL: URL(string: "https://example.com/a.m3u8")!))
    }

    func testNormalByteRangePlaylistParsesWithoutRegression() throws {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:1000@0
            segment.ts
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:2000
            segment.ts
            #EXT-X-ENDLIST
            """
        let playlist = try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)
        guard case .media(let media) = playlist else {
            return XCTFail("Expected media playlist")
        }
        XCTAssertEqual(media.segments.count, 2)
        XCTAssertEqual(media.segments[0].byteRange, HLSByteRange(length: 1000, offset: 0))
        XCTAssertEqual(media.segments[1].byteRange, HLSByteRange(length: 2000, offset: 1000))
    }

    func testNearMaxValidByteRangeSucceeds() throws {
        // Int64.max is 9223372036854775807.
        // 9223372036854775707 + 100 = 9223372036854775807 (exact upper boundary)
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:100@9223372036854775707
            segment.ts
            #EXT-X-ENDLIST
            """
        let playlist = try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)
        guard case .media(let media) = playlist else {
            return XCTFail("Expected media playlist")
        }
        XCTAssertEqual(media.segments.count, 1)
        XCTAssertEqual(media.segments[0].byteRange, HLSByteRange(length: 100, offset: 9223372036854775707))
    }

    func testNearMaxOverflowByteRangeThrows() throws {
        // 9223372036854775707 + 101 = 9223372036854775808 (overflow by 1)
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:101@9223372036854775707
            segment.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(try HLSParser().parse(text, baseURL: URL(string: "https://example.com/a.m3u8")!)) {
            error in
            XCTAssertTrue(error is HLSParserError)
        }
    }

    func testDASHTimelineRepeatCountNearMaxThrowsInsteadOfCrashing() throws {
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1000">
                    <SegmentTemplate timescale="1" media="seg$Number$.m4s" startNumber="0">
                      <SegmentTimeline>
                        <S t="0" d="1" r="9223372036854775807"/>
                      </SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        XCTAssertThrowsError(
            try DASHParser().parse(manifest, baseURL: URL(string: "https://example.com/manifest.mpd")!)
        ) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .segmentLimitExceeded = dashError {
                // Pass: segmentLimitExceeded error correctly caught instead of runtime trap
            } else {
                XCTFail("Expected .segmentLimitExceeded but got \(dashError)")
            }
        }
    }

    func testDASHTimelineStartNumberNearMaxOverflowThrowsInsteadOfCrashing() throws {
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1000">
                    <SegmentTemplate timescale="1" media="seg$Number$.m4s" startNumber="9223372036854775807">
                      <SegmentTimeline>
                        <S t="0" d="1"/>
                        <S t="1" d="1"/>
                      </SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        XCTAssertThrowsError(
            try DASHParser().parse(manifest, baseURL: URL(string: "https://example.com/manifest.mpd")!)
        ) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .invalidNumber = dashError {
                // Pass: invalidNumber caught instead of runtime trap
            } else {
                XCTFail("Expected .invalidNumber but got \(dashError)")
            }
        }
    }

    func testDASHByteRangeNearMaxOverflowThrows() throws {
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1000">
                    <SegmentList>
                      <Initialization range="0-9223372036854775807"/>
                      <SegmentURL media="seg1.m4s"/>
                    </SegmentList>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        XCTAssertThrowsError(
            try DASHParser().parse(manifest, baseURL: URL(string: "https://example.com/manifest.mpd")!)
        ) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .invalidNumber = dashError {
                // Pass: invalidNumber caught
            } else {
                XCTFail("Expected .invalidNumber but got \(dashError)")
            }
        }
    }
}
