import Foundation
import IDMEngine

final class ProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: @Sendable (DownloadProgress) -> Void
    private var lastDelivery = Date.distantPast

    init(callback: @escaping @Sendable (DownloadProgress) -> Void) {
        self.callback = callback
    }

    func receive(_ progress: DownloadProgress) {
        lock.lock()
        let now = Date()
        let shouldDeliver =
            now.timeIntervalSince(lastDelivery) >= 0.2
            || progress.totalBytes == progress.receivedBytes
        if shouldDeliver {
            lastDelivery = now
        }
        lock.unlock()
        if shouldDeliver {
            callback(progress)
        }
    }
}

extension Notification.Name {
    static let macIDMCreateDownload = Notification.Name("MacIDMCreateDownload")
    static let macIDMHotKeyRequested = Notification.Name("MacIDMHotKeyRequested")
    static let macIDMRequestRemoval = Notification.Name("MacIDMRequestRemoval")
    static let macIDMRequestSettings = Notification.Name("MacIDMRequestSettings")
    static let macIDMRequestMainWindow = Notification.Name("MacIDMRequestMainWindow")
}
