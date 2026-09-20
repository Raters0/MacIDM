import Foundation
import IDMEngine
import MacIDMBridge

extension AppModel {
    func task(with id: UUID) -> AppTask? {
        tasks.first { $0.id == id }
    }

    func update(_ id: UUID, body: (inout AppTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = tasks[index].status
        body(&tasks[index])
        tasks[index].updatedAt = Date()
        notifyStatusTransition(task: tasks[index], previous: previousStatus)
        // Status/size/name changes flow to the table's cells through the
        // live-model bridge; the table body only re-renders on structural
        // changes (see TaskTableSynchronizer).
        tableSynchronizer.updateLive(tasks[index])
        scheduleStatusExport()
    }

    /// Coalesces the status export driven by `update()` to at most one per
    /// `statusExportInterval`, with a trailing flush so the last state is
    /// always published. Keeps agent-facing status fresh without paying the
    /// export cost on every progress tick.
    func scheduleStatusExport() {
        let elapsed = Date().timeIntervalSince(lastStatusExport)
        if elapsed >= Self.statusExportInterval {
            lastStatusExport = Date()
            exportStatus()
        } else if !statusExportPending {
            statusExportPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.statusExportInterval * 1_000_000_000)
                )
                guard let self, self.statusExportPending else { return }
                self.statusExportPending = false
                self.lastStatusExport = Date()
                self.exportStatus()
            }
        }
    }

    func notifyStatusTransition(task: AppTask, previous: AppTaskStatus) {
        guard task.status != previous else { return }
        switch task.status {
        case .completed:
            notifier.notifyTaskFinished(
                filename: task.filename,
                succeeded: true,
                errorMessage: nil,
                playSound: settings.notificationSoundsEnabled
            )
        case .failed, .storageError:
            notifier.notifyTaskFinished(
                filename: task.filename,
                succeeded: false,
                errorMessage: task.errorMessage
            )
        default:
            break
        }
    }

    static func defaultFFmpegService() -> FFmpegService? {
        // Pinned environment toolchain wins (reproducible Debug builds from
        // the integration scripts). When that is absent — i.e. a normal
        // double-click launch — the App falls back to an autodetecting
        // proxy (FFmpegAutodetectProxy) that locates an ffmpeg/ffprobe pair
        // on PATH or in common Homebrew locations on first use. This is the
        // product path: users cannot be expected to set six MACIDM_* env
        // vars, and without it every HLS/DASH task fails with
        // FFMPEG_UNAVAILABLE even when a working ffmpeg is already
        // installed. The autodetected toolchain goes through the same
        // validateToolchain checks, so output remains reproducible; only
        // the trust root differs (local binary vs. env var).
        if let toolchain = FFmpegToolchain.fromEnvironment() {
            return FFmpegService(toolchain: toolchain)
        }
        return nil
    }

    func persist() throws {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        try persistenceCoordinator.save(tasks)
    }

    enum PersistenceKind {
        /// Structural change (add/remove/status transition): full upsert.
        case full
        /// Pure progress tick: only volatile columns are updated.
        case progress
    }

    func tryPersistOrPresentError(immediate: Bool = false) {
        schedulePersistence(kind: .full, immediate: immediate)
    }

    func schedulePersistence(kind: PersistenceKind, immediate: Bool) {
        // A full save subsumes any queued progress-only save.
        if kind == .full { pendingPersistenceKind = .full }
        pendingPersistenceTask?.cancel()
        let stale = Date().timeIntervalSince(lastPersistenceFlush)
        let delay: UInt64 =
            immediate || stale >= Self.maximumPersistenceStaleness ? 0 : 250_000_000
        pendingPersistenceTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingPersistence()
        }
    }

    func flushPendingPersistence() {
        pendingPersistenceTask = nil
        lastPersistenceFlush = Date()
        let kind = pendingPersistenceKind
        pendingPersistenceKind = .progress
        let snapshot = tasks
        // Progress-only writes re-encode speed history and segments JSON per
        // row; restricting the snapshot to actually-active tasks keeps idle
        // history rows (hundreds of them) out of the 2-second tick.
        let persistenceSnapshot =
            kind == .progress
            ? snapshot.filter { $0.status.isActive }
            : snapshot
        let completion: @Sendable (String?) -> Void = { [weak self] message in
            guard let message else { return }
            Task { @MainActor in
                self?.presentedError = PresentedError(
                    title: String(localized: "无法保存任务状态"),
                    message: message
                )
            }
        }
        switch kind {
        case .full:
            persistenceCoordinator.saveAsync(persistenceSnapshot, completion: completion)
        case .progress:
            persistenceCoordinator.saveProgressAsync(persistenceSnapshot, completion: completion)
        }
    }

    func startTakeoverSweep() {
        takeoverSweepTask?.cancel()
        takeoverSweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.takeoverSweepInterval)
                guard !Task.isCancelled else { return }
                self?.sweepStaleTakeovers()
            }
        }
    }

    func startFileExistenceCheck() {
        fileCheckTask?.cancel()
        // Snapshot the completed set before the first sweep. A destination
        // that is already missing for one of these tasks was lost before this
        // session, so the sweep renders the flag without announcing one
        // notification and one log line per task on every launch.
        fileCheckBaselineTaskIDs = Set(tasks.filter { $0.status == .completed }.map(\.id))
        fileCheckSeenTaskIDs = []
        fileCheckTask = Task { @MainActor [weak self] in
            var lastExportSignature = Self.statusExportSignature(
                tasks: self?.tasks ?? [],
                bridgeStatus: self?.browserBridgeStatus ?? .stopped,
                ytdlpInstalled: YTDlpManager.isAvailable,
                ffmpegAvailable: self?.ffmpegRemuxer != nil
            )
            var needsInitialExport = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.fileCheckInterval)
                guard let self, !Task.isCancelled else { return }
                self.checkCompletedTaskFiles()
                // Exporting unconditionally rewrote status.json (a full task
                // snapshot plus recent logs) every 5 seconds even when the
                // app was idle. Export only when something observable changed.
                let signature = Self.statusExportSignature(
                    tasks: self.tasks,
                    bridgeStatus: self.browserBridgeStatus,
                    ytdlpInstalled: YTDlpManager.isAvailable,
                    ffmpegAvailable: self.ffmpegRemuxer != nil
                )
                // Plus once right after launch, so the file never carries
                // a previous session's content forward.
                if needsInitialExport || signature != lastExportSignature {
                    needsInitialExport = false
                    lastExportSignature = signature
                    self.exportStatus()
                }
            }
        }
    }

    /// Cheap change detector for the periodic status export: structural
    /// identity, statuses, progress bytes and toolchain/bridge availability.
    /// Deliberately excludes speed (changes every tick) — speed updates
    /// schedule their own coalesced export via `scheduleStatusExport`.
    static func statusExportSignature(
        tasks: [AppTask],
        bridgeStatus: BrowserBridgeStatus,
        ytdlpInstalled: Bool,
        ffmpegAvailable: Bool
    ) -> Int {
        var hash = tasks.count.hashValue
        for task in tasks {
            hash =
                hash
                &+ task.id.hashValue
                &+ task.status.rawValue.hashValue
                &+ Int(task.receivedBytes).hashValue
                &+ (task.totalBytes?.hashValue ?? 0)
                &+ (task.fileMissing ? 1 : 0)
        }
        return hash
            &+ bridgeStatus.title.hashValue
            &+ (ytdlpInstalled ? 1 : 0)
            &+ (ffmpegAvailable ? 1 : 0)
    }

    /// One destination the sweep stats off the main actor, plus whether a newly
    /// detected loss may be announced (see `shouldAnnounceFileMissing`).
    private struct FileCheckEntry: Sendable {
        let taskID: UUID
        let path: String
        let announce: Bool
    }

    /// A state change observed by the sweep: `missing` is the freshly stat'ed
    /// result, not the flag the table currently renders.
    private struct FileCheckOutcome: Sendable {
        let taskID: UUID
        let missing: Bool
        let announce: Bool
    }

    /// Announcement rule for one missing destination, isolated as a pure
    /// function for testing. A task that was already completed when this
    /// session's sweep started reports its loss as pre-existing baseline state
    /// on the first observation only; every other loss — including the same
    /// file disappearing again later in the session — is an event worth a
    /// notification and a per-task log line.
    static func shouldAnnounceFileMissing(
        taskID: UUID,
        baselineTaskIDs: Set<UUID>,
        seenTaskIDs: Set<UUID>
    ) -> Bool {
        !(baselineTaskIDs.contains(taskID) && !seenTaskIDs.contains(taskID))
    }

    /// Lightweight periodic sweep: for completed tasks whose destination file
    /// has been deleted or moved, mark `fileMissing` so the UI can warn the
    /// user. When the file reappears the flag is cleared. Only completed tasks
    /// are checked and at most `fileCheckBatchLimit` per cycle to avoid disk
    /// I/O pressure. This is a transient UI flag and intentionally does not
    /// trigger persistence or update `updatedAt`.
    ///
    /// Notification and logging are limited to losses detected *during* this
    /// session: the first observation of a task that was already completed at
    /// launch only establishes the baseline (one aggregate log line per sweep),
    /// so a history full of deleted files does not fire a notification storm on
    /// every launch.
    func checkCompletedTaskFiles() {
        let completed = tasks.filter { $0.status == .completed }
        guard !completed.isEmpty else { return }
        // Rotate the cursor so successive cycles cover different tasks.
        let start = fileCheckCursor % completed.count
        let primary = Array(completed[start...].prefix(Self.fileCheckBatchLimit))
        let remaining = Self.fileCheckBatchLimit - primary.count
        let wrap = remaining > 0 ? Array(completed.prefix(start).prefix(remaining)) : []
        let batch = primary + wrap
        fileCheckCursor = (start + batch.count) % max(1, completed.count)
        // Collect paths to check off the main actor. Use task IDs instead
        // of array indices because the tasks array may change (insertions,
        // deletions) between the detached check and the MainActor apply.
        let entries = batch.map {
            FileCheckEntry(
                taskID: $0.id,
                path: $0.destinationPath,
                announce: Self.shouldAnnounceFileMissing(
                    taskID: $0.id,
                    baselineTaskIDs: fileCheckBaselineTaskIDs,
                    seenTaskIDs: fileCheckSeenTaskIDs
                )
            )
        }
        for entry in entries { fileCheckSeenTaskIDs.insert(entry.taskID) }
        let priorStates = Dictionary(
            batch.map { ($0.id, $0.fileMissing) },
            uniquingKeysWith: { _, last in last }
        )
        Task.detached(priority: .utility) { [weak self] in
            let fileManager = FileManager.default
            let outcomes = entries.compactMap { entry -> FileCheckOutcome? in
                let missing = !fileManager.fileExists(atPath: entry.path)
                // Only report changes to avoid unnecessary MainActor wake-ups.
                guard priorStates[entry.taskID] != missing else { return nil }
                return FileCheckOutcome(
                    taskID: entry.taskID,
                    missing: missing,
                    announce: entry.announce
                )
            }
            guard !outcomes.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var baselineMissingCount = 0
                for outcome in outcomes {
                    guard let index = self.tasks.firstIndex(where: { $0.id == outcome.taskID })
                    else { continue }
                    let name = self.tasks[index].filename
                    let destinationPath = self.tasks[index].destinationPath
                    // Route through update() so the table's live models pick
                    // up the missing-file flag immediately instead of waiting
                    // for the next structural change.
                    self.update(outcome.taskID) { $0.fileMissing = outcome.missing }
                    guard outcome.missing else { continue }
                    if !outcome.announce {
                        baselineMissingCount += 1
                        continue
                    }
                    self.notifier.notifyFileMissing(filename: name)
                    // The ordinary log keeps only the task ID; the full
                    // filename goes to the private log (§3.3).
                    DownloadDiagnosticEventLog.recordTaskLifecycle(
                        event: "task.fileMissing",
                        taskID: outcome.taskID,
                        filename: name,
                        destinationPath: destinationPath
                    )
                }
                if baselineMissingCount > 0 {
                    DownloadDiagnosticEventLog.recordFileMissingBaseline(
                        count: baselineMissingCount
                    )
                }
            }
        }
    }

    func shutdown() {
        takeoverSweepTask?.cancel()
        takeoverSweepTask = nil
        fileCheckTask?.cancel()
        fileCheckTask = nil
        queueScheduleTask?.cancel()
        queueScheduleTask = nil
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        cancelCompletionCountdown()
        // Use pause semantics on quit, not cancel. The engine's error path
        // treats IDMError.cancelled as "delete the sidecar and temp file"
        // (DownloadEngine.swift:244-247), which would destroy in-flight
        // checkpoint progress when the user quits the app — a 1 GB download
        // at 90% would restart from zero on the next launch. Pause keeps the
        // sidecar and temp file intact so the task resumes from its
        // checkpoint after restart. The Task cancellation here only tears
        // down the Swift concurrency task; the engine observes .pause via
        // the control token and checkpoints cleanly.
        for control in executions.controls { control.pause() }
        for task in executions.tasks { task.cancel() }
        // Mark every still-running task as paused so the persisted state and
        // the in-memory state agree; otherwise a task that was .running when
        // shutdown began would be persisted as .running and the load path
        // has no recovery branch for that.
        for index in tasks.indices {
            if tasks[index].status.isActive {
                tasks[index].status = .paused
                tasks[index].bytesPerSecond = 0
            }
        }
        // Publish quit intent before closing the socket so the Host cannot
        // interpret this deliberate shutdown as a crash and relaunch the App.
        BridgeLaunchIntent.recordQuitIntent(in: AppSupportPaths.supportDirectory())
        browserBridge.stop()
        MonitorHTTPServer.shared.stop()
        try? persistenceCoordinator.save(tasks)
        try? store.saveQueues(queues)
    }

    func taskSnapshot(_ task: AppTask, formatter: ISO8601DateFormatter) -> StatusExporter.TaskSnapshot {
        StatusExporter.TaskSnapshot(
            id: task.id.uuidString,
            jobId: task.jobID,
            status: task.status.rawValue,
            filename: task.filename,
            receivedBytes: task.receivedBytes,
            totalBytes: task.totalBytes,
            speed: task.bytesPerSecond > 0 ? task.bytesPerSecond : nil,
            category: task.categoryOverride?.rawValue,
            errorMessage: task.errorMessage,
            backend: task.sourceKind?.rawValue,
            sourceKind: task.sourceKind?.rawValue,
            createdAt: formatter.string(from: task.createdAt)
        )
    }

    static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? ""
        let buildDate = info?["MacIDMBuildDate"] as? String ?? ""
        if !buildDate.isEmpty {
            return "MacIDM \(version) (\(buildDate))"
        }
        return "MacIDM \(version) (\(build))"
    }

    func monitorState() -> MonitorHTTPServer.MonitorState {
        let formatter = ISO8601DateFormatter()
        let taskSnapshots = tasks.map { taskSnapshot($0, formatter: formatter) }
        return MonitorHTTPServer.MonitorState(
            timestamp: formatter.string(from: Date()),
            appVersion: Self.appVersionString(),
            bridgeStatus: browserBridgeStatus.title,
            ytdlpInstalled: YTDlpManager.isAvailable,
            ytdlpVersion: YTDlpManager.currentVersionSync(),
            ffmpegAvailable: ffmpegRemuxer != nil,
            tasks: taskSnapshots,
            recentLogs: AppLogger.shared.readLog(maxLines: 20)
                .split(separator: "\n")
                .map(String.init)
        )
    }

    func startMonitorServer() {
        // Both configure calls precede `start`: a connection accepted first would
        // otherwise be dispatched with no token and no command handler.
        MonitorHTTPServer.shared.configure(token: Self.agentControlToken())
        MonitorHTTPServer.shared.configure { [weak self] command in
            guard let self else {
                return MonitorHTTPServer.AgentResponse(
                    ok: false,
                    message: String(localized: "应用状态不可用")
                )
            }
            // AppModel is @MainActor; awaiting hops to the main actor, which
            // also lets the command handler run async work (title lookups).
            return await self.handleAgentCommand(command)
        }
        MonitorHTTPServer.shared.start { [weak self] in
            guard let self else { return nil }
            return self.monitorState()
        }
    }

    /// Per-launch bearer token guarding the control endpoints of the local
    /// monitor server. It is written to `agent-token` (0600) inside the
    /// app's Application Support directory so trusted local clients (CLI,
    /// automation scripts, AI agents on this machine) can read it, while a
    /// web page has no way to guess or obtain it.
    static func agentControlToken() -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacIDM", isDirectory: true)
        let tokenURL = directory.appendingPathComponent("agent-token")
        let token = UUID().uuidString
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenURL.path
            )
        } catch {
            AppLogger.shared.warning(
                .bridge,
                "agent token file could not be written: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? "SANITIZE_FAILED")"
            )
        }
        return token
    }

    func exportStatus() {
        // Snapshot the main-actor state cheaply, then move the heavy parts
        // (log tail read, JSON encoding, file write) off the main actor.
        // This path runs on every task update flush while downloads are
        // active and must never block the UI.
        let formatter = ISO8601DateFormatter()
        let snapshot = tasks.map { taskSnapshot($0, formatter: formatter) }
        let bridgeStatusTitle = browserBridgeStatus.title
        let ytdlpInstalled = YTDlpManager.isAvailable
        let ytdlpVersion = YTDlpManager.currentVersionSync()
        let ffmpegAvailable = ffmpegRemuxer != nil
        let appVersion = Self.appVersionString()
        Task.detached(priority: .utility) {
            let recentLogs = AppLogger.shared.readLog(maxLines: 20)
                .split(separator: "\n")
                .map(String.init)
            StatusExporter.shared.export(
                bridgeStatus: bridgeStatusTitle,
                ytdlpInstalled: ytdlpInstalled,
                ytdlpVersion: ytdlpVersion,
                ffmpegAvailable: ffmpegAvailable,
                appVersion: appVersion,
                tasks: snapshot,
                recentLogs: recentLogs
            )
            let state = MonitorHTTPServer.MonitorState(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                appVersion: appVersion,
                bridgeStatus: bridgeStatusTitle,
                ytdlpInstalled: ytdlpInstalled,
                ytdlpVersion: ytdlpVersion,
                ffmpegAvailable: ffmpegAvailable,
                tasks: snapshot,
                recentLogs: recentLogs
            )
            MonitorHTTPServer.shared.update(state)
        }
    }
}
