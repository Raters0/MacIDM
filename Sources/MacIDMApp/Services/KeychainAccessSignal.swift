import Foundation

extension Notification.Name {
    /// Posted when the last Keychain credential access in flight has returned,
    /// so window code can recover what the system approval dialog took away.
    static let macIDMCredentialAccessFinished = Notification.Name("MacIDMCredentialAccessFinished")
}

/// Tracks whether a Keychain credential access is in flight.
///
/// Frontmost-application polling cannot classify the resulting focus loss
/// reliably. MacIDM is an `.accessory` app and the confirmation panel is a
/// `.nonactivatingPanel`, so neither ever becomes the frontmost application:
/// while the approval dialog is on screen, `NSWorkspace.frontmostApplication`
/// still reports the browser the user came from, so a panel losing key status
/// looks exactly like the user switching apps.
///
/// Every read or write can raise that dialog — a freshly installed bundle
/// carries a new code identity, which the stored item's login-Keychain ACL does
/// not list yet — so the signal follows the accesses themselves, from whichever
/// thread they run.
///
/// `lock` guards `depth`; every access to it is inside `lock.withLock`.
final class KeychainAccessSignal: @unchecked Sendable {
    static let shared = KeychainAccessSignal()

    private let lock = NSLock()
    /// Nested accesses must not clear the flag early: an inspection and a
    /// download start can overlap.
    private var depth = 0

    var isInFlight: Bool {
        lock.withLock { depth > 0 }
    }

    /// Mark the window around an access that stays on its caller's thread.
    func begin() {
        lock.withLock { depth += 1 }
    }

    func end() {
        let remaining = lock.withLock { () -> Int in
            depth -= 1
            return depth
        }
        guard remaining == 0 else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .macIDMCredentialAccessFinished, object: nil)
        }
    }

    /// Runs `access` off the main actor and marks the window while it runs.
    ///
    /// Off-main is not a performance nicety here: the approval dialog blocks
    /// until the user answers it, and a blocked main thread also delays the
    /// window's resign-key notification until *after* the access has returned.
    /// The window code would then see no access in flight and treat the dialog
    /// as a user-initiated app switch.
    func access<T: Sendable>(_ access: @escaping @Sendable () -> T) async -> T {
        begin()
        defer { end() }
        return await Task.detached(priority: .userInitiated) { access() }.value
    }
}
