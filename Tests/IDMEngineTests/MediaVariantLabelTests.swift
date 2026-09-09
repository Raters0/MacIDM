import XCTest

@testable import IDMEngine

final class MediaVariantLabelTests: XCTestCase {
    // MARK: - Slot grammar

    func testFormatJoinsAllSlotsInFixedOrder() {
        XCTAssertEqual(
            MediaVariantLabel.format(
                width: 1920,
                height: 1080,
                fps: 60,
                codecs: "avc1.640033,mp4a.40.2",
                bandwidth: 6_500_000
            ),
            "1080P · 60fps · H.264 · 6.5 Mbps"
        )
    }

    func testFormatSkipsMissingSlotsWithoutPlaceholders() {
        XCTAssertEqual(
            MediaVariantLabel.format(width: nil, height: 720, codecs: nil, bandwidth: 800_000),
            "720p · 800 kbps"
        )
        XCTAssertEqual(
            MediaVariantLabel.format(width: nil, height: nil, codecs: "av01.0.05M.08", bandwidth: nil),
            "AV1"
        )
        XCTAssertTrue(
            MediaVariantLabel.format(width: nil, height: nil, codecs: nil, bandwidth: nil).isEmpty
        )
    }

    func testFormatOmitsCodecSlotForUnknownCodecsInsteadOfFourCC() {
        XCTAssertEqual(
            MediaVariantLabel.format(width: 640, height: 360, codecs: "vp8", bandwidth: nil),
            "360P"
        )
    }

    // MARK: - Resolution slot

    func testResolutionPrefersTierLabelsAndFallsBackToExactPixels() {
        XCTAssertEqual(MediaVariantLabel.resolution(width: 3840, height: 2160), "4K")
        XCTAssertEqual(MediaVariantLabel.resolution(width: 2560, height: 1440), "2K")
        XCTAssertEqual(MediaVariantLabel.resolution(width: 1280, height: 720), "720P")
        XCTAssertEqual(MediaVariantLabel.resolution(width: 1088, height: 608), "1088×608")
        XCTAssertEqual(MediaVariantLabel.resolution(width: nil, height: 480), "480p")
        XCTAssertNil(MediaVariantLabel.resolution(width: nil, height: nil))
    }

    // MARK: - Codec family

    func testFamilyMapsKnownPrefixesAndRejectsUnknown() {
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "avc1.640033"), "H.264")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "hev1.2.4.L153.B0"), "H.265")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "hvc1.1.6.L150.B0"), "H.265")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "av01.0.05M.08"), "AV1")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "vp09.00.31.08"), "VP9")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "mp4a.40.2"), "AAC")
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "opus"), "Opus")
        // For combined strings, take the first comma-separated entry (usually the video codec).
        XCTAssertEqual(MediaVariantLabel.family(forCodecs: "avc1.640028,mp4a.40.2"), "H.264")
        XCTAssertNil(MediaVariantLabel.family(forCodecs: "vp8"))
        XCTAssertNil(MediaVariantLabel.family(forCodecs: "  "))
        XCTAssertNil(MediaVariantLabel.family(forCodecs: nil))
    }

    // MARK: - Bitrate slot

    func testBitrateFormatsMegabitsAndKilobitsAndSkipsSubKbpsNoise() {
        XCTAssertEqual(MediaVariantLabel.bitrate(6_500_000), "6.5 Mbps")
        XCTAssertEqual(MediaVariantLabel.bitrate(1_000_000), "1.0 Mbps")
        XCTAssertEqual(MediaVariantLabel.bitrate(800_000), "800 kbps")
        XCTAssertNil(MediaVariantLabel.bitrate(800))
        XCTAssertNil(MediaVariantLabel.bitrate(0))
        XCTAssertNil(MediaVariantLabel.bitrate(nil))
    }
}
