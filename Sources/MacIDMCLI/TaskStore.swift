import Darwin
import Foundation
import IDMEngine

enum StoredStatus: String, Codable {
    case queued, probing, running, pausing, paused, cancelling, cancelled
    case verifying, completed, failed, needsRestart, filenameConflict, storageError
}

enum DesiredAction: String, Codable {
    case run, pause, cancel
}

struct StoredTask: Codable {
    let id: UUID
    var url: String
    let destination: String
    let parallelRequests: Int
    let expectedSHA256: String?
    let createdAt: Date
    var updatedAt: Date
    var status: StoredStatus
    var desiredAction: DesiredAction
    var receivedBytes: Int64
    var totalBytes: Int64?
    var sha256: String?
    var errorCode: String?
    var errorMessage: String?
    var workerPID: Int32?
    /// True when the on-disk URL has had query/credential material removed.
    /// Optional keeps older task JSON files decodable without a migration.
    var requiresRefetch: Bool?
}

final class TaskStore: @unchecked Sendable {
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let sharedMirror: CLIGUIStateMirror?
    private let transientURLLock = NSLock()
    private var transientURLs: [UUID: URL] = [:]

    init(directory: URL) throws {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if directory.lastPathComponent == "cli",
            directory.deletingLastPathComponent().lastPathComponent == "MacIDM"
        {
            sharedMirror = try? CLIGUIStateMirror(
                appDirectory: directory.deletingLastPathComponent().appendingPathComponent("app")
            )
        } else {
            sharedMirror = nil
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func create(_ task: StoredTask) throws {
        try withLock {
            let url = taskURL(task.id)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try writeUnlocked(task)
            try sharedMirror?.upsert(task)
        }
    }

    func load(_ id: UUID) throws -> StoredTask? {
        try withLock {
            let url = taskURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                return try sanitizedLoadedTask(
                    try decoder.decode(StoredTask.self, from: Data(contentsOf: url))
                )
            }
            return try sharedMirror?.load(id)
        }
    }

    func list() throws -> [StoredTask] {
        try withLock {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" && $0.lastPathComponent != ".lock.json" }
            let localTasks: [StoredTask] = urls.compactMap { url in
                guard let task = try? decoder.decode(StoredTask.self, from: Data(contentsOf: url)) else {
                    return nil
                }
                do {
                    return try sanitizedLoadedTask(task)
                } catch {
                    return nil
                }
            }
            let localIDs = Set(localTasks.map(\.id))
            let sharedTasks = (try? sharedMirror?.list() ?? []) ?? []
            return (localTasks + sharedTasks.filter { !localIDs.contains($0.id) })
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Keep signed material in memory only for a foreground invocation. A
    /// detached worker never receives this map, so it cannot recover a secret
    /// URL from disk after a process restart.
    func rememberTransientURL(_ url: URL, for id: UUID) {
        transientURLLock.lock()
        transientURLs[id] = url
        transientURLLock.unlock()
    }

    func runtimeURL(for id: UUID) -> URL? {
        transientURLLock.lock()
        defer { transientURLLock.unlock() }
        return transientURLs[id]
    }

    func hasLocalRecord(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: taskURL(id).path)
    }

    /// Permanently deletes a CLI task record and its App-DB mirror row.
    /// With `deleteFile` the downloaded file (for completed tasks) and all
    /// partial download artifacts are removed as well.
    func remove(_ id: UUID, deleteFile: Bool) throws {
        try withLock {
            if deleteFile, let task = try loadUnlocked(id) {
                let destination = URL(fileURLWithPath: task.destination)
                if task.status == .completed {
                    // removeItem recurses into directories; a completed task's
                    // destination must be a regular file, never a directory
                    // the user pointed --output at.
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: destination.path,
                        isDirectory: &isDirectory
                    )
                    if exists && !isDirectory.boolValue {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                for url in DownloadArtifacts.partialArtifactURLs(destination: destination, taskID: id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let local = taskURL(id)
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try sharedMirror?.delete(id)
        }
    }

    @discardableResult
    func mutate(_ id: UUID, _ body: (inout StoredTask) throws -> Void) throws -> StoredTask? {
        try withLock {
            let localRecord = FileManager.default.fileExists(atPath: taskURL(id).path)
            guard var task = try loadUnlocked(id) ?? sharedMirror?.load(id) else { return nil }
            try body(&task)
            task.updatedAt = Date()
            if localRecord {
                try writeUnlocked(task)
            }
            try sharedMirror?.upsert(task)
            return task
        }
    }

    func claimWorker(_ id: UUID) throws -> StoredTask? {
        try mutate(id) { task in
            if let pid = task.workerPID, pid != getpid(), CLIWorker.isWorkerProcessAlive(pid) {
                throw WorkerClaimError.alreadyRunning
            }
            guard task.status != .completed, task.status != .cancelled else {
                throw WorkerClaimError.terminal
            }
            if task.desiredAction == .pause {
                task.status = .paused
                task.workerPID = nil
                throw WorkerClaimError.terminal
            }
            if task.desiredAction == .cancel {
                task.status = .cancelled
                task.workerPID = nil
                throw WorkerClaimError.terminal
            }
            task.workerPID = getpid()
            task.status = .probing
            task.errorCode = nil
            task.errorMessage = nil
        }
    }

    private func loadUnlocked(_ id: UUID) throws -> StoredTask? {
        let url = taskURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(StoredTask.self, from: Data(contentsOf: url))
    }

    private func writeUnlocked(_ task: StoredTask) throws {
        var sanitized = task
        if let url = URL(string: task.url), CLIURLSafety.hasTransientMaterial(url) {
            sanitized.requiresRefetch = true
        }
        sanitized.url = CLIURLSafety.redacted(task.url)
        let destination = taskURL(task.id)
        let temporary = directory.appendingPathComponent(".\(task.id.uuidString).\(UUID().uuidString).tmp")
        try encoder.encode(sanitized).write(to: temporary, options: .withoutOverwriting)
        guard rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
    }

    private func taskURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func sanitizedLoadedTask(_ task: StoredTask) throws -> StoredTask {
        let redacted = CLIURLSafety.redacted(task.url)
        let requiresRefetch =
            task.requiresRefetch == true
            || DownloadURLPolicy.hasTransientMaterial(task.url)
        guard requiresRefetch else { return task }
        var sanitized = task
        sanitized.url = redacted
        sanitized.requiresRefetch = true
        let hasRuntimeURL = runtimeURL(for: task.id) != nil
        if !hasRuntimeURL && sanitized.status != .completed && sanitized.status != .cancelled {
            sanitized.status = .needsRestart
            sanitized.desiredAction = .pause
            sanitized.errorCode = "NEEDS_REFETCH"
            sanitized.errorMessage = "带参数的下载地址未持久化，请在前台重新提交原始链接。"
            sanitized.workerPID = nil
        }
        try writeUnlocked(sanitized)
        return sanitized
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent(".lock").path
        let descriptor = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw IDMError.storageError("Cannot open task store lock") }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw IDMError.storageError("Cannot lock task store")
        }
        return try operation()
    }
}

enum WorkerClaimError: Error {
    case alreadyRunning
    case terminal
}

/// Thin wrappers over the shared engine policy so the CLI and the App apply
/// the same persistence/redaction rules from one source of truth.
enum CLIURLSafety {
    static func hasTransientMaterial(_ url: URL) -> Bool {
        DownloadURLPolicy.hasTransientMaterial(url.absoluteString)
    }

    static func redacted(_ raw: String) -> String {
        DownloadURLPolicy.redactedForStorage(raw)
    }
}
