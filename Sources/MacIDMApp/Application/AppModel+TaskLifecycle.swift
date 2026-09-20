import AppKit
import Foundation
import IDMEngine

extension AppModel {
    func pause(_ id: UUID) {
        guard let task = task(with: id), !task.isCLIManaged else { return }
        // Filenames are often derived from video titles: the ordinary log
        // records only the task ID (technical-spec §3.1.7).
        AppLogger.shared.info(.download, "paused task=\(id)")
        switch task.status {
        case .queued:
            update(id) {
                $0.status = .paused
                $0.bytesPerSecond = 0
            }
            scheduleQueuedTasks()
        case .probing, .running, .verifying:
            executions[id].control?.pause()
            update(id) { $0.status = .pausing }
            scheduleStuckTransitionFallback(id, from: .pausing, to: .paused)
        default:
            return
        }
        tryPersistOrPresentError()
    }

    /// Escalate cancellation without releasing ownership of a possibly live writer.
    /// Only the execution completion may release its handle and permit a retry.
    func scheduleStuckTransitionFallback(
        _ id: UUID,
        from transitional: AppTaskStatus,
        to settled: AppTaskStatus
    ) {
        let token = UUID()
        executions[id].transitionToken = token
        let generation = executions[id].generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self,
                self.executions[id].transitionToken == token,
                self.executions[id].generation == generation,
                self.task(with: id)?.status == transitional
            else { return }
            self.executions[id].task?.cancel()
            self.executions[id].pendingProgress = nil
            self.update(id) {
                $0.status = self.executions[id].task == nil ? settled : .failed
                $0.bytesPerSecond = 0
                if self.executions[id].task != nil {
                    $0.errorCode = "STOP_TIMEOUT"
                    $0.errorMessage = "下载尚未确认停止，正在等待写入结束；结束后才可重试或删除文件。"
                }
            }
            self.tryPersistOrPresentError()
        }
    }

    func resume(_ id: UUID) {
        guard executions[id].task == nil else {
            presentedError = PresentedError(
                title: "下载仍在停止中",
                message: "旧执行尚未结束，不能同时启动新的写入。请等待停止完成后重试。"
            )
            return
        }
        guard let task = task(with: id), !task.isCLIManaged else { return }
        if requiresBrowserRefetch(task) {
            // The task's browser context (signed URL, cookies, referer) was
            // never persisted and is lost after restart. Surface this to the
            // user instead of silently doing nothing, so they know to
            // re-submit the download from Chrome.
            presentedError = PresentedError(
                title: String(localized: "无法继续此任务"),
                message: task.errorMessage
                    ?? String(
                        localized: "此任务的浏览器下载上下文未在本机持久化，请从 Chrome 重新提交原始链接。"
                    )
            )
            return
        }
        switch task.status {
        case .paused, .failed, .needsRestart, .storageError, .cancelled:
            AppLogger.shared.info(.download, "resumed task=\(id)")
            update(id) {
                $0.status = .queued
                $0.errorCode = nil
                $0.errorMessage = nil
                $0.errorRecommendation = nil
                $0.errorCategory = nil
            }
            tryPersistOrPresentError()
            scheduleQueuedTasks()
        default:
            return
        }
    }

    /// Halves the task's parallel-request cap and re-queues it — the
    /// one-click remedy for rate-limit (HTTP 429) failures, where high
    /// concurrency is usually what triggered the throttle.
    func reduceParallelismAndRetry(_ id: UUID) {
        guard let task = task(with: id), !task.isCLIManaged else { return }
        let reduced = max(1, task.maximumParallelRequests / 2)
        update(id) { $0.maximumParallelRequests = reduced }
        // The ordinary log keeps only the task ID and concurrency count; the
        // full filename goes to the private log (§3.3).
        DownloadDiagnosticEventLog.recordTaskLifecycle(
            event: "task.parallelismReduced",
            taskID: id,
            filename: task.filename,
            destinationPath: task.destinationPath,
            summary: "reduced parallelism to \(reduced) and retrying"
        )
        resume(id)
    }

    /// Switches a failed native download to the yt-dlp backend and
    /// re-queues it — yt-dlp's extractor library covers thousands of
    /// sites, so it often succeeds where a plain HTTP transfer failed
    /// (player-driven media URLs, site-specific headers, pagination).
    func retryWithYtdlp(_ id: UUID) {
        guard let task = task(with: id), !task.isCLIManaged else { return }
        guard task.browserSubmissionType != "youtube.extractor" else {
            // Already on that backend; a plain retry is the only option.
            resume(id)
            return
        }
        update(id) {
            // start() derives the backend from this marker, the same way a
            // browser-submitted yt-dlp task is flagged; the flag persists
            // so later restarts keep the fallback backend.
            $0.browserSubmissionType = "youtube.extractor"
            $0.receivedBytes = 0
            $0.overallProgressFraction = nil
            $0.bytesPerSecond = 0
        }
        AppLogger.shared.info(.download, "retrying via yt-dlp fallback task=\(id)")
        tryPersistOrPresentError()
        resume(id)
    }

    func setCategory(_ id: UUID, category: DownloadCategory?) {
        guard let task = task(with: id), !task.isCLIManaged else { return }
        update(id) { task in
            task.categoryOverride = category
        }
        tryPersistOrPresentError()
    }

    /// Rename the destination of a `.filenameConflict` task and re-queue it,
    /// so the user does not have to delete the task and re-download from
    /// scratch. The in-memory signed URL / request context is preserved
    /// across a filenameConflict failure (it is non-terminal), so the retry
    /// can reuse the same transient context the original submission carried.
    func retryWithNewFilename(_ id: UUID, filename rawFilename: String) throws {
        let trimmed = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilenameRetryError.emptyFilename }
        let safeName = InputValidator.safeFilename(trimmed)
        guard safeName == trimmed, !safeName.isEmpty else {
            throw FilenameRetryError.invalidFilename
        }
        guard let task = task(with: id), !task.isCLIManaged else {
            throw FilenameRetryError.taskMissing
        }
        guard task.status == .filenameConflict else { throw FilenameRetryError.notInConflict }
        let directory = URL(fileURLWithPath: task.destinationPath).deletingLastPathComponent()
        let newDestination = directory.appendingPathComponent(safeName)
        // The new name must not collide with an existing file or a reserved
        // task destination either, or the engine would just throw
        // filenameConflict again on the next probe.
        do {
            _ = try availableDestination(for: newDestination, automaticRename: false)
        } catch {
            throw FilenameRetryError.alreadyExists(safeName)
        }
        autoRenameAttempts[id] = nil
        update(id) {
            $0.destinationPath = newDestination.path
            $0.status = .queued
            $0.errorCode = nil
            $0.errorMessage = nil
            $0.bytesPerSecond = 0
        }
        tryPersistOrPresentError()
        scheduleQueuedTasks()
    }

    func cancel(_ id: UUID) {
        guard let task = task(with: id), !task.isCLIManaged,
            task.status != .completed, task.status != .cancelled
        else {
            return
        }
        AppLogger.shared.info(.download, "cancelled task=\(id)")
        if executions[id].task != nil {
            executions[id].control?.cancel()
            update(id) { $0.status = .cancelling }
            scheduleStuckTransitionFallback(id, from: .cancelling, to: .cancelled)
            tryPersistOrPresentError()
            return
        }

        if task.status == .queued || task.status == .paused || task.status == .failed
            || task.status == .needsRestart || task.status == .takeoverPending
            || task.status == .takeoverConflict || task.status == .filenameConflict
        {
            if task.status == .takeoverPending,
                let takeoverIndex = browserTakeovers.firstIndex(where: { $0.taskID == id })
            {
                // Keep the takeover record until Chrome acknowledges the
                // cancellation. Removing it here lets a late browser
                // callback create a second task or resume the wrong state.
                browserTakeovers[takeoverIndex].state = .appCancelled
                browserTakeovers[takeoverIndex].updatedAt = Date()
                persistBrowserTakeoversOrPresentError()
                takeoverLog?.append(event: "cancelled-by-user", taskID: id, detail: "接管等待期间被用户取消")
            } else if let takeover = browserTakeovers.first(where: { $0.taskID == id }) {
                rememberAbandonedTakeover(
                    clientID: takeover.authenticatedClientID,
                    idempotencyKey: takeover.idempotencyKey,
                    browserDownloadID: takeover.browserDownloadID
                )
                takeoverStore.release(path: takeover.reservationPath)
                browserTakeovers.removeAll { $0.taskID == id }
                persistBrowserTakeoversOrPresentError()
            }
            // Invalidate the current execution's generation: a stranded
            // engine Task (stuck-pause fallback released its control state)
            // finishing later would otherwise flip .cancelled back to
            // .paused or even .completed through finish()'s generation
            // check. Monotonic bump, never removal — a removal followed by
            // start()'s `default: 0` counter would let the new execution
            // reuse the stranded task's generation number.
            executions[id].generation += 1
            update(id) {
                $0.status = .cancelled
                $0.bytesPerSecond = 0
            }
            tryPersistOrPresentError()
            scheduleQueuedTasks()
        } else if [.probing, .running, .pausing, .verifying].contains(task.status) {
            executions[id].control?.cancel()
            update(id) { $0.status = .cancelling }
            scheduleStuckTransitionFallback(id, from: .cancelling, to: .cancelled)
            tryPersistOrPresentError()
        }
    }

    func remove(_ id: UUID) {
        remove(id, deletingFile: false)
    }

    /// `deletingFile` is honored for completed tasks (the final file is
    /// removed) and for non-completed tasks that have partial download
    /// artifacts (temp files, sidecars, HLS inputs, DASH pair directories).
    /// Removing a task archives it into history rather than permanently
    /// deleting, so the user can re-download later. Active tasks are stopped
    /// first: the engine control is cancelled and the execution task torn
    /// down before the record is archived, so a running download can be
    /// deleted in one step without a manual pause/cancel round trip.
    func remove(_ id: UUID, deletingFile: Bool) {
        guard let task = task(with: id), !task.isCLIManaged else { return }
        if let execution = executions[id].task {
            guard pendingRemovals.insert(id).inserted else { return }
            executions[id].control?.cancel()
            execution.cancel()
            update(id) { $0.status = .cancelling }
            scheduleStuckTransitionFallback(id, from: .cancelling, to: .cancelled)
            tryPersistOrPresentError()
            Task { @MainActor [weak self] in
                await execution.value
                guard let self else { return }
                self.pendingRemovals.remove(id)
                self.remove(id, deletingFile: deletingFile)
            }
            return
        }
        if task.status.isActive {
            update(id) {
                $0.status = .cancelled
                $0.bytesPerSecond = 0
            }
            cleanUpExecution(id)
        }
        if deletingFile {
            if task.status == .completed {
                try? FileManager.default.removeItem(atPath: task.destinationPath)
            }
            // Always clean up partial download artifacts when the user asks
            // to delete files, regardless of task status. A paused/failed
            // task may have a partially-written temp file, a sidecar, an
            // HLS raw input, or a DASH pair directory occupying disk space.
            for url in Self.partialArtifactURLs(for: task) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if selectedTaskID == id {
            selectedTaskID = nil
        }
        if let takeover = browserTakeovers.first(where: { $0.taskID == id }) {
            rememberAbandonedTakeover(
                clientID: takeover.authenticatedClientID,
                idempotencyKey: takeover.idempotencyKey,
                browserDownloadID: takeover.browserDownloadID
            )
            takeoverStore.release(path: takeover.reservationPath)
            browserTakeovers.removeAll { $0.taskID == id }
            persistBrowserTakeoversOrPresentError()
        }
        if settings.archiveOnDelete {
            update(id) { $0.isArchived = true }
        } else {
            tasks.removeAll { $0.id == id }
        }
        // The task no longer owns its destination; drop the unredacted URL
        // so signed links do not linger in the vault until TTL expiry.
        sourceURLVault.remove(ids: [id])
        exportStatus()
        selectedTaskIDs.remove(id)
        // Direct mutation — push the pruned selection into the table
        // binding (nothing round-trips through the appearance token).
        tableSynchronizer.applyExternalSelection(selectedTaskIDs)
        if let selectedID = selectedTaskID, !tasks.contains(where: { $0.id == selectedID }) {
            selectedTaskID = nil
        }
        tableSynchronizer.replaceAllLive(tasks)
        tryPersistOrPresentError()
    }

    /// Permanently removes a task from history (irreversible).
    func permanentlyRemove(_ id: UUID) {
        guard let task = task(with: id), task.isArchived else { return }
        if selectedTaskID == id {
            selectedTaskID = nil
        }
        if let takeover = browserTakeovers.first(where: { $0.taskID == id }) {
            rememberAbandonedTakeover(
                clientID: takeover.authenticatedClientID,
                idempotencyKey: takeover.idempotencyKey,
                browserDownloadID: takeover.browserDownloadID
            )
            takeoverStore.release(path: takeover.reservationPath)
            browserTakeovers.removeAll { $0.taskID == id }
            persistBrowserTakeoversOrPresentError()
        }
        tasks.removeAll { $0.id == id }
        selectedTaskIDs.remove(id)
        tableSynchronizer.applyExternalSelection(selectedTaskIDs)
        sourceURLVault.remove(ids: [id])
        tableSynchronizer.replaceAllLive(tasks)
        tryPersistOrPresentError()
    }

    /// Whether removing any of these tasks could also delete a local file or
    /// partial download artifacts, which decides if the confirmation dialog
    /// offers that choice.
    func hasRemovableFiles(_ ids: Set<UUID>) -> Bool {
        tasks.contains { id in
            ids.contains(id.id)
                && !id.isCLIManaged
                && (id.status == .completed
                    || !Self.partialArtifactURLs(for: id).filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }.isEmpty)
        }
    }

    /// Clears all archived tasks (download history) permanently.
    func clearHistory() {
        let archivedIDs = Set(tasks.filter { $0.isArchived && !$0.isCLIManaged }.map(\.id))
        guard !archivedIDs.isEmpty else { return }
        for id in archivedIDs {
            if let takeover = browserTakeovers.first(where: { $0.taskID == id }) {
                rememberAbandonedTakeover(
                    clientID: takeover.authenticatedClientID,
                    idempotencyKey: takeover.idempotencyKey,
                    browserDownloadID: takeover.browserDownloadID
                )
                takeoverStore.release(path: takeover.reservationPath)
                browserTakeovers.removeAll { $0.taskID == id }
            }
        }
        persistBrowserTakeoversOrPresentError()
        tasks.removeAll { archivedIDs.contains($0.id) }
        selectedTaskIDs.subtract(archivedIDs)
        tableSynchronizer.applyExternalSelection(selectedTaskIDs)
        sourceURLVault.remove(ids: archivedIDs)
        if let selectedID = selectedTaskID, archivedIDs.contains(selectedID) {
            selectedTaskID = nil
        }
        tableSynchronizer.replaceAllLive(tasks)
        tryPersistOrPresentError(immediate: true)
    }

    /// Re-downloads a task from history by creating a new task with the
    /// same source URL and destination directory.
    func reDownload(_ id: UUID) {
        guard let archived = task(with: id), archived.isArchived, !archived.isCLIManaged else { return }
        guard !requiresBrowserRefetch(archived) else {
            presentedError = PresentedError(
                title: String(localized: "需要重新提交原始链接"),
                message: String(
                    localized: "该任务的下载地址只在原会话保留，请从 Chrome 或原始页面重新提交。"
                )
            )
            return
        }
        guard !Self.isTransientDASHPair(archived) else {
            presentedError = PresentedError(
                title: String(localized: "需要重新选择音视频轨道"),
                message: String(
                    localized: "该任务的 DASH 音视频配对地址只在原会话保留，请从浏览器媒体候选重新提交。"
                )
            )
            return
        }
        let directory = URL(fileURLWithPath: settings.downloadDirectory, isDirectory: true)
        let destination = directory.appendingPathComponent(archived.filename)
        do {
            try addDownload(
                urlString: archived.sourceURL,
                destination: destination,
                maximumParallelRequests: settings.maximumParallelRequests,
                expectedSHA256: archived.expectedSHA256,
                startImmediately: settings.autoStartDownloads,
                sourceKind: archived.sourceKind ?? .http,
                automaticRename: true
            )
        } catch {
            presentedError = PresentedError(
                title: String(localized: "重新下载失败"),
                message: error.localizedDescription
            )
        }
    }

    func revealInFinder(_ id: UUID) {
        guard let task = task(with: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.destinationPath)])
    }

    func openFile(_ id: UUID) {
        guard let task = task(with: id), task.status == .completed else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: task.destinationPath))
    }

    func copyDestinationPath(_ id: UUID) {
        guard let task = task(with: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.destinationPath, forType: .string)
    }

    /// Space: pause everything pausable in the selection; when nothing is
    /// pausable, resume everything resumable instead.
    func togglePauseResumeSelection() {
        let selection = selectedTasks
        guard !selection.isEmpty else { return }
        let pausable = selection.filter {
            [.queued, .probing, .running, .verifying].contains($0.status)
        }
        if !pausable.isEmpty {
            for task in pausable { pause(task.id) }
            return
        }
        for task in selection
        where !requiresBrowserRefetch(task)
            && [.paused, .failed, .needsRestart, .storageError].contains(task.status)
        {
            resume(task.id)
        }
    }
}
