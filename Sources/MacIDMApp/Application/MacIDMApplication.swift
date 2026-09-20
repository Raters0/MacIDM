import AppKit
import SwiftUI

@main
struct MacIDMApplication: App {
    private static let stableMainWindowLayoutMigrationKey = "didApplyStableMainWindowLayoutV2"
    private static let legacyMenuBarExtraInsertedKey = "menuBarExtraInsertedV1"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @State private var hotKeyService: GlobalHotKeyService?
    // Deliberately @State, not @AppStorage: the system may write false into
    // the persisted insertion binding, which made subsequent launches start
    // without the menu-bar icon. Launching always inserts the item again.
    @State private var isMenuBarExtraInserted = true

    init() {
        Self.pinOverlayScrollerPreference()
        Self.normalizeMainWindowLayoutIfNeeded()
        // The delegate handles AppKit lifecycle callbacks and global hot-key
        // requests, both of which need the model before any scene appears.
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.model = model
    }

    /// Set the process preference before any scroll view is created to avoid
    /// an initial legacy scrollbar frame. Per-view configuration handles later changes.
    private static func pinOverlayScrollerPreference() {
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    /// `defaultSize` only applies when SwiftUI has no restored AppWindow
    /// frame. Older builds persisted a 1177 pt window that pins the task list
    /// to its 540 pt minimum on every launch. Remove only legacy main-window
    /// frames once; the next launch uses the 1380 pt product default, and any
    /// resize the user makes afterward is persisted normally.
    private static func normalizeMainWindowLayoutIfNeeded() {
        let defaults = UserDefaults.standard
        // Scrub the legacy MenuBarExtra insertion key persisted by the former
        // @AppStorage binding — a persisted false suppressed the menu-bar
        // icon on launch. Runs before the migration guard because affected
        // machines have already completed the layout migration.
        defaults.removeObject(forKey: legacyMenuBarExtraInsertedKey)
        guard !defaults.bool(forKey: stableMainWindowLayoutMigrationKey) else { return }

        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame ")
            && (key == "NSWindow Frame main-AppWindow-1"
                || key.contains("MacIDMApp.MainWindowView"))
        {
            defaults.removeObject(forKey: key)
        }
        defaults.set(400, forKey: "mainDetailColumnWidthV1")
        defaults.set(true, forKey: stableMainWindowLayoutMigrationKey)
    }

    var body: some Scene {
        WindowGroup("MacIDM", id: "main") {
            MainWindowView()
                .environmentObject(model)
                .tint(AppTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                // 232 sidebar + 540 task list + 320 detail column, plus
                // separators. This prevents the three detail actions from
                // being compressed below their single-line minimum.
                // The ideal dimensions are important here: a GeometryReader
                // reports a tiny intrinsic size during the first scene pass,
                // so a minimum-only frame briefly opens at the minimum before
                // SwiftUI applies the restored window frame.
                .frame(
                    minWidth: 1_160,
                    idealWidth: 1_380,
                    minHeight: 480,
                    idealHeight: 760
                )
                .background(MainWindowLayoutConfigurator())
                .task {
                    model.startBrowserBridge()
                    model.startMonitorServer()
                    model.ytdlpManager.autoCheckIfNeeded(settings: model.settings)
                    configureGlobalHotKey()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    model.shutdown()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    model.detectClipboardLinkIfEnabled()
                }
        }
        // A new or reset main window starts with enough room for the fixed
        // sidebar, the compact detail column and a useful seven-column task
        // table. Previously only a minimum was supplied, so the split view
        // distributed restored window space without a product-level default.
        .defaultSize(width: 1_380, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Drop SwiftUI's default "New Window": the app is
                // single-main-window by design — a second main window only
                // duplicates the same state and reads as a bug.
            }
            CommandGroup(after: .newItem) {
                Button("添加下载…") {
                    model.presentNewDownload(draft: nil)
                }
                .keyboardShortcut("n")
                Divider()
                Button("导入任务列表…") {
                    model.importTasks()
                }
                Button("导出任务列表（JSON）…") {
                    model.exportTasks(format: .json)
                }
                Button("导出任务列表（CSV）…") {
                    model.exportTasks(format: .csv)
                }
                Divider()
                Button("清除历史记录…") {
                    NotificationCenter.default.post(name: .macIDMRequestClearHistory, object: nil)
                }
            }

            CommandMenu(String(localized: "任务")) {
                Button("暂停 / 继续") {
                    model.togglePauseResumeSelection()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedTaskIDs.isEmpty)

                Button("查看详情") {
                    model.revealDetailColumn()
                }
                .keyboardShortcut("i")
                .disabled(model.selectedTaskIDs.isEmpty)

                Divider()

                Button("移除记录") {
                    NotificationCenter.default.post(name: .macIDMRequestRemoval, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedTaskIDs.isEmpty)
            }

            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") {
                    SettingsWindowPresenter.shared.show(model: model)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        // A windowed app must use the insertion-binding overload. Apple's
        // unbound MenuBarExtra initializer defines an app's primary scene and
        // must not be combined with WindowGroup; doing so registered the item
        // in System Settings without reliably inserting its menu-bar control.
        MenuBarExtra(isInserted: $isMenuBarExtraInserted) {
            MenuBarContentView()
                .environmentObject(model)
                .tint(AppTheme.accent)
        } label: {
            MenuBarIconLabel()
        }
        .menuBarExtraStyle(.window)
    }

    private func configureGlobalHotKey() {
        guard hotKeyService == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = GlobalHotKeyService {
            // AppDelegate receives the request even when no window (and
            // therefore no SwiftUI observer) is alive.
            NotificationCenter.default.post(name: .macIDMHotKeyRequested, object: nil)
        }
        service.register()
        hotKeyService = service
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.settings.colorScheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Window-close behavior: with "close window keeps menu bar only" enabled, closing the
/// last regular window drops the Dock icon and keeps only the menu-bar
/// control (the download engine never stops). Reads UserDefaults directly
/// because the delegate is created before the SwiftUI model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let closeWindowHidesKey = "closeWindowHidesToMenuBar"
    static let mainWindowFrameName = "main-AppWindow-1"

    /// Injected by the App before any scene appears so lifecycle actions and
    /// the global hot key can operate on the same model as the SwiftUI scenes.
    var model: AppModel?

    private var mainWindow: NSWindow?
    /// Hides the first main window when menu-bar mode is enabled. Cleared
    /// after the first hide so explicit window-opening actions work normally.
    private var shouldHideMainWindowOnLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy (e.g. relaunched after reinstalling
        // over a running app) would share one SQLite DB, host socket and
        // session marker. Hand focus to the existing instance and exit.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = duplicates.first {
            AppLogger.shared.warning(
                .system, "second instance launched while one is running; handing over")
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        // First order of business: crash recording. Installs fatal-signal
        // handlers and reports whether the previous session died abnormally
        // — without this, crashes leave nothing in macidm.log.
        CrashReporter.install(logFileURL: AppLogger.shared.logFileURL)
        // Cold-launch silence: when the user's preference is "close window
        // hides to menu bar", switch to .accessory policy IMMEDIATELY —
        // before SwiftUI creates the main window. This prevents the Dock
        // icon from ever appearing and reduces the visual flash when the
        // main window is hidden a moment later in mainWindowBecameMain.
        // The confirmation window (DownloadDraftWindow) is a separate
        // NSWindow and still appears normally; it temporarily switches
        // back to .regular if needed to honor NSApp.activate.
        if UserDefaults.standard.bool(forKey: Self.closeWindowHidesKey) {
            shouldHideMainWindowOnLaunch = true
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillCloseObserved(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGlobalHotKey),
            name: .macIDMHotKeyRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowBecameMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMainWindowRequested),
            name: .macIDMRequestMainWindow,
            object: nil
        )
    }

    @objc private func handleGlobalHotKey() {
        model?.handleGlobalHotKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Sheets attached to a window veto `terminate(nil)`'s close
    /// negotiation: quitting from ⌘Q, the app menu, the menu-bar window or
    /// the completion action silently did nothing while the settings sheet
    /// (or its nested cookie sheet) was up. End every attached sheet here —
    /// deepest first — then let the termination proceed. Quitting cancels
    /// any in-progress sheet input by design; it must never hang.
    private var isResolvingTerminationSheets = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sheets = sender.windows.filter { $0.sheetParent != nil }
        guard !sheets.isEmpty else { return .terminateNow }
        guard !isResolvingTerminationSheets else { return .terminateLater }

        isResolvingTerminationSheets = true
        for sheet in Self.orderedForEnding(sheets) {
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
        }

        DispatchQueue.main.async {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Attached sheets ordered deepest-first: a nested sheet (the cookie
    /// paste sheet presented on top of the settings sheet) must end before
    /// its parent, or ending the parent strands it. The parent lookup is
    /// injectable so tests can cover the nesting order without driving
    /// real windows.
    static func orderedForEnding(
        _ sheets: [NSWindow],
        parentProvider: (NSWindow) -> NSWindow? = { $0.sheetParent }
    ) -> [NSWindow] {
        func depth(of window: NSWindow) -> Int {
            var steps = 0
            var current: NSWindow? = window
            while let parent = current.flatMap(parentProvider) {
                steps += 1
                current = parent
            }
            return steps
        }
        return sheets.sorted { depth(of: $0) > depth(of: $1) }
    }

    /// SwiftUI can recreate a WindowGroup window after a close. Keep the
    /// reference to the current main window as the source of truth and hide
    /// it instead of relying on a post-close scan of `NSApp.windows`.
    private func resolvedMainWindow(from notification: Notification) -> NSWindow? {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else {
            return nil
        }
        guard window.identifier?.rawValue == "main" || window.title == "MacIDM" else {
            return nil
        }
        return window
    }

    private func hideMainWindowToMenuBar(_ window: NSWindow) {
        guard UserDefaults.standard.bool(forKey: Self.closeWindowHidesKey) else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.orderOut(nil)
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            AppLogger.shared.info(.system, "main window hidden; activation policy=accessory")
        }
    }

    private func restoreMainWindow(_ window: NSWindow) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            AppLogger.shared.info(.system, "main window restored; activation policy=regular")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘N / File > New Window / Dock relaunch must never open a second
    /// main window: focus the existing one instead. Returning false blocks
    /// SwiftUI from instantiating another MainWindowView.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        mainWindow == nil
    }

    /// Opening the app again from Finder/Spotlight while it is in menu-bar
    /// mode should restore the retained main window instead of doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, let mainWindow {
            restoreMainWindow(mainWindow)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.markCleanShutdown()
    }

    @objc private func windowWillCloseObserved(_ notification: Notification) {
        guard let window = resolvedMainWindow(from: notification) else { return }
        // SwiftUI normally autosaves this frame, but explicitly saving it
        // before a menu-bar hide/close makes the next launch deterministic.
        window.setFrameAutosaveName(Self.mainWindowFrameName)
        window.saveFrame(usingName: Self.mainWindowFrameName)
        hideMainWindowToMenuBar(window)
    }

    @objc private func mainWindowBecameMain(_ notification: Notification) {
        guard let window = resolvedMainWindow(from: notification) else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.mainWindowFrameName)
        // Cold-launch silence: hide the first main window immediately so a
        // Host-triggered launch never flashes the main window or
        // steals focus. The confirmation window (DownloadDraftWindow) is a
        // separate NSWindow and still appears normally. Cleared after the
        // first hide so subsequent user-initiated window opens behave
        // normally (e.g. clicking the menu-bar icon restores the window).
        if shouldHideMainWindowOnLaunch {
            shouldHideMainWindowOnLaunch = false
            hideMainWindowToMenuBar(window)
        }
    }

    @objc private func openMainWindowRequested() {
        if let window = mainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) }) {
            mainWindow = window
            restoreMainWindow(window)
            return
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
