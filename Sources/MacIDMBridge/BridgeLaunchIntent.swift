import Foundation

/// Persists deliberate App termination across the Native Messaging Host's lifetime.
/// Background requests honor the marker; explicit user actions may clear it and launch.
public enum BridgeLaunchIntent {
    static let markerFileName = "quit-intent.json"

    /// Persisted quit record. The timestamp/pid are diagnostic only; the
    /// Host's decision keys off the marker's presence, not its age, so a
    /// quit stays honored until the user asks to wake the App again.
    public struct Marker: Codable, Equatable {
        public let pid: Int32
        public let quitAt: TimeInterval

        public init(pid: Int32, quitAt: TimeInterval) {
            self.pid = pid
            self.quitAt = quitAt
        }
    }

    public static func markerURL(in directory: URL = BridgePaths.defaultDirectory) -> URL {
        directory.appendingPathComponent(markerFileName)
    }

    /// App-side: persist the quit intent during a graceful shutdown.
    /// Best-effort — a persistence failure must never block termination.
    public static func recordQuitIntent(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: Date = Date(),
        in directory: URL = BridgePaths.defaultDirectory
    ) {
        let marker = Marker(pid: pid, quitAt: now.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = markerURL(in: directory)
        try? data.write(to: url, options: .atomic)
        // Owner-only: the marker lives beside the bridge secret and socket.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Reads the marker. A missing or corrupt marker is treated as "no quit
    /// intent" so a stale/garbled file can never wedge the Host into
    /// refusing every launch.
    public static func quitIntent(in directory: URL = BridgePaths.defaultDirectory) -> Marker? {
        guard let data = try? Data(contentsOf: markerURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    public static func hasQuitIntent(in directory: URL = BridgePaths.defaultDirectory) -> Bool {
        quitIntent(in: directory) != nil
    }

    /// App-side on launch, and Host-side when a user-initiated request
    /// authorizes a fresh wake.
    public static func clearQuitIntent(in directory: URL = BridgePaths.defaultDirectory) {
        try? FileManager.default.removeItem(at: markerURL(in: directory))
    }

    /// Host-side launch decision, isolated as a pure function for testing.
    /// - No marker: preserve the original cold-start behavior (relaunch).
    /// - Marker + background request: suppress — the user quit on purpose.
    /// - Marker + user-initiated request: relaunch; the caller clears the
    ///   marker because the user explicitly asked to wake the App.
    public static func shouldRelaunchApp(
        quitIntentPresent: Bool,
        requestUserInitiated: Bool
    ) -> Bool {
        guard quitIntentPresent else { return true }
        return requestUserInitiated
    }

    /// Classifies a bridge request as an explicit user action (may wake a
    /// quit App) versus background traffic (must not). Downloads are always
    /// user-driven — the product never auto-downloads — and `app.activate`
    /// is the dedicated "open the App" gesture. Inspection can be automatic
    /// (page auto-parse) or manual, so it defers to the `userInitiated`
    /// flag; `ping` is pure background status probing and never wakes a
    /// deliberately quit App.
    public static func isUserInitiatedRequest(_ request: MessageRequest) -> Bool {
        switch request.type {
        case "app.activate", "download.create":
            return true
        case "download.enqueue":
            // The first interactive enqueue is a genuine user action, but the
            // extension's 1s confirmation retries carry poll=true and are
            // background traffic: they must not wake an App the user just
            // quit, otherwise quitting mid-confirmation zombie-restarts it.
            return request.payload["poll"]?.boolValue != true
        case "media.inspect":
            return request.payload["userInitiated"]?.boolValue == true
        default:
            return false
        }
    }
}
