import AppKit
import SwiftUI

/// One reusable settings workspace, independent of the main window's sheets.
@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowPresenter()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "设置")
        window.identifier = NSUserInterfaceItemIdentifier("macidm-settings")
        window.contentMinSize = NSSize(width: 940, height: 580)
        // An empty unified toolbar gives the settings window the same calm,
        // vertically centered title region as the main window without
        // introducing visible toolbar items or a second content header.
        let titlebarToolbar = NSToolbar(identifier: "MacIDMSettingsTitlebar")
        titlebarToolbar.displayMode = .iconOnly
        titlebarToolbar.showsBaselineSeparator = true
        window.toolbar = titlebarToolbar
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(
            rootView: SettingsWindowRoot(model: model, settings: model.settings)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacIDMSettings")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SettingsWindowRoot: View {
    let model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsView(model: model)
            .environmentObject(model)
            .tint(AppTheme.accent)
            .preferredColorScheme(colorScheme)
            .background(WindowAppearanceConfigurator(colorScheme: settings.colorScheme))
    }

    private var colorScheme: ColorScheme? {
        switch settings.colorScheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, downloads, network, browser, appearance, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .downloads: String(localized: "下载")
        case .network: String(localized: "网络")
        case .browser: String(localized: "浏览器与站点")
        case .appearance: String(localized: "外观")
        case .advanced: String(localized: "高级与关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .network: "network"
        case .browser: "globe"
        case .appearance: "circle.lefthalf.filled"
        case .advanced: "slider.horizontal.3"
        }
    }
}
