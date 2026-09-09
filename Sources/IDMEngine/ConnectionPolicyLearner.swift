import Foundation

/// Learns the optimal number of parallel connections per host by observing
/// server responses. When a host rate-limits concurrent connections (429/503,
/// as classified by the caller), the learner records a cap; when a download
/// completes without rejection, it records a hint at the connection count
/// that worked. Entries expire
/// after 24 hours so stale CDN behavior does not permanently throttle traffic.
///
/// The design mirrors FluxDown's dual-observation model (negative cap +
/// positive hint) but is implemented in pure Swift with UserDefaults
/// persistence so it integrates naturally with the existing MacIDM stack.
public actor ConnectionPolicyLearner {

    // MARK: - Public types

    /// A learned policy entry for a single host.
    public struct Entry: Codable, Sendable {
        /// Hard ceiling: the server rejected this many concurrent connections.
        /// nil means no rejection has been observed.
        public var rejectionCap: Int?
        /// The highest connection count that completed successfully.
        public var successHint: Int?
        /// When the entry was last updated.
        public var updatedAt: TimeInterval
    }

    // MARK: - Configuration

    /// Entries older than this are discarded on load and on access.
    private let ttl: TimeInterval = 24 * 60 * 60
    /// Hard floor: never suggest fewer than this many connections.
    private let minimumConnections = 1
    /// Hard ceiling: never suggest more than this many connections. Must stay
    /// aligned with the engine-wide parallel request bound (1...64).
    private let maximumConnections = 64
    /// UserDefaults key for the persisted dictionary.
    private let storageKey = "ConnectionPolicyLearner.entries"

    // MARK: - State

    private var entries: [String: Entry] = [:]
    private let defaults: UserDefaults

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Inline persistence loading here because actor init is nonisolated
        // in Swift 6 and cannot call actor-isolated methods directly.
        if let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            let cutoff = Date().timeIntervalSince1970 - ttl
            self.entries = decoded.filter { $0.value.updatedAt >= cutoff }
        }
    }

    // MARK: - Observation

    /// Records that a download to `host` was rejected by the server while
    /// using `connectionCount` concurrent connections. The learner sets a
    /// cap at `connectionCount - 1` (the server rejected `connectionCount`).
    public func recordRejection(host: String, connectionCount: Int) {
        let normalizedHost = host.lowercased()
        let newCap = max(minimumConnections, connectionCount - 1)
        var entry =
            entries[normalizedHost]
            ?? Entry(
                rejectionCap: nil, successHint: nil, updatedAt: 0
            )
        // Tighten the cap: only lower it, never raise from a rejection.
        if let existingCap = entry.rejectionCap {
            entry.rejectionCap = min(existingCap, newCap)
        } else {
            entry.rejectionCap = newCap
        }
        entry.updatedAt = Date().timeIntervalSince1970
        entries[normalizedHost] = entry
        persistEntries()
    }

    /// Records that a download to `host` completed successfully using
    /// `connectionCount` concurrent connections. The learner stores this
    /// as a positive hint.
    ///
    /// Single-connection successes are ignored: they prove nothing about the
    /// host's tolerance for parallelism, and recording `1` would permanently
    /// cap every later ranged download on the host to a single connection.
    public func recordSuccess(host: String, connectionCount: Int) {
        guard connectionCount >= 2 else { return }
        let normalizedHost = host.lowercased()
        var entry =
            entries[normalizedHost]
            ?? Entry(
                rejectionCap: nil, successHint: nil, updatedAt: 0
            )
        // Raise the hint: keep the highest successful count.
        if let existingHint = entry.successHint {
            entry.successHint = max(existingHint, connectionCount)
        } else {
            entry.successHint = connectionCount
        }
        entry.updatedAt = Date().timeIntervalSince1970
        entries[normalizedHost] = entry
        persistEntries()
    }

    // MARK: - Query

    /// Returns the recommended number of parallel connections for `host`,
    /// clamped to [minimumConnections, requested]. When no policy has been
    /// learned, returns `requested` unchanged.
    ///
    /// The success hint never throttles an unpenalized host — using it as a
    /// general downward cap would lock the first successful count in place
    /// forever and prevent exploration. It only guides hosts that already
    /// have a rejection cap, steering them toward a proven-good count.
    public func recommendedConnections(for host: String, requested: Int) -> Int {
        let normalizedHost = host.lowercased()
        purgeExpiredEntries()
        guard let entry = entries[normalizedHost] else { return requested }
        var result = requested
        if let cap = entry.rejectionCap {
            // Hard constraint: never exceed what the server rejected minus one.
            result = min(result, cap)
            // Prefer a proven-good count when we know the host is sensitive.
            if let hint = entry.successHint, hint <= cap {
                result = min(result, hint)
            }
        }
        return max(minimumConnections, min(maximumConnections, result))
    }

    /// Clears all learned policies. Call when the proxy configuration changes
    /// because CDN behavior is proxy-dependent.
    public func resetAll() {
        entries.removeAll()
        persistEntries()
    }

    /// Returns a snapshot of all current entries for debugging/display.
    public func snapshot() -> [String: Entry] {
        purgeExpiredEntries()
        return entries
    }

    // MARK: - Expiration

    private func purgeExpiredEntries() {
        let cutoff = Date().timeIntervalSince1970 - ttl
        let expired = entries.filter { $0.value.updatedAt < cutoff }.map(\.key)
        for key in expired {
            entries.removeValue(forKey: key)
        }
        if !expired.isEmpty {
            persistEntries()
        }
    }

    // MARK: - Persistence

    private func persistEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
