import XCTest

@testable import IDMEngine

final class FFmpegMetadataTests: XCTestCase {
    func testTitleDerivesFromOutputFilenameStem() {
        // The name the user confirmed in the download window becomes the
        // file's internal title, so players show it instead of URL residue.
        XCTAssertEqual(
            FFmpegMetadata.title(forOutput: URL(fileURLWithPath: "/tmp/第 1 集.mp4")),
            "第 1 集"
        )
        XCTAssertEqual(
            FFmpegMetadata.title(forOutput: URL(fileURLWithPath: "/tmp/deep.dive.name.m4a")),
            "deep.dive.name"
        )
        // Placeholder names carry no information; leave the title unset.
        XCTAssertNil(FFmpegMetadata.title(forOutput: URL(fileURLWithPath: "/tmp/download.mp4")))
        // Hidden working files are intermediates; their task-id names must
        // never leak into a published file's title.
        XCTAssertNil(
            FFmpegMetadata.title(
                forOutput: URL(fileURLWithPath: "/tmp/.0F8E2C2A-1111-2222-3333-444455556666.macidm.hls-input.ts")
            )
        )
    }

    func testSanitizedTitleStripsControlCharactersAndCapsLength() {
        XCTAssertNil(FFmpegMetadata.sanitizedTitle(" \n "))
        XCTAssertEqual(FFmpegMetadata.sanitizedTitle("a\u{01}b"), "ab")
        XCTAssertEqual(FFmpegMetadata.sanitizedTitle(String(repeating: "长", count: 600))?.count, 500)
    }
}
