import AppKit
import SwiftUI

/// Owns independent, reusable log windows. Logs are diagnostic workspaces,
/// not decisions that belong in an attached settings sheet, so each viewer
/// can now be moved, resized, minimized, and kept open after settings closes.
@MainActor
final class LogWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = LogWindowPresenter()

    private enum Kind: Hashable {
        case app
        case takeover
    }

    private var windows: [Kind: NSWindow] = [:]

    func showAppLog(settings: AppSettings) {
        show(
            kind: .app,
            title: String(localized: "MacIDM 日志"),
            rootView: AnyView(LogViewerView()),
            settings: settings
        )
    }

    func showTakeoverLog(logURL: URL?, settings: AppSettings) {
        show(
            kind: .takeover,
            title: String(localized: "MacIDM 接管日志"),
            rootView: AnyView(TakeoverLogView(logURL: logURL)),
            settings: settings
        )
    }

    private func show(
        kind: Kind,
        title: String,
        rootView: AnyView,
        settings: AppSettings
    ) {
        let themedRoot = AnyView(
            ThemedLogWindowRoot(settings: settings, content: rootView)
        )
        if let window = windows[kind] {
            window.contentViewController = NSHostingController(rootView: themedRoot)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(
            kind == .app ? "macidm-app-log" : "macidm-takeover-log"
        )
        window.contentMinSize = NSSize(width: 840, height: 480)
        window.contentViewController = NSHostingController(rootView: themedRoot)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closed }
    }
}

/// Independent AppKit windows do not inherit the SwiftUI WindowGroup's
/// preferred color scheme. Observe the same settings object and apply the
/// theme to both the hosted SwiftUI content and the native title bar.
private struct ThemedLogWindowRoot: View {
    @ObservedObject var settings: AppSettings
    let content: AnyView

    var body: some View {
        content
            .tint(AppTheme.accent)
            .preferredColorScheme(preferredColorScheme)
            .appWindowSurface()
            .background(WindowAppearanceConfigurator(colorScheme: settings.colorScheme))
    }

    private var preferredColorScheme: ColorScheme? {
        switch settings.colorScheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
