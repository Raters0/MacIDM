import Foundation
import XCTest

@testable import IDMEngine

final class HLSSegmentPlanTests: XCTestCase {
    func testPlannerBuildsStableInitializationAndMediaUnits() throws {
        let media = try parseMediaFixture()
        let playlistURL = URL(string: "https://cdn.example.test/video/media.m3u8")!

        let plan = try HLSDownloadPlanner().makePlan(media, playlistURL: playlistURL)

        XCTAssertTrue(plan.isVideoOnDemand)
        XCTAssertEqual(plan.playlistURL, playlistURL)
        XCTAssertEqual(plan.mediaSequence, 42)
        XCTAssertEqual(plan.totalDuration, 15.25, accuracy: 0.000_001)
        XCTAssertEqual(plan.units.count, 4)
        XCTAssertEqual(plan.units[0].kind, .initialization)
        XCTAssertEqual(plan.units[0].url.absoluteString, "https://cdn.example.test/video/init.mp4")
        XCTAssertEqual(plan.units[0].byteRange, HLSByteRange(length: 720, offset: 0))
        XCTAssertNil(plan.units[0].encryptionKey)
        XCTAssertEqual(plan.units[1].kind, .media)
        XCTAssertEqual(plan.units[1].mediaSequence, 42)
        XCTAssertEqual(plan.units[1].duration ?? -1, 5.5, accuracy: 0.000_001)
        XCTAssertEqual(plan.units[1].byteRange, HLSByteRange(length: 1_200, offset: 720))
        XCTAssertEqual(plan.units[1].encryptionKey?.url.absoluteString, "https://cdn.example.test/video/keys/key.bin")
        XCTAssertEqual(plan.units[3].mediaSequence, 44)
        XCTAssertTrue(plan.units[3].isDiscontinuity)
    }

    func testPlannerRejectsLivePlaylist() throws {
        let playlist = HLSMediaPlaylist(
            targetDuration: 6,
            mediaSequence: 8,
            playlistType: nil,
            isEndList: false,
            initializationSegment: nil,
            segments: [
                HLSSegment(
                    url: URL(string: "https://cdn.example.test/live/1.ts")!,
                    duration: 6,
                    title: "live"
                )
            ]
        )

        XCTAssertThrowsError(
            try HLSDownloadPlanner().makePlan(
                playlist,
                playlistURL: URL(string: "https://cdn.example.test/live.m3u8")!
            )
        ) { error in
            guard case IDMError.unsupportedScheme = error else {
                return XCTFail("expected unsupported scheme, got \(error)")
            }
        }
    }

    func testResumeStateRequiresMatchingTaskPlaylistAndUnits() throws {
        let plan = try HLSDownloadPlanner().makePlan(
            try parseMediaFixture(),
            playlistURL: URL(string: "https://cdn.example.test/video/media.m3u8")!
        )
        let taskID = UUID(uuidString: "E6B7C8A9-4D3E-4B1A-8F21-2CC1EA0E5B10")!
        var state = HLSResumeState(taskID: taskID, plan: plan)

        try state.markCompleted(unitIndex: 0, receivedBytes: 720)
        try state.markCompleted(unitIndex: 1, receivedBytes: 1_200)
        XCTAssertTrue(state.units[1].completed)
        XCTAssertEqual(state.units[1].receivedBytes, 1_200)
        try state.validatingCompatibility(taskID: taskID, plan: plan)

        XCTAssertThrowsError(try state.validatingCompatibility(taskID: UUID(), plan: plan)) { error in
            XCTAssertEqual(error as? HLSResumeError, .taskChanged)
        }

        let changedUnit = HLSDownloadUnit(
            index: 1,
            kind: .media,
            url: URL(string: "https://cdn.example.test/video/changed.ts")!,
            duration: 5.5,
            byteRange: HLSByteRange(length: 1_200, offset: 720),
            encryptionKey: plan.units[1].encryptionKey,
            mediaSequence: 42
        )
        var changedUnits = plan.units
        changedUnits[1] = changedUnit
        let changedPlan = HLSDownloadPlan(
            playlistURL: plan.playlistURL,
            mediaSequence: plan.mediaSequence,
            isVideoOnDemand: plan.isVideoOnDemand,
            totalDuration: plan.totalDuration,
            units: changedUnits
        )
        XCTAssertThrowsError(try state.validatingCompatibility(taskID: taskID, plan: changedPlan)) { error in
            XCTAssertEqual(error as? HLSResumeError, .unitChanged(1))
        }

        XCTAssertThrowsError(try state.markCompleted(unitIndex: 1, receivedBytes: -1)) { error in
            XCTAssertEqual(error as? HLSResumeError, .invalidCheckpoint(1))
        }
    }

    func testResumeRecordRoundTripOmitsSensitiveURLs() throws {
        let plan = try HLSDownloadPlanner().makePlan(
            try parseMediaFixture(),
            playlistURL: URL(string: "https://cdn.example.test/video/media.m3u8")!
        )
        let taskID = UUID()
        var state = HLSResumeState(taskID: taskID, plan: plan)
        try state.markCompleted(unitIndex: 0, receivedBytes: 720)
        try state.markCompleted(unitIndex: 1, receivedBytes: 1_200)

        let record = state.record()
        let encoded = try JSONEncoder().encode(record)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("media.m3u8"))
        XCTAssertFalse(json.contains("media.mp4"))
        XCTAssertFalse(json.contains("key.bin"))

        let decodedRecord = try JSONDecoder().decode(HLSResumeRecord.self, from: encoded)
        let restored = try HLSResumeState(record: decodedRecord, plan: plan)
        XCTAssertEqual(restored.taskID, taskID)
        XCTAssertTrue(restored.units[1].completed)
        XCTAssertEqual(restored.units[1].receivedBytes, 1_200)
    }

    private func parseMediaFixture() throws -> HLSMediaPlaylist {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/media.m3u8")
        let playlist = try HLSParser().parse(
            String(contentsOf: url, encoding: .utf8),
            baseURL: URL(string: "https://cdn.example.test/video/master.m3u8")!
        )
        guard case .media(let media) = playlist else {
            throw HLSParserError.emptyPlaylist
        }
        return media
    }
}
