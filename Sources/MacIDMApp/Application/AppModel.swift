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
    var takeoverLog: TakeoverLog?
    /// Enforces the global speed limit from settings (nil inner = unlimited).
    /// One stable wrapper instance is captured by every started task; the
    /// inner token bucket is swapped whenever the speed-limit setting changes
    /// so in-flight downloads pick up the new limit without a pause/resume.
    let sharedRateLimiter = DynamicRateLimiter()
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
    var takeoverSweepTask: Task<Void, Never>?
    var fileCheckTask: Task<Void, Never>?
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
                ffmpegRemuxer: resolvedRemuxer
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
        startQueueScheduleLoop()
        rebuildSharedRateLimiter()
        rebuildProxyPolicy()
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
        self.settings.$speedLimitKBps
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rebuildSharedRateLimiter()
            }
            .store(in: &cancellables)
        // When the user increases the concurrent download limit, queued
        // tasks should start automatically without requiring a manual
        // pause/resume cycle.
        self.settings.$simultaneousDownloads
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleQueuedTasks()
            }
            .store(in: &cancellables)
        // Forward settings changes so views observing the model re-render
        // when preferences like hiddenTableColumns change.
        self.settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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

    /// Archived history rows keep their `fileMissing` flag forever (the
    /// file is gone and the row is only kept for re-download), which made
    /// the status-bar warning stale after the user already removed those
    /// records. Only rows still present in the main list count.
    var fileMissingCount: Int {
        tasks.count { $0.fileMissing && !$0.isArchived }
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

    /// Strips credentials and auth-looking query parameters from a page
    /// URL before storing it on the task. Innocuous identifiers (e.g.
    /// YouTube's `v=`) are preserved so the stored page URL stays useful
    /// for display and diagnostics without leaking tokens.
    static func pageURLForStorage(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        // Fragments only carry internal data (e.g. the `#height=N`
        // quality-selection marker); they are never part of the real page.
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            let filtered = items.filter { !looksLikeAuthParameter($0.name) }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.string ?? url.absoluteString
    }

    private static let authParameterSignatures = [
        "token", "secret", "sign", "auth", "session", "credential",
        "password", "cookie", "apikey", "api_key", "access", "private",
        "sid", "key",
    ]

    static func looksLikeAuthParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return authParameterSignatures.contains { lower.contains($0) }
    }

    /// Records the durable, non-secret re-resolution identity for a
    /// site-adapter (Bilibili) DASH-pair task and archives its login cookie,
    /// so a paused task can be re-resolved to fresh signed track URLs after a
    /// restart instead of being forced into NEEDS_REFETCH.
    ///
    /// The signed track URLs themselves stay transient (never persisted); only
    /// the page URL (already on the task), the cid, the chosen track's
    /// format_id, and the page-origin cookie (Keychain via SessionStore) are
    /// kept. Does nothing for tasks whose page URL is not a supported
    /// site-adapter page. Cookie archiving honors `rememberSiteSessions`.
    func recordSiteAdapterResumeContext(
        task: inout AppTask,
        downloadURL: URL,
        pairCID: String?,
        requestContext: DownloadRequestContext?
    ) {
        guard let pageURLString = task.pageURL,
            let pageURL = URL(string: pageURLString),
            BilibiliPlayurlAdapter.supports(pageURL)
        else { return }
        task.mediaCID = pairCID
        task.selectedQuality = BilibiliPlayurlAdapter.m4sFormatID(in: downloadURL)
        // Archive the page-origin login cookie (bilibili.com), not the CDN
        // host: re-resolution calls the Bilibili API, which needs the page
        // login state. The value goes to the Keychain; only non-secret
        // metadata lands in sessions.json.
        if settings.rememberSiteSessions,
            let cookie = requestContext?.cookie, !cookie.isEmpty
        {
            sessionStore.store(
                url: pageURL,
                cookie: cookie,
                userAgent: requestContext?.userAgent
            )
        }
    }

    func addDownload(
        urlString: String,
        destination: URL,
        maximumParallelRequests: Int,
        expectedSHA256: String?,
        startImmediately: Bool,
        sourceKind: DownloadSourceKind = .http,
        requestContext: DownloadRequestContext? = nil,
        automaticRename: Bool = false,
        pairAudioURL: URL? = nil,
        pairCID: String? = nil,
        backend: DownloadBackend = .native,
        priority: Int = 0,
        estimatedSize: Int64? = nil,
        mediaDuration: TimeInterval? = nil,
        categoryOverride: DownloadCategory? = nil,
        mimeType: String? = nil,
        selectionIntent: Date? = nil,
        takeoverDraftID: String? = nil
    ) throws {
        let takeover = try takeoverDraftID.map { try validatedInteractiveTakeover($0) }
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else { throw IDMError.invalidURL }
        if pairAudioURL != nil, sourceKind != .dash {
            throw IDMError.invalidURL
        }
        if let pairAudioURL {
            guard let scheme = pairAudioURL.scheme?.lowercased(),
                (scheme == "http" || scheme == "https"),
                pairAudioURL.host != nil
            else { throw IDMError.invalidURL }
        }
        let normalizedHash = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedDestination = try categorizedDestination(
            for: destination.standardizedFileURL,
            categoryOverride: categoryOverride,
            mimeType: mimeType
        )
        let initialRequest = DownloadRequest(
            url: url,
            destination: preparedDestination,
            sourceKind: sourceKind,
            maximumParallelRequests: maximumParallelRequests,
            expectedSHA256: normalizedHash?.isEmpty == true ? nil : normalizedHash,
            requestContext: requestContext,
            pairAudioURL: pairAudioURL,
            pairCID: pairCID,
            backend: backend
        )
        try InputValidator.validate(initialRequest)
        let resolvedDestination = try availableDestination(
            for: initialRequest.destination,
            automaticRename: automaticRename
        )
        let request: DownloadRequest
        if resolvedDestination == initialRequest.destination {
            request = initialRequest
        } else {
            request = DownloadRequest(
                url: initialRequest.url,
                destination: resolvedDestination,
                sourceKind: initialRequest.sourceKind,
                maximumParallelRequests: initialRequest.maximumParallelRequests,
                expectedSHA256: initialRequest.expectedSHA256,
                taskID: initialRequest.taskID,
                requestContext: initialRequest.requestContext,
                pairAudioURL: initialRequest.pairAudioURL,
                pairCID: initialRequest.pairCID,
                backend: initialRequest.backend
            )
        }
        try InputValidator.validate(request)

        let now = Date()
        // Signed browser/media URLs are intentionally redacted in the task
        // store. Keep an in-memory source and a durable refetch marker so the
        // current session can finish the transfer while a later restart is
        // prevented from silently retrying the redacted URL.
        let transientSubmissionType: String? =
            backend == .youtubeExtractor
            ? "youtube.extractor"
            : (url.query != nil || url.user != nil || url.password != nil
                ? "manual.transient"
                : nil)
        var task = AppTask(
            id: request.taskID,
            sourceURL: request.url.absoluteString,
            destinationPath: request.destination.path,
            maximumParallelRequests: request.maximumParallelRequests,
            expectedSHA256: request.expectedSHA256,
            sourceKind: request.sourceKind,
            browserClientID: takeover?.clientID,
            browserSubmissionType: transientSubmissionType,
            browserSubmissionKey: takeover?.request.idempotencyKey,
            createdAt: now,
            updatedAt: now,
            status: takeover != nil ? .takeoverPending : (startImmediately ? .queued : .paused),
            receivedBytes: 0,
            totalBytes: estimatedSize,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.priority = min(100, max(-100, priority))
        task.mediaDuration = mediaDuration
        task.categoryOverride = categoryOverride
        task.mimeType = mimeType
        // Preserve the user-facing page URL (credentials stripped): the
        // persisted sourceURL loses query parameters to redaction, which
        // would strip e.g. YouTube's video identifier.
        task.pageURL = Self.pageURLForStorage(url)
        // For a site-adapter DASH pair the download URL is a signed CDN track,
        // not a page. Keep the Bilibili page (carried in the adapter-provided
        // referer) as pageURL so the task can be re-resolved to fresh track
        // URLs after a restart instead of being forced into NEEDS_REFETCH.
        if sourceKind == .dash, pairAudioURL != nil,
            let referer = requestContext?.referer,
            let refererURL = URL(string: referer),
            BilibiliPlayurlAdapter.supports(refererURL)
        {
            task.pageURL = Self.pageURLForStorage(refererURL)
        }
        recordSiteAdapterResumeContext(
            task: &task,
            downloadURL: url,
            pairCID: pairCID,
            requestContext: requestContext
        )
        let takeoverRecord = try takeover.map {
            try makeInteractiveTakeoverRecord($0, task: task, startImmediately: startImmediately)
        }
        if let takeoverRecord {
            // Preserve extractor routing if the user selected an extractor variant.
            if task.browserSubmissionType != "youtube.extractor" { task.browserSubmissionType = "download.create" }
            browserTakeovers.append(takeoverRecord)
        }
        tasks.insert(task, at: 0)
        tableSynchronizer.updateLive(task)
        exportStatus()
        transientSourceURLs[task.id] = url
        // Keep the unredacted URL across restarts when the persisted task
        // row would lose information to redaction (signed query/credentials)
        // or comes from a browser submission whose context is memory-only.
        if transientSubmissionType != nil || url.query != nil || url.user != nil
            || url.password != nil
        {
            sourceURLVault.store(id: task.id, url: url)
        }
        if let pairAudioURL {
            transientPairAudioURLs[task.id] = pairAudioURL
            if let pairCID { transientPairCIDs[task.id] = pairCID }
        }
        if let requestContext {
            transientRequestContexts[task.id] = TransientRequestContext(
                value: requestContext,
                expiresAt: now.addingTimeInterval(24 * 60 * 60)
            )
        }
        // Select the new task only while the user has not moved on. The
        // confirmation sheet's submit runs on a deferred main-actor task; a
        // rapid click on another row between "Start download" and task creation
        // must win, otherwise the focus visibly jumps back to the new task.
        if selectionIntent == nil || lastUserSelectionChange <= selectionIntent! {
            selectTasks([task.id])
        }
        do {
            if takeoverRecord != nil { try persistBrowserTakeovers() }
            try persist()
        } catch {
            if let takeoverRecord {
                browserTakeovers.removeAll { $0.taskID == task.id }
                takeoverStore.release(path: takeoverRecord.reservationPath)
                try? persistBrowserTakeovers()
            }
            tasks.removeAll { $0.id == task.id }
            transientSourceURLs[task.id] = nil
            transientPairAudioURLs[task.id] = nil
            transientPairCIDs[task.id] = nil
            transientRequestContexts[task.id] = nil
            selectedTaskIDs.remove(task.id)
            tableSynchronizer.applyExternalSelection(selectedTaskIDs)
            if selectedTaskID == task.id { selectedTaskID = nil }
            tableSynchronizer.replaceAllLive(tasks)
            throw error
        }
        if startImmediately {
            scheduleQueuedTasks()
        }
    }

    /// Runs `operation` with a wall-clock deadline; returns nil when it
    /// throws or exceeds the budget. Used to keep interactive lookups
    /// (YouTube format listing) from blocking the new-download dialog.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                (try? await operation())
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func resolveDownloadOptions(
        urlString: String,
        filenameHint: String? = nil,
        sourceKind: DownloadSourceKind = .http,
        requestContext: DownloadRequestContext? = nil,
        pageTitle: String? = nil,
        mimeType: String? = nil
    ) async throws -> [DownloadMediaOption] {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else { throw IDMError.invalidURL }
        if BilibiliPlayurlAdapter.supports(url) {
            let playurlOptions = try await bilibiliAdapter.resolve(
                pageURL: url,
                requestContext: requestContext
            )
            return playurlOptions.map { option in
                let displayLabel = bilibiliOptionLabel(for: option)
                let encoding = BilibiliPlayurlAdapter.displayCodec(option.codecs)
                return DownloadMediaOption(
                    url: option.videoURL,
                    sourceKind: .dash,
                    filename: DownloadNaming.suggestedFilename(
                        url: option.videoURL,
                        sourceKind: .dash,
                        filenameHint: filenameHint,
                        pageTitle: option.title,
                        resourceInfo: nil,
                        label: displayLabel
                    ),
                    label: displayLabel,
                    encoding: encoding,
                    requestContext: option.requestContext,
                    pairAudioURL: option.audioURL,
                    estimatedSize: option.estimatedSize,
                    duration: option.duration
                )
            }
        }
        if Self.isYouTubePageURL(url) {
            let title = DownloadNaming.nonEmptyPageTitle(pageTitle) ?? String(localized: "YouTube 视频")
            let fallback = [
                DownloadMediaOption(
                    url: url,
                    sourceKind: .http,
                    filename: DownloadNaming.suggestedFilename(
                        url: url,
                        sourceKind: .http,
                        filenameHint: filenameHint,
                        pageTitle: title,
                        resourceInfo: nil,
                        label: title
                    ),
                    label: String(localized: "YouTube 视频"),
                    requestContext: requestContext,
                    backend: .youtubeExtractor
                )
            ]
            // Ask yt-dlp for the real format list so the user can pick a
            // resolution, mirroring the browser-extension sniff panel.
            // Bounded to 15s: a slow/stuck resolve must never block the
            // dialog — it falls back to the single default option.
            guard YTDlpManager.isAvailable else { return fallback }
            let inspection = await Self.withTimeout(15) {
                try await YouTubeMediaInspector().inspect(
                    url: url,
                    requestContext: requestContext,
                    mediaKind: .http
                )
            }
            guard let inspection, !inspection.variants.isEmpty else { return fallback }
            return inspection.variants.map { variant in
                DownloadMediaOption(
                    url: variant.url,
                    sourceKind: .http,
                    filename: DownloadNaming.suggestedFilename(
                        url: url,
                        sourceKind: .http,
                        filenameHint: filenameHint,
                        pageTitle: title,
                        resourceInfo: nil,
                        label: variant.label
                    ),
                    label: variant.label,
                    encoding: MediaVariantLabel.family(forCodecs: variant.codecs),
                    requestContext: requestContext,
                    backend: .youtubeExtractor,
                    estimatedSize: variant.estimatedSize,
                    duration: variant.duration
                )
            }
        }
        let inferredKind = sourceKind == .http ? sourceKindForURL(url) : sourceKind
        if inferredKind == .hls || inferredKind == .dash {
            return try await inspectDownloadOptions(
                url: url,
                sourceKind: inferredKind,
                filenameHint: filenameHint,
                pageTitle: pageTitle,
                requestContext: requestContext
            )
        }

        if isDirectMediaURL(url, declaredMime: mimeType) {
            return [
                DownloadMediaOption(
                    url: url,
                    sourceKind: .http,
                    filename: DownloadNaming.suggestedFilename(
                        url: url,
                        sourceKind: .http,
                        filenameHint: filenameHint,
                        pageTitle: pageTitle,
                        resourceInfo: nil
                    ),
                    label: String(localized: "直链")
                )
            ]
        }

        let probeRequest = DownloadRequest(
            url: url,
            destination: URL(fileURLWithPath: settings.downloadDirectory, isDirectory: true)
                .appendingPathComponent(InputValidator.safeFilename(filenameHint ?? "download")),
            maximumParallelRequests: settings.maximumParallelRequests,
            requestContext: requestContext
        )
        if let info = try? await browserProbe(probeRequest),
            !isHTMLMime(info.mimeType),
            info.mimeType != nil || !url.pathExtension.isEmpty
        {
            return [
                DownloadMediaOption(
                    url: info.finalURL,
                    sourceKind: .http,
                    filename: DownloadNaming.suggestedFilename(
                        url: info.finalURL,
                        sourceKind: .http,
                        filenameHint: filenameHint,
                        pageTitle: pageTitle,
                        resourceInfo: info
                    ),
                    label: String(localized: "直链"),
                    // A probed Content-Length is the real size; hand it to the
                    // confirmation window too, so it does not keep showing
                    // "size unknown" after the probe finishes.
                    estimatedSize: info.size,
                    sizeProbed: info.size != nil
                )
            ]
        }

        let discovery = try? await pageMediaDiscoverer.discover(
            url: url,
            requestContext: requestContext
        )
        var options: [DownloadMediaOption] = []
        for candidate in discovery?.candidates ?? [] {
            if candidate.sourceKind == .hls || candidate.sourceKind == .dash {
                let inspected = try await inspectDownloadOptions(
                    url: candidate.url,
                    sourceKind: candidate.sourceKind,
                    filenameHint: nil,
                    pageTitle: discovery?.title ?? pageTitle,
                    requestContext: requestContext
                )
                options.append(contentsOf: inspected)
            } else {
                options.append(
                    DownloadMediaOption(
                        url: candidate.url,
                        sourceKind: .http,
                        filename: DownloadNaming.suggestedFilename(
                            url: candidate.url,
                            sourceKind: .http,
                            // The page title is the user-facing name for a
                            // page-discovered resource. The URL filename is
                            // only a fallback when the page has no title.
                            filenameHint: nil,
                            pageTitle: discovery?.title ?? pageTitle,
                            resourceInfo: nil
                        ),
                        label: candidate.label
                    )
                )
            }
        }
        // yt-dlp fallback: the regular probe found nothing (or errored),
        // but yt-dlp's extractor library understands thousands of sites'
        // player-embedded media. One bounded attempt before giving up.
        if options.isEmpty,
            let fallback = await ytdlpGenericFallback(
                url: url,
                filenameHint: filenameHint,
                pageTitle: pageTitle,
                requestContext: requestContext
            )
        {
            return fallback
        }
        guard !options.isEmpty else { throw WebPageMediaDiscoveryError.noCandidates }
        return options
    }

    /// Asks yt-dlp to resolve a playable media URL for `url` (any site).
    /// Bounded to 15s like the YouTube format listing: a slow or stuck
    /// fallback must never block the new-download dialog. Returns nil on
    /// any failure so the caller keeps its original error path.
    private func ytdlpGenericFallback(
        url: URL,
        filenameHint: String?,
        pageTitle: String?,
        requestContext: DownloadRequestContext?
    ) async -> [DownloadMediaOption]? {
        guard YTDlpManager.isAvailable else { return nil }
        let extraction =
            await Self.withTimeout(15) {
                try await YouTubeMediaInspector().inspectGeneric(
                    url: url,
                    requestContext: requestContext
                )
            } ?? nil
        guard let extraction else { return nil }
        AppLogger.shared.info(
            .download, "yt-dlp generic fallback resolved media for host: \(url.host ?? "?")")
        let title = extraction.title ?? pageTitle
        return [
            DownloadMediaOption(
                url: extraction.mediaURL,
                sourceKind: .http,
                filename: DownloadNaming.suggestedFilename(
                    url: extraction.mediaURL,
                    sourceKind: .http,
                    filenameHint: filenameHint,
                    pageTitle: title,
                    resourceInfo: nil
                ),
                label: String(localized: "yt-dlp 提取"),
                requestContext: requestContext,
                estimatedSize: extraction.estimatedSize,
                duration: extraction.duration
            )
        ]
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

    func presentNewDownload(draft: DownloadDraft?) {
        if let presenter = newDownloadPresenter {
            presenter(draft)
            return
        }
        DownloadDraftWindowManager.shared.open(draft: draft, model: self)
    }

    /// ⌘⇧N (Carbon global hotkey, delivered via MenuBarContentView): open a
    /// new-download window, prefilled from the clipboard when it holds a link.
    func handleGlobalHotKey() {
        let value = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var draft: DownloadDraft?
        if let value,
            value.count <= 2_048,
            let url = URL(string: value),
            url.scheme == "http" || url.scheme == "https",
            url.host != nil
        {
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
            value != lastDetectedClipboardURL,
            value.count <= 2_048,
            let url = URL(string: value),
            url.scheme == "http" || url.scheme == "https",
            url.host != nil
        else { return }
        lastDetectedClipboardURL = value
        NotificationCenter.default.post(name: .macIDMCreateDownload, object: value)
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

    private func inspectDownloadOptions(
        url: URL,
        sourceKind: DownloadSourceKind,
        filenameHint: String?,
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
                    label: variant.label
                ),
                label: variant.label,
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

    func effectiveSourceKind(
        for url: URL,
        requested: DownloadSourceKind,
        pairAudioURL: URL?,
        allowPageAdapters: Bool = false
    ) -> DownloadSourceKind {
        if pairAudioURL != nil { return .dash }
        guard requested == .http else { return requested }
        if allowPageAdapters, BilibiliPlayurlAdapter.supports(url) { return .dash }
        return sourceKindForURL(url)
    }

    private func isDirectMediaURL(_ url: URL, declaredMime: String? = nil) -> Bool {
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

    private func isHTMLMime(_ mime: String?) -> Bool {
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

final class ProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: @Sendable (DownloadProgress) -> Void
    private var lastDelivery = Date.distantPast

    init(callback: @escaping @Sendable (DownloadProgress) -> Void) {
        self.callback = callback
    }

    func receive(_ progress: DownloadProgress) {
        lock.lock()
        let now = Date()
        let shouldDeliver =
            now.timeIntervalSince(lastDelivery) >= 0.2
            || progress.totalBytes == progress.receivedBytes
        if shouldDeliver {
            lastDelivery = now
        }
        lock.unlock()
        if shouldDeliver {
            callback(progress)
        }
    }
}

extension Notification.Name {
    static let macIDMCreateDownload = Notification.Name("MacIDMCreateDownload")
    static let macIDMHotKeyRequested = Notification.Name("MacIDMHotKeyRequested")
    static let macIDMRequestRemoval = Notification.Name("MacIDMRequestRemoval")
    static let macIDMRequestClearHistory = Notification.Name("MacIDMRequestClearHistory")
    static let macIDMRequestSettings = Notification.Name("MacIDMRequestSettings")
    static let macIDMRequestMainWindow = Notification.Name("MacIDMRequestMainWindow")
}
