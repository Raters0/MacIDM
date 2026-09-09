import Foundation
import XCTest

@testable import MacIDMApp

@MainActor
final class TaskFilterMembershipTests: XCTestCase {
    private func fixture() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storeDirectory: directory, settings: AppSettings(defaults: makeIsolatedDefaults()))
        addTeardownBlock { @MainActor in
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        for name in ["alpha.zip", "beta.zip"] {
            try model.addDownload(
                urlString: "https://example.test/data", destination: directory.appendingPathComponent(name),
                maximumParallelRequests: 1, expectedSHA256: nil, startImmediately: false
            )
        }
        return model
    }

    func testSearchUpdatesAfterDestinationChange() throws {
        let model = try fixture()
        model.searchText = "alpha"
        XCTAssertEqual(model.filteredTasks.count, 1)
        let index = try XCTUnwrap(model.tasks.firstIndex { $0.filename == "alpha.zip" })
        model.tasks[index].destinationPath = "/tmp/renamed.zip"
        XCTAssertEqual(model.filteredTasks.count, 0)
    }

    func testCategoryUpdatesAfterExtensionChange() throws {
        let model = try fixture()
        model.sidebarFilter = .category(.archive)
        XCTAssertEqual(model.filteredTasks.count, 2)
        model.tasks[0].destinationPath = "/tmp/movie.mp4"
        XCTAssertEqual(model.filteredTasks.count, 1)
    }

    func testBatchStatusSwapKeepsTaskIdentity() throws {
        let model = try fixture()
        var snapshot = model.tasks
        snapshot[0].status = .completed
        snapshot[1].status = .paused
        model.tasks = snapshot
        model.sidebarFilter = .completed
        XCTAssertEqual(model.filteredTasks.map(\.id), [snapshot[0].id])
        snapshot[0].status = .paused
        snapshot[1].status = .completed
        model.tasks = snapshot
        XCTAssertEqual(model.filteredTasks.map(\.id), [snapshot[1].id])
    }
}
