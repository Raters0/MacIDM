import Foundation

/// Access and resource rules for the localhost monitor, kept free of socket
/// types so the decisions can be tested without binding a port.
enum MonitorAccessPolicy {
    /// Names a loopback request may legitimately carry. A rebinding page sends
    /// its own hostname, so this list is what refuses it.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// `/health` is the only endpoint readable without the per-launch token,
    /// and its payload is limited to a liveness flag plus the version.
    ///
    /// Every other read names files, errors or log lines, so an unauthenticated
    /// local process could enumerate what the user is downloading.
    static func isPublicReadEndpoint(method: String, path: String) -> Bool {
        method.uppercased() == "GET" && path == "/health"
    }

    static func hostIsAllowed(_ headerValue: String?) -> Bool {
        guard let headerValue, !headerValue.isEmpty else { return false }
        return loopbackHosts.contains(stripPort(headerValue.lowercased()))
    }

    /// A missing `Origin` (curl, CLI, scripts) is allowed; a present one must be
    /// a loopback origin, or the request came from a remote document.
    static func originIsAllowed(_ headerValue: String?) -> Bool {
        guard let headerValue, !headerValue.isEmpty else { return true }
        guard let host = URL(string: headerValue)?.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") {
            // Bracketed IPv6 keeps its own colons; only what follows the
            // closing bracket can be a port.
            guard let closeBracket = host.firstIndex(of: "]") else { return host }
            return String(host[...closeBracket])
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        let tail = host[host.index(after: colon)...]
        return tail.allSatisfy(\.isNumber) ? String(host[..<colon]) : host
    }
}

/// Sliding-window request counter per source address.
///
/// Coarse by design: its job is to stop one flooding client from occupying all
/// of the monitor's bounded connections, not to meter polite automation.
struct MonitorRateLimiter {
    let maximumRequests: Int
    let window: TimeInterval
    private var timestampsBySource: [String: [Date]] = [:]

    init(maximumRequests: Int = 40, window: TimeInterval = 10) {
        self.maximumRequests = maximumRequests
        self.window = window
    }

    mutating func shouldAccept(source: String, now: Date = Date()) -> Bool {
        pruneEmptySources(now: now)
        var stamps = recentStamps(for: source, now: now)
        guard stamps.count < maximumRequests else {
            timestampsBySource[source] = stamps
            return false
        }
        stamps.append(now)
        timestampsBySource[source] = stamps
        return true
    }

    private mutating func pruneEmptySources(now: Date) {
        guard timestampsBySource.count > 32 else { return }
        timestampsBySource = timestampsBySource.filter { entry in
            guard let last = entry.value.last else { return false }
            return now.timeIntervalSince(last) < window
        }
    }

    private func recentStamps(for source: String, now: Date) -> [Date] {
        (timestampsBySource[source] ?? []).filter { now.timeIntervalSince($0) < window }
    }
}
