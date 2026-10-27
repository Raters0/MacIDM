import AppKit
import Combine
import Foundation
import IDMEngine
import MacIDMBridge
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [AppTask]
    @Published var queues: [AppQueue] = []
    @Published var selectedTaskID: UUID?
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var sidebarFilter: SidebarFilter? = .all
    @Published var searchText = ""
    @Published var isDetailColumnRequested = false
    @Published var presentedError: PresentedError?
    @Published var browserBridgeStatus: BrowserBridgeStatus = .stopped
    @Published var browserBridgeLastActivity: Date?
    // displayTick was removed: it triggered a global objectWillChange every
    // second, causing the entire Table and all model-dependent views to
    // re-render even when only a single DurationCell needed updating.
    // DurationCell now manages its own local timer via .onReceive.

    let settings: AppSettings

    let store: AppTaskStore
    let takeoverStore: BrowserTakeoverStore
    let persistenceCoordinator: AppTaskPersistenceCoordinator
    let notifier = NotificationService()
    let keychainCredentialStore = KeychainCredentialStore()
    /// 语义判断服务 KEY 的钥匙串存储（独立 service，见 technical-spec §8.1）。
    let semanticTitleKeychainStore = KeychainCredentialStore.PresetService.semanticTitle
    let semanticTitleService: SemanticTitleService
    var takeoverLog: TakeoverLog?
    /// Enforces the global speed limit from settings (nil inner = unlimited).
    /// One stable wrapper instance is captured by every started task; the
    /// inner token bucket is swapped whenever the speed-limit setting changes
    /// so in-flight downloads pick up the new limit without a pause/resume.
    let sharedRateLimiter = DynamicRateLimiter()
    /// Continuous clipboard watch (`clipboardWatch` setting, default off).
    /// The on-activate detector and this watcher share the offer path.
    let clipboardLinkWatcher = ClipboardLinkWatcher()
    /// Per-task dynamic limiters, one for every task that has started a
    /// transfer (unlimited until the user caps it). Keyed by task id so a cap
    /// set on an already-running task reaches its in-flight transfers;
    /// entries are dropped when the task is removed.
    private(set) var taskRateLimiters: [UUID: DynamicRateLimiter] = [:]
    /// Learns optimal connection counts per host to avoid CDN throttling.
    let connectionPolicyLearner = ConnectionPolicyLearner()

    var takeoverLogURL: URL? { takeoverLog?.url }
    let browserProbe: @Sendable (DownloadRequest) async throws -> ResourceInfo
    let downloadRunner: any AppDownloadRunning
    let ffmpegRemuxer: (any FFmpegRemuxing)?
    let ffmpegMerger: (any FFmpegMerging)?
    let mediaInspector: any MediaInspecting
    let pageMediaDiscoverer: any WebPageMediaDiscovering
    let bilibiliAdapter: BilibiliPlayurlAdapter
    let browserBridge = AppBrowserBridge()
    let ytdlpManager = YTDlpManager()
    /// Sparkle-backed update engine (check, download, install, relaunch).
    /// Started from the app delegate once NSApplication exists; Settings
    /// and the menu bar panel render its state.
    let updateEngine = AppUpdateEngine()
    /// Manages the "launch at login" registration via SMAppService.
    /// Exposed so SettingsView can bind a toggle and surface errors.
    let launchAtLoginManager = LaunchAtLoginManager()
    /// Per-site persisted login sessions (cookie headers). Successful
    /// browser-extension downloads archive their session here; manually
    /// added URLs reuse it, and auth failures flag it as expired.
    let sessionStore: SessionStore

    /// User-facing prompt raised when a download fails because a site
    /// session is missing or appears expired.
    struct SessionAlert: Identifiable, Equatable {
        let id = UUID()
        let domain: String
        /// true: a stored session was used but rejected (likely expired);
        /// false: no session was available at all.
        let expired: Bool
        /// The failed task, so the paste flow can retry it immediately.
        let taskID: UUID?
    }

    /// Non-nil when the session-expiry guidance alert should be shown.
    @Published var sessionAlert: SessionAlert?
    /// Bounded queue of pending session guidance alerts waiting to be presented.
    var pendingSessionAlerts: [SessionAlert] = []
    static let maximumPendingSessionAlerts = 20
    /// Count of authentication failure guidance alerts dropped due to reaching `maximumPendingSessionAlerts`.
    private(set) var droppedSessionAlertsCount: Int = 0
    /// Flag ensuring at most one next-alert presentation task is scheduled across runloop turns.
    private var isNextSessionAlertScheduled = false
    /// Drives the manual cookie-paste sheet (opened from the alert or
    /// from the new-download advanced options).
    @Published var cookiePasteDomain: String?
    /// Task captured alongside `cookiePasteDomain` so the paste flow can
    /// retry it — the alert item is cleared before the sheet appears.
    @Published var cookiePasteRetryTaskID: UUID?
    /// Protected persistence for original (unredacted) source URLs, so a
    /// paused signed/browser URL download can resume after an app restart
    /// instead of being forced into NEEDS_REFETCH.
    let sourceURLVault: SourceURLVault
    var browserTakeovers: [BrowserTakeoverRecord]
    var abandonedTakeovers: [AbandonedBrowserTakeover]
    var transientSourceURLs: [UUID: URL] = [:]
    var transientPairAudioURLs: [UUID: URL] = [:]
    var transientPairCIDs: [UUID: String] = [:]
    var transientRequestContexts: [UUID: TransientRequestContext] = [:]
    var pendingInteractiveTakeovers: [String: PendingInteractiveTakeover] = [:]
    /// Per-draft outcome chosen when the user dismisses a browser-takeover
    /// confirmation: true = also cancel the paused browser download (the
    /// default "取消"), false = hand control back so the browser resumes.
    var interactiveCancelOutcomes: [String: Bool] = [:]
    var pendingDownloadDrafts: [String: DownloadDraft] = [:]
    /// Bumped by every start(id:); stale engine callbacks whose generation
    /// no longer matches must not mutate the replacement execution's state.
    let executions = AppExecutionRegistry()
    var pendingRemovals: Set<UUID> = []
    var progressSamples: [UUID: (date: Date, bytes: Int64)] = [:]
    /// Per-task active-transfer accumulator behind the completion average:
    /// the last progress instant, the highest byte count seen, and the
    /// accumulated seconds during which bytes actually advanced. Seeded on
    /// (re)start from the persisted value so pause/resume gaps never count.
    var activeTransferAccumulators: [UUID: (date: Date, bytes: Int64, seconds: TimeInterval)] = [:]
    /// Most recent non-zero speed per task. Progress sources can briefly
    /// report zero between phases (e.g. yt-dlp download → FFmpeg remux);
    /// the UI falls back to this so the speed column never blanks out
    /// mid-task.
    var lastKnownSpeeds: [UUID: Double] = [:]
    /// Pending progress updates buffered for throttled UI flushing. Each
    /// progress callback from the download engine stores the latest value
    /// here; a timer flushes them to `tasks` at most every 300 ms, avoiding
    /// a full Table re-render on every callback (which can arrive many
    /// times per second and cause UI lag, especially on initial click).
    var progressFlushTask: Task<Void, Never>?
    var lastProgressFlush = Date.distantPast
    /// Automatic " (N)" suffix renames already applied per task to resolve
    /// filename conflicts; capped so a destination that keeps colliding falls
    /// back to the manual filenameConflict state instead of looping forever.
    var autoRenameAttempts: [UUID: Int] = [:]
    /// The moment the user last changed the table selection themselves.
    /// Task-creation flows compare their click timestamp against this value
    /// so a late (post-await) auto-select never steals focus back to the
    /// freshly created task after the user has already moved on.
    var lastUserSelectionChange = Date.distantPast
    /// Live-value bridge for the task table. The table view deliberately
    /// observes nothing that changes at download frequency (see
    /// `TaskTableSynchronizer`); progress/status/speed updates are pushed
    /// into per-cell models through this object instead of through
    /// `objectWillChange`.
    let tableSynchronizer = TaskTableSynchronizer()
    /// Throttle state for the status export driven by high-frequency task
    /// updates. `update()` used to rebuild the monitor state (full log-file
    /// read included) and write `status.json` synchronously on the main
    /// actor on every call; during active downloads that stalled the UI and
    /// swallowed rapid table clicks.
    var lastStatusExport = Date.distantPast
    var statusExportPending = false
    var pendingPersistenceTask: Task<Void, Never>?
    var lastPersistenceFlush = Date.distantPast
    /// Last persistence failure already shown to the user; a successful save
    /// clears it so a later, new failure is reported again.
    var lastReportedPersistenceError: String?
    /// The task that most recently transitioned to `.completed` in this
    /// session. `updatedAt` cannot answer "what just finished": renaming or
    /// re-tagging an old task bumps it too.
    var lastCompletedTaskID: UUID?
    var takeoverSweepTask: Task<Void, Never>?
    var fileCheckTask: Task<Void, Never>?
    /// Polls free space while tasks are parked for a full disk; nil when
    /// none are waiting (see AppModel+DiskSpaceWatch).
    var diskSpaceWatchTask: Task<Void, Never>?
    var queueScheduleTask: Task<Void, Never>?
    var cancellables = Set<AnyCancellable>()
    /// Restarting the app must not instantly time out takeovers that Chrome
    /// is about to replay; the timeout counts from the later of the task's
    /// last update and this process's launch.
    let launchDate = Date()

    /// A browser takeover that Chrome never confirms (browser crash,
    /// extension removed, service worker killed for good) must not pin a
    /// task in "waiting for browser confirmation" forever.
    static let takeoverPendingTimeout: TimeInterval = 120
    /// Keep a compensation tombstone long enough to cover a delayed native
    /// response, service-worker retry, or App relaunch. The record contains
    /// no URL or authentication material and is purged on the next request.
    static let abandonedTakeoverRetention: TimeInterval = 10 * 60
    static let takeoverSweepInterval: UInt64 = 30_000_000_000
    /// Periodic file-existence check for completed tasks: interval and the
    /// maximum number of tasks inspected per cycle to limit disk I/O.
    static let fileCheckInterval: UInt64 = 5_000_000_000
    static let fileCheckBatchLimit = 50
    /// Progress events arrive every 200 ms and each one re-arms the 250 ms
    /// debounce; without an upper bound a continuous download would starve
    /// persistence for its whole duration. Flush at least this often.
    static let maximumPersistenceStaleness: TimeInterval = 2
    /// Minimum interval between status exports triggered by task updates; the
    /// status file and HTTP cache stay fresh enough for agents while the
    /// main actor is spared per-update log reads and JSON writes.
    static let statusExportInterval: TimeInterval = 1
    /// Upper bound of automatic suffix renames per task before a persisting
    /// filename conflict is surfaced for manual "rename and retry" resolution.
    static let maximumAutoRenameAttempts = 3

    // Stored properties used by AppModel+Persistence.swift — Swift does not
    // allow stored properties in extensions, so they live here.
    var pendingPersistenceKind: PersistenceKind = .progress
    var fileCheckCursor = 0
    /// Completed task IDs captured when this session's file sweep started. A
    /// destination that is already missing for one of them is pre-existing
    /// state rather than an event, so it is rendered in the table without a
    /// notification or a per-task log line (see `checkCompletedTaskFiles`).
    var fileCheckBaselineTaskIDs: Set<UUID> = []
    /// Task IDs whose destination has already been checked once this session.
    var fileCheckSeenTaskIDs: Set<UUID> = []
    /// Signature of the last proxy configuration pushed into the engine, so
    /// the settings observer only reconfigures (and resets the connection
    /// learner) when proxy fields actually change.
    var lastProxySignature: String?
    /// Completion action countdown state. Non-nil while the cancelable
    /// countdown window is open; nil otherwise.
    @Published var completionCountdownSeconds: Int?
    var completionCountdownTask: Task<Void, Never>?
    /// True once any task entered `.running` in this session; prevents an
    /// armed completion action from firing immediately after launch on an
    /// already-finished task list.
    var hasStartedTasksThisSession = false

    init(
        storeDirectory: URL? = nil,
        settings: AppSettings? = nil,
        browserProbe: (@Sendable (DownloadRequest) async throws -> ResourceInfo)? = nil,
        downloadRunner: (any AppDownloadRunning)? = nil,
        ffmpegRemuxer: (any FFmpegRemuxing)? = nil,
        ffmpegMerger: (any FFmpegMerging)? = nil,
        mediaInspector: (any MediaInspecting)? = nil,
        pageMediaDiscoverer: (any WebPageMediaDiscovering)? = nil,
        bilibiliAdapter: BilibiliPlayurlAdapter? = nil,
        youtubeDownloader: (any YouTubeDownloadRunning)? = nil,
        useEnvironmentFFmpeg: Bool = true,
        sessionStore: SessionStore? = nil
    ) {
        self.settings = settings ?? AppSettings()
        self.sessionStore = sessionStore ?? SessionStore()
        let resolvedSettings = self.settings
        let semanticKeychain = semanticTitleKeychainStore
        let semanticKeyAccount = SemanticTitleService.keychainAccount
        self.semanticTitleService = SemanticTitleService(
            configProvider: {
                // The KEY lives in the login Keychain, so this read can raise
                // the system approval dialog for a freshly built bundle. It runs
                // off-main and marked: the confirmation window is already on
                // screen when the semantic title resolves.
                let apiKey =
                    await KeychainAccessSignal.shared.access {
                        semanticKeychain.loadPassword(username: semanticKeyAccount)
                    } ?? ""
                guard !apiKey.isEmpty else { return nil }
                return SemanticTitleConfig(
                    format: SemanticTitleFormat(providerID: resolvedSettings.semanticTitleProvider),
                    endpoint: resolvedSettings.semanticTitleEndpoint,
                    model: resolvedSettings.semanticTitleModel,
                    apiKey: apiKey
                )
            }
        )
        self.browserProbe =
            browserProbe ?? { request in
                try await HTTPHandler(
                    probeRequestTimeout: 4,
                    probeResourceTimeout: 6
                ).probe(request)
            }
        let configuredFFmpeg: (any FFmpegRemuxing & FFmpegMerging)?
        if useEnvironmentFFmpeg {
            // Prefer a pinned env toolchain (reproducible Debug builds); fall
            // back to an autodetecting proxy that locates ffmpeg on PATH /
            // Homebrew on first use, so a normal launch with a working ffmpeg
            // installed can still run HLS/DASH tasks instead of failing with
            // FFMPEG_UNAVAILABLE.
            if let pinned = Self.defaultFFmpegService() {
                configuredFFmpeg = pinned
            } else {
                let proxy = FFmpegAutodetectProxy()
                configuredFFmpeg = proxy
            }
        } else {
            configuredFFmpeg = nil
        }
        let resolvedRemuxer = ffmpegRemuxer ?? configuredFFmpeg
        let resolvedMerger = ffmpegMerger ?? configuredFFmpeg
        let resolvedYouTubeDownloader =
            youtubeDownloader
            ?? YouTubeDownloadRunner(
                ffmpegRemuxer: resolvedRemuxer,
                // Shared with the inspection entry points below: the live gate
                // reuses a verdict this session already paid for instead of
                // running the same extraction per download.
                liveStatusCache: .shared
            )
        self.downloadRunner =
            downloadRunner
            ?? EngineDownloadRunner(
                dashMerger: resolvedMerger,
                youtubeDownloader: resolvedYouTubeDownloader,
                connectionPolicyLearner: connectionPolicyLearner
            )
        self.ffmpegRemuxer = resolvedRemuxer
        self.ffmpegMerger = resolvedMerger
        self.mediaInspector = mediaInspector ?? CompositeMediaInspector()
        self.pageMediaDiscoverer = pageMediaDiscoverer ?? URLSessionWebPageMediaDiscoverer()
        self.bilibiliAdapter = bilibiliAdapter ?? BilibiliPlayurlAdapter()
        // Auto-tune download resource limits based on physical memory so
        // low-RAM machines stay safe while beefy Macs get higher throughput.
        DownloadResourceLimits.autoTune()
        // Apply the user-configured media in-flight request limit.
        DownloadResourceLimits.configure(
            maximumInFlightRequests: self.settings.mediaInFlightRequests
        )
        let directory =
            storeDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacIDM/app", isDirectory: true)
        takeoverLog = TakeoverLog(directory: directory)
        let vault = SourceURLVault(directory: directory)
        sourceURLVault = vault
        var restoredVaultURLs: [UUID: URL] = [:]

        let initialization:
            (
                store: AppTaskStore,
                takeoverStore: BrowserTakeoverStore,
                tasks: [AppTask],
                takeovers: [BrowserTakeoverRecord],
                abandonedTakeovers: [AbandonedBrowserTakeover],
                error: PresentedError?
            )
        do {
            let resolvedStore = try AppTaskStore(directory: directory)
            let resolvedTakeoverStore = try BrowserTakeoverStore(directory: directory)
            var loaded = try resolvedStore.load()
            let takeovers = try resolvedTakeoverStore.load()
            let loadedAbandonedTakeovers = try resolvedTakeoverStore.loadAbandoned()
            let now = Date()
            let abandonedTakeovers = loadedAbandonedTakeovers.filter { $0.expiresAt > now }
            let vaultEntries = vault.load(now: now)
            var shouldPersistLoadedTasks = false
            for index in loaded.indices {
                // CLI-owned rows are mirrored for visibility only. The CLI
                // worker owns their live state, so App startup must not
                // reinterpret a running CLI task as an interrupted App task.
                if loaded[index].status.isActive, !loaded[index].isCLIManaged {
                    loaded[index].status = .paused
                    loaded[index].errorCode = "INTERRUPTED"
                    loaded[index].errorMessage = String(
                        localized: "MacIDM 上次退出时任务仍在运行，请继续任务以执行恢复检查。"
                    )
                    loaded[index].bytesPerSecond = 0
                    shouldPersistLoadedTasks = true
                }

                // A completed download had every byte verified before
                // publication, so a segment snapshot still reporting a
                // shortfall is stale split-parent data (the engine used to
                // keep a split parent's pre-split range as its total).
                // Settle it once so historical rows display correctly.
                let segmentsBeforeSettle = loaded[index].segments
                loaded[index].settleSegmentProgress()
                if loaded[index].segments != segmentsBeforeSettle {
                    shouldPersistLoadedTasks = true
                }

                // Browser submissions deliberately persist only a redacted URL.
                // The real signed URL and request context live in memory, so using
                // the redacted value after a restart would turn a recoverable task
                // into a misleading 401/403 or a request for the wrong resource.
                // A pending takeover is the one exception: the extension can
                // replay its idempotent request and restore the transient context.
                let hasTakeoverRecord = takeovers.contains { $0.taskID == loaded[index].id }
                let canReplayTakeover =
                    loaded[index].status == .takeoverPending
                    && loaded[index].browserSubmissionType == "download.create"
                    && hasTakeoverRecord
                let hlsInputPath = URL(fileURLWithPath: loaded[index].destinationPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent(".\(loaded[index].id.uuidString).macidm.hls-input.ts")
                    .path
                let hlsInputSize =
                    (try? FileManager.default.attributesOfItem(atPath: hlsInputPath)[.size])
                    as? NSNumber
                let hasRecoverableHLSInput =
                    loaded[index].sourceKind == .hls
                    && (hlsInputSize?.int64Value ?? 0) > 0
                let hasTransientDASHPair = Self.isTransientDASHPair(loaded[index])
                // A site-adapter (Bilibili) DASH pair is re-resolvable: its page
                // URL is persisted and the adapter can fetch fresh signed track
                // URLs on resume, so unlike an opaque signed URL it must not be
                // force-failed here. The login cookie is restored from
                // SessionStore at resume time (best effort; guest otherwise).
                let canReresolveSiteAdapter =
                    hasTransientDASHPair
                    && (loaded[index].pageURL.flatMap { URL(string: $0) }
                        .map { BilibiliPlayurlAdapter.supports($0) } ?? false)
                let needsRefetch =
                    loaded[index].errorCode == "NEEDS_REFETCH"
                    || (loaded[index].browserSubmissionType != nil && !loaded[index].isCLIManaged)
                    || hasTransientDASHPair
                if needsRefetch,
                    !loaded[index].status.isTerminal,
                    !canReplayTakeover,
                    !hasRecoverableHLSInput,
                    !canReresolveSiteAdapter
                {
                    // The vault may still hold the original URL (signed query,
                    // browser submission, YouTube watch link). When it does,
                    // restore it and keep the task's pre-restart state — a
                    // paused download stays paused and resumable instead of
                    // being force-failed. Cookie/Authorization context is
                    // still memory-only; if the server needs it the resumed
                    // task fails with a regular auth error the user can act
                    // on. DASH pairs cannot resume: the audio track URL was
                    // never persisted.
                    let restoredURL = vaultEntries[loaded[index].id].flatMap { URL(string: $0.url) }
                    if let restoredURL, !hasTransientDASHPair {
                        restoredVaultURLs[loaded[index].id] = restoredURL
                        if loaded[index].errorCode == "NEEDS_REFETCH" {
                            loaded[index].errorCode = nil
                            loaded[index].errorMessage = nil
                            shouldPersistLoadedTasks = true
                        }
                    } else {
                        loaded[index].status = .failed
                        loaded[index].errorCode = "NEEDS_REFETCH"
                        loaded[index].errorMessage =
                            hasTransientDASHPair
                            ? String(
                                localized: "音视频配对地址只在当前会话保留，请从浏览器媒体候选重新提交。"
                            )
                            : loaded[index].browserSubmissionType != nil && !loaded[index].isCLIManaged
                                ? String(
                                    localized: "浏览器下载上下文未在本机持久化，请从 Chrome 重新提交。"
                                )
                                : String(
                                    localized: "带参数的下载地址未在本机持久化，请重新提交原始链接。"
                                )
                        loaded[index].bytesPerSecond = 0
                        shouldPersistLoadedTasks = true
                    }
                }
                // Re-resolvable site-adapter pairs keep their pre-restart state
                // (paused stays paused and resumable); drop any stale refetch
                // marker so resume() re-resolves instead of surfacing an error.
                if canReresolveSiteAdapter,
                    !loaded[index].status.isTerminal,
                    loaded[index].errorCode == "NEEDS_REFETCH"
                {
                    loaded[index].errorCode = nil
                    loaded[index].errorMessage = nil
                    shouldPersistLoadedTasks = true
                }
                // Failed tasks likewise keep their original link in the Vault
                // so a retry after relaunch can reuse it: cleanUpExecution
                // deliberately leaves Vault entries for failed tasks. Without
                // restoring it, the retry would silently run the redacted URL
                // (e.g. a YouTube watch link losing its v= parameter, making
                // yt-dlp download the homepage and report "no media files
                // generated").
                if loaded[index].status == .failed,
                    let restoredFailedURL = vaultEntries[loaded[index].id].flatMap({
                        URL(string: $0.url)
                    })
                {
                    restoredVaultURLs[loaded[index].id] = restoredFailedURL
                }
            }
            let initialTasks = loaded.sorted { $0.createdAt > $1.createdAt }
            if shouldPersistLoadedTasks {
                try resolvedStore.save(initialTasks)
            }
            if abandonedTakeovers.count != loadedAbandonedTakeovers.count {
                try resolvedTakeoverStore.saveAbandoned(abandonedTakeovers)
            }
            initialization = (
                resolvedStore,
                resolvedTakeoverStore,
                initialTasks,
                takeovers,
                abandonedTakeovers,
                nil
            )
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacIDM-\(UUID().uuidString)", isDirectory: true)
            do {
                let fallbackStore = try AppTaskStore(directory: fallback)
                let fallbackTakeoverStore = try BrowserTakeoverStore(directory: fallback)
                initialization = (
                    fallbackStore,
                    fallbackTakeoverStore,
                    [],
                    [],
                    [],
                    PresentedError(
                        title: String(localized: "无法打开任务记录"),
                        message: error.localizedDescription
                    )
                )
            } catch {
                // A damaged or read-only Application Support directory must
                // not turn startup recovery into a force-unwrap crash. Keep
                // the session usable in memory and make the loss of durable
                // persistence visible to the user.
                initialization = (
                    AppTaskStore.ephemeral(),
                    BrowserTakeoverStore.ephemeral(),
                    [],
                    [],
                    [],
                    PresentedError(
                        title: String(localized: "无法持久化任务记录"),
                        message: String(localized: "任务将暂时保存在内存中；请检查磁盘权限后重启 MacIDM。")
                    )
                )
            }
        }
        store = initialization.store
        takeoverStore = initialization.takeoverStore
        persistenceCoordinator = AppTaskPersistenceCoordinator(store: initialization.store)
        tasks = initialization.tasks
        queues = (try? initialization.store.loadQueues()) ?? []
        for (id, url) in restoredVaultURLs {
            transientSourceURLs[id] = url
        }
        browserTakeovers = initialization.takeovers
        abandonedTakeovers = initialization.abandonedTakeovers
        presentedError = initialization.error
        if initialization.error == nil {
            scheduleQueuedTasks()
        }
        startTakeoverSweep()
        startFileExistenceCheck()
        startDiskSpaceWatchIfNeeded()
        startQueueScheduleLoop()
        rebuildSharedRateLimiter()
        rebuildProxyPolicy()
        clipboardLinkWatcher.onLinkCopied = { [weak self] value in
            self?.offerClipboardLink(value)
        }
        updateClipboardWatcher()
        // Check yt-dlp availability on launch. If not found, present an
        // install dialog so the user knows YouTube downloads require it
        // before they try to download a YouTube video.
        if !YTDlpManager.isAvailable {
            ytdlpManager.alert = .installRequired
            AppLogger.shared.warning(.youtube, "yt-dlp not found on launch")
        }
        $tasks
            .map { tasks in tasks.count { $0.status.isActive } }
            .removeDuplicates()
            .sink { [weak self] count in
                self?.notifier.updateDockBadge(activeCount: count)
            }
            .store(in: &cancellables)
        // `@Published` publishes in `willSet`, so a subscriber that reads the
        // settings back still sees the previous value. These side effects all
        // re-read settings, so they run after the write lands; without the hop
        // the first change of each of them was applied one step late (setting a
        // speed limit or enabling a proxy did nothing until something else
        // triggered the same rebuild).
        self.settings.$speedLimitKBps
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSharedRateLimiter()
            }
            .store(in: &cancellables)
        // The continuous clipboard watch follows its setting without a
        // restart; disabling stops the timer immediately.
        self.settings.$clipboardWatch
            .combineLatest(self.settings.$clipboardWatchFilesOnly)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateClipboardWatcher()
            }
            .store(in: &cancellables)
        // When the user increases the concurrent download limit, queued
        // tasks should start automatically without requiring a manual
        // pause/resume cycle.
        self.settings.$simultaneousDownloads
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleQueuedTasks()
            }
            .store(in: &cancellables)
        // The global shortcut follows its settings: the switch and a newly
        // recorded combination re-register it immediately. `@Published` publishes
        // in `willSet`, so the emitted values are passed down instead of read
        // back from the properties, which still hold the previous value.
        self.settings.$globalHotKeyEnabled
            .combineLatest(self.settings.$globalHotKeyCombo)
            .sink { [weak self] enabled, combo in
                let recording = self?.isGlobalHotKeyRecording ?? false
                self?.refreshGlobalHotKeyRegistration(
                    wanted: enabled && !recording ? combo : nil
                )
            }
            .store(in: &cancellables)
        // Forward settings changes so views observing the model re-render
        // when preferences like hiddenTableColumns change. This one must stay
        // synchronous: SwiftUI needs the will-change notification.
        self.settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // The proxy policy re-reads several settings fields, so it applies after
        // the write (see the willSet note above).
        self.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildProxyPolicy()
            }
            .store(in: &cancellables)
        // Forward yt-dlp manager state changes so SwiftUI views observing
        // AppModel re-render when the install/update alert changes.
        self.ytdlpManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // Wire the table bridge once self is fully initialized.
        tableSynchronizer.provideRows = { [weak self] in
            self?.filteredTasks ?? []
        }
        tableSynchronizer.seedTask = { [weak self] id in
            self?.task(with: id)
        }
        tableSynchronizer.commitSelection = { [weak self] ids in
            self?.selectTasksFromTable(ids)
        }
        tableSynchronizer.replaceAllLive(tasks)
    }

    func rebuildSharedRateLimiter() {
        let limitKBps = settings.speedLimitKBps
        sharedRateLimiter.reconfigure(
            limitKBps > 0
                ? try? TokenBucketRateLimiter(rateBytesPerSecond: Int64(limitKBps) * 1_024)
                : nil
        )
    }

    /// Caps one task's transfer rate. Runs through a per-task dynamic
    /// limiter so a change applies to an in-flight task immediately, the
    /// same live behavior the global limit has.
    func setTaskRateLimit(_ kbps: Int?, for id: UUID) {
        let limit = (kbps ?? 0) > 0 ? kbps : nil
        update(id) { $0.rateLimitKBps = limit }
        tryPersistOrPresentError()
        taskRateLimiters[id]?.reconfigure(Self.taskBucket(limit))
    }

    /// The limiter a task's transfers use: the global dynamic limiter plus
    /// the task's own dynamic limiter. Every task gets the per-task wrapper
    /// (unlimited when uncapped), so a cap added while the task is already
    /// downloading applies immediately instead of after a pause/resume. Both
    /// must grant every byte, so the tighter bound always wins.
    func rateLimiter(for record: AppTask) -> any DownloadRateLimiting {
        let limiter: DynamicRateLimiter
        if let existing = taskRateLimiters[record.id] {
            limiter = existing
        } else {
            limiter = DynamicRateLimiter()
            taskRateLimiters[record.id] = limiter
        }
        limiter.reconfigure(Self.taskBucket(record.rateLimitKBps))
        return CombinedRateLimiter(global: sharedRateLimiter, task: limiter)
    }

    /// The effective cap in KB/s for backends that run outside the
    /// in-process limiters (yt-dlp): the tighter of the global and per-task
    /// limits, nil when neither applies. Captured at start; yt-dlp cannot be
    /// re-limited mid-run.
    func effectiveRateLimitKBps(for record: AppTask) -> Int? {
        [settings.speedLimitKBps, record.rateLimitKBps ?? 0].filter { $0 > 0 }.min()
    }

    private static func taskBucket(_ kbps: Int?) -> (any DownloadRateLimiting)? {
        guard let kbps, kbps > 0 else { return nil }
        return try? TokenBucketRateLimiter(rateBytesPerSecond: Int64(kbps) * 1_024)
    }

    /// Drops a removed task's per-task limiter so the dictionary cannot
    /// outgrow the task list.
    func discardTaskRateLimiter(_ id: UUID) {
        taskRateLimiters[id] = nil
    }

    var filteredTasks: [AppTask] {
        let filter = sidebarFilter ?? .all
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            guard filter.matches(task) else { return false }
            return query.isEmpty
                || task.filename.localizedCaseInsensitiveContains(query)
                || task.jobID.localizedCaseInsensitiveContains(query)
                || task.redactedSourceURL.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedTask: AppTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var selectedTasks: [AppTask] {
        tasks.filter { selectedTaskIDs.contains($0.id) }
    }

    /// Keeps the multi-selection set and the detail-column "primary"
    /// selection consistent: single selection drives the detail column;
    /// with several tasks selected the primary stays on a task that is
    /// still part of the selection. External entry point — the new
    /// selection is pushed straight into the table's binding; it must
    /// not travel through the appearance token, which would re-evaluate
    /// the table body and re-apply the binding mid-gesture.
    func selectTasks(_ ids: Set<UUID>) {
        selectTasksCore(ids)
        tableSynchronizer.applyExternalSelection(ids)
    }

    /// Selection committed by the task table itself. The table already
    /// displays it, so nothing echoes back: an echo re-evaluates the
    /// table body and re-applies the selection binding mid-gesture,
    /// which corrupts NSTableView click tracking (a multi-selection
    /// collapsed by a plain click got cleared entirely).
    func selectTasksFromTable(_ ids: Set<UUID>) {
        selectTasksCore(ids)
    }

    private func selectTasksCore(_ ids: Set<UUID>) {
        selectedTaskIDs = ids
        lastUserSelectionChange = Date()
        if ids.count == 1, let only = ids.first {
            selectedTaskID = only
        } else if let current = selectedTaskID, ids.contains(current) {
            // Keep the current detail task while it remains selected.
        } else {
            selectedTaskID = tasks.first { ids.contains($0.id) }?.id
        }
    }

    var aggregateSpeed: Double {
        tasks.reduce(0) { $0 + ($1.status == .running ? $1.bytesPerSecond : 0) }
    }

    var activeCount: Int {
        tasks.count { ($0.status.isActive || executions[$0.id].task != nil) && !$0.isCLIManaged }
    }

    /// Active/total scoped to the current sidebar filter + search, so the
    /// status bar's "active tasks x/y" matches the list the user is looking at
    /// instead of always quoting the all-time total.
    var filteredActiveCount: Int {
        filteredTasks.count { $0.status.isActive && !$0.isCLIManaged }
    }

    var fileMissingCount: Int {
        tasks.count { $0.fileMissing }
    }

    /// Received/total across active tasks that know their size; nil when no
    /// active task can report a total (avoids a misleading 0%).
    var globalProgress: Double? {
        let measurable = tasks.filter {
            $0.status.isActive && !$0.isCLIManaged && ($0.totalBytes ?? 0) > 0
        }
        let total = measurable.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        guard total > 0 else { return nil }
        let received = measurable.reduce(Int64(0)) { $0 + $1.receivedBytes }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// Returns all partial-download artifact URLs for a task: HTTP temp
    /// download file, HTTP sidecar, HLS raw input, and DASH pair directory.
    /// All live in the destination directory alongside the final file.
    static func partialArtifactURLs(for task: AppTask) -> [URL] {
        DownloadArtifacts.partialArtifactURLs(
            destination: URL(fileURLWithPath: task.destinationPath),
            taskID: task.id
        )
    }

    // MARK: - Clipboard auto-detection

    private var lastDetectedClipboardURL: String?

    /// Unified entry point for the new-download confirmation. Always opens a
    /// standalone confirmation window and never requires the main window, so
    /// browser submissions, the global hotkey and the menu command all work
    /// while the main window is closed. Tests override `newDownloadPresenter`
    /// to capture the draft without creating real windows.
    var newDownloadPresenter: ((DownloadDraft?) -> Void)?

    /// Moves a local file to the Finder Trash. Injectable so tests can
    /// verify the trash wiring without touching the real Trash.
    var trashFile: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func presentNewDownload(draft: DownloadDraft?) {
        if let presenter = newDownloadPresenter {
            presenter(draft)
            return
        }
        DownloadDraftWindowManager.shared.open(draft: draft, model: self)
    }

    // MARK: - Global hot key

    /// The live registration, installed by the App scene only when running from
    /// a bundled `.app`. Nothing registers while this is nil, so constructing a
    /// model in a test never touches Carbon; a test of the wiring below installs
    /// a fake registrar.
    private(set) var globalHotKeyRegistrar: (any GlobalHotKeyRegistering)?

    /// Why the shortcut is not live, or nil when it is. The system refuses a
    /// combination another application already owns, and a silently dead
    /// shortcut is worse than a visible reason.
    @Published var globalHotKeyError: String?

    /// Set while the settings recorder is capturing keys. Carbon delivers the
    /// combination to whoever registered it first, so the live registration has
    /// to step aside or recording the shortcut in use would do nothing.
    var isGlobalHotKeyRecording = false {
        didSet { refreshGlobalHotKeyRegistration(wanted: wantedGlobalHotKeyCombo()) }
    }

    /// Install the process's single registrar. A recreated main window re-runs
    /// the App's startup task, so a previous registration is released first
    /// rather than being owned twice — the second `RegisterEventHotKey` for the
    /// same combination would be refused and reported as occupied.
    func installGlobalHotKeyRegistrar(_ registrar: any GlobalHotKeyRegistering) {
        guard globalHotKeyRegistrar !== registrar else { return }
        globalHotKeyRegistrar?.apply(combo: nil)
        globalHotKeyRegistrar = registrar
        refreshGlobalHotKeyRegistration(wanted: wantedGlobalHotKeyCombo())
    }

    /// What the settings currently ask for: nil when the master switch is off,
    /// the recorder was cleared, or a recording is in progress.
    private func wantedGlobalHotKeyCombo() -> GlobalHotKeyCombo? {
        guard settings.globalHotKeyEnabled, !isGlobalHotKeyRecording else { return nil }
        return settings.globalHotKeyCombo
    }

    /// Push one resolved combination onto the system; nil unregisters. The
    /// settings subscription resolves it from the values it publishes, because
    /// `@Published` fires in `willSet` and reading the properties back there
    /// would still return the previous state.
    func refreshGlobalHotKeyRegistration(wanted: GlobalHotKeyCombo?) {
        guard let registrar = globalHotKeyRegistrar else { return }
        if registrar.apply(combo: wanted) {
            globalHotKeyError = nil
            return
        }
        // The registrar kept the combination that was working. Name the live key
        // instead of writing the refused one back: assigning to the recorded
        // combination from inside its own publication would be overwritten by the
        // write that just started, and a silent revert reads like a bug.
        if let refused = wanted, let live = registrar.registeredCombo, refused != live {
            globalHotKeyError = String(
                localized: "\(refused.displayString) 已被系统或其他应用占用；全局快捷键仍是 \(live.displayString)。"
            )
        } else {
            globalHotKeyError = String(localized: "该组合键已被系统或其他应用占用，全局快捷键未生效。")
        }
    }

    /// The configured global shortcut, wherever the user set it: open a
    /// new-download window, prefilled from the clipboard when it holds a link.
    func handleGlobalHotKey() {
        let value = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var draft: DownloadDraft?
        if let value, let url = ClipboardLinkWatcher.httpLink(from: value) {
            draft = DownloadDraft(urlString: url.absoluteString)
            lastDetectedClipboardURL = value
        }
        presentNewDownload(draft: draft)
    }

    /// When enabled in settings, offers to download an HTTP(S) link found on
    /// the clipboard as the app becomes active (copy in browser → switch
    /// here → confirmation window). Only fires once per distinct URL.
    func detectClipboardLinkIfEnabled() {
        guard settings.clipboardAutoDetect else { return }
        guard
            let value = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            ClipboardLinkWatcher.httpLink(from: value) != nil
        else { return }
        offerClipboardLink(value)
    }

    /// Shared offer path for the on-activate detector and the continuous
    /// watcher: dedupe per distinct URL, then open the confirmation flow.
    /// Never starts a download by itself.
    private func offerClipboardLink(_ value: String) {
        guard value != lastDetectedClipboardURL else { return }
        lastDetectedClipboardURL = value
        NotificationCenter.default.post(name: .macIDMCreateDownload, object: value)
    }

    /// Starts or stops the continuous clipboard watch to match the setting.
    func updateClipboardWatcher() {
        clipboardLinkWatcher.filesOnly = settings.clipboardWatchFilesOnly
        clipboardLinkWatcher.update(enabled: settings.clipboardWatch)
    }

    // MARK: - Import / Export

    func exportTasks(format: TaskTransfer.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacIDM-\(String(localized: "任务")).\(format.fileExtension)"
        panel.allowedContentTypes = format == .json ? [.json] : [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try format == .json ? TaskTransfer.jsonData(for: tasks) : TaskTransfer.csvData(for: tasks)
            try data.write(to: url, options: .atomic)
        } catch {
            presentedError = PresentedError(
                title: String(localized: "导出失败"),
                message: error.localizedDescription
            )
        }
    }

    func importTasks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try TaskTransfer.decodeImport(Data(contentsOf: url))
            var imported = 0
            for entry in entries {
                guard URL(string: entry.sourceURL) != nil else { continue }
                let destination = URL(fileURLWithPath: settings.downloadDirectory, isDirectory: true)
                    .appendingPathComponent(InputValidator.safeFilename(entry.filename))
                do {
                    try addDownload(
                        urlString: entry.sourceURL,
                        destination: destination,
                        maximumParallelRequests: settings.maximumParallelRequests,
                        expectedSHA256: nil,
                        startImmediately: false,
                        sourceKind: entry.downloadSourceKind,
                        automaticRename: true
                    )
                    imported += 1
                } catch {
                    // Skip entries that conflict or fail validation; the
                    // summary below tells the user how many made it.
                }
            }
            guard imported > 0 else { throw TaskTransferError.noImportableTasks }
            presentedError = PresentedError(
                title: String(localized: "导入完成"),
                message: String(localized: "已导入 \(imported) 个任务（全部处于暂停状态，请手动继续）。")
            )
        } catch {
            presentedError = PresentedError(
                title: String(localized: "导入失败"),
                message: error.localizedDescription
            )
        }
    }

    /// ⌘I: make sure the detail column is visible for the current selection.
    func revealDetailColumn() {
        guard selectedTaskID != nil || !selectedTaskIDs.isEmpty else { return }
        isDetailColumnRequested = true
        DispatchQueue.main.async { [weak self] in
            self?.isDetailColumnRequested = false
        }
    }

    func importDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        guard !supported.isEmpty else { return false }

        for provider in supported {
            let type =
                provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                ? UTType.url.identifier : UTType.plainText.identifier
            provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
                let value: String?
                if let url = item as? URL {
                    value = url.absoluteString
                } else if let data = item as? Data {
                    value = String(data: data, encoding: .utf8)
                } else {
                    value = item as? String
                }
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.presentedError = PresentedError(
                            title: String(localized: "无法读取拖入内容"),
                            message: error.localizedDescription
                        )
                    } else if let value,
                        let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                        url.scheme == "http" || url.scheme == "https"
                    {
                        NotificationCenter.default.post(
                            name: .macIDMCreateDownload,
                            object: url.absoluteString
                        )
                    }
                }
            }
        }
        return true
    }

    func showError(_ error: Error, title: String = String(localized: "操作未完成")) {
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }

    func inspectDownloadOptions(
        url: URL,
        sourceKind: DownloadSourceKind,
        filenameHint: String?,
        filenameHintSource: FilenameHintSource = .urlPath,
        pageTitle: String?,
        requestContext: DownloadRequestContext?
    ) async throws -> [DownloadMediaOption] {
        let inspection = try await mediaInspector.inspect(
            url: url,
            requestContext: requestContext,
            mediaKind: sourceKind
        )
        return inspection.variants.map { variant in
            DownloadMediaOption(
                url: variant.url,
                sourceKind: sourceKind,
                filename: DownloadNaming.suggestedFilename(
                    url: variant.url,
                    sourceKind: sourceKind,
                    filenameHint: filenameHint,
                    pageTitle: pageTitle,
                    resourceInfo: nil,
                    label: variant.label,
                    hintSource: filenameHintSource
                ),
                label: variant.label,
                // A separate-audio master (X/Twitter) resolves each variant's
                // EXT-X-MEDIA rendition during inspection. Dropping it here
                // makes a manually pasted master download a silent file,
                // because the selected variant alone carries no audio.
                pairAudioURL: variant.pairAudioURL,
                pairCID: variant.pairCID,
                estimatedSize: variant.estimatedSize,
                duration: variant.duration
            )
        }
    }

    func availableDestination(
        for preferred: URL,
        automaticRename: Bool
    ) throws -> URL {
        let destination = preferred.standardizedFileURL
        guard destinationIsReserved(destination) else { return destination }
        guard automaticRename else { throw AppModelError.duplicateDestination }

        let extensionName = destination.pathExtension
        let filename = destination.lastPathComponent
        let stem: String
        if extensionName.isEmpty {
            stem = filename
        } else {
            stem = String(filename.dropLast(extensionName.count + 1))
        }
        for sequence in 1...10_000 {
            let candidateName =
                extensionName.isEmpty
                ? "\(stem) (\(sequence))"
                : "\(stem) (\(sequence)).\(extensionName)"
            let candidate = destination.deletingLastPathComponent()
                .appendingPathComponent(candidateName)
                .standardizedFileURL
            if !destinationIsReserved(candidate) { return candidate }
        }
        throw AppModelError.duplicateDestination
    }

    func categorizedDestination(
        for preferred: URL,
        categoryOverride: DownloadCategory? = nil,
        mimeType: String? = nil
    ) throws -> URL {
        let category =
            categoryOverride
            ?? DownloadCategory(filename: preferred.lastPathComponent, mimeType: mimeType)
        // Per-category custom path takes priority over the subfolder toggle.
        if let customPath = settings.categoryPaths[category.rawValue],
            !customPath.isEmpty
        {
            let directory = URL(fileURLWithPath: customPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return directory.appendingPathComponent(preferred.lastPathComponent)
        }
        guard settings.organizeByCategory else { return preferred }
        let directory =
            preferred
            .deletingLastPathComponent()
            .appendingPathComponent(category.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent(preferred.lastPathComponent)
    }

    private func destinationIsReserved(_ destination: URL) -> Bool {
        let path = destination.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path) { return true }
        // Only non-terminal tasks (queued, downloading, paused) reserve a path
        // that doesn't yet exist on disk. Terminal tasks (completed, failed,
        // cancelled) no longer block the name — if the user deleted the file,
        // re-downloading should reuse the original filename.
        return tasks.contains {
            !$0.status.isTerminal
                && URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == path
        }
    }

    func sourceKindForURL(_ url: URL) -> DownloadSourceKind {
        switch url.pathExtension.lowercased() {
        case "m3u8": return .hls
        case "mpd": return .dash
        default: return .http
        }
    }

    static func isYouTubePageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let rawHost = url.host?.lowercased()
        else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        if host == "youtu.be" { return !url.path.isEmpty }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
        return url.path == "/watch" || url.path.hasPrefix("/shorts/")
    }

    /// .m3u8 媒体清单/master playlist 判据（URL 路径扩展名，不含查询串）。
    func isHLSPlaylistURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    func effectiveSourceKind(
        for url: URL,
        requested: DownloadSourceKind,
        pairAudioURL: URL?,
        allowPageAdapters: Bool = false
    ) -> DownloadSourceKind {
        // 带音轨的提交有两种：Bilibili m4s（DASH pair，直链分片）与
        // HLS 独立音轨变体（EXT-X-MEDIA 音频组，输入是媒体清单）。误判
        // .dash 会把 m3u8 清单当直链分片下载，FFmpeg 报
        // 「Not detecting m3u8/hls…」。
        if let pairAudioURL {
            // URL 判据优先于扩展的 mediaKind：任一侧是 .m3u8 媒体清单就是
            // HLS pair——候选 format 在观察链上可能被兜底成 video，不能依赖
            // 它做类型判断。
            if isHLSPlaylistURL(url) || isHLSPlaylistURL(pairAudioURL) { return .hls }
            return requested == .hls ? .hls : .dash
        }
        guard requested == .http else { return requested }
        if allowPageAdapters, BilibiliPlayurlAdapter.supports(url) { return .dash }
        return sourceKindForURL(url)
    }

    func isDirectMediaURL(_ url: URL, declaredMime: String? = nil) -> Bool {
        if ["m3u8", "mpd", "mp4", "m4v", "webm", "mov", "mp3", "m4a", "aac", "flac", "ogg"]
            .contains(url.pathExtension.lowercased())
        {
            return true
        }

        let queryMime = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { item in
                let name = item.name.lowercased()
                return name == "mime" || name == "content-type" || name == "type"
            }?.value
        let mime = (declaredMime ?? queryMime)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mime?.hasPrefix("video/") == true || mime?.hasPrefix("audio/") == true {
            return true
        }

        // YouTube's signed `videoplayback` URLs intentionally have no file
        // extension. Keep this host/path check narrow so an arbitrary page
        // with a `type` query parameter is never treated as a media file.
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix(".googlevideo.com") && url.path.contains("/videoplayback")
    }

    func isHTMLMime(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased() else { return false }
        return mime.contains("text/html") || mime.contains("application/xhtml")
    }

    static func isTransientDASHPair(_ task: AppTask) -> Bool {
        guard task.sourceKind == .dash,
            let url = URL(string: task.sourceURL)
        else { return false }
        return url.pathExtension.lowercased() == "m4s"
    }

    // MARK: - Session Alert Lifecycle & Manual Cookie Submission

    /// Enqueues or immediately presents a session guidance alert for an authentication failure.
    func enqueueSessionAlert(domain: String, expired: Bool, taskID: UUID) {
        guard sessionAlert?.taskID != taskID,
            !pendingSessionAlerts.contains(where: { $0.taskID == taskID })
        else {
            return
        }
        let alert = SessionAlert(domain: domain, expired: expired, taskID: taskID)
        if cookiePasteDomain != nil || sessionAlert != nil || isNextSessionAlertScheduled {
            if pendingSessionAlerts.count < Self.maximumPendingSessionAlerts {
                pendingSessionAlerts.append(alert)
            } else {
                droppedSessionAlertsCount += 1
                AppLogger.shared.warning(
                    .download,
                    "session alert queue capacity reached (\(Self.maximumPendingSessionAlerts)); dropped guidance alert for host '\(domain)', taskID: \(taskID.uuidString)"
                )
            }
        } else {
            sessionAlert = alert
        }
    }

    /// Single production entry point for SwiftUI Alert Binding dismissal (`set: { if $0 == nil { ... } }`).
    /// Strictly idempotent: if `sessionAlert` is already nil (e.g. rapid duplicate SwiftUI callbacks),
    /// this is a no-op. Advances to the next queued alert on the NEXT main-actor turn to prevent
    /// same-event multi-dequeue races.
    func handleSessionAlertBindingDismissal() {
        guard sessionAlert != nil else {
            return
        }
        sessionAlert = nil
        scheduleNextSessionAlertPresentation()
    }

    /// User chose to enter the manual cookie paste sheet from the alert or settings.
    func requestManualCookiePaste(domain: String, retryTaskID: UUID?) {
        sessionAlert = nil
        cookiePasteRetryTaskID = retryTaskID
        cookiePasteDomain = domain
    }

    /// Initiates dismissal of the CookiePasteSheet. Clears sheet binding states
    /// but DOES NOT drain the alert queue until the sheet has completely finished its dismissal animation.
    func requestDismissCookiePasteSheet() {
        cookiePasteDomain = nil
        cookiePasteRetryTaskID = nil
    }

    /// Called when the CookiePasteSheet presentation lifecycle has completely finished (onDismiss).
    /// Safely presents the next queued alert now that the modal sheet is completely offscreen.
    func cookiePasteSheetDidDismiss() {
        requestDismissCookiePasteSheet()
        scheduleNextSessionAlertPresentation()
    }

    /// Submits a pasted cookie, stores it in `SessionStore`, optionally retries the failed task,
    /// and requests sheet dismissal (actual queue drain happens in `cookiePasteSheetDidDismiss`).
    func submitManualCookie(
        domain: String,
        cookie: String,
        userAgent: String? = nil,
        retryTaskID: UUID? = nil
    ) -> SessionStoreOutcome {
        let outcome = sessionStore.store(domain: domain, cookie: cookie, userAgent: userAgent)
        if outcome == .stored {
            if let retryTaskID, task(with: retryTaskID)?.status == .failed {
                resume(retryTaskID)
            }
            requestDismissCookiePasteSheet()
        }
        return outcome
    }

    private func scheduleNextSessionAlertPresentation() {
        guard !isNextSessionAlertScheduled else { return }
        guard cookiePasteDomain == nil, !pendingSessionAlerts.isEmpty else { return }
        isNextSessionAlertScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isNextSessionAlertScheduled = false
            guard self.cookiePasteDomain == nil, self.sessionAlert == nil else { return }
            guard !self.pendingSessionAlerts.isEmpty else { return }
            self.sessionAlert = self.pendingSessionAlerts.removeFirst()
        }
    }
}

struct TransientRequestContext {
    let value: DownloadRequestContext
    let expiresAt: Date
}

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum AppModelError: LocalizedError {
    case duplicateDestination
    case ffmpegUnavailable

    var errorDescription: String? {
        switch self {
        case .duplicateDestination:
            String(localized: "该保存位置已存在于任务列表中，请先移除旧任务或选择新文件名。")
        case .ffmpegUnavailable:
            String(localized: "HLS 下载需要已配置且通过校验的 FFmpeg 工具链。")
        }
    }

    /// Stable code persisted on the task, mirroring `IDMError.code`. A missing
    /// FFmpeg toolchain is a local setup problem: without its own code the
    /// failure is stamped as a generic network error and the detail panel
    /// points the user at the wrong remedy.
    var code: String {
        switch self {
        case .duplicateDestination: "DUPLICATE_DESTINATION"
        case .ffmpegUnavailable: "FFMPEG_UNAVAILABLE"
        }
    }
}

enum FilenameRetryError: LocalizedError {
    case emptyFilename
    case invalidFilename
    case taskMissing
    case notInConflict
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyFilename:
            String(localized: "文件名不能为空。")
        case .invalidFilename:
            String(localized: "文件名不能包含路径或控制字符。")
        case .taskMissing:
            String(localized: "找不到该任务。")
        case .notInConflict:
            String(localized: "该任务当前不是文件名冲突状态。")
        case .alreadyExists(let name):
            String(localized: "「\(name)」在目标目录已存在，请换一个名字。")
        }
    }
}
