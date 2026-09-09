import Foundation
import IDMEngine

final class DownloadControlToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DownloadControl = .continue

    func read() -> DownloadControl {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func pause() {
        lock.lock()
        value = .pause
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        value = .cancel
        lock.unlock()
    }
}
