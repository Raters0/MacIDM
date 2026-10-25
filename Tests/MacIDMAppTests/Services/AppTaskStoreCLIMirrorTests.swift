import XCTest

@testable import MacIDMApp
@testable import MacIDMCLI

/// Locks the App-side removal contract for terminal CLI mirror records
/// (technical-spec §3.1.6): the CLI mirrors rows into the App store via
/// CLIGUIStateMirror, `save()` must never touch them, and an explicit
/// `deleteRecord` is what removes a terminal row — otherwise it would
/// reappear on the next launch.
final class AppTaskStoreCLIMirrorTests: XCTestCase {
    private func makeStoredTask(id: UUID, status: StoredStatus) -> StoredTask {
        StoredTask(
            id: id,
            url: "https://127.0.0.1:18768/number.mpd",
            destination: "/tmp/macidm-cli-mirror-test/\(id.uuidString).mp4",
            parallelRequests: 4,
            expectedSHA256: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: status,
            desiredAction: .run,
            receivedBytes: 0,
            totalBytes: 1_024,
            sha256: nil,
            errorCode: nil,
            errorMessage: nil,
            workerPID: nil,
            requiresRefetch: false
        )
    }

    private func makeStoreAndMirror() throws -> (AppTaskStore, CLIGUIStateMirror, URL) {
        let appDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let store = try AppTaskStore(directory: appDirectory)
        let mirror = try CLIGUIStateMirror(appDirectory: appDirectory)
        return (store, mirror, appDirectory)
    }

    func testTerminalCLIMirrorRowSurvivesSaveAndIsDeletedByDeleteRecord() throws {
        let (store, mirror, appDirectory) = try makeStoreAndMirror()
        defer { try? FileManager.default.removeItem(at: appDirectory) }

        let id = UUID()
        try mirror.upsert(makeStoredTask(id: id, status: .completed))

        let loaded = try store.load()
        let mirrored = loaded.first { $0.id == id }
        XCTAssertEqual(mirrored?.isCLIManaged, true)
        XCTAssertEqual(mirrored?.isTerminalCLIRecord, true)
        XCTAssertEqual(mirrored?.isRemovableFromApp, true)

        // A full App save rewrites only App-managed rows; the CLI row must
        // survive it, because the CLI worker still owns the record.
        try store.save(loaded.filter { $0.id != id })
        XCTAssertEqual(try store.load().contains { $0.id == id }, true)

        // Explicit record deletion is the removal path for terminal rows.
        try store.deleteRecord(id)
        XCTAssertEqual(try store.load().contains { $0.id == id }, false)
    }

    func testNonTerminalCLIMirrorRowStaysReadOnly() throws {
        let (store, mirror, appDirectory) = try makeStoreAndMirror()
        defer { try? FileManager.default.removeItem(at: appDirectory) }

        let id = UUID()
        try mirror.upsert(makeStoredTask(id: id, status: .running))

        let mirrored = try store.load().first { $0.id == id }
        XCTAssertEqual(mirrored?.isCLIManaged, true)
        XCTAssertEqual(mirrored?.isTerminalCLIRecord, false)
        XCTAssertEqual(mirrored?.isRemovableFromApp, false)
    }

    func testTerminalStatusesMirrorTheCLIRemoveGuard() {
        // The App's removable set must equal `macidm remove`'s terminal set
        // (completed/cancelled/failed/storageError); paused and running stay
        // CLI-owned.
        let terminal: [AppTaskStatus] = [.completed, .cancelled, .failed, .storageError]
        for status in terminal {
            var task = AppTask(
                id: UUID(),
                sourceURL: "https://127.0.0.1/sample.bin",
                destinationPath: "/tmp/macidm-cli-mirror-test/sample.bin",
                maximumParallelRequests: 4,
                expectedSHA256: nil,
                browserClientID: nil,
                browserSubmissionType: "cli",
                browserSubmissionKey: nil,
                createdAt: Date(),
                updatedAt: Date(),
                status: status,
                receivedBytes: 0,
                totalBytes: 1_024,
                bytesPerSecond: 0,
                speedHistory: [],
                sha256: nil,
                verification: nil,
                errorCode: nil,
                errorMessage: nil,
                segments: []
            )
            XCTAssertTrue(task.isTerminalCLIRecord, "\(status) must be terminal for CLI removal")
            XCTAssertTrue(task.isRemovableFromApp)
            task.browserSubmissionType = nil
            XCTAssertFalse(task.isCLIManaged)
            XCTAssertTrue(task.isRemovableFromApp, "App-managed tasks are always removable")
        }
        for status: AppTaskStatus in [.queued, .running, .paused, .verifying, .cancelling] {
            let task = AppTask(
                id: UUID(),
                sourceURL: "https://127.0.0.1/sample.bin",
                destinationPath: "/tmp/macidm-cli-mirror-test/sample.bin",
                maximumParallelRequests: 4,
                expectedSHA256: nil,
                browserClientID: nil,
                browserSubmissionType: "cli",
                browserSubmissionKey: nil,
                createdAt: Date(),
                updatedAt: Date(),
                status: status,
                receivedBytes: 0,
                totalBytes: 1_024,
                bytesPerSecond: 0,
                speedHistory: [],
                sha256: nil,
                verification: nil,
                errorCode: nil,
                errorMessage: nil,
                segments: []
            )
            XCTAssertFalse(task.isTerminalCLIRecord, "\(status) must stay CLI-owned")
            XCTAssertFalse(task.isRemovableFromApp)
        }
    }
}
