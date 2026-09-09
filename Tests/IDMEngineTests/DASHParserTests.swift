import Foundation
import XCTest

@testable import IDMEngine

final class DASHParserTests: XCTestCase {
    func testSegmentTemplateExpandsNumberAndInitialization() throws {
        let manifest = try parseFixture("template.mpd")
        let representation = try XCTUnwrap(manifest.videoRepresentations.first)

        XCTAssertEqual(representation.contentKind, .video)
        XCTAssertEqual(representation.width, 1_280)
        XCTAssertEqual(representation.height, 720)
        XCTAssertEqual(
            representation.initialization?.url.absoluteString,
            "https://media.example.test/vod/video-720-init.m4s"
        )
        XCTAssertEqual(representation.segments.map(\.number), [1, 2, 3])
        XCTAssertEqual(
            representation.segments.map { $0.url.absoluteString },
            [
                "https://media.example.test/vod/video-720-00001.m4s",
                "https://media.example.test/vod/video-720-00002.m4s",
                "https://media.example.test/vod/video-720-00003.m4s",
            ]
        )
    }

    func testSegmentTimelineExpandsRepeatedAndExplicitTimes() throws {
        let manifest = try parseFixture("timeline.mpd")
        let representation = try XCTUnwrap(manifest.audioRepresentations.first)

        XCTAssertEqual(representation.segments.map(\.startTime), [0, 1_000, 2_000])
        XCTAssertEqual(representation.segments.map(\.duration), [1_000, 1_000, 500])
        XCTAssertEqual(representation.segments.last?.url.absoluteString, "https://media.example.test/audio/a-2000.m4s")
    }

    func testSegmentListPreservesInitializationAndByteRanges() throws {
        let manifest = try parseFixture("list.mpd")
        let representation = try XCTUnwrap(manifest.videoRepresentations.first)

        XCTAssertEqual(representation.initialization?.byteRange?.length, 100)
        XCTAssertEqual(representation.segments.count, 2)
        XCTAssertEqual(representation.segments[1].byteRange?.start, 200)
        XCTAssertEqual(representation.segments[1].byteRange?.endInclusive, 299)
    }

    func testSegmentListWithoutSourceURLFallsBackToBaseURL() throws {
        // The spec allows SegmentList Initialization/SegmentURL to omit sourceURL/media,
        // in which case byte ranges live in the single resource named by the Representation BaseURL.
        let manifest = try parseFixture("list-no-sourceurl.mpd")
        let representation = try XCTUnwrap(manifest.videoRepresentations.first)

        XCTAssertEqual(
            representation.initialization?.url.absoluteString,
            "https://fallback.example/media_muxed.mp4"
        )
        XCTAssertEqual(representation.initialization?.byteRange?.start, 0)
        XCTAssertEqual(representation.initialization?.byteRange?.endInclusive, 1256)
        XCTAssertEqual(representation.segments.count, 2)
        XCTAssertEqual(
            representation.segments[0].url.absoluteString,
            "https://fallback.example/media_muxed.mp4"
        )
        XCTAssertEqual(representation.segments[0].byteRange?.start, 1257)
        XCTAssertEqual(representation.segments[1].byteRange?.endInclusive, 1_909_476)
    }

    func testLiveManifestIsRejected() throws {
        let live = "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"dynamic\"></MPD>"
        XCTAssertThrowsError(try DASHParser().parse(live, baseURL: URL(string: "https://example.com/")!)) { error in
            XCTAssertEqual(error as? DASHParserError, .unsupportedLiveManifest)
        }
    }

    private func parseFixture(_ name: String) throws -> DASHManifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DASH/\(name)")
        return try DASHParser().parse(
            String(contentsOf: url, encoding: .utf8),
            baseURL: URL(string: "https://fallback.example/")!
        )
    }
}
