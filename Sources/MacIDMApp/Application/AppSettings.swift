import Combine
import Foundation
import IDMEngine

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let maximumParallelRequests = "maximumParallelRequests"
        static let simultaneousDownloads = "simultaneousDownloads"
        static let downloadDirectory = "downloadDirectory"
        static let colorScheme = "colorScheme"
        static let clipboardAutoDetect = "clipboardAutoDetect"
        static let clipboardWatch = "clipboardWatch"
        static let clipboardWatchFilesOnly = "clipboardWatchFilesOnly"
        static let globalHotKeyEnabled = "globalHotKeyEnabled"
        static let globalHotKeyCode = "globalHotKeyCode"
        static let globalHotKeyModifiers = "globalHotKeyModifiers"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let speedLimitKBps = "speedLimitKBps"
        static let notificationSoundsEnabled = "notificationSoundsEnabled"
        static let autoStartDownloads = "autoStartDownloads"
        static let organizeByCategory = "organizeByCategory"
        static let hiddenTableColumns = "hiddenTableColumns"
        static let categoryPaths = "categoryPaths"
        static let ytdlpAutoCheckUpdates = "ytdlpAutoCheckUpdates"
        static let redactFilenames = "redactFilenames"
        static let closeWindowHidesToMenuBar = "closeWindowHidesToMenuBar"
        static let semanticTitleEnabled = "semanticTitleEnabled"
        static let semanticTitleProvider = "semanticTitleProvider"
        static let semanticTitleEndpoint = "semanticTitleEndpoint"
        static let semanticTitleModel = "semanticTitleModel"
        static let mediaInFlightRequests = "mediaInFlightRequests"
        static let proxyEnabled = "proxyEnabled"
        static let proxyKind = "proxyKind"
        static let proxyHost = "proxyHost"
        static let proxyPort = "proxyPort"
        static let proxyUsername = "proxyUsername"
        static let completionAction = "completionAction"
        static let rememberSiteSessions = "rememberSiteSessions"
        static let languagePreference = "languagePreference"
    }

    private let defaults: UserDefaults

    @Published var maximumParallelRequests: Int {
        didSet {
            let clamped = min(64, max(1, maximumParallelRequests))
            // Clamp the in-memory value too: the Agent API assigns raw
            // numbers, and a persisted-only clamp would leave 0 in memory
            // until relaunch (failing every new download).
            if clamped != maximumParallelRequests {
                maximumParallelRequests = clamped
            }
            defaults.set(clamped, forKey: Key.maximumParallelRequests)
        }
    }

    @Published var simultaneousDownloads: Int {
        didSet {
            let clamped = min(10, max(1, simultaneousDownloads))
            if clamped != simultaneousDownloads {
                simultaneousDownloads = clamped
            }
            defaults.set(clamped, forKey: Key.simultaneousDownloads)
        }
    }

    @Published var downloadDirectory: String {
        didSet { defaults.set(downloadDirectory, forKey: Key.downloadDirectory) }
    }

    @Published var colorScheme: AppColorScheme {
        didSet { defaults.set(colorScheme.rawValue, forKey: Key.colorScheme) }
    }

    @Published var clipboardAutoDetect: Bool {
        didSet { defaults.set(clipboardAutoDetect, forKey: Key.clipboardAutoDetect) }
    }

    /// Continuously watch the clipboard for copied links (no need to switch
    /// to this app), off by default. `clipboardAutoDetect` covers the
    /// "copy in browser, then switch here" flow; this covers "copy anywhere".
    @Published var clipboardWatch: Bool {
        didSet { defaults.set(clipboardWatch, forKey: Key.clipboardWatch) }
    }

    /// The continuous watch only offers file and media links (on by
    /// default), so copying an ordinary web page link stays silent.
    @Published var clipboardWatchFilesOnly: Bool {
        didSet { defaults.set(clipboardWatchFilesOnly, forKey: Key.clipboardWatchFilesOnly) }
    }

    /// Master switch for every system-wide shortcut; turning it off
    /// unregisters all of them immediately.
    @Published var globalHotKeyEnabled: Bool {
        didSet { defaults.set(globalHotKeyEnabled, forKey: Key.globalHotKeyEnabled) }
    }

    /// The recorded shortcut for "open New Download", or nil when the user
    /// cleared the recorder (a cleared shortcut is simply not registered).
    @Published var globalHotKeyCombo: GlobalHotKeyCombo? {
        didSet {
            defaults.set(globalHotKeyCombo.map { Int($0.keyCode) } ?? -1, forKey: Key.globalHotKeyCode)
            defaults.set(
                globalHotKeyCombo.map { Int($0.carbonModifiers) } ?? -1,
                forKey: Key.globalHotKeyModifiers
            )
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Global speed limit in KB/s; 0 means unlimited.
    @Published var speedLimitKBps: Int {
        didSet {
            let clamped = max(0, speedLimitKBps)
            if clamped != speedLimitKBps {
                speedLimitKBps = clamped
            }
            defaults.set(clamped, forKey: Key.speedLimitKBps)
        }
    }

    @Published var notificationSoundsEnabled: Bool {
        didSet { defaults.set(notificationSoundsEnabled, forKey: Key.notificationSoundsEnabled) }
    }

    @Published var autoStartDownloads: Bool {
        didSet { defaults.set(autoStartDownloads, forKey: Key.autoStartDownloads) }
    }

    /// When enabled, new downloads are placed below an ASCII category
    /// subdirectory (video/, document/, etc.). Existing files are not moved.
    @Published var organizeByCategory: Bool {
        didSet { defaults.set(organizeByCategory, forKey: Key.organizeByCategory) }
    }

    @Published var hiddenTableColumns: [String] {
        didSet { defaults.set(hiddenTableColumns, forKey: Key.hiddenTableColumns) }
    }

    /// Per-category custom download paths. Keys are `DownloadCategory.rawValue`
    /// strings (e.g., "video", "audio"); values are absolute directory paths.
    /// An empty or missing key falls back to `downloadDirectory`.
    @Published var categoryPaths: [String: String] {
        didSet { defaults.set(categoryPaths, forKey: Key.categoryPaths) }
    }

    /// When true, the app silently checks for yt-dlp releases at startup
    /// (throttled to once per day) and offers an update when outdated.
    @Published var ytdlpAutoCheckUpdates: Bool {
        didSet { defaults.set(ytdlpAutoCheckUpdates, forKey: Key.ytdlpAutoCheckUpdates) }
    }

    /// When true, task lists show the Job ID instead of the filename so the
    /// UI can be shared or screenshotted without revealing what was
    /// downloaded. The on-disk files are untouched.
    @Published var redactFilenames: Bool {
        didSet { defaults.set(redactFilenames, forKey: Key.redactFilenames) }
    }

    /// When true, closing the main window hides the app to the menu bar
    /// (Dock icon removed) instead of leaving it in the Dock; the download
    /// engine and the menu-bar control keep running either way.
    @Published var closeWindowHidesToMenuBar: Bool {
        didSet { defaults.set(closeWindowHidesToMenuBar, forKey: Key.closeWindowHidesToMenuBar) }
    }

    /// 智能命名辅助（technical-spec §8.1 语义判断服务）：默认关闭。开启且配
    /// 置了 endpoint/KEY 后，确认窗口打开时对扩展上送的候选标题做一次仲裁。
    @Published var semanticTitleEnabled: Bool {
        didSet { defaults.set(semanticTitleEnabled, forKey: Key.semanticTitleEnabled) }
    }

    /// 服务商预设 id（SemanticTitleProviderPreset）；选中后设置页自动填充
    /// endpoint 与默认模型。KEY 本体在 Keychain（KeychainCredentialStore 的
    /// semanticTitle 预设），这里只保存非秘密配置。
    @Published var semanticTitleProvider: String {
        didSet { defaults.set(semanticTitleProvider, forKey: Key.semanticTitleProvider) }
    }

    /// 语义判断服务 endpoint；默认空，由服务商预设填充。
    @Published var semanticTitleEndpoint: String {
        didSet { defaults.set(semanticTitleEndpoint, forKey: Key.semanticTitleEndpoint) }
    }

    /// 语义判断服务模型 id；由服务商预设填充，可修改。
    @Published var semanticTitleModel: String {
        didSet { defaults.set(semanticTitleModel, forKey: Key.semanticTitleModel) }
    }

    /// Maximum concurrent HTTP requests for a single HLS/DASH media task.
    /// Higher values improve throughput on fast connections but may trigger
    /// CDN throttling. Default 4 (conservative); range 1–16.
    @Published var mediaInFlightRequests: Int {
        didSet {
            let clamped = min(16, max(1, mediaInFlightRequests))
            // Reassigning unconditionally would re-enter didSet and recurse;
            // the guard stops after the single corrective write.
            if clamped != mediaInFlightRequests {
                mediaInFlightRequests = clamped
            }
            defaults.set(clamped, forKey: Key.mediaInFlightRequests)
            DownloadResourceLimits.configure(maximumInFlightRequests: clamped)
        }
    }

    /// Download proxy. Only the username is persisted here; the password
    /// lives in the login Keychain under the same username as account.
    @Published var proxyEnabled: Bool {
        didSet { defaults.set(proxyEnabled, forKey: Key.proxyEnabled) }
    }

    @Published var proxyKind: ProxyKind {
        didSet { defaults.set(proxyKind.rawValue, forKey: Key.proxyKind) }
    }

    @Published var proxyHost: String {
        didSet { defaults.set(proxyHost, forKey: Key.proxyHost) }
    }

    @Published var proxyPort: Int {
        didSet { defaults.set(min(65_535, max(1, proxyPort)), forKey: Key.proxyPort) }
    }

    @Published var proxyUsername: String {
        didSet { defaults.set(proxyUsername, forKey: Key.proxyUsername) }
    }

    /// What to do once all downloads finish. Persisted across launches:
    /// a user who arms "Shut down" expects it to survive an app restart during
    /// a long overnight batch.
    @Published var completionAction: SystemCompletionAction {
        didSet { defaults.set(completionAction.rawValue, forKey: Key.completionAction) }
    }

    /// When true, a successful browser-extension download automatically
    /// archives that site's session (cookie header) so manually-added
    /// URLs for the same domain can reuse the login state.
    @Published var rememberSiteSessions: Bool {
        didSet { defaults.set(rememberSiteSessions, forKey: Key.rememberSiteSessions) }
    }

    /// Display language. Applied through `LanguageManager`, which writes the
    /// `AppleLanguages` override and relaunches the app; the persisted value
    /// alone never changes the live locale.
    @Published var languagePreference: AppLanguage {
        didSet { defaults.set(languagePreference.rawValue, forKey: Key.languagePreference) }
    }

    /// Validated engine-facing configuration, or nil when the current
    /// fields do not form a usable proxy (invalid host/port).
    var proxyConfiguration: ProxyConfiguration? {
        var credentialReference: ProxyCredentialReference?
        if !proxyUsername.isEmpty {
            guard
                let reference = try? ProxyCredentialReference(keychainAccount: proxyUsername)
            else { return nil }
            credentialReference = reference
        }
        return try? ProxyConfiguration(
            kind: proxyKind,
            host: proxyHost,
            port: proxyPort,
            credentialReference: credentialReference
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let parallel = defaults.integer(forKey: Key.maximumParallelRequests)
        maximumParallelRequests = parallel == 0 ? 8 : min(64, max(1, parallel))
        let simultaneous = defaults.integer(forKey: Key.simultaneousDownloads)
        simultaneousDownloads = simultaneous == 0 ? 3 : min(10, max(1, simultaneous))
        downloadDirectory =
            defaults.string(forKey: Key.downloadDirectory)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        colorScheme =
            defaults.string(forKey: Key.colorScheme).flatMap(AppColorScheme.init(rawValue:))
            ?? .system
        clipboardAutoDetect = defaults.bool(forKey: Key.clipboardAutoDetect)
        clipboardWatch = defaults.bool(forKey: Key.clipboardWatch)
        clipboardWatchFilesOnly =
            defaults.object(forKey: Key.clipboardWatchFilesOnly) == nil
            ? true : defaults.bool(forKey: Key.clipboardWatchFilesOnly)
        globalHotKeyEnabled =
            defaults.object(forKey: Key.globalHotKeyEnabled) == nil
            ? true : defaults.bool(forKey: Key.globalHotKeyEnabled)
        // keyCode 0 is a real key (A), so "never recorded" must be detected by
        // the missing object rather than by integer(forKey:) defaulting to 0;
        // -1 is the explicit "cleared" marker. Unreadable stored values read as
        // cleared instead of resurrecting a global key the user never chose.
        if let keyCode = defaults.object(forKey: Key.globalHotKeyCode) as? Int,
            let modifiers = defaults.object(forKey: Key.globalHotKeyModifiers) as? Int
        {
            if keyCode < 0 || modifiers < 0 {
                globalHotKeyCombo = nil
            } else {
                let recorded = GlobalHotKeyCombo(
                    keyCode: UInt32(keyCode),
                    carbonModifiers: UInt32(modifiers)
                )
                globalHotKeyCombo = recorded.isValid ? recorded : nil
            }
        } else {
            globalHotKeyCombo = .defaultValue
        }
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        speedLimitKBps = max(0, defaults.integer(forKey: Key.speedLimitKBps))
        notificationSoundsEnabled =
            defaults.object(forKey: Key.notificationSoundsEnabled) == nil
            ? true : defaults.bool(forKey: Key.notificationSoundsEnabled)
        autoStartDownloads =
            defaults.object(forKey: Key.autoStartDownloads) == nil
            ? true : defaults.bool(forKey: Key.autoStartDownloads)
        organizeByCategory = defaults.bool(forKey: Key.organizeByCategory)
        hiddenTableColumns = defaults.stringArray(forKey: Key.hiddenTableColumns) ?? []
        categoryPaths =
            defaults.dictionary(forKey: Key.categoryPaths) as? [String: String] ?? [:]
        ytdlpAutoCheckUpdates =
            defaults.object(forKey: Key.ytdlpAutoCheckUpdates) == nil
            ? true : defaults.bool(forKey: Key.ytdlpAutoCheckUpdates)
        redactFilenames = defaults.bool(forKey: Key.redactFilenames)
        closeWindowHidesToMenuBar =
            defaults.object(forKey: Key.closeWindowHidesToMenuBar) == nil
            ? true : defaults.bool(forKey: Key.closeWindowHidesToMenuBar)
        semanticTitleEnabled = defaults.bool(forKey: Key.semanticTitleEnabled)
        semanticTitleProvider =
            defaults.string(forKey: Key.semanticTitleProvider)
            ?? SemanticTitleProviderPreset.all[0].id
        semanticTitleEndpoint = defaults.string(forKey: Key.semanticTitleEndpoint) ?? ""
        semanticTitleModel = defaults.string(forKey: Key.semanticTitleModel) ?? ""
        let mediaInFlight = defaults.integer(forKey: Key.mediaInFlightRequests)
        mediaInFlightRequests = mediaInFlight == 0 ? 4 : min(16, max(1, mediaInFlight))
        proxyEnabled = defaults.bool(forKey: Key.proxyEnabled)
        proxyKind =
            defaults.string(forKey: Key.proxyKind).flatMap(ProxyKind.init(rawValue:)) ?? .http
        proxyHost = defaults.string(forKey: Key.proxyHost) ?? ""
        let storedPort = defaults.integer(forKey: Key.proxyPort)
        proxyPort = storedPort == 0 ? 8080 : min(65_535, max(1, storedPort))
        proxyUsername = defaults.string(forKey: Key.proxyUsername) ?? ""
        completionAction =
            defaults.string(forKey: Key.completionAction)
            .flatMap(SystemCompletionAction.init(rawValue:)) ?? .none
        rememberSiteSessions =
            defaults.object(forKey: Key.rememberSiteSessions) == nil
            ? true : defaults.bool(forKey: Key.rememberSiteSessions)
        languagePreference =
            defaults.string(forKey: Key.languagePreference).flatMap(AppLanguage.init(rawValue:))
            ?? .system
    }
}

enum AppColorScheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }
}

/// User-selectable display language. `rawValue` doubles as the locale
/// identifier written into the `AppleLanguages` override; adding a language
/// means adding a case here plus a matching `.lproj` catalog and a
/// `CFBundleLocalizations` entry in the build script.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Language names are deliberately shown in their own language and are
    /// not translated.
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}
