import Foundation

/// Periodically writes a JSON snapshot of the app's state to
/// `~/Library/Application Support/MacIDM/status.json` so that external
/// tools (including AI agents) can monitor downloads, bridge status,
/// and yt-dlp availability without screenshots or UI automation.
///
/// The file is written on state changes and at most once per second.
/// It is best-effort: any write failure is silently ignored.
final class StatusExporter: @unchecked Sendable {
    static let shared = StatusExporter()

    private let lock = NSLock()
    private let statusURL: URL
    private var pendingFlush = false
    private var lastFlushTime: Date = .distantPast
    private let minInterval: TimeInterval = 1.0

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacIDM")
        statusURL = directory.appendingPathComponent("status.json")
    }

    struct Snapshot: Codable {
        var timestamp: String
        var appVersion: String
        var bridgeStatus: String
        var ytdlpInstalled: Bool
        var ytdlpVersion: String?
        var ffmpegAvailable: Bool
        var tasks: [TaskSnapshot]
        var recentLogs: [String]
    }

    struct TaskSnapshot: Codable {
        var id: String
        /// Short stable identifier for support reports; safe to share.
        var jobId: String?
        var status: String
        var filename: String
        var receivedBytes: Int64
        var totalBytes: Int64?
        var speed: Double?
        var category: String?
        var errorMessage: String?
        var backend: String?
        var sourceKind: String?
        var createdAt: String
    }

    func export(
        bridgeStatus: String,
        ytdlpInstalled: Bool,
        ytdlpVersion: String?,
        ffmpegAvailable: Bool,
        appVersion: String,
        tasks: [TaskSnapshot],
        recentLogs: [String]
    ) {
        lock.lock()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFlushTime)
        if elapsed < minInterval {
            if !pendingFlush {
                pendingFlush = true
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + (minInterval - elapsed)
                ) { [weak self] in
                    self?.flush(
                        bridgeStatus: bridgeStatus,
                        ytdlpInstalled: ytdlpInstalled,
                        ytdlpVersion: ytdlpVersion,
                        ffmpegAvailable: ffmpegAvailable,
                        appVersion: appVersion,
                        tasks: tasks,
                        recentLogs: recentLogs
                    )
                }
            }
            lock.unlock()
            return
        }
        lastFlushTime = now
        pendingFlush = false
        lock.unlock()
        flush(
            bridgeStatus: bridgeStatus,
            ytdlpInstalled: ytdlpInstalled,
            ytdlpVersion: ytdlpVersion,
            ffmpegAvailable: ffmpegAvailable,
            appVersion: appVersion,
            tasks: tasks,
            recentLogs: recentLogs
        )
    }

    private func flush(
        bridgeStatus: String,
        ytdlpInstalled: Bool,
        ytdlpVersion: String?,
        ffmpegAvailable: Bool,
        appVersion: String,
        tasks: [TaskSnapshot],
        recentLogs: [String]
    ) {
        lock.lock()
        lastFlushTime = Date()
        pendingFlush = false
        lock.unlock()

        let snapshot = Snapshot(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            bridgeStatus: bridgeStatus,
            ytdlpInstalled: ytdlpInstalled,
            ytdlpVersion: ytdlpVersion,
            ffmpegAvailable: ffmpegAvailable,
            tasks: tasks,
            recentLogs: recentLogs
        )

        do {
            let directory = statusURL.deletingLastPathComponent()
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            try data.write(to: statusURL, options: .atomic)
            // The snapshot contains filenames and recent log lines; keep it
            // owner-only even though the write API has no attributes variant.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: statusURL.path
            )
        } catch {
            // Best-effort: silently ignore write failures.
        }
    }
}
