import Darwin
import Foundation
import SQLite3

/// A narrow bridge to the App task database. The CLI keeps its worker control
/// files separate, but the default CLI state also mirrors task identity and
/// progress into the App SQLite store so `macidm status` and the GUI see the
/// same downloads. Signed URL material is redacted before this bridge writes.
final class CLIGUIStateMirror: @unchecked Sendable {
    private let databaseURL: URL

    init(appDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        databaseURL = appDirectory.appendingPathComponent("tasks.sqlite3")
        try ensureDatabase()
    }

    func upsert(_ task: StoredTask) throws {
        try withDatabase { database in
            let statement = try prepare(
                """
                INSERT INTO tasks (
                    id, source_url, destination_path, maximum_parallel_requests,
                    expected_sha256, source_kind, browser_client_id,
                    browser_submission_type, browser_submission_key, created_at,
                    updated_at, status, received_bytes, total_bytes,
                    bytes_per_second, speed_history_json, sha256, verification,
                    error_code, error_message, segments_json,
                    is_archived, average_speed, total_duration, category, priority
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL, 'cli', NULL, ?, ?, ?, ?, ?, 0, '[]', ?, NULL, ?, ?, '[]', 0, NULL, NULL, NULL, 0)
                ON CONFLICT(id) DO UPDATE SET
                    source_url = excluded.source_url,
                    destination_path = excluded.destination_path,
                    maximum_parallel_requests = excluded.maximum_parallel_requests,
                    expected_sha256 = excluded.expected_sha256,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    status = excluded.status,
                    received_bytes = excluded.received_bytes,
                    total_bytes = excluded.total_bytes,
                    sha256 = excluded.sha256,
                    error_code = excluded.error_code,
                    error_message = excluded.error_message,
                    browser_submission_type = 'cli'
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            let values: [SQLiteValue] = [
                .text(task.id.uuidString.lowercased()),
                .text(CLIURLSafety.redacted(task.url)),
                .text(task.destination),
                .integer(Int64(task.parallelRequests)),
                .text(task.expectedSHA256),
                .real(task.createdAt.timeIntervalSince1970),
                .real(task.updatedAt.timeIntervalSince1970),
                .text(appStatus(task.status).rawValue),
                .integer(task.receivedBytes),
                .integer(task.totalBytes),
                .text(task.sha256),
                .text(task.errorCode),
                .text(task.errorMessage),
            ]
            for (offset, value) in values.enumerated() {
                try bind(value, to: statement, at: Int32(offset + 1))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
        }
    }

    /// Deletes a mirrored CLI row. Used by `macidm remove` so a deleted
    /// CLI task disappears from the GUI list; the App never writes CLI rows
    /// itself, so the deletion is not resurrected by App persistence.
    func delete(_ id: UUID) throws {
        try withDatabase { database in
            let statement = try prepare("DELETE FROM tasks WHERE id = ?", database: database)
            defer { sqlite3_finalize(statement) }
            try bind(.text(id.uuidString.lowercased()), to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
        }
    }

    func load(_ id: UUID) throws -> StoredTask? {
        try withDatabase { database in
            let statement = try prepare(
                """
                SELECT id, source_url, destination_path, maximum_parallel_requests,
                       expected_sha256, created_at, updated_at, status,
                       received_bytes, total_bytes, sha256, error_code, error_message
                FROM tasks WHERE id = ?
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(.text(id.uuidString.lowercased()), to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decode(statement)
        }
    }

    func list() throws -> [StoredTask] {
        try withDatabase { database in
            let statement = try prepare(
                """
                SELECT id, source_url, destination_path, maximum_parallel_requests,
                       expected_sha256, created_at, updated_at, status,
                       received_bytes, total_bytes, sha256, error_code, error_message
                FROM tasks ORDER BY created_at DESC
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            var tasks: [StoredTask] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return tasks }
                guard result == SQLITE_ROW else { throw databaseError(database) }
                if let task = try decode(statement) { tasks.append(task) }
            }
        }
    }

    private func decode(_ statement: OpaquePointer) throws -> StoredTask? {
        guard let id = UUID(uuidString: columnText(statement, 0) ?? ""),
            let status = StoredStatus(rawValue: columnText(statement, 7) ?? "")
                ?? fallbackStatus(columnText(statement, 7)),
            let destination = columnText(statement, 2)
        else { return nil }
        return StoredTask(
            id: id,
            url: CLIURLSafety.redacted(columnText(statement, 1) ?? ""),
            destination: destination,
            parallelRequests: Int(sqlite3_column_int(statement, 3)),
            expectedSHA256: columnText(statement, 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            status: status,
            desiredAction: status == .paused ? .pause : .run,
            receivedBytes: sqlite3_column_int64(statement, 8),
            totalBytes: nullableInt64(statement, 9),
            sha256: columnText(statement, 10),
            errorCode: columnText(statement, 11),
            errorMessage: columnText(statement, 12),
            workerPID: nil
        )
    }

    private func ensureDatabase() throws {
        try withDatabase { database in
            try exec(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER NOT NULL);
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
                    priority INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS task_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    detail TEXT
                );
                CREATE INDEX IF NOT EXISTS tasks_created_at_index ON tasks(created_at DESC);
                CREATE INDEX IF NOT EXISTS task_events_task_index ON task_events(task_id, created_at DESC);
                """,
                database: database
            )
            // The App owns migrations, but the CLI can be launched first.
            // Upgrade older task databases here before the first mirror write
            // instead of merely stamping a newer schema version on a table
            // that still lacks the new columns.
            if try !hasColumn("category", in: database) {
                try exec("ALTER TABLE tasks ADD COLUMN category TEXT;", database: database)
            }
            if try !hasColumn("priority", in: database) {
                try exec(
                    "ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;",
                    database: database
                )
            }
            let versionStatement = try prepare(
                "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
                database: database
            )
            defer { sqlite3_finalize(versionStatement) }
            guard sqlite3_step(versionStatement) == SQLITE_ROW else { throw databaseError(database) }
            let version = sqlite3_column_int(versionStatement, 0)
            if version < 3 {
                try exec(
                    "DELETE FROM schema_migrations; INSERT INTO schema_migrations(version) VALUES (3);",
                    database: database
                )
            }
        }
    }

    private func hasColumn(_ name: String, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(tasks)", database: database)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == name { return true }
        }
        return false
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
            throw NSError(domain: "CLIGUIStateMirror", code: Int(result))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        return try body(database)
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw databaseError(database) }
        return statement
    }

    private func exec(_ sql: String, database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        defer { if let errorPointer { sqlite3_free(errorPointer) } }
        guard result == SQLITE_OK else { throw databaseError(database) }
    }

    private func databaseError(_ database: OpaquePointer) -> Error {
        NSError(
            domain: "CLIGUIStateMirror",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func nullableInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        switch value {
        case .text(let value):
            if let value {
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
        case .integer(let value):
            result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        case .real(let value):
            result = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw databaseError(sqlite3_db_handle(statement)) }
    }

    private enum SQLiteValue {
        case text(String?)
        case integer(Int64?)
        case real(Double?)
    }

    private func appStatus(_ status: StoredStatus) -> StoredStatus { status }

    private func fallbackStatus(_ raw: String?) -> StoredStatus? {
        switch raw {
        case "queued", "probing", "running", "pausing", "cancelling", "verifying": return .queued
        case "completed": return .completed
        case "cancelled": return .cancelled
        case "paused": return .paused
        default: return .failed
        }
    }
}
