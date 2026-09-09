import Darwin
import Foundation
import IDMEngine
import SQLite3

enum AppTaskStoreError: LocalizedError, Equatable {
    case database(String)
    case unsupportedSchema(Int)
    case invalidStoredTask(String)

    var errorDescription: String? {
        switch self {
        case .database(let message):
            String(localized: "任务数据库错误：") + message
        case .unsupportedSchema(let version):
            String(localized: "任务数据库版本 \(version) 不受支持。")
        case .invalidStoredTask(let message):
            String(localized: "任务记录无效：") + message
        }
    }
}

struct AppTaskStore: @unchecked Sendable {
    let directory: URL
    private let fileManager: FileManager
    private let ephemeralBackend: InMemoryTaskStore?

    init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.ephemeralBackend = nil
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try prepareDatabase()
        try migrateLegacyJSONIfNeeded()
    }

    static func ephemeral() -> AppTaskStore {
        AppTaskStore(ephemeralBackend: InMemoryTaskStore())
    }

    private init(ephemeralBackend: InMemoryTaskStore) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDM-ephemeral", isDirectory: true)
        fileManager = .default
        self.ephemeralBackend = ephemeralBackend
    }

    func load() throws -> [AppTask] {
        if let ephemeralBackend { return ephemeralBackend.load() }
        return try withDatabase { database in
            let statement = try prepare(
                """
                SELECT \(AppTaskColumn.selection)
                FROM tasks
                ORDER BY created_at DESC
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            var tasks: [AppTask] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(database) }
                tasks.append(try decodeTask(from: statement))
            }
            return tasks
        }
    }

    func save(_ tasks: [AppTask]) throws {
        if let ephemeralBackend {
            ephemeralBackend.save(tasks)
            return
        }
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
            do {
                let previousStatuses = try loadStatuses(in: database)
                // CLI rows are a read-only mirror from the App's point of
                // view. AppModel loads them for visibility, but must not
                // write a stale snapshot over the live CLI worker state when
                // an unrelated App task changes.
                let appManagedTasks = tasks.filter { !$0.isCLIManaged }
                let taskIDs = Set(appManagedTasks.map { $0.id.uuidString.lowercased() })
                try deleteMissingTasks(taskIDs: taskIDs, in: database)
                for task in appManagedTasks {
                    try upsert(task, in: database)
                    let key = task.id.uuidString.lowercased()
                    if previousStatuses[key] != task.status.rawValue {
                        try insertStatusEvent(task: task, in: database)
                    }
                }
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
    }

    /// Progress-only write path used by the 200 ms download tick. Updates
    /// just the volatile columns of existing rows — no full-table scan, no
    /// status-event bookkeeping, no task identity changes. Callers must
    /// guarantee a full `save` happens on any structural change (add,
    /// remove, status transitions), otherwise those changes would be lost.
    func saveProgress(_ tasks: [AppTask]) throws {
        if let ephemeralBackend {
            ephemeralBackend.saveProgress(tasks)
            return
        }
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
            do {
                for task in tasks where !task.isCLIManaged {
                    try updateProgressColumns(task, in: database)
                }
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
    }

    // MARK: - Queues

    func loadQueues() throws -> [AppQueue] {
        if let ephemeralBackend { return ephemeralBackend.loadQueues() }
        return try withDatabase { database in
            let statement = try prepare(
                """
                SELECT id, name, concurrency, order_mode, is_paused, stop_on_empty,
                       schedule_enabled, schedule_days, schedule_start_minutes,
                       schedule_stop_minutes, created_at
                FROM queues
                ORDER BY created_at ASC
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }
            var queues: [AppQueue] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw databaseError(database) }
                queues.append(try decodeQueue(from: statement))
            }
            return queues
        }
    }

    /// Replaces the persisted queue set atomically. Callers own the
    /// in-memory truth; this is only invoked on structural queue changes.
    func saveQueues(_ queues: [AppQueue]) throws {
        if let ephemeralBackend {
            ephemeralBackend.saveQueues(queues)
            return
        }
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
            do {
                try execute("DELETE FROM queues", in: database)
                for queue in queues {
                    try insertQueue(queue, in: database)
                }
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
    }

    private func insertQueue(_ queue: AppQueue, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO queues (
                id, name, concurrency, order_mode, is_paused, stop_on_empty,
                schedule_enabled, schedule_days, schedule_start_minutes,
                schedule_stop_minutes, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let values: [SQLiteValue] = [
            .text(queue.id.uuidString.lowercased()),
            .text(queue.name),
            .integer(Int64(queue.concurrency)),
            .text(queue.orderMode.rawValue),
            .integer(queue.isPaused ? 1 : 0),
            .integer(queue.stopOnEmpty ? 1 : 0),
            .integer(queue.scheduleEnabled ? 1 : 0),
            .integer(Int64(queue.scheduleDays)),
            .integer(Int64(queue.scheduleStartMinutes)),
            .integer(queue.scheduleStopMinutes.map(Int64.init)),
            .real(queue.createdAt.timeIntervalSince1970),
        ]
        for (offset, value) in values.enumerated() { try bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private func decodeQueue(from statement: OpaquePointer) throws -> AppQueue {
        guard let idString = columnText(statement, 0),
            let id = UUID(uuidString: idString),
            let name = columnText(statement, 1),
            let orderModeString = columnText(statement, 3),
            let orderMode = AppQueue.OrderMode(rawValue: orderModeString)
        else {
            throw AppTaskStoreError.invalidStoredTask(String(localized: "queues 表包含无法解析的行"))
        }
        return AppQueue(
            id: id,
            name: name,
            concurrency: Int(sqlite3_column_int(statement, 2)),
            orderMode: orderMode,
            isPaused: sqlite3_column_int(statement, 4) != 0,
            stopOnEmpty: sqlite3_column_int(statement, 5) != 0,
            scheduleEnabled: sqlite3_column_int(statement, 6) != 0,
            scheduleDays: Int(sqlite3_column_int(statement, 7)),
            scheduleStartMinutes: Int(sqlite3_column_int(statement, 8)),
            scheduleStopMinutes: nullableInt64(statement, 9).map { Int($0) },
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    private func updateProgressColumns(_ task: AppTask, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            UPDATE tasks SET
                updated_at = ?, status = ?, received_bytes = ?, total_bytes = ?,
                bytes_per_second = ?, speed_history_json = ?, segments_json = ?,
                active_transfer_duration = ?
            WHERE id = ?
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let speedHistory = try String(decoding: encoder.encode(task.speedHistory), as: UTF8.self)
        let segments = try String(decoding: encoder.encode(task.segments), as: UTF8.self)
        let values: [SQLiteValue] = [
            .real(task.updatedAt.timeIntervalSince1970),
            .text(task.status.rawValue),
            .integer(task.receivedBytes),
            .integer(task.totalBytes),
            .real(task.bytesPerSecond),
            .text(speedHistory),
            .text(segments),
            .real(task.activeTransferDuration),
            .text(task.id.uuidString.lowercased()),
        ]
        for (offset, value) in values.enumerated() { try bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private var databaseURL: URL {
        directory.appendingPathComponent("tasks.sqlite3")
    }

    private var legacyJSONURL: URL {
        directory.appendingPathComponent("tasks.json")
    }

    private func prepareDatabase() throws {
        if !fileManager.fileExists(atPath: databaseURL.path) {
            guard
                fileManager.createFile(
                    atPath: databaseURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw AppTaskStoreError.database(String(localized: "无法创建 tasks.sqlite3"))
            }
        } else {
            _ = chmod(databaseURL.path, mode_t(0o600))
        }

        try withDatabase { database in
            try execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER NOT NULL
                );
                """,
                in: database
            )
            let version = try schemaVersion(in: database)
            if version > 12 { throw AppTaskStoreError.unsupportedSchema(version) }
            if version == 0 {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS tasks (
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
                        used_parallel_requests INTEGER,
                        mime_type TEXT,
                        active_transfer_duration REAL NOT NULL DEFAULT 0,
                        media_cid TEXT,
                        selected_quality INTEGER
                    );
                    CREATE INDEX IF NOT EXISTS tasks_created_at_index
                        ON tasks(created_at DESC);
                    CREATE TABLE IF NOT EXISTS task_events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        task_id TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        event_type TEXT NOT NULL,
                        status TEXT NOT NULL,
                        detail TEXT
                    );
                    CREATE INDEX IF NOT EXISTS task_events_task_index
                        ON task_events(task_id, created_at DESC);
                    CREATE TABLE IF NOT EXISTS queues (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        concurrency INTEGER NOT NULL,
                        order_mode TEXT NOT NULL,
                        is_paused INTEGER NOT NULL DEFAULT 0,
                        stop_on_empty INTEGER NOT NULL DEFAULT 0,
                        schedule_enabled INTEGER NOT NULL DEFAULT 0,
                        schedule_days INTEGER NOT NULL DEFAULT 127,
                        schedule_start_minutes INTEGER NOT NULL DEFAULT 0,
                        schedule_stop_minutes INTEGER,
                        created_at REAL NOT NULL
                    );
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (12);
                    """,
                    in: database
                )
            }
            var migratedVersion = version
            if migratedVersion == 1 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE tasks ADD COLUMN average_speed REAL;
                    ALTER TABLE tasks ADD COLUMN total_duration REAL;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (2);
                    """,
                    in: database
                )
                migratedVersion = 2
            }
            if migratedVersion == 2 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN category TEXT;
                    ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (3);
                    """,
                    in: database
                )
                migratedVersion = 3
            }
            if migratedVersion == 3 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN started_at REAL;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (4);
                    """,
                    in: database
                )
                migratedVersion = 4
            }
            if migratedVersion == 4 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN media_duration REAL;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (5);
                    """,
                    in: database
                )
                migratedVersion = 5
            }
            if migratedVersion == 5 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN queue_id TEXT;
                    CREATE TABLE IF NOT EXISTS queues (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        concurrency INTEGER NOT NULL,
                        order_mode TEXT NOT NULL,
                        is_paused INTEGER NOT NULL DEFAULT 0,
                        stop_on_empty INTEGER NOT NULL DEFAULT 0,
                        schedule_enabled INTEGER NOT NULL DEFAULT 0,
                        schedule_days INTEGER NOT NULL DEFAULT 127,
                        schedule_start_minutes INTEGER NOT NULL DEFAULT 0,
                        schedule_stop_minutes INTEGER,
                        created_at REAL NOT NULL
                    );
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (6);
                    """,
                    in: database
                )
                migratedVersion = 6
            }
            if migratedVersion == 6 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN page_url TEXT;
                    ALTER TABLE tasks ADD COLUMN error_recommendation TEXT;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (7);
                    """,
                    in: database
                )
                migratedVersion = 7
            }
            if migratedVersion == 7 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN error_category TEXT;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (8);
                    """,
                    in: database
                )
                migratedVersion = 8
            }
            if migratedVersion == 8 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN used_parallel_requests INTEGER;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (9);
                    """,
                    in: database
                )
                migratedVersion = 9
            }
            if migratedVersion == 9 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN mime_type TEXT;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (10);
                    """,
                    in: database
                )
                migratedVersion = 10
            }
            if migratedVersion == 10 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN active_transfer_duration REAL NOT NULL DEFAULT 0;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (11);
                    """,
                    in: database
                )
                migratedVersion = 11
            }
            if migratedVersion == 11 {
                try execute(
                    """
                    ALTER TABLE tasks ADD COLUMN media_cid TEXT;
                    ALTER TABLE tasks ADD COLUMN selected_quality INTEGER;
                    DELETE FROM schema_migrations;
                    INSERT INTO schema_migrations(version) VALUES (12);
                    """,
                    in: database
                )
            }
        }
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard fileManager.fileExists(atPath: legacyJSONURL.path), try load().isEmpty else { return }
        // Legacy tasks.json predates timestamped speed samples: clear the
        // timeless `[Double]` histories instead of fabricating timestamps,
        // and inject defaults for keys introduced since that format existed.
        var raw = try Data(contentsOf: legacyJSONURL)
        if var objects = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] {
            for index in objects.indices {
                objects[index]["speedHistory"] = [String]()
                if objects[index]["isArchived"] == nil { objects[index]["isArchived"] = false }
                if objects[index]["activeTransferDuration"] == nil {
                    objects[index]["activeTransferDuration"] = 0
                }
            }
            raw = try JSONSerialization.data(withJSONObject: objects)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyTasks = try decoder.decode([AppTask].self, from: raw)
        try save(legacyTasks)
        try? fileManager.removeItem(at: legacyJSONURL)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message =
                database.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(localized: "无法打开数据库")
            if let database { sqlite3_close(database) }
            throw AppTaskStoreError.database(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        try execute(
            "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;",
            in: database
        )
        return try body(database)
    }

    private func schemaVersion(in database: OpaquePointer) throws -> Int {
        let statement = try prepare("SELECT COALESCE(MAX(version), 0) FROM schema_migrations", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func loadStatuses(in database: OpaquePointer) throws -> [String: String] {
        let statement = try prepare("SELECT id, status FROM tasks", in: database)
        defer { sqlite3_finalize(statement) }
        var statuses: [String: String] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return statuses }
            guard result == SQLITE_ROW,
                let id = columnText(statement, 0),
                let status = columnText(statement, 1)
            else { throw databaseError(database) }
            statuses[id] = status
        }
    }

    private func deleteMissingTasks(taskIDs: Set<String>, in database: OpaquePointer) throws {
        guard !taskIDs.isEmpty else {
            try execute(
                "DELETE FROM tasks WHERE COALESCE(browser_submission_type, '') != 'cli'",
                in: database
            )
            return
        }
        let statement = try prepare(
            "SELECT id, browser_submission_type FROM tasks",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var stale: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let id = columnText(statement, 0) else {
                throw databaseError(database)
            }
            let isCLIManaged = columnText(statement, 1) == "cli"
            if !taskIDs.contains(id), !isCLIManaged { stale.append(id) }
        }
        for id in stale {
            let delete = try prepare("DELETE FROM tasks WHERE id = ?", in: database)
            defer { sqlite3_finalize(delete) }
            try bind(id, to: delete, at: 1)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw databaseError(database) }
        }
    }

    private func upsert(_ task: AppTask, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO tasks (\(AppTaskColumn.selection)) VALUES (\(AppTaskColumn.placeholders))
            ON CONFLICT(id) DO UPDATE SET \(AppTaskColumn.updates)
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let speedHistory = try String(decoding: encoder.encode(task.speedHistory), as: UTF8.self)
        let segments = try String(decoding: encoder.encode(task.segments), as: UTF8.self)
        let sourceNeedsRefetch =
            sourceURLNeedsRefetch(task.sourceURL)
            && task.status != .completed
            && task.status != .cancelled
        // A redacted (query-stripped) URL can never resume correctly after a
        // restart, regardless of what error originally stopped the task. Force
        // NEEDS_REFETCH in that case so the load path blocks resume instead of
        // silently retrying with the broken URL. Without this, a task that
        // failed with e.g. NETWORK_ERROR keeps that code and bypasses the
        // refetch guard on the next launch.
        let shouldWriteRefetchError = sourceNeedsRefetch && task.errorCode == nil
        let persistedErrorCode =
            shouldWriteRefetchError
            ? "NEEDS_REFETCH"
            : task.errorCode
        let persistedErrorMessage =
            shouldWriteRefetchError
            ? String(localized: "带参数的下载地址未持久化，请重新提交原始链接。")
            : task.errorMessage
        let values: [AppTaskColumn: SQLiteValue] = [
            .id: .text(task.id.uuidString.lowercased()),
            .sourceUrl: .text(redactedURL(task.sourceURL)),
            .destinationPath: .text(task.destinationPath),
            .maximumParallelRequests: .integer(Int64(task.maximumParallelRequests)),
            .expectedSha256: .text(task.expectedSHA256),
            .sourceKind: .text(task.sourceKind?.rawValue),
            .browserClientId: .text(task.browserClientID),
            .browserSubmissionType: .text(task.browserSubmissionType),
            .browserSubmissionKey: .text(task.browserSubmissionKey),
            .createdAt: .real(task.createdAt.timeIntervalSince1970),
            .updatedAt: .real(task.updatedAt.timeIntervalSince1970),
            .status: .text(task.status.rawValue),
            .receivedBytes: .integer(task.receivedBytes),
            .totalBytes: .integer(task.totalBytes),
            .bytesPerSecond: .real(task.bytesPerSecond),
            .speedHistoryJson: .text(speedHistory),
            .sha256: .text(task.sha256),
            .verification: .text(task.verification),
            .errorCode: .text(persistedErrorCode),
            .errorMessage: .text(persistedErrorMessage),
            .segmentsJson: .text(segments),
            .isArchived: .integer(task.isArchived ? 1 : 0),
            .averageSpeed: .real(task.averageSpeed),
            .totalDuration: .real(task.totalDuration),
            .category: .text(task.categoryOverride?.rawValue),
            .priority: .integer(Int64(task.queuePriority)),
            .startedAt: .real(task.startedAt?.timeIntervalSince1970),
            .mediaDuration: .real(task.mediaDuration),
            .queueId: .text(task.queueID?.uuidString.lowercased()),
            .pageUrl: .text(task.pageURL),
            .errorRecommendation: .text(task.errorRecommendation),
            .errorCategory: .text(task.errorCategory),
            .usedParallelRequests: .integer(task.usedParallelRequests.map { Int64($0) }),
            .mimeType: .text(task.mimeType),
            .activeTransferDuration: .real(task.activeTransferDuration),
            .mediaCid: .text(task.mediaCID),
            .selectedQuality: .integer(task.selectedQuality.map { Int64($0) }),
        ]
        for column in AppTaskColumn.allCases {
            guard let value = values[column] else { throw AppTaskStoreError.invalidStoredTask("Missing task column") }
            try bind(value, to: statement, at: column.rawValue + 1)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private func insertStatusEvent(task: AppTask, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO task_events(task_id, created_at, event_type, status) VALUES (?, ?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(task.id.uuidString.lowercased(), to: statement, at: 1)
        try bind(task.updatedAt.timeIntervalSince1970, to: statement, at: 2)
        try bind("status", to: statement, at: 3)
        try bind(task.status.rawValue, to: statement, at: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    private func decodeTask(from statement: OpaquePointer) throws -> AppTask {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let idString = columnText(statement, AppTaskColumn.id.rawValue),
            let id = UUID(uuidString: idString),
            let sourceURL = columnText(statement, AppTaskColumn.sourceUrl.rawValue),
            let destinationPath = columnText(statement, AppTaskColumn.destinationPath.rawValue),
            let statusString = columnText(statement, AppTaskColumn.status.rawValue),
            let status = AppTaskStatus(rawValue: statusString),
            let speedJSON = columnText(statement, AppTaskColumn.speedHistoryJson.rawValue),
            let segmentsJSON = columnText(statement, AppTaskColumn.segmentsJson.rawValue),
            let segments = try? decoder.decode([SegmentSnapshot].self, from: Data(segmentsJSON.utf8))
        else {
            throw AppTaskStoreError.invalidStoredTask(
                String(localized: "tasks.sqlite3 包含无法解析的字段")
            )
        }
        // Speed-history migration policy: new-format
        // samples carry real timestamps; the legacy `[Double]` has no time info
        // and degrades to an empty history on read — never fabricate timestamps
        // for it and claim a real 120-second window. Sanitize uniformly after
        // load (§5): out-of-order and non-finite/negative-speed samples are
        // already sorted out before task construction, so `loaded.speedHistory`
        // is itself the clean view; do not trim against the current wall clock,
        // so snapshots of already-completed historical tasks are not wrongly
        // cleared.
        let decodedHistory =
            (try? decoder.decode([SpeedSample].self, from: Data(speedJSON.utf8))) ?? []
        let speedHistory = SpeedHistoryPolicy.loaded(decodedHistory)
        var task = AppTask(
            id: id,
            sourceURL: redactedURL(sourceURL),
            destinationPath: destinationPath,
            maximumParallelRequests: Int(sqlite3_column_int(statement, AppTaskColumn.maximumParallelRequests.rawValue)),
            expectedSHA256: columnText(statement, AppTaskColumn.expectedSha256.rawValue),
            sourceKind: columnText(statement, AppTaskColumn.sourceKind.rawValue).flatMap(
                DownloadSourceKind.init(rawValue:)),
            browserClientID: columnText(statement, AppTaskColumn.browserClientId.rawValue),
            browserSubmissionType: columnText(statement, AppTaskColumn.browserSubmissionType.rawValue),
            browserSubmissionKey: columnText(statement, AppTaskColumn.browserSubmissionKey.rawValue),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, AppTaskColumn.createdAt.rawValue)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, AppTaskColumn.updatedAt.rawValue)),
            status: status,
            receivedBytes: sqlite3_column_int64(statement, AppTaskColumn.receivedBytes.rawValue),
            totalBytes: nullableInt64(statement, AppTaskColumn.totalBytes.rawValue),
            bytesPerSecond: sqlite3_column_double(statement, AppTaskColumn.bytesPerSecond.rawValue),
            speedHistory: speedHistory,
            sha256: columnText(statement, AppTaskColumn.sha256.rawValue),
            verification: columnText(statement, AppTaskColumn.verification.rawValue),
            errorCode: columnText(statement, AppTaskColumn.errorCode.rawValue),
            errorMessage: columnText(statement, AppTaskColumn.errorMessage.rawValue),
            segments: segments
        )
        task.isArchived = sqlite3_column_int(statement, AppTaskColumn.isArchived.rawValue) != 0
        task.averageSpeed = nullableDouble(statement, AppTaskColumn.averageSpeed.rawValue)
        task.totalDuration = nullableDouble(statement, AppTaskColumn.totalDuration.rawValue)
        task.categoryOverride = columnText(statement, AppTaskColumn.category.rawValue).flatMap(
            DownloadCategory.init(rawValue:))
        task.priority = Int(sqlite3_column_int(statement, AppTaskColumn.priority.rawValue))
        task.startedAt = nullableDouble(statement, AppTaskColumn.startedAt.rawValue).map {
            Date(timeIntervalSince1970: $0)
        }
        task.mediaDuration = nullableDouble(statement, AppTaskColumn.mediaDuration.rawValue)
        task.queueID = columnText(statement, AppTaskColumn.queueId.rawValue).flatMap(UUID.init(uuidString:))
        task.pageURL = columnText(statement, AppTaskColumn.pageUrl.rawValue)
        task.errorRecommendation = columnText(statement, AppTaskColumn.errorRecommendation.rawValue)
        task.errorCategory = columnText(statement, AppTaskColumn.errorCategory.rawValue)
        task.usedParallelRequests = nullableInt64(statement, AppTaskColumn.usedParallelRequests.rawValue).map {
            Int($0)
        }
        task.mimeType = columnText(statement, AppTaskColumn.mimeType.rawValue)
        task.activeTransferDuration = nullableDouble(statement, AppTaskColumn.activeTransferDuration.rawValue) ?? 0
        task.mediaCID = columnText(statement, AppTaskColumn.mediaCid.rawValue)
        task.selectedQuality = nullableInt64(statement, AppTaskColumn.selectedQuality.rawValue).map { Int($0) }
        return task
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw databaseError(database) }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        defer {
            if let errorPointer { sqlite3_free(errorPointer) }
        }
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            throw AppTaskStoreError.database(message)
        }
    }

    private func databaseError(_ database: OpaquePointer) -> AppTaskStoreError {
        .database(String(cString: sqlite3_errmsg(database)))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func nullableInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func nullableDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func redactedURL(_ raw: String) -> String {
        DownloadURLPolicy.redactedForStorage(raw)
    }

    private func sourceURLNeedsRefetch(_ raw: String) -> Bool {
        DownloadURLPolicy.hasTransientMaterial(raw)
    }

    private enum SQLiteValue {
        case text(String?)
        case integer(Int64?)
        case real(Double?)
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        switch value {
        case .text(let value):
            guard let value else {
                result = sqlite3_bind_null(statement, index)
                break
            }
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
            }
        case .integer(let value):
            if let value {
                result = sqlite3_bind_int64(statement, index, value)
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        case .real(let value):
            if let value {
                result = sqlite3_bind_double(statement, index, value)
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        }
        guard result == SQLITE_OK else {
            throw AppTaskStoreError.database(String(localized: "无法写入任务字段"))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try bind(.text(value), to: statement, at: index)
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        try bind(.real(value), to: statement, at: index)
    }
}

private final class InMemoryTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [AppTask] = []
    private var queues: [AppQueue] = []

    func load() -> [AppTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    func save(_ tasks: [AppTask]) {
        lock.lock()
        self.tasks = tasks
        lock.unlock()
    }

    /// Progress-only merge mirroring the SQLite updateProgressColumns
    /// column set. The performance round narrowed the caller's snapshot to
    /// active tasks only; a full replace here would wipe every idle row.
    func saveProgress(_ tasks: [AppTask]) {
        lock.lock()
        defer { lock.unlock() }
        for task in tasks {
            guard let index = self.tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            var existing = self.tasks[index]
            existing.updatedAt = task.updatedAt
            existing.status = task.status
            existing.receivedBytes = task.receivedBytes
            existing.totalBytes = task.totalBytes
            existing.bytesPerSecond = task.bytesPerSecond
            existing.speedHistory = task.speedHistory
            existing.segments = task.segments
            existing.activeTransferDuration = task.activeTransferDuration
            self.tasks[index] = existing
        }
    }

    func loadQueues() -> [AppQueue] {
        lock.lock()
        defer { lock.unlock() }
        return queues
    }

    func saveQueues(_ queues: [AppQueue]) {
        lock.lock()
        self.queues = queues
        lock.unlock()
    }
}

final class AppTaskPersistenceCoordinator: @unchecked Sendable {
    private let store: AppTaskStore
    private let queue = DispatchQueue(label: "com.macidm.task-persistence", qos: .utility)

    init(store: AppTaskStore) {
        self.store = store
    }

    func save(_ tasks: [AppTask]) throws {
        try queue.sync {
            try store.save(tasks)
        }
    }

    func saveAsync(
        _ tasks: [AppTask],
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async {
            do {
                try self.store.save(tasks)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    func saveProgressAsync(
        _ tasks: [AppTask],
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async {
            do {
                try self.store.saveProgress(tasks)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
