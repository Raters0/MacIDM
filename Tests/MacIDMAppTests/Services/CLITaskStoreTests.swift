import Foundation
import XCTest

@testable import IDMEngine
@testable import MacIDMCLI

final class CLITaskStoreTests: XCTestCase {
    private var storeDirectory: URL!
    private var downloadDirectory: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCLITaskStoreTests-\(UUID().uuidString)")
        storeDirectory = root.appendingPathComponent("store")
        downloadDirectory = root.appendingPathComponent("downloads")
        try? FileManager.default.createDirectory(
            at: downloadDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: storeDirectory.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeStore() throws -> TaskStore {
        try TaskStore(directory: storeDirectory)
    }

    private func makeTask(
        id: UUID = UUID(),
        destination: URL,
        status: StoredStatus = .completed
    ) -> StoredTask {
        StoredTask(
            id: id,
            url: "https://cdn.example.com/file.bin",
            destination: destination.path,
            parallelRequests: 8,
            expectedSHA256: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: status,
            desiredAction: .run,
            receivedBytes: 0,
            totalBytes: nil,
            sha256: nil,
            errorCode: nil,
            errorMessage: nil,
            workerPID: nil
        )
    }

    func testRemoveWithDeleteFileCleansCompletedProductAndArtifacts() throws {
        let store = try makeStore()
        let id = UUID()
        let destination = downloadDirectory.appendingPathComponent("file.bin")
        try Data("payload".utf8).write(to: destination)
        for url in DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id) {
            try Data("partial".utf8).write(to: url)
        }
        try store.create(makeTask(id: id, destination: destination))

        try store.remove(id, deleteFile: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        for url in DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertNil(try store.load(id))
    }

    func testRemoveWithoutDeleteFileKeepsProductAndArtifacts() throws {
        let store = try makeStore()
        let id = UUID()
        let destination = downloadDirectory.appendingPathComponent("file.bin")
        try Data("payload".utf8).write(to: destination)
        let artifacts = DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id)
        try Data("partial".utf8).write(to: artifacts[0])
        try store.create(makeTask(id: id, destination: destination))

        try store.remove(id, deleteFile: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].path))
        XCTAssertNil(try store.load(id))
    }

    func testRemoveKeepsCompletedFileOnlyForCompletedStatus() throws {
        let store = try makeStore()
        let id = UUID()
        let destination = downloadDirectory.appendingPathComponent("file.bin")
        // A cancelled task leaves a stray file; remove --delete-file must not
        // treat it as a published product, but partial artifacts still go.
        try Data("stray".utf8).write(to: destination)
        let artifacts = DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id)
        try Data("partial".utf8).write(to: artifacts[1])
        try store.create(makeTask(id: id, destination: destination, status: .cancelled))

        try store.remove(id, deleteFile: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts[1].path))
        XCTAssertNil(try store.load(id))
    }

    func testRemoveMissingTaskDoesNotThrow() throws {
        let store = try makeStore()
        try store.remove(UUID(), deleteFile: true)
    }

    func testRemoveOnlyAffectsRequestedTask() throws {
        let store = try makeStore()
        let removedID = UUID()
        let keptID = UUID()
        let removedDestination = downloadDirectory.appendingPathComponent("removed.bin")
        let keptDestination = downloadDirectory.appendingPathComponent("kept.bin")
        try Data("a".utf8).write(to: removedDestination)
        try Data("b".utf8).write(to: keptDestination)
        try store.create(makeTask(id: removedID, destination: removedDestination))
        try store.create(makeTask(id: keptID, destination: keptDestination))

        try store.remove(removedID, deleteFile: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: removedDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptDestination.path))
        XCTAssertNotNil(try store.load(keptID))
    }
}

final class CLIPauseTerminalTaskTests: XCTestCase {
    private var storeDirectory: URL!

    override func setUp() {
        super.setUp()
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCLIPauseTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeDirectory)
        super.tearDown()
    }

    private func makeFailedTask(id: UUID) throws -> TaskStore {
        let store = try TaskStore(directory: storeDirectory)
        try store.create(
            StoredTask(
                id: id,
                url: "https://cdn.example.com/file.bin",
                destination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("file.bin").path,
                parallelRequests: 8,
                expectedSHA256: nil,
                createdAt: Date(),
                updatedAt: Date(),
                status: .failed,
                desiredAction: .run,
                receivedBytes: 0,
                totalBytes: nil,
                sha256: nil,
                errorCode: "NETWORK_ERROR",
                errorMessage: nil,
                workerPID: nil
            ))
        return store
    }

    /// Pausing a failed task used to silently flip it to "paused" (the
    /// de-facto retry path). Pause now refuses terminal states; retrying a
    /// failed task goes through resume directly.
    func testPauseRejectsFailedTaskWithGuidance() async throws {
        let id = UUID()
        _ = try makeFailedTask(id: id)
        let arguments = try CLIArguments([
            "pause", id.uuidString, "--state-dir", storeDirectory.path,
        ])
        await XCTAssertThrowsErrorAsync(
            try await CLIApplication.execute(arguments)
        ) { error in
            guard case CLIError.usage(let message) = error else {
                return XCTFail("expected usage error, got \(error)")
            }
            XCTAssertTrue(message.contains("resume"), "guidance should point at resume: \(message)")
        }
        let store = try TaskStore(directory: storeDirectory)
        XCTAssertEqual(try store.load(id)?.status, .failed)
    }
}

func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: @escaping (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error")
    } catch {
        errorHandler(error)
    }
}
