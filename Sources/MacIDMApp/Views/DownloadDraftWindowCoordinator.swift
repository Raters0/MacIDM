import AppKit
import Foundation

/// Abstract frontmost-application handle; enables mocks in pure-logic unit tests.
public protocol RunningApplicationHandle: AnyObject, Sendable {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }
    @discardableResult
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: RunningApplicationHandle {}

/// Pure-logic coordinator: manages the standalone new-download confirmation
/// window lifecycle and the frontmost-app restoration strategy.
@MainActor
final class DownloadDraftWindowCoordinator {
    /// Where a confirmation panel stands with respect to a system approval
    /// dialog raised by one of our own Keychain accesses.
    enum SystemDialogPhase: Equatable {
        /// No dialog involved: the plain focus-follow level policy applies.
        case none
        /// A credential access is in flight, so the panel is not key only
        /// because the dialog sits on top of it.
        case dialogOpen
        /// The dialog closed and macOS is handing focus back to the application
        /// that had it before. Measured on a live install, that hand-back takes
        /// key status away from a panel raised immediately after the dialog —
        /// four milliseconds after the raise — so the panel waits instead of
        /// demoting, and is raised once more when the wait ends.
        case settling
    }

    private var activeWindowIDs: Set<ObjectIdentifier> = []
    private var submittedWindowIDs: Set<ObjectIdentifier> = []
    private var phasesByWindow: [ObjectIdentifier: SystemDialogPhase] = [:]
    private(set) var previousFrontmostApp: (any RunningApplicationHandle)?
    private let currentProcessPID: pid_t

    init(currentProcessPID: pid_t = NSRunningApplication.current.processIdentifier) {
        self.currentProcessPID = currentProcessPID
    }

    /// Records the frontmost app and registers the window before a new
    /// confirmation window opens.
    ///
    /// `credentialAccessInFlight` covers a dialog that is already on screen when
    /// the panel opens: the panel never becomes key, so it gets no resign-key
    /// event to classify and would otherwise be left behind the browser.
    func prepareForWindowOpen(
        windowID: ObjectIdentifier,
        frontmostApp: (any RunningApplicationHandle)?,
        credentialAccessInFlight: Bool = false
    ) {
        if activeWindowIDs.isEmpty {
            if let app = frontmostApp,
                app.processIdentifier != currentProcessPID,
                !app.isTerminated
            {
                previousFrontmostApp = app
            } else {
                previousFrontmostApp = nil
            }
        }
        activeWindowIDs.insert(windowID)
        if credentialAccessInFlight {
            phasesByWindow[windowID] = .dialogOpen
        }
    }

    /// Marks a confirmation window as successfully submitted with a download
    /// created.
    func markSubmitted(windowID: ObjectIdentifier) {
        submittedWindowIDs.insert(windowID)
        // When the download is created, the user has explicitly submitted the
        // task inside MacIDM, so frontmost focus is no longer handed back.
        previousFrontmostApp = nil
    }

    /// Lifecycle handling when a window is about to close.
    /// Returns the frontmost app to restore when this is the last confirmation
    /// window closing via cancel/Esc/red close button and no download was
    /// ever submitted from it.
    func windowWillClose(windowID: ObjectIdentifier) -> (any RunningApplicationHandle)? {
        activeWindowIDs.remove(windowID)
        phasesByWindow.removeValue(forKey: windowID)
        let wasSubmitted = submittedWindowIDs.remove(windowID) != nil

        if wasSubmitted {
            if activeWindowIDs.isEmpty {
                previousFrontmostApp = nil
            }
            return nil
        }

        // Do not hand focus back while other confirmation windows are alive.
        guard activeWindowIDs.isEmpty else {
            return nil
        }

        guard let app = previousFrontmostApp else {
            return nil
        }
        previousFrontmostApp = nil

        // Do not activate when the previous app has terminated or is ourselves.
        guard !app.isTerminated, app.processIdentifier != currentProcessPID else {
            return nil
        }
        return app
    }

    #if DEBUG
        var activeCount: Int {
            activeWindowIDs.count
        }

        var submittedCount: Int {
            submittedWindowIDs.count
        }
    #endif

    /// Confirmation-window level policy: float above other apps **only while
    /// the user is interacting with that window**.
    ///
    /// `.floating` is required at open time — with an `.accessory` app and a
    /// `.nonactivatingPanel`, a `.normal` window is not reliably raised above
    /// the frontmost browser on macOS 14+ (`orderFrontRegardless()` alone does
    /// not do it). Keeping that level permanently is what made the panel
    /// uncoverable: switching to another app could never put a window over it.
    /// Demoting on resign-key lets other apps cover it, and re-promoting when
    /// it becomes key again keeps it readable while the user fills the form.
    ///
    /// A panel in either dialog phase keeps `.floating` although it is not key:
    /// only the dialog, or the focus hand-back that follows it, is in front.
    static func windowLevel(isKeyWindow: Bool, phase: SystemDialogPhase) -> NSWindow.Level {
        (isKeyWindow || phase != .none) ? .floating : .normal
    }

    func phase(of windowID: ObjectIdentifier) -> SystemDialogPhase {
        phasesByWindow[windowID] ?? .none
    }

    /// Classifies a lost-key event and returns the resulting phase.
    ///
    /// `credentialAccessInFlight` is the signal: while one of our own credential
    /// accesses runs, the only thing that can take focus is the approval dialog.
    /// The frontmost application cannot be used for this — it keeps reporting
    /// the browser, because a `.nonactivatingPanel` never activates MacIDM.
    func recordResignKey(
        windowID: ObjectIdentifier,
        credentialAccessInFlight: Bool
    ) -> SystemDialogPhase {
        // The focus hand-back after a dialog looks exactly like the user
        // switching apps. Waiting for the settle timer is what separates them.
        if phase(of: windowID) == .settling { return .settling }
        let next: SystemDialogPhase = credentialAccessInFlight ? .dialogOpen : .none
        phasesByWindow[windowID] = next
        return next
    }

    func recordBecomeKey(windowID: ObjectIdentifier) {
        phasesByWindow.removeValue(forKey: windowID)
    }

    /// Called when the last credential access returned: the panels held for the
    /// dialog move to their waiting phase, and the caller schedules one raise.
    func beginSettlingAfterSystemDialog() -> [ObjectIdentifier] {
        let opened = phasesByWindow.compactMap { $0.value == .dialogOpen ? $0.key : nil }
        for windowID in opened {
            phasesByWindow[windowID] = .settling
        }
        return opened
    }

    /// Panels still waiting for the focus hand-back, taken as the wait ends.
    func endSettlingAfterSystemDialog() -> [ObjectIdentifier] {
        let waiting = phasesByWindow.compactMap { $0.value == .settling ? $0.key : nil }
        for windowID in waiting {
            phasesByWindow.removeValue(forKey: windowID)
        }
        return waiting
    }

    var isAnyWindowSettlingAfterSystemDialog: Bool {
        phasesByWindow.values.contains(.settling)
    }
}
