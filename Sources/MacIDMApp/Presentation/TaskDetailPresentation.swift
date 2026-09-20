import Foundation

extension AppTaskStatus {
    /// Byte completion is not task success: errors after transfer must not
    /// retain a full success-looking progress bar in the list or inspector.
    var showsTransferProgress: Bool {
        switch self {
        case .queued, .probing, .running, .pausing, .paused, .cancelling, .verifying:
            true
        default:
            false
        }
    }
}

enum TaskLinkPresentation {
    /// Input must already be redacted by AppTask. Never decode or reconstruct
    /// a signed URL just to generate a shorter display label.
    static func summary(_ value: String) -> String {
        guard let components = URLComponents(string: value), let host = components.host else {
            return String(value.prefix(100))
        }
        let path = components.percentEncodedPath
        return host + (path == "/" ? "" : String(path.prefix(80)))
    }
}
