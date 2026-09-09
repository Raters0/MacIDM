import AppKit
import Foundation

/// Applies the user-selected display language. macOS resolves a bundle's
/// localization at process launch, so an in-app switch writes the standard
/// `AppleLanguages` override into the app's UserDefaults and relaunches.
/// Declaring `CFBundleLocalizations` in the bundle also lets users pick a
/// per-app language from System Settings; both paths use the same catalogs.
enum LanguageManager {
    static let appleLanguagesKey = "AppleLanguages"

    /// Persists the override for the next launch. `.system` removes the
    /// override so the bundle falls back to the system preference list.
    static func apply(
        _ language: AppLanguage,
        defaults: UserDefaults = .standard
    ) {
        if language == .system {
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
    }

    /// Relaunches the app bundle. The replacement instance must not launch
    /// until this process has FULLY exited: the single-instance guard in
    /// `AppDelegate` hands focus back to a still-running copy and exits,
    /// which reads as a stuck restart. The helper polls this PID instead of
    /// assuming a fixed delay, because shutdown persistence (task state,
    /// bridge teardown) takes a variable amount of time.
    @MainActor
    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        guard !bundlePath.isEmpty else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open '\(bundlePath)'",
        ]
        try? process.run()
        // terminate(nil) negotiates window closes, and a sheet attached to
        // the main window (the settings pane hosts this alert) silently
        // cancels the whole quit. End every sheet and close the windows
        // programmatically first: NSWindow.close() bypasses the delegate
        // negotiation, so nothing can veto the shutdown.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        for window in NSApp.windows {
            window.close()
        }
        NSApp.terminate(nil)
    }
}
