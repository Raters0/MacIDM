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
    private var activeWindowIDs: Set<ObjectIdentifier> = []
    private var submittedWindowIDs: Set<ObjectIdentifier> = []
    private(set) var previousFrontmostApp: (any RunningApplicationHandle)?
    private let currentProcessPID: pid_t

    init(currentProcessPID: pid_t = NSRunningApplication.current.processIdentifier) {
        self.currentProcessPID = currentProcessPID
    }

    /// Records the frontmost app and registers the window before a new
    /// confirmation window opens.
    func prepareForWindowOpen(
        windowID: ObjectIdentifier,
        frontmostApp: (any RunningApplicationHandle)?
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
}
