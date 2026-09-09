import AppKit
import SwiftUI

/// Hosts download-confirmation drafts in standalone windows. The window is
/// the single required surface for creating a download: browser submissions,
/// the global hotkey and the menu command all open one directly, so the
/// main window never has to be opened (macOS also presents at most one sheet
/// per window, which made sheet-based confirmations block each other).
/// Several drafts can be reviewed side by side without blocking each other.
@MainActor
final class DownloadDraftWindowManager: NSObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = DownloadDraftWindowManager()

    private var windows: [NSWindow] = []
    private var draftsByWindow: [ObjectIdentifier: DownloadDraft] = [:]
    private var modelsByWindow: [ObjectIdentifier: AppModel] = [:]
    let coordinator = DownloadDraftWindowCoordinator()

    func open(draft: DownloadDraft?, model: AppModel) {
        var view = NewDownloadView(draft: draft)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 688, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let key = ObjectIdentifier(window)
        coordinator.prepareForWindowOpen(
            windowID: key,
            frontmostApp: NSWorkspace.shared.frontmostApplication
        )
        // The confirmation form grows with media option cards and the
        // advanced-options disclosure; a hard floor keeps the hosting view
        // resolvable while letting the user enlarge an overflowing form
        // instead of hitting an unsatisfiable-constraint crash.
        window.contentMinSize = NSSize(width: 640, height: 420)
        view.onClose = { [weak window] in
            window?.close()
        }
        view.onSubmitSuccess = { [weak self, weak window] in
            guard let window else { return }
            self?.coordinator.markSubmitted(windowID: ObjectIdentifier(window))
        }
        var relayout: (() -> Void)?
        view.onLayoutChange = { relayout?() }
        let hosting = NSHostingView(rootView: view.environmentObject(model))
        window.contentView = hosting

        // Fit the window's height to the form's natural height so every
        // option is visible at once without a scrollbar. A ceiling keeps very
        // long forms scrollable instead of taller than the screen. Runs at
        // open time and again whenever content grows (async option
        // resolution, disclosure toggles); the top edge stays put so the form
        // never jumps around while the user reads it.
        func fitHeight(animated: Bool) {
            let content = window.contentRect(forFrameRect: window.frame)
            let width = content.width > 0 ? content.width : 688
            // Measure with the window's real width. NSHostingView.fittingSize
            // alone uses the root view's ideal width, where long paths and
            // labels don't wrap — producing a shorter height and visibly
            // shrinking the window on re-layout.
            let probe = NSHostingController(rootView: hosting.rootView)
            let size = probe.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
            let ceiling = min(780, (NSScreen.main?.visibleFrame.height ?? 780) * 0.9)
            let measured = size.height.isFinite ? size.height : 600
            let height = min(max(measured, 480), ceiling)
            guard abs(content.height - height) > 8 else { return }
            let newContent = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            var frame = window.frameRect(forContentRect: newContent)
            frame.origin.x = window.frame.origin.x
            frame.origin.y = window.frame.maxY - frame.height
            window.setFrame(frame, display: true, animate: animated)
        }
        fitHeight(animated: false)
        // One runloop tick later: the SwiftUI state change behind the layout
        // event must settle before measuring, or the probe reads a transient
        // (too small) height and the window collapses.
        relayout = {
            DispatchQueue.main.async { fitHeight(animated: true) }
        }

        window.title = String(localized: "新建下载任务")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // Cascade against the newest confirmation window so several of them
        // stay visible at once instead of stacking on the exact same spot.
        if let previous = windows.last {
            let previousTopLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: previousTopLeft))
        }
        if let draft {
            draftsByWindow[key] = draft
        }
        modelsByWindow[key] = model
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Mirrors the sheet flow's dismiss cleanup: whatever the outcome (submit
    /// or cancel), the pending browser draft record is no longer needed.
    /// NSWindow delegate callbacks arrive on the main thread.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        if let model = modelsByWindow.removeValue(forKey: key) {
            if let draft = draftsByWindow.removeValue(forKey: key) {
                model.clearPendingDownloadDraft(draft)
            }
        }
        windows.removeAll { $0 === window }
        if let appToRestore = coordinator.windowWillClose(windowID: key) {
            DispatchQueue.main.async {
                guard !appToRestore.isTerminated else { return }
                appToRestore.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}
