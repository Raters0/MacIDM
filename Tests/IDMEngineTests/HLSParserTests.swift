import Foundation
import XCTest

@testable import IDMEngine

final class HLSParserTests: XCTestCase {
    func testMasterPlaylistProducesVariantsAndAudioGroups() throws {
        let playlist = try parseFixture("master.m3u8")

        guard case .master(let master) = playlist else {
            return XCTFail("expected a master playlist")
        }
        XCTAssertEqual(master.variants.count, 2)
        XCTAssertEqual(master.variants[0].bandwidth, 800_000)
        XCTAssertEqual(master.variants[0].width, 640)
        XCTAssertEqual(master.variants[0].height, 360)
        XCTAssertEqual(master.variants[0].audioGroup, "audio")
        XCTAssertEqual(
            master.variants[1].url.absoluteString,
            "https://cdn.example.test/video/720.m3u8"
        )
        XCTAssertEqual(master.mediaGroups.first?.url?.absoluteString, "https://cdn.example.test/audio/en.m3u8")
        XCTAssertTrue(master.mediaGroups.first?.isDefault == true)
    }

    func testMediaPlaylistResolvesRangesKeysAndDiscontinuities() throws {
        let playlist = try parseFixture("media.m3u8")

        guard case .media(let media) = playlist else {
            return XCTFail("expected a media playlist")
        }
        XCTAssertEqual(media.targetDuration, 6)
        XCTAssertEqual(media.mediaSequence, 42)
        XCTAssertEqual(media.playlistType, "VOD")
        XCTAssertTrue(media.isVideoOnDemand)
        XCTAssertEqual(media.initializationSegment?.url.absoluteString, "https://cdn.example.test/video/init.mp4")
        XCTAssertEqual(media.initializationSegment?.byteRange, HLSByteRange(length: 720, offset: 0))
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertEqual(media.segments[0].byteRange, HLSByteRange(length: 1_200, offset: 720))
        XCTAssertEqual(media.segments[1].byteRange, HLSByteRange(length: 900, offset: 1_920))
        XCTAssertEqual(
            media.segments[0].encryptionKey?.url.absoluteString, "https://cdn.example.test/video/keys/key.bin")
        XCTAssertEqual(media.segments[0].encryptionKey?.iv, "0x0000000000000000000000000000002a")
        XCTAssertTrue(media.segments[2].isDiscontinuity)
        XCTAssertTrue(media.isEndList)
    }

    func testUnsupportedEncryptionIsRejectedBeforeAnyNetworkWork() throws {
        XCTAssertThrowsError(try parseFixture("unsupported-encryption.m3u8")) { error in
            XCTAssertEqual(error as? HLSParserError, .unsupportedEncryption("SAMPLE-AES"))
        }
    }

    func testInvalidAndOversizedPlaylistsAreRejected() throws {
        let baseURL = URL(string: "https://cdn.example.test/video/master.m3u8")!
        XCTAssertThrowsError(try HLSParser().parse("#EXTM3U\n", baseURL: baseURL))
        XCTAssertThrowsError(
            try HLSParser(maximumPlaylistBytes: 10).parse(
                "#EXTM3U\n#EXT-X-ENDLIST\n",
                baseURL: baseURL
            ))
        XCTAssertThrowsError(
            try HLSParser().parse(
                "#EXTM3U\n#EXTINF:4,\nfile://segment.ts\n#EXT-X-ENDLIST\n",
                baseURL: baseURL
            ))
    }

    private func parseFixture(_ name: String) throws -> HLSPlaylist {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS")
            .appendingPathComponent(name)
        return try HLSParser().parse(
            String(contentsOf: url, encoding: .utf8),
            baseURL: URL(
                string: name == "master.m3u8"
                    ? "https://cdn.example.test/master.m3u8"
                    : "https://cdn.example.test/video/master.m3u8"
            )!
        )
    }
}
