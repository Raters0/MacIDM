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
    /// Non-destructive local actions: surface the most recently completed
    /// file without any countdown or system permission.
    case openFile
    case revealInFinder

    var title: String {
        switch self {
        case .none: String(localized: "无操作")
        case .quitApp: String(localized: "退出 MacIDM")
        case .sleep: String(localized: "睡眠")
        case .shutDown: String(localized: "关机")
        case .openFile: String(localized: "打开最近完成的文件")
        case .revealInFinder: String(localized: "在访达中显示最近完成的文件")
        }
    }

    /// Seconds the countdown window stays open before the action runs,
    /// giving the user a chance to cancel or add new downloads. Local,
    /// reversible actions run immediately — a countdown only guards things
    /// that interrupt the whole Mac or end the session.
    var countdownSeconds: Int {
        switch self {
        case .none, .openFile, .revealInFinder: 0
        case .quitApp: 30
        case .sleep, .shutDown: 60
        }
    }
}
