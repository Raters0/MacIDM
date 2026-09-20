import Foundation
import ServiceManagement

/// Manages the "launch at login" registration via `SMAppService.mainApp`.
///
/// macOS 13+ replaced the legacy `SMLoginItemSetEnabled` helper with
/// `SMAppService`, which registers the main app bundle directly with
/// launchd. The registration survives app updates (the bundle identifier
/// is the key) and shows up in System Settings → General → Login Items.
///
/// Caveats:
/// - `register()` throws when the app is not in a standard location
///   (e.g. running from `.build/debug/` during development). The error is
///   surfaced to the user so they know why the toggle did not stick.
/// - `status == .requiresApproval` means the user previously denied the
///   prompt; the toggle reflects this as "on but blocked" and the UI
///   should guide them to System Settings.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered but the user denied the system prompt; they must
        /// re-enable it in System Settings → General → Login Items.
        case requiresApproval
        /// The API is unavailable (macOS < 13) or the bundle is not in a
        /// standard location (development build).
        case unavailable(String)
    }

    @Published private(set) var state: State = .disabled

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    /// Re-read the system state. Called after register/unregister and on
    /// app activation (the user may have changed it in System Settings).
    func refresh() {
        switch service.status {
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .notFound:
            state = .disabled
        @unknown default:
            state = .disabled
        }
    }

    /// Toggle the registration. Returns an error message suitable for
    /// display if the operation failed; nil on success.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
            return nil
        } catch {
            refresh()
            AppLogger.shared.warning(
                .system,
                "launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            // SMAppService throws a generic NSError; the most common cause
            // during development is "operation not permitted" when the app
            // is not in /Applications. Surface a actionable hint.
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                return String(localized: "开机自启动注册被取消。")
            }
            return String(localized: "无法设置开机自启动：\(error.localizedDescription)")
        }
    }
}
