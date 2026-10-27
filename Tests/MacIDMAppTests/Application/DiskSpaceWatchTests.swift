import IDMEngine
import XCTest

@testable import MacIDMApp

@MainActor
final class DiskSpaceWatchTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSpaceWatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults())
        )
    }

    /// Adds a paused task parked for a full disk with `remaining` bytes left.
    private func addParkedTask(to model: AppModel, name: String, remaining: Int64) throws -> UUID {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try model.addDownload(
            urlString: "https://example.com/\(name)",
            destination: destination,
            maximumParallelRequests: 2,
            expectedSHA256: nil,
            startImmediately: false
        )
        let id = try XCTUnwrap(model.tasks.first { $0.destinationPath == destination.path }?.id)
        model.update(id) {
            $0.status = .paused
            $0.errorCode = AppModel.diskFullErrorCode
            $0.totalBytes = remaining + 100
            $0.receivedBytes = 100
        }
        return id
    }

    func testResumesOnlyWhatTheFreeSpaceCanHold() throws {
        let model = try makeModel()
        let small = try addParkedTask(to: model, name: "small-\(UUID().uuidString).bin", remaining: 100)
        let large = try addParkedTask(to: model, name: "large-\(UUID().uuidString).bin", remaining: 10_000_000_000)
        var resumed: [UUID] = []

        let waiting = model.resumeDiskFullTasksWithRoom(
            availableCapacity: { _ in AppModel.diskSpaceResumeMargin + 1_000 },
            resumeTask: { resumed.append($0) }
        )

        XCTAssertEqual(resumed, [small])
        XCTAssertFalse(resumed.contains(large))
        XCTAssertTrue(waiting, "the large task must keep waiting")
    }

    func testUnparkedTasksAreNotTouched() throws {
        let model = try makeModel()
        let id = try addParkedTask(to: model, name: "manual-\(UUID().uuidString).bin", remaining: 10)
        // The user paused it again manually: no disk-full code any more.
        model.update(id) { $0.errorCode = nil }
        var resumed: [UUID] = []

        let waiting = model.resumeDiskFullTasksWithRoom(
            availableCapacity: { _ in Int64.max / 2 },
            resumeTask: { resumed.append($0) }
        )

        XCTAssertTrue(resumed.isEmpty)
        XCTAssertFalse(waiting)
    }
}
