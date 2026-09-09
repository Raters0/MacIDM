import XCTest

@testable import IDMEngine

/// Regression tests for the EXT-X-MAP BYTERANGE chain: RFC 8216 keeps the
/// map's range chain independent from media segment ranges, so a map
/// BYTERANGE without an explicit `@offset` must resolve against the previous
/// map's end (starting at 0), never against the previous segment's end.
final class HLSMapByteRangeTests: XCTestCase {
    private func parse(_ playlist: String) throws -> HLSMediaPlaylist {
        let parser = HLSParser()
        let parsed = try parser.parse(
            playlist,
            baseURL: URL(string: "https://cdn.example.test/list.m3u8")!
        )
        guard case .media(let media) = parsed else {
            XCTFail("expected a media playlist")
            throw HLSParserError.invalidAttribute("playlist-kind")
        }
        return media
    }

    func testMapByteRangeWithoutOffsetResolvesAgainstMapChainNotSegmentChain() throws {
        // The preceding media segment ends at 4; with the pre-fix bug the
        // map's implicit offset resolved to 4 (reading past/into wrong data).
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            #EXT-X-BYTERANGE:4@0
            seg1.ts
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="8"
            #EXTINF:4,
            #EXT-X-BYTERANGE:4@4
            seg2.ts
            #EXT-X-ENDLIST
            """
        let result = try parse(playlist)
        XCTAssertEqual(result.segments[0].byteRange?.offset, 0)
        XCTAssertEqual(result.segments[1].byteRange?.offset, 4)
        XCTAssertEqual(result.initializationSegment?.byteRange?.offset, 0)
        XCTAssertEqual(result.initializationSegment?.byteRange?.length, 8)
    }

    func testConsecutiveMapsWithoutOffsetChainAgainstEachOther() throws {
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="a.mp4",BYTERANGE="4"
            #EXTINF:4,
            #EXT-X-BYTERANGE:8@0
            seg1.ts
            #EXT-X-MAP:URI="b.mp4",BYTERANGE="6"
            #EXTINF:4,
            #EXT-X-BYTERANGE:8@8
            seg2.ts
            #EXT-X-ENDLIST
            """
        let result = try parse(playlist)
        XCTAssertEqual(result.segments[1].byteRange?.offset, 8)
        // The parser keeps the last map as the playlist-level init; its
        // offset must be 4 (end of the first map), not 8 (end of segment 1).
        XCTAssertEqual(result.initializationSegment?.byteRange?.offset, 4)
        XCTAssertEqual(result.initializationSegment?.byteRange?.length, 6)
    }
}

/// R9-4 regression: a hostile playlist declaring near-Int64.max BYTERANGE
/// values must fail parsing instead of trapping on `offset + length`.
final class HLSByteRangeOverflowTests: XCTestCase {
    func testOverflowingByteRangeChainThrowsInsteadOfTrapping() {
        let parser = HLSParser()
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4,
            #EXT-X-BYTERANGE:9223372036854775807@4611686018427387904
            seg1.ts
            #EXT-X-ENDLIST
            """
        XCTAssertThrowsError(
            try parser.parse(playlist, baseURL: URL(string: "https://cdn.example.test/list.m3u8")!)
        ) { error in
            guard case HLSParserError.invalidNumber = error else {
                return XCTFail("expected invalidNumber, got \\(error)")
            }
        }
    }
}
