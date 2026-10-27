import AppKit
import Sparkle

/// Sparkle-backed app update engine (technical-spec §6.1). Owns the
/// `SPUUpdater` and translates its delegate callbacks into the published
/// `State` that the Settings row and the menu bar banner render.
///
/// Consent model: Sparkle's scheduled check (daily, `SUScheduledCheckInterval`)
/// asks for permission once through the standard driver on first use, and
/// installation only proceeds after the user approves Sparkle's dialog
/// unless they explicitly enable automatic downloads in Settings. The feed
/// and the EdDSA public key come from Info.plist; the app bundle itself is
/// ad-hoc signed — update authenticity rests on the EdDSA signature of the
/// release archive, not on Developer ID.
@MainActor
final class AppUpdateEngine: NSObject, ObservableObject {

    enum State: Equatable {
        /// Engine configured but no check has completed yet (or it never
        /// started because the bundle lacks the Sparkle configuration).
        case idle
        case upToDate
        case updateAvailable(latest: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private var updater: SPUUpdater?

    /// Whether Sparkle may run its scheduled daily check. Persisted by
    /// Sparkle (`SUAutomaticallyChecksForUpdates`); before the user answers
    /// the first-run consent prompt this reads as off. With scheduled checks
    /// off, the Settings "check now" button is the only check source.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            // A computed property does not publish on its own, so views reading
            // it (the Settings row that is disabled while checks are off)
            // would keep their stale state until something else re-rendered.
            objectWillChange.send()
        }
    }

    /// Whether Sparkle may download and install found updates without a
    /// per-update prompt. Sparkle persists the value itself.
    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            updater?.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    /// Starts the Sparkle updater. Call once after the application exists
    /// (applicationDidFinishLaunching). Idempotent. A thrown start leaves
    /// the engine idle with a failed state so Settings can show why.
    func start() {
        guard updater == nil else { return }
        let hostBundle = Bundle.main
        let driver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        let updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            state = .failed(message: error.localizedDescription)
            AppLogger.shared.warning(
                .system, "update engine failed to start: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        AppLogger.shared.info(
            .system, "update engine started (feed: \(updater.feedURL?.absoluteString ?? "none"))")
    }

    /// User-initiated check. Sparkle's standard driver renders the progress
    /// and result dialogs — including the update window with the embedded
    /// release notes and the Install button — and the delegate callbacks
    /// below mirror the outcome into `state` so it stays visible after the
    /// dialogs close. The app is activated first: from the menu bar panel it
    /// may not be frontmost, and Sparkle's window would open behind others.
    func checkForUpdates() {
        guard let updater else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}

extension AppUpdateEngine: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let latest = item.displayVersionString
        state = .updateAvailable(latest: latest)
        AppLogger.shared.info(.system, "update available via Sparkle: \(latest)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state = .upToDate
        AppLogger.shared.info(.system, "update check finished: up to date")
    }

    func updater(_ updater: SPUUpdater, failedWithError error: Error) {
        state = .failed(message: error.localizedDescription)
        AppLogger.shared.warning(
            .system, "update check failed: \(error.localizedDescription)")
    }
}
