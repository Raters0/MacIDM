import SQLite3
import XCTest

@testable import MacIDMApp
@testable import MacIDMCLI

final class AppTaskStoreTests: XCTestCase {
    func testRoundTripPreservesTaskIdentityAndProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        var task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip?token=private",
            destinationPath: directory.appendingPathComponent("file.zip").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .running,
            receivedBytes: 512,
            totalBytes: 1_024,
            bytesPerSecond: 256,
            speedHistory: [
                SpeedSample(timestamp: Date(timeIntervalSinceNow: -4), bytesPerSecond: 128),
                SpeedSample(timestamp: Date(timeIntervalSinceNow: -2), bytesPerSecond: 256),
            ],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: [
                SegmentSnapshot(
                    index: 0,
                    receivedBytes: 512,
                    totalBytes: 1_024
                )
            ]
        )
        task.categoryOverride = .video
        task.priority = 7
        task.activeTransferDuration = 42.5

        try store.save([task])
        let loaded = try XCTUnwrap(store.load().first)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("tasks.sqlite3").path
            )
        )
        XCTAssertEqual(loaded.id, task.id)
        XCTAssertEqual(loaded.sourceURL, "https://example.com/file.zip")
        XCTAssertEqual(loaded.receivedBytes, 512)
        XCTAssertEqual(loaded.segments.first?.receivedBytes, 512)
        XCTAssertEqual(loaded.categoryOverride, .video)
        XCTAssertEqual(loaded.category, .video)
        XCTAssertEqual(loaded.priority, 7)
        XCTAssertEqual(loaded.speedHistory, task.speedHistory)
        XCTAssertEqual(loaded.activeTransferDuration, 42.5, accuracy: 0.001)
    }

    func testRoundTripPersistsSiteAdapterResumeIdentity() throws {
        // 站点适配（B 站）重解析续传依赖持久化的非机密身份：页面 URL +
        // cid + 所选轨 format_id（v12 新增列）。签名轨地址仍脱敏。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMResumeIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        var task = AppTask(
            id: UUID(),
            sourceURL: "https://upos.bilivideo.com/x/12345678-1-30080.m4s?deadline=9",
            destinationPath: directory.appendingPathComponent("v.mp4").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .dash,
            browserClientID: nil,
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.pageURL = "https://www.bilibili.com/video/BV1xx411c7mD"
        task.mediaCID = "12345678"
        task.selectedQuality = 30080

        try store.save([task])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.mediaCID, "12345678")
        XCTAssertEqual(loaded.selectedQuality, 30080)
        XCTAssertEqual(loaded.pageURL, "https://www.bilibili.com/video/BV1xx411c7mD")
        // 签名查询参数仍被脱敏，不随新列一起落盘。
        XCTAssertFalse(loaded.sourceURL.contains("deadline"))
    }

    func testLegacyJSONIsMigratedOnceAndRemovedAfterCommit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/video.mp4?token=private",
            destinationPath: directory.appendingPathComponent("video.mp4").path,
            maximumParallelRequests: 2,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            status: .paused,
            receivedBytes: 12,
            totalBytes: 100,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([task]).write(
            to: directory.appendingPathComponent("tasks.json"),
            options: .atomic
        )

        let store = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id, task.id)
        XCTAssertEqual(loaded.sourceURL, "https://example.com/video.mp4")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("tasks.json").path)
        )
    }

    func testAppSaveDoesNotDeleteCLIManagedMirrorRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCLIMirrorStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/cli.zip",
            destinationPath: directory.appendingPathComponent("cli.zip").path,
            maximumParallelRequests: 2,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: "cli",
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )

        let mirror = try CLIGUIStateMirror(appDirectory: directory)
        let stored = StoredTask(
            id: task.id,
            url: task.sourceURL,
            destination: task.destinationPath,
            parallelRequests: task.maximumParallelRequests,
            expectedSHA256: nil,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            status: .queued,
            desiredAction: .run,
            receivedBytes: 0,
            totalBytes: nil,
            sha256: nil,
            errorCode: nil,
            errorMessage: nil,
            workerPID: nil
        )
        try mirror.upsert(stored)
        var staleAppSnapshot = task
        staleAppSnapshot.status = .failed
        staleAppSnapshot.errorCode = "STALE_APP_COPY"
        try store.save([staleAppSnapshot])
        try store.save([])

        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id, task.id)
        XCTAssertTrue(loaded.isCLIManaged)
        XCTAssertEqual(loaded.status, .queued)
    }

    func testRoundTripPreservesUsedParallelRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppParallelismTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        var task = makePersistableTask(destination: directory.appendingPathComponent("file.zip").path)
        task.status = .completed
        task.usedParallelRequests = 1

        try store.save([task])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.usedParallelRequests, 1)

        // Rows without a recorded value stay nil (legacy semantics).
        var second = makePersistableTask(destination: directory.appendingPathComponent("other.zip").path)
        second.usedParallelRequests = nil
        try store.save([task, second])
        let reloaded = try store.load().first { $0.id == second.id }
        XCTAssertNil(reloaded?.usedParallelRequests)
    }

    func testRoundTripPreservesMimeType() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppMimeStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        var task = makePersistableTask(destination: directory.appendingPathComponent("signed-media").path)
        task.mimeType = "video/mp4"

        try store.save([task])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.mimeType, "video/mp4")
        XCTAssertEqual(loaded.category, .video)

        // Rows without a declared MIME stay nil (legacy semantics).
        let second = makePersistableTask(destination: directory.appendingPathComponent("other.zip").path)
        try store.save([task, second])
        let reloaded = try store.load().first { $0.id == second.id }
        XCTAssertNil(reloaded?.mimeType)
    }

    func testV8DatabaseMigratesToUsedParallelRequestsColumn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppV8MigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Build a v8 database by hand: the full schema minus the
        // used_parallel_requests column introduced in v9, plus one row.
        let taskID = UUID().uuidString.lowercased()
        let databaseURL = directory.appendingPathComponent("tasks.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySchema = """
            CREATE TABLE schema_migrations (version INTEGER NOT NULL);
            INSERT INTO schema_migrations(version) VALUES (8);
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY NOT NULL,
                source_url TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                maximum_parallel_requests INTEGER NOT NULL,
                expected_sha256 TEXT,
                source_kind TEXT,
                browser_client_id TEXT,
                browser_submission_type TEXT,
                browser_submission_key TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                received_bytes INTEGER NOT NULL,
                total_bytes INTEGER,
                bytes_per_second REAL NOT NULL,
                speed_history_json TEXT NOT NULL,
                sha256 TEXT,
                verification TEXT,
                error_code TEXT,
                error_message TEXT,
                segments_json TEXT NOT NULL,
                is_archived INTEGER NOT NULL DEFAULT 0,
                average_speed REAL,
                total_duration REAL,
                category TEXT,
                priority INTEGER NOT NULL DEFAULT 0,
                started_at REAL,
                media_duration REAL,
                queue_id TEXT,
                page_url TEXT,
                error_recommendation TEXT,
                error_category TEXT
            );
            INSERT INTO tasks (
                id, source_url, destination_path, maximum_parallel_requests,
                expected_sha256, source_kind, browser_client_id,
                browser_submission_type, browser_submission_key, created_at,
                updated_at, status, received_bytes, total_bytes,
                bytes_per_second, speed_history_json, sha256, verification,
                error_code, error_message, segments_json,
                is_archived, average_speed, total_duration, category, priority,
                started_at, media_duration, queue_id, page_url, error_recommendation,
                error_category
            ) VALUES (
                '\(taskID)', 'https://example.com/legacy.zip', '/tmp/legacy.zip', 8,
                NULL, NULL, NULL, 'youtube.extractor', NULL, 1700000000,
                1700000001, 'completed', 100, 100,
                0, '[]', NULL, NULL,
                NULL, NULL, '[]',
                0, NULL, NULL, NULL, 0,
                NULL, NULL, NULL, NULL, NULL,
                NULL
            );
            """
        var errorPointer: UnsafeMutablePointer<CChar>?
        let schemaResult = sqlite3_exec(database, legacySchema, nil, nil, &errorPointer)
        if let errorPointer { sqlite3_free(errorPointer) }
        XCTAssertEqual(schemaResult, SQLITE_OK)
        sqlite3_close(database)

        // Opening the store runs the v8→v9 migration; the legacy row must
        // survive it and the new column must read back as nil.
        let store = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id.uuidString.lowercased(), taskID)
        XCTAssertEqual(loaded.browserSubmissionType, "youtube.extractor")
        XCTAssertNil(loaded.usedParallelRequests)

        // The migrated column is writable afterwards.
        var migrated = loaded
        migrated.usedParallelRequests = 1
        try store.save([migrated])
        XCTAssertEqual(try XCTUnwrap(store.load().first).usedParallelRequests, 1)
    }

    func testV9DatabaseMigratesToMimeTypeColumn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAppV9MigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Build a v9 database by hand: the full schema minus the
        // mime_type column introduced in v10, plus one row.
        let taskID = UUID().uuidString.lowercased()
        let databaseURL = directory.appendingPathComponent("tasks.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySchema = """
            CREATE TABLE schema_migrations (version INTEGER NOT NULL);
            INSERT INTO schema_migrations(version) VALUES (9);
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY NOT NULL,
                source_url TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                maximum_parallel_requests INTEGER NOT NULL,
                expected_sha256 TEXT,
                source_kind TEXT,
                browser_client_id TEXT,
                browser_submission_type TEXT,
                browser_submission_key TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                received_bytes INTEGER NOT NULL,
                total_bytes INTEGER,
                bytes_per_second REAL NOT NULL,
                speed_history_json TEXT NOT NULL,
                sha256 TEXT,
                verification TEXT,
                error_code TEXT,
                error_message TEXT,
                segments_json TEXT NOT NULL,
                is_archived INTEGER NOT NULL DEFAULT 0,
                average_speed REAL,
                total_duration REAL,
                category TEXT,
                priority INTEGER NOT NULL DEFAULT 0,
                started_at REAL,
                media_duration REAL,
                queue_id TEXT,
                page_url TEXT,
                error_recommendation TEXT,
                error_category TEXT,
                used_parallel_requests INTEGER
            );
            INSERT INTO tasks (
                id, source_url, destination_path, maximum_parallel_requests,
                expected_sha256, source_kind, browser_client_id,
                browser_submission_type, browser_submission_key, created_at,
                updated_at, status, received_bytes, total_bytes,
                bytes_per_second, speed_history_json, sha256, verification,
                error_code, error_message, segments_json,
                is_archived, average_speed, total_duration, category, priority,
                started_at, media_duration, queue_id, page_url, error_recommendation,
                error_category, used_parallel_requests
            ) VALUES (
                '\(taskID)', 'https://example.com/legacy.zip', '/tmp/legacy.zip', 8,
                NULL, NULL, NULL, NULL, NULL, 1700000000,
                1700000001, 'completed', 100, 100,
                0, '[]', NULL, NULL,
                NULL, NULL, '[]',
                0, NULL, NULL, NULL, 0,
                NULL, NULL, NULL, NULL, NULL,
                NULL, NULL
            );
            """
        var errorPointer: UnsafeMutablePointer<CChar>?
        let schemaResult = sqlite3_exec(database, legacySchema, nil, nil, &errorPointer)
        if let errorPointer { sqlite3_free(errorPointer) }
        XCTAssertEqual(schemaResult, SQLITE_OK)
        sqlite3_close(database)

        // Opening the store runs the v9→v10 migration; the legacy row must
        // survive it and the new column must read back as nil.
        let store = try AppTaskStore(directory: directory)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.id.uuidString.lowercased(), taskID)
        XCTAssertNil(loaded.mimeType)

        // The migrated column is writable afterwards.
        var migrated = loaded
        migrated.mimeType = "video/mp4"
        try store.save([migrated])
        XCTAssertEqual(try XCTUnwrap(store.load().first).mimeType, "video/mp4")
    }

    private func makePersistableTask(destination: String) -> AppTask {
        AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
    }
}
