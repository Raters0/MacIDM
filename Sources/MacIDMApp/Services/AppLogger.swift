import Foundation

/// Bounded diagnostic logger for the MacIDM app. Writes single-line, structured
/// entries to `~/Library/Application Support/MacIDM/macidm.log` and auto-rotates
/// the file so it never grows unbounded.
///
/// Rotation is size-based: when `macidm.log` exceeds 2 MB it is moved to
/// `macidm.log.1`, older archives shift one generation up, and anything past
/// `macidm.log.7` is dropped. Total disk usage is bounded at roughly 16 MB,
/// which in practice retains about a week of history even under heavy
/// download activity.
///
/// Thread-safe via an internal lock. Every failure is swallowed: logging must
/// never throw, trap, or otherwise disturb the download pipeline.
///
/// Privacy: callers must run any URL through ``redact(_:)`` before logging so
/// query strings, fragments, cookies, and signed tokens never reach disk.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    enum Level: String, Sendable {
        case debug, info, warning, error
    }

    enum Category: String, Sendable {
        case download, engine, bridge, browser, youtube, bilibili, ui, system
    }

    private let lock = NSLock()
    private let logURL: URL
    private let formatter: ISO8601DateFormatter
    private let maximumBytes: UInt64 = 2 * 1024 * 1024
    /// Number of rotated archives kept beside the active log. 7 generations
    /// x 2 MB bounds disk usage at ~16 MB while retaining roughly a week of
    /// history for support investigations.
    private let archiveCount = 7
    /// Bounded tail window for `readLog`; log lines are short single-line
    /// entries, so 128 KB comfortably holds thousands of recent lines.
    private static let tailReadLimit: UInt64 = 128 * 1024

    /// The URL of a rotated archive (`macidm.log.1` … `macidm.log.7`).
    private func archiveURL(generation: Int) -> URL {
        logURL.appendingPathExtension("\(generation)")
    }

    /// The URL of the active log file, exposed for "reveal in Finder" flows.
    var logFileURL: URL { logURL }

    private init() {
        // Tests run in an isolated temporary directory (AppSupportPaths) so
        // `swift test` never appends fixture output to the user's log.
        logURL = AppSupportPaths.supportDirectory().appendingPathComponent("macidm.log")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // MARK: - Convenience entry points

    func debug(_ category: Category, _ message: String) { log(.debug, category, message) }
    func info(_ category: Category, _ message: String) { log(.info, category, message) }
    func warning(_ category: Category, _ message: String) { log(.warning, category, message) }
    func error(_ category: Category, _ message: String) { log(.error, category, message) }

    /// Strips the query string and fragment from a URL so credentials, signed
    /// tokens, and tracking parameters are never persisted to the log.
    func redact(_ url: String) -> String {
        let cutPoints = [url.firstIndex(of: "?"), url.firstIndex(of: "#")].compactMap { $0 }
        guard let cut = cutPoints.min() else { return url }
        return String(url[url.startIndex..<cut])
    }

    // MARK: - Log reading and management

    /// Returns the last `maxLines` lines from the active log file. The most
    /// recent entry is the last line. If the active file has fewer lines than
    /// requested, rotated archives are prepended newest-first until the
    /// request is satisfied or all archives are exhausted.
    ///
    /// Large active files are read from the tail (last ``tailReadLimit``
    /// bytes) instead of in full: status exports read the log on the hot
    /// path and must never pay for megabytes of history just to surface a
    /// handful of recent lines.
    func readLog(maxLines: Int = 500) -> String {
        lock.lock()
        defer { lock.unlock() }
        let activeText = readTail(of: logURL)
        var lines = activeText.split(separator: "\n", omittingEmptySubsequences: true)
        var generation = 1
        while lines.count < maxLines, generation <= archiveCount {
            let archiveText =
                (try? String(contentsOf: archiveURL(generation: generation), encoding: .utf8))
                ?? ""
            if !archiveText.isEmpty {
                let archiveLines = archiveText.split(
                    separator: "\n", omittingEmptySubsequences: true)
                lines = archiveLines + lines
            }
            generation += 1
        }
        guard lines.count > maxLines else { return lines.joined(separator: "\n") }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Reads a bounded tail of a log file. Files within the limit are read
    /// whole; larger files are read from `size - tailReadLimit` and the
    /// first (possibly partial) line is dropped.
    private func readTail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else { return "" }
        if size <= Self.tailReadLimit {
            handle.seek(toFileOffset: 0)
        } else {
            handle.seek(toFileOffset: size - Self.tailReadLimit)
        }
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        if size > Self.tailReadLimit, let firstNewline = text.firstIndex(of: "\n") {
            // The chunk starts mid-line; drop the partial first line.
            text.removeSubrange(text.startIndex...firstNewline)
        }
        return text
    }

    /// Returns the full log contents including all rotated archives (oldest
    /// first), suitable for exporting to a user-selected file.
    func readFullLog() -> String {
        lock.lock()
        defer { lock.unlock() }
        var contents = ""
        for generation in stride(from: archiveCount, through: 1, by: -1) {
            let archiveURL = archiveURL(generation: generation)
            guard let archiveText = try? String(contentsOf: archiveURL, encoding: .utf8),
                !archiveText.isEmpty
            else { continue }
            contents += archiveText
            if !contents.hasSuffix("\n") { contents += "\n" }
        }
        if let activeText = try? String(contentsOf: logURL, encoding: .utf8) {
            contents += activeText
        }
        return contents
    }

    /// Clears the active log file and removes every rotated archive.
    func clearLog() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: logURL, options: .atomic)
        for generation in 1...archiveCount {
            try? FileManager.default.removeItem(at: archiveURL(generation: generation))
        }
    }

    // MARK: - Core

    private func log(_ level: Level, _ category: Category, _ message: String) {
        let sanitized =
            message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        lock.lock()
        defer { lock.unlock() }
        let timestamp = formatter.string(from: Date())
        let entry = "\(timestamp) [\(level.rawValue)] [\(category.rawValue)] \(sanitized)\n"
        write(entry)
    }

    private func write(_ entry: String) {
        let fileManager = FileManager.default
        do {
            let directory = logURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            rotateIfNeeded()
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            // Logging must never break the app; drop the entry silently.
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? UInt64,
            size > maximumBytes
        else { return }
        let fileManager = FileManager.default
        // Shift archives one generation up (newest-first numbering), drop the
        // oldest, then move the active log into generation 1.
        try? fileManager.removeItem(at: archiveURL(generation: archiveCount))
        for generation in stride(from: archiveCount - 1, through: 1, by: -1) {
            let source = archiveURL(generation: generation)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(
                at: source,
                to: archiveURL(generation: generation + 1)
            )
        }
        do {
            try fileManager.moveItem(at: logURL, to: archiveURL(generation: 1))
        } catch {
            // If the move fails (e.g. another process holds the file), fall
            // back to truncating in place so the file does not grow forever.
            try? Data().write(to: logURL, options: .atomic)
            return
        }
        // Start a fresh log file.
        fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
}
