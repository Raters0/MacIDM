import Foundation
import XCTest

@testable import IDMEngine

/// Regression: when DASHParser converted the Double result of
/// presentationDuration × timescale to Int64, the old upper-bound check
/// `rawX <= Double(Int64.max)` (Double cannot represent Int64.max exactly and
/// rounds it up to 2^63) let unrepresentable values through, and the
/// non-failing conversion `Int64(_:)` then trapped at runtime (signal 5)
/// instead of throwing a catchable error.
/// The fix switched to the failable `Int64(exactly:)` conversion, throwing
/// DASHParserError on out-of-range values.
///
/// Before the fix these cases crashed the test process (unable to report a
/// failure); after it they throw catchable errors → Before-Fail(crash)/After-Pass.
final class DASHParserFloatConversionRegressionTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com/manifest.mpd")!

    private func manifest(segmentTemplateBody: String) -> String {
        """
        <MPD type="static" mediaPresentationDuration="PT1S">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v1" bandwidth="1000">
        \(segmentTemplateBody)
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    // Path 1: duration template without SegmentTimeline (rawUnits → totalUnits conversion in DASHParser.swift)
    func testDurationTemplateTimescaleOverflowThrowsInsteadOfTrapping() {
        // presentationDuration=1.0, timescale=Int64.max → 1.0 * Double(Int64.max) rounds up to 2^63.
        // Before the fix: the guard let it through (2^63 <= Double(Int64.max) is true) → Int64(2^63) traps.
        // After the fix: Int64(exactly: 2^63) == nil → throws .invalidNumber.
        let text = manifest(
            segmentTemplateBody:
                #"        <SegmentTemplate timescale="9223372036854775807" duration="1" media="seg$Number$.m4s" startNumber="0"/>"#
        )
        XCTAssertThrowsError(try DASHParser().parse(text, baseURL: baseURL)) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .invalidNumber = dashError {
                // Expected: out-of-range is safely rejected as a catchable error
            } else {
                XCTFail("Expected .invalidNumber but got \(dashError)")
            }
        }
    }

    // Path 2: SegmentTimeline negative repeat count determines the end boundary from
    // presentationDuration (rawTotal → total conversion)
    func testTimelineNegativeRepeatDurationOverflowThrowsInsteadOfTrapping() {
        // A single S r="-1" with no later explicit time boundary → takes the presentationDuration branch.
        // presentationDuration=1.0, timescale=Int64.max → rawTotal=2^63.
        // Before the fix: Int64(2^63) traps; after: Int64(exactly:) == nil → throws .invalidDuration.
        let text = manifest(
            segmentTemplateBody: """
                        <SegmentTemplate timescale="9223372036854775807" media="seg$Number$.m4s" startNumber="0">
                          <SegmentTimeline>
                            <S t="0" d="1" r="-1"/>
                          </SegmentTimeline>
                        </SegmentTemplate>
                """
        )
        XCTAssertThrowsError(try DASHParser().parse(text, baseURL: baseURL)) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .invalidDuration = dashError {
                // Expected: out-of-range is safely rejected as a catchable error
            } else {
                XCTFail("Expected .invalidDuration but got \(dashError)")
            }
        }
    }

    // Near the boundary but exactly representable as Int64: the conversion succeeds, then the
    // value is safely rejected for far exceeding the segment cap (catchable, no trap)
    func testDurationTemplateNearMaxRepresentableIsSafelyRejected() {
        // 2^63 - 2048 = 9223372036854773760 is exactly representable as a Double and < Int64.max,
        // so Int64(exactly:) succeeds; count64 then far exceeds maximumSegmentsPerRepresentation → .segmentLimitExceeded.
        let text = manifest(
            segmentTemplateBody:
                #"        <SegmentTemplate timescale="9223372036854773760" duration="1" media="seg$Number$.m4s" startNumber="0"/>"#
        )
        XCTAssertThrowsError(try DASHParser().parse(text, baseURL: baseURL)) { error in
            guard let dashError = error as? DASHParserError else {
                return XCTFail("Expected DASHParserError but got \(error)")
            }
            if case .segmentLimitExceeded = dashError {
                // Expected: representable-but-huge input is safely intercepted by the segment cap
            } else {
                XCTFail("Expected .segmentLimitExceeded but got \(dashError)")
            }
        }
    }

    // Normal small values, zero regression: duration template path
    func testDurationTemplateNormalSmallValueParses() throws {
        let text = """
            <MPD type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1000">
                    <SegmentTemplate timescale="1" duration="1" media="seg$Number$.m4s" startNumber="0"/>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let manifest = try DASHParser().parse(text, baseURL: baseURL)
        let representation = try XCTUnwrap(manifest.videoRepresentations.first)
        XCTAssertEqual(representation.segments.count, 4)
        XCTAssertEqual(representation.segments.map(\.number), [0, 1, 2, 3])
    }

    // Normal small values, zero regression: SegmentTimeline negative repeat count path (finite total duration)
    func testTimelineNegativeRepeatNormalParses() throws {
        let text = """
            <MPD type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1000">
                    <SegmentTemplate timescale="1" media="seg$Number$.m4s" startNumber="1">
                      <SegmentTimeline>
                        <S t="0" d="1" r="-1"/>
                      </SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let manifest = try DASHParser().parse(text, baseURL: baseURL)
        let representation = try XCTUnwrap(manifest.videoRepresentations.first)
        XCTAssertEqual(representation.segments.count, 4)
    }
}
