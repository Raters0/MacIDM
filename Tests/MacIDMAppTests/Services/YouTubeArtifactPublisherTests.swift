import Foundation
import XCTest

@testable import MacIDMApp

final class YouTubeArtifactPublisherTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubeArtifactPublisherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testProducedMediaFiltersPartFilesAndNonVideoExtensions() throws {
        let partFile = tempDirectory.appendingPathComponent("video.mp4.part")
        let textFile = tempDirectory.appendingPathComponent("info.json")
        let logFile = tempDirectory.appendingPathComponent("output.log")
        let validMedia = tempDirectory.appendingPathComponent("final_video.mp4")

        try "part-data".write(to: partFile, atomically: true, encoding: .utf8)
        try "{}".write(to: textFile, atomically: true, encoding: .utf8)
        try "log".write(to: logFile, atomically: true, encoding: .utf8)
        try "video-bytes".write(to: validMedia, atomically: true, encoding: .utf8)

        let result = YouTubeArtifactPublisher.producedMedia(in: tempDirectory)
        XCTAssertEqual(result?.lastPathComponent, "final_video.mp4")
    }

    func testProducedMediaSelectsMostRecentValidMedia() throws {
        let olderMedia = tempDirectory.appendingPathComponent("older.webm")
        let newerMedia = tempDirectory.appendingPathComponent("newer.mkv")

        try "old".write(to: olderMedia, atomically: true, encoding: .utf8)
        // Set older modification date
        let oldDate = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: olderMedia.path)

        try "new".write(to: newerMedia, atomically: true, encoding: .utf8)
        let newDate = Date().addingTimeInterval(0)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newerMedia.path)

        let result = YouTubeArtifactPublisher.producedMedia(in: tempDirectory)
        XCTAssertEqual(result?.lastPathComponent, "newer.mkv")
    }

    func testProducedMediaSupportsAllowedExtensions() throws {
        let allowed = ["mp4", "m4v", "webm", "mkv", "mov"]
        for ext in allowed {
            let testDir = tempDirectory.appendingPathComponent("test_\(ext)")
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            let mediaFile = testDir.appendingPathComponent("media.\(ext)")
            try "data".write(to: mediaFile, atomically: true, encoding: .utf8)

            let found = YouTubeArtifactPublisher.producedMedia(in: testDir)
            XCTAssertEqual(found?.lastPathComponent, "media.\(ext)")
        }
    }

    func testProducedMediaReturnsNilForEmptyDirectory() {
        let emptyDir = tempDirectory.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let result = YouTubeArtifactPublisher.producedMedia(in: emptyDir)
        XCTAssertNil(result)
    }
}
