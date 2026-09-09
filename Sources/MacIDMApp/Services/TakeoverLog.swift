import Foundation

/// Appends browser-takeover events to a bounded JSONL log so users (and
/// support) can trace why a takeover was accepted, rejected, or timed out.
struct TakeoverLog: Sendable {
    private let fileURL: URL
    private let maximumBytes: UInt64 = 256 * 1_024

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("takeover-log.jsonl")
    }

    var url: URL { fileURL }

    func ensureFileExists() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        // The log contains destination filenames; keep it owner-only.
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    func append(event: String, taskID: UUID?, detail: String) {
        struct Entry: Encodable {
            let timestamp: String
            let event: String
            let taskID: String?
            let detail: String
        }
        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            event: event,
            taskID: taskID?.uuidString.lowercased(),
            detail: detail
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var line = data
        line.append(0x0A)
        ensureFileExists()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Logging must never break the takeover flow.
            }
        } else {
            try? line.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size > maximumBytes,
            let data = try? Data(contentsOf: fileURL)
        else { return }
        // Keep the newest half; drop to the next line boundary so every
        // remaining line is still valid JSON.
        let tail = data.suffix(Int(maximumBytes / 2))
        guard let newlineIndex = tail.firstIndex(of: 0x0A) else { return }
        try? tail.suffix(from: tail.index(after: newlineIndex)).write(to: fileURL, options: .atomic)
    }
}
