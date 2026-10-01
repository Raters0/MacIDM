import Foundation
import IDMEngine

/// Bounded in-memory record of "this exact video was just resolved to a
/// downloadable VOD or ended replay", optionally together with the quality
/// list that same resolution produced.
///
/// Why it exists: the live gate in front of every YouTube download is a full
/// `yt-dlp -J --simulate` extraction (JS signature challenge plus player API),
/// and the download itself then resolves the same video a second time. On this
/// machine that pre-launch gate alone measured 0–79 s for the same video, so
/// retrying a failed task, picking a second quality, or resuming after a pause
/// paid the extraction again for an answer that cannot have changed — a plain
/// VOD does not become live, and an ended replay does not either. The same
/// argument covers the inspection that lists qualities: reopening the panel,
/// switching quality or re-submitting from the browser re-ran an extraction
/// whose format list is identical.
///
/// Fail-closed rules that keep the live product invariant (§3.1) intact:
/// - Only a positively allowed verdict reaches the cache. Blocked
///   (currently live / upcoming / replay not generated), `.unknown`, process
///   failure, launch failure and timeout never do, so every outcome short of
///   "explicitly downloadable" keeps running the gate next time.
/// - A key carries a one-way fingerprint of the cookie header the request will
///   actually send, so a verdict obtained anonymously is never reused for an
///   authorized request or the other way round. Raw cookies are never stored.
/// - Entries expire, the table is bounded, and nothing is persisted: an app
///   restart re-probes.
final class YouTubeLiveStatusCache: @unchecked Sendable {
    /// Shared production store; unit tests construct their own instance.
    static let shared = YouTubeLiveStatusCache()

    struct Key: Hashable {
        let videoID: String
        /// `DiagnosticFingerprint.sha256HexPrefix` of the supplied cookie, or
        /// nil when the request runs anonymously.
        let cookieFingerprint: String?
    }

    /// One confirmed video: when it was confirmed, plus the inspection's
    /// quality list when the confirmation came from a full extraction.
    ///
    /// Storing variants is safe for the whole window because a variant URL is
    /// the page URL carrying MacIDM's own `#height=&itag=` selection fragment —
    /// never a signed media address — so reusing the list cannot hand out an
    /// expired download URL; the download path still resolves through yt-dlp.
    struct Entry {
        let confirmedAt: Date
        let variants: [MediaVariant]?
    }

    /// How long one allowed verdict stays authoritative. Deliberately short: it
    /// only has to cover the seconds between an inspection and the download it
    /// authorizes, plus a user's retry of the same video.
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    init(ttl: TimeInterval = 10 * 60, maxEntries: Int = 128) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Cache key for a download/inspection request, or nil when the URL carries
    /// no recognizable video ID. No identity means no caching — the gate runs
    /// instead of guessing an identity from a URL prefix.
    static func key(url: URL, cookie: String?) -> Key? {
        guard let videoID = YouTubeCommandBuilder.youTubeVideoID(from: url) else { return nil }
        return Key(
            videoID: videoID,
            cookieFingerprint: cookie.flatMap { DiagnosticFingerprint.sha256HexPrefix($0) }
        )
    }

    /// True while a fresh allowed verdict exists for the same video and the
    /// same credential shape.
    func isConfirmed(_ key: Key, now: Date = Date()) -> Bool {
        liveEntry(key, now: now) != nil
    }

    /// The quality list recorded with a fresh allowed verdict, or nil when the
    /// entry carries none (a gate-only confirmation) or has expired.
    func cachedVariants(_ key: Key, now: Date = Date()) -> [MediaVariant]? {
        liveEntry(key, now: now)?.variants
    }

    /// Records an allowed verdict, re-stamping the window when the same video
    /// is confirmed again (inspection followed by download, quality switch…).
    /// A confirmation without variants keeps whatever list an earlier
    /// inspection stored, so the download path never erases it.
    func confirm(_ key: Key, variants: [MediaVariant]? = nil, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let payload = variants ?? entries[key]?.variants
        if entries[key] != nil {
            entries[key] = Entry(confirmedAt: now, variants: payload)
            return
        }
        if entries.count >= maxEntries {
            prune(now: now)
        }
        entries[key] = Entry(confirmedAt: now, variants: payload)
    }

    /// Test/diagnostic view of the live table only; never a source of truth.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Reads one entry under the lock, dropping it when its window has passed.
    private func liveEntry(_ key: Key, now: Date) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.confirmedAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    /// Drops expired entries first, then the oldest ones, so a long session
    /// touching many videos cannot grow the table without bound.
    private func prune(now: Date) {
        for (key, entry) in entries where now.timeIntervalSince(entry.confirmedAt) > ttl {
            entries.removeValue(forKey: key)
        }
        while entries.count >= maxEntries,
            let oldest = entries.min(by: { $0.value.confirmedAt < $1.value.confirmedAt })?.key
        {
            entries.removeValue(forKey: oldest)
        }
    }
}
