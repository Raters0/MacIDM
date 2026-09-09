import Foundation

/// Persists the original (unredacted) source URL of each task that would
/// otherwise lose information to the task store's privacy redaction.
///
/// The SQLite task store keeps only a redacted URL (signed query strings,
/// credentials and fragments stripped), which is correct for long-term
/// storage — but it also means a paused download whose URL carries a query
/// (CDN signatures, YouTube watch links, browser takeover URLs) could not
/// survive an app restart: the load path had no usable URL and was forced
/// into NEEDS_REFETCH even though the link itself was still valid.
///
/// The vault stores URLs only — never Cookies, Authorization headers or any
/// other request context, which remain memory-only per spec. Entries expire
/// after a TTL (default 24 h, the spec's default for signed URLs without an
/// explicit expiry) and are dropped when the owning task completes, is
/// cancelled, or is removed. The file lives in the app's private state
/// directory with tightened permissions (0700 directory, 0600 file).
struct SourceURLVault: Sendable {
    struct Entry: Codable, Equatable {
        let url: String
        let expiresAt: Date
    }

    static let defaultTTL: TimeInterval = 24 * 60 * 60

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("source-urls-v1.json")
    }

    /// Reads all entries that have not expired yet; expired or unparsable
    /// entries are silently dropped.
    func load(now: Date = Date()) -> [UUID: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        var entries: [UUID: Entry] = [:]
        for (key, entry) in decoded {
            guard let id = UUID(uuidString: key), entry.expiresAt > now else { continue }
            entries[id] = entry
        }
        return entries
    }

    func save(_ entries: [UUID: Entry]) {
        var payload: [String: Entry] = [:]
        for (id, entry) in entries {
            payload[id.uuidString.lowercased()] = entry
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLogger.shared.warning(
                .system,
                "source URL vault could not be written: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? "SANITIZE_FAILED")"
            )
        }
    }

    func store(id: UUID, url: URL, now: Date = Date(), ttl: TimeInterval = SourceURLVault.defaultTTL) {
        var entries = load(now: now)
        entries[id] = Entry(url: url.absoluteString, expiresAt: now.addingTimeInterval(ttl))
        save(entries)
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var entries = load()
        let before = entries.count
        for id in ids { entries[id] = nil }
        guard entries.count != before else { return }
        save(entries)
    }
}
