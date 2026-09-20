import AppKit
import SwiftUI

/// Applies the main window's saved frame before the first stable content
/// layout. SwiftUI's scene restoration can otherwise show the content at its
/// minimum size for one run-loop pass, then resize it to the autosaved frame.
/// The configurator runs once per window, so later user resizing is untouched.
struct MainWindowLayoutConfigurator: NSViewRepresentable {
    private static let defaultSize = NSSize(width: 1_380, height: 760)
    private static let minimumSize = NSSize(width: 1_160, height: 480)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowFrameSpyView()
        view.onAttachedToWindow = { [weak coordinator = context.coordinator] view in
            coordinator?.tryConfigure(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.tryConfigure(from: nsView)
    }

    /// A plain NSView that fires `onAttachedToWindow` synchronously in
    /// `viewDidMoveToWindow`. This is earlier than the next runloop tick
    /// (`DispatchQueue.main.async`), so the saved window frame is applied
    /// before the window's first visible display pass — eliminating the
    /// startup list squeeze-bounce that happened when the content laid out
    /// at the initial (often minimum) size before the frame was restored.
    private final class WindowFrameSpyView: NSView {
        var onAttachedToWindow: ((NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onAttachedToWindow?(self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var didConfigure = false
        private let focusResetter = InitialFocusResetter()
        private let titleVisibilityKeeper = TitleVisibilityKeeper()

        func tryConfigure(from view: NSView) {
            guard !didConfigure, let window = view.window else { return }
            configure(window)
        }

        private func configure(_ window: NSWindow) {
            guard !didConfigure else { return }

            didConfigure = true
            window.contentMinSize = MainWindowLayoutConfigurator.minimumSize
            window.setFrameAutosaveName(AppDelegate.mainWindowFrameName)

            // Match the calmer settings-window chrome: an empty native
            // unified toolbar gives the titlebar controls enough vertical
            // room while the actual actions remain flat accessory views.
            if window.toolbar == nil {
                let titlebarToolbar = NSToolbar(identifier: "MacIDMMainTitlebar")
                titlebarToolbar.displayMode = .iconOnly
                titlebarToolbar.showsBaselineSeparator = true
                window.toolbar = titlebarToolbar
            }
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            focusResetter.attach(to: window)
            titleVisibilityKeeper.attach(to: window)
            TrafficLightAligner.attach(to: window)

            if let savedFrame = Self.savedFrame(),
                Self.isUsable(savedFrame),
                Self.isOnScreen(savedFrame)
            {
                window.setFrame(savedFrame, display: false)
                return
            }

            let targetSize = MainWindowLayoutConfigurator.defaultSize
            window.setContentSize(targetSize)
            window.center()
        }

        private static func savedFrame() -> NSRect? {
            guard
                let raw = UserDefaults.standard.string(
                    forKey: "NSWindow Frame \(AppDelegate.mainWindowFrameName)"
                )
            else {
                return nil
            }
            return NSRectFromString(raw)
        }

        private static func isUsable(_ frame: NSRect) -> Bool {
            frame.width.isFinite && frame.height.isFinite
                && frame.width >= MainWindowLayoutConfigurator.minimumSize.width
                && frame.height >= MainWindowLayoutConfigurator.minimumSize.height
        }

        private static func isOnScreen(_ frame: NSRect) -> Bool {
            NSScreen.screens.contains { screen in
                let intersection = screen.visibleFrame.intersection(frame)
                return intersection.width >= 80 && intersection.height >= 80
            }
        }
    }

    /// Clears the window's initial first responder once, right after the
    /// window first becomes key. SwiftUI promotes the toolbar search field
    /// (the first focusable control) to first responder on launch; without
    /// this reset the user's first click in the task list is consumed just
    /// clearing that focus.
    ///
    /// `@unchecked Sendable`: the observer token is only touched on the main
    /// thread (the notification is delivered on `.main`), but the closure
    /// given to NotificationCenter is `@Sendable`.
    private final class InitialFocusResetter: @unchecked Sendable {
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow) {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self else { return }
                if let observer = self.observer {
                    NotificationCenter.default.removeObserver(observer)
                    self.observer = nil
                }
                // Async: let SwiftUI finish its own first-responder pass for
                // the key event before clearing it.
                DispatchQueue.main.async {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }

    /// Aligns the traffic-light cluster with the sidebar content below:
    /// the close button's left edge lands at x = 18 (the sidebar's 10 pt
    /// list padding + 8 pt row padding, i.e. the "All downloads" icon's left
    /// edge). The system default parks the lights ~7 pt from the window
    /// edge, which read as misaligned with the flat design's column edges.
    /// Re-applied on a few delayed ticks because titlebar subviews are
    /// created lazily and accessory installation re-lays-out the titlebar.
    private enum TrafficLightAligner {
        private static let targetLeadingX: CGFloat = 18

        static func attach(to window: NSWindow) {
            MainActor.assumeIsolated {
                apply(to: window)
                for delay in [0.05, 0.15, 0.4, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated {
                            apply(to: window)
                        }
                    }
                }
            }
        }

        @MainActor
        private static func apply(to window: NSWindow?) {
            guard let window,
                let close = window.standardWindowButton(.closeButton)
            else { return }
            let delta = targetLeadingX - close.frame.origin.x
            guard abs(delta) > 0.01 else { return }
            for buttonType: NSWindow.ButtonType in [
                .closeButton, .miniaturizeButton, .zoomButton,
            ] {
                window.standardWindowButton(buttonType)?.frame.origin.x += delta
            }
            // Re-layout so the leading accessory view follows the moved
            // cluster instead of keeping its old gap.
            close.superview?.needsLayout = true
            close.superview?.layoutSubtreeIfNeeded()
        }
    }

    /// Keeps `titleVisibility = .hidden` in force. SwiftUI reasserts the
    /// visible title when it asynchronously installs the window toolbar,
    /// which brought the "MacIDM" text back after every launch. Reassert
    /// immediately, on a few delayed ticks that bracket toolbar
    /// installation, and every time the window becomes key again.
    private final class TitleVisibilityKeeper: @unchecked Sendable {
        func attach(to window: NSWindow) {
            // Called from the @MainActor coordinator; the delayed and
            // notification closures are delivered on the main thread too,
            // so each hop re-enters the main actor explicitly.
            MainActor.assumeIsolated {
                window.titleVisibility = .hidden
                for delay in [0.05, 0.15, 0.4, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                        MainActor.assumeIsolated {
                            window?.titleVisibility = .hidden
                        }
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        window?.titleVisibility = .hidden
                    }
                }
            }
        }
    }
}
