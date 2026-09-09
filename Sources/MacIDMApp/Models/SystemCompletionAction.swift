import Foundation

/// Action to perform once every download has settled and nothing is left
/// queued. Mirrors the IDM signature experience, implemented with explicit
/// macOS capability semantics: system sleep/shutdown go through System
/// Events and can fail (Automation permission denied, pending OS dialogs);
/// failures never take the app down silently.
enum SystemCompletionAction: String, Codable, CaseIterable, Sendable {
    case none
    case quitApp
    case sleep
    case shutDown

    var title: String {
        switch self {
        case .none: String(localized: "无操作")
        case .quitApp: String(localized: "退出 MacIDM")
        case .sleep: String(localized: "睡眠")
        case .shutDown: String(localized: "关机")
        }
    }

    /// Seconds the countdown window stays open before the action runs,
    /// giving the user a chance to cancel or add new downloads.
    var countdownSeconds: Int {
        switch self {
        case .none: 0
        case .quitApp: 30
        case .sleep, .shutDown: 60
        }
    }
}
