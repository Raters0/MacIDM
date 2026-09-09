import Foundation
import IDMEngine

extension AppModel {
    /// Starts queued tasks while respecting both the global simultaneous
    /// download cap and each user queue's own concurrency limit. The main
    /// queue (tasks without a `queueID`) is served first; paused queues
    /// never auto-start. Ordering inside a queue follows its order mode.
    func scheduleQueuedTasks() {
        rescindCompletionCountdownIfBusy()
        var globalSlots = max(0, settings.simultaneousDownloads - activeCount)
        guard globalSlots > 0 else { return }
        let queued = tasks.filter { $0.status == .queued && !$0.isCLIManaged }
        globalSlots -= startQueued(
            queued.filter { $0.queueID == nil },
            limit: globalSlots,
            orderMode: .priority
        )
        for queue in queues.sorted(by: { $0.createdAt < $1.createdAt }) where !queue.isPaused {
            guard globalSlots > 0 else { break }
            let activeInQueue = tasks.count {
                $0.queueID == queue.id && ($0.status.isActive || executions[$0.id].task != nil) && !$0.isCLIManaged
            }
            let queueSlots = min(queue.concurrency - activeInQueue, globalSlots)
            guard queueSlots > 0 else { continue }
            globalSlots -= startQueued(
                queued.filter { $0.queueID == queue.id },
                limit: queueSlots,
                orderMode: queue.orderMode
            )
        }
    }

    /// Starts up to `limit` tasks from `candidates` ordered by the queue's
    /// order mode and returns how many were actually started.
    private func startQueued(
        _ candidates: [AppTask],
        limit: Int,
        orderMode: AppQueue.OrderMode
    ) -> Int {
        guard limit > 0, !candidates.isEmpty else { return 0 }
        let ordered: [AppTask]
        switch orderMode {
        case .priority:
            ordered = candidates.sorted {
                if $0.queuePriority != $1.queuePriority {
                    return $0.queuePriority > $1.queuePriority
                }
                return $0.createdAt < $1.createdAt
            }
        case .fifo:
            ordered = candidates.sorted { $0.createdAt < $1.createdAt }
        }
        var started = 0
        for task in ordered {
            guard started < limit else { break }
            start(task.id)
            started += 1
        }
        return started
    }

    func start(_ id: UUID) {
        guard executions[id].task == nil, !pendingRemovals.contains(id), let record = task(with: id),
            record.status == .queued,
            let url = transientSourceURLs[id] ?? URL(string: record.sourceURL)
        else { return }
        // Generational guard: the stuck-pause fallback can strand an engine
        // Task that still finishes later. If the user resumed in between, the
        // stale callback must not tear down the replacement execution's
        // control state (see finish(_:error:execution:)).
        executions[id].generation += 1
        let executionGeneration = executions[id].generation
        executions[id].pendingProgress = nil
        executions[id].transitionToken = nil

        let contextRecord = transientRequestContexts[id]
        if let contextRecord, contextRecord.expiresAt <= Date() {
            transientRequestContexts[id] = nil
            update(id) {
                $0.status = .failed
                $0.errorCode = "NEEDS_AUTH"
                $0.errorMessage = String(
                    localized: "浏览器授权上下文已过期，请从 Chrome 重新提交下载。"
                )
            }
            tryPersistOrPresentError()
            return
        }
        // Fall back to a persisted site session when the task carries no
        // fresh browser context — this is what lets manually-added URLs
        // reuse a login state captured by an earlier extension download
        // (or pasted by hand). YouTube downloads merge it with
        // --cookies-from-browser chrome inside yt-dlp.
        let effectiveContext: DownloadRequestContext?
        if let contextRecord {
            effectiveContext = contextRecord.value
        } else if let stored = sessionStore.lookup(url: url),
            let cookie = sessionStore.cookieHeader(for: stored)
        {
            // A session whose credential is gone (never migrated, Keychain
            // refused it) must fall through to no-session rather than to an
            // empty Cookie header that reads as "logged in".
            effectiveContext = DownloadRequestContext(
                cookie: cookie,
                referer: nil,
                userAgent: stored.userAgent
            )
        } else {
            effectiveContext = nil
        }
        let request = DownloadRequest(
            url: url,
            destination: record.sourceKind == .hls
                ? hlsInputURL(for: record)
                : URL(fileURLWithPath: record.destinationPath),
            sourceKind: record.sourceKind ?? .http,
            maximumParallelRequests: record.maximumParallelRequests,
            expectedSHA256: record.sourceKind == .hls ? nil : record.expectedSHA256,
            taskID: record.id,
            requestContext: effectiveContext,
            rateLimiter: sharedRateLimiter,
            pairAudioURL: transientPairAudioURLs[id],
            pairCID: transientPairCIDs[id],
            backend: record.browserSubmissionType == "youtube.extractor" ? .youtubeExtractor : .native
        )
        let isHLS = record.sourceKind == .hls
        let isDASH = record.sourceKind == .dash
        guard !isHLS || ffmpegRemuxer != nil else {
            update(id) {
                $0.status = .failed
                $0.errorCode = "FFMPEG_UNAVAILABLE"
                $0.errorMessage = String(
                    localized: "HLS 下载需要已配置且通过版本/SHA-256 校验的 FFmpeg 工具链。"
                )
            }
            tryPersistOrPresentError()
            scheduleQueuedTasks()
            return
        }
        guard !isDASH || ffmpegMerger != nil else {
            update(id) {
                $0.status = .failed
                $0.errorCode = "FFMPEG_UNAVAILABLE"
                $0.errorMessage = String(
                    localized: "DASH 下载需要已配置且通过版本/SHA-256 校验的 FFmpeg 工具链。"
                )
            }
            tryPersistOrPresentError()
            scheduleQueuedTasks()
            return
        }
        if record.browserSubmissionType == "youtube.extractor" {
            guard YTDlpManager.isAvailable else {
                update(id) {
                    $0.status = .failed
                    $0.errorCode = "YTDLP_NOT_FOUND"
                    $0.errorMessage = String(
                        localized:
                            "YouTube 下载需要 yt-dlp。点击「安装」自动安装，或手动执行 brew install yt-dlp。"
                    )
                }
                tryPersistOrPresentError()
                ytdlpManager.alert = .installRequired
                scheduleQueuedTasks()
                return
            }
        }
        let hlsInput = isHLS ? request.destination : nil
        let control = DownloadControlToken()
        executions[id].control = control
        progressSamples[id] = (Date(), record.receivedBytes)
        // Seed the active-transfer clock from the persisted value: seconds
        // accumulated before a pause/restart survive, and the fresh baseline
        // guarantees the pause gap itself never counts as transfer time.
        activeTransferAccumulators[id] = (
            Date(), record.receivedBytes, record.activeTransferDuration
        )
        hasStartedTasksThisSession = true
        update(id) {
            $0.status = .probing
            $0.errorCode = nil
            $0.errorMessage = nil
            $0.errorRecommendation = nil
            $0.errorCategory = nil
        }
        tryPersistOrPresentError()

        let bridge = ProgressBridge { [weak self] progress in
            Task { @MainActor in self?.receive(progress, for: id, execution: executionGeneration) }
        }
        executions[id].task = Task { [weak self] in
            guard let self, self.isCurrentExecution(id, executionGeneration) else { return }
            do {
                // A site-adapter (Bilibili) DASH pair loses its transient track
                // URLs across a restart; re-resolve fresh signed URLs from the
                // persisted page URL + archived cookie before running. Returns
                // nil when no re-resolution is needed (normal in-session path).
                var effectiveRequest = request
                if let resolved = try await self.reresolveSiteAdapterPair(id: id, record: record) {
                    effectiveRequest = resolved
                }
                self.update(id) {
                    // A pause/cancel clicked between start() and the engine's
                    // first observation must not be flipped back to .running.
                    guard $0.status == .probing || $0.status == .queued else { return }
                    $0.status = .running
                    if $0.startedAt == nil { $0.startedAt = Date() }
                }
                // Short-circuit: if a complete raw HLS input exists from a
                // previous run (e.g. app crashed after segments finished but
                // before remux), skip re-downloading and go straight to remux.
                // BUT only when no sidecar is present — a sidecar means the
                // HLS executor was mid-download and must validate/truncate
                // before resuming. Feeding an incomplete file to FFmpeg would
                // silently produce a corrupt MP4.
                let result: DownloadResult
                if let hlsInput,
                    let recovered = self.existingHLSInputResult(at: hlsInput),
                    !self.hlsSidecarExists(for: hlsInput)
                {
                    result = recovered
                } else {
                    result = try await self.downloadRunner.run(
                        effectiveRequest,
                        control: { control.read() },
                        progress: { bridge.receive($0) }
                    )
                }
                guard self.isCurrentExecution(id, executionGeneration) else { return }
                if isHLS {
                    switch control.read() {
                    case .pause: throw IDMError.paused
                    case .cancel: throw IDMError.cancelled
                    case .continue: break
                    }
                    guard let ffmpegRemuxer, let hlsInput else {
                        throw AppModelError.ffmpegUnavailable
                    }
                    let remuxed = try await ffmpegRemuxer.remux(
                        FFmpegRemuxRequest(
                            inputURL: hlsInput,
                            outputURL: URL(fileURLWithPath: record.destinationPath),
                            outputKind: .mp4,
                            control: { control.read() }
                        )
                    )
                    guard self.isCurrentExecution(id, executionGeneration) else { return }
                    try? FileManager.default.removeItem(at: hlsInput)
                    self.finish(
                        id,
                        result: DownloadResult(
                            destination: remuxed.destination,
                            byteCount: remuxed.byteCount,
                            sha256: remuxed.sha256,
                            usedParallelRequests: result.usedParallelRequests,
                            resumed: result.resumed,
                            verification: "ffmpeg-ffprobe"
                        ),
                        execution: executionGeneration
                    )
                } else {
                    self.finish(id, result: result, execution: executionGeneration)
                }
            } catch {
                guard self.isCurrentExecution(id, executionGeneration) else { return }
                // App shutdown cancels the Swift task only after publishing a
                // pause intent to the engine. Cancellation can therefore win
                // the race before the engine has produced IDMError.paused;
                // preserve the user's intent instead of turning a resumable
                // task into a failed/cleaned-up task.
                let effectiveError: Error
                if Task.isCancelled {
                    switch control.read() {
                    case .pause: effectiveError = IDMError.paused
                    case .cancel: effectiveError = IDMError.cancelled
                    case .continue: effectiveError = error
                    }
                } else {
                    effectiveError = error
                }
                if isHLS, let hlsInput, shouldDiscardHLSInput(after: effectiveError) {
                    try? FileManager.default.removeItem(at: hlsInput)
                }
                self.finish(id, error: effectiveError, execution: executionGeneration)
            }
        }
    }

    func hlsInputURL(for task: AppTask) -> URL {
        URL(fileURLWithPath: task.destinationPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".\(task.id.uuidString).macidm.hls-input.ts")
    }

    func existingHLSInputResult(at url: URL) -> DownloadResult? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0
        else { return nil }
        return DownloadResult(
            destination: url,
            byteCount: size.int64Value,
            sha256: nil,
            usedParallelRequests: 1,
            resumed: true,
            verification: "segments-and-size"
        )
    }

    func shouldDiscardHLSInput(after error: Error) -> Bool {
        // A completed raw input is the recovery boundary for remux. Keep it
        // when FFmpeg rejects the input or the filesystem temporarily fails so
        // the user can retry remux without downloading every segment again.
        // An explicit cancellation — whether surfaced as FFmpegError.cancelled
        // (internal FFmpeg process cancellation) or IDMError.cancelled (control
        // token cancellation during remux) — removes the intermediate file so
        // hundreds of MiB of .hls-input.ts do not leak on a cancelled task.
        if error as? FFmpegError == .cancelled { return true }
        if let engineError = error as? IDMError, case .cancelled = engineError { return true }
        return false
    }

    /// Checks whether an HLS executor sidecar (`.macidm.hls`) for this
    /// specific task exists in the same directory as the HLS input file.
    /// A sidecar indicates the executor was mid-download with a valid
    /// checkpoint — in that case we must NOT short-circuit, because the
    /// input file may be incomplete.
    func hlsSidecarExists(for hlsInput: URL) -> Bool {
        let directory = hlsInput.deletingLastPathComponent()
        // The HLS input file is named `.{taskUUID}.macidm.hls-input.ts`.
        // The HLS executor sidecar is named `.{name}.{taskUUID}.macidm.hls`.
        // Extract the task UUID from the input filename and check for a
        // sidecar containing that UUID.
        let inputName = hlsInput.lastPathComponent
        let stripped = inputName.replacingOccurrences(of: ".macidm.hls-input.ts", with: "")
        guard stripped.count > 1 else { return false }
        let taskUUID = String(stripped.dropFirst())
        let suffix = ".macidm.hls"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return contents.contains { $0.hasSuffix(suffix) && $0.contains(taskUUID) }
    }

    func receive(_ progress: DownloadProgress, for id: UUID, execution generation: Int) {
        guard isCurrentExecution(id, generation) else { return }
        guard let current = task(with: id), current.status == .running else { return }

        // Buffer the progress and flush at most every 300 ms. Each flush
        // calls `update(id)` once, which triggers a single
        // `objectWillChange.send()` instead of one per callback. This
        // prevents the Table from re-rendering dozens of times per second
        // during active downloads, which caused UI lag and unresponsive
        // clicks — especially right after app launch when many tasks are
        // being restored and the Table is already expensive to render.
        let isCompleting = progress.totalBytes.map { progress.receivedBytes >= $0 } ?? false
        executions[id].pendingProgress = (generation, progress)

        if isCompleting {
            // Flush immediately when the download reaches 100% so the
            // status transitions to .verifying without delay.
            progressFlushTask?.cancel()
            progressFlushTask = nil
            flushPendingProgress()
            schedulePersistence(kind: .progress, immediate: false)
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressFlush)
        if elapsed >= 0.3 {
            // Enough time has passed — flush now.
            progressFlushTask?.cancel()
            progressFlushTask = nil
            flushPendingProgress()
            schedulePersistence(kind: .progress, immediate: false)
        } else if progressFlushTask == nil {
            // Schedule a flush for the remaining time.
            let delay = 0.3 - elapsed
            progressFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.progressFlushTask = nil
                self.flushPendingProgress()
                self.schedulePersistence(kind: .progress, immediate: false)
            }
        }
    }

    /// Flushes all pending progress updates in a single pass. Called by
    /// the throttle timer or immediately on completion.
    ///
    /// All progress changes are applied in a single `tasks` mutation so
    /// `objectWillChange` fires exactly once, regardless of how many
    /// tasks have pending progress. This prevents the Table from
    /// re-rendering N times per flush (which caused visible selection
    /// flicker when the user clicked a different row during an active
    /// download).
    private func flushPendingProgress() {
        let pendingProgress = executions.pendingProgress
        guard !pendingProgress.isEmpty else { return }
        lastProgressFlush = Date()
        let now = Date()

        // Phase 1: compute all progress values without touching `tasks`.
        struct ProgressPatch {
            let index: Int
            let receivedBytes: Int64
            let totalBytes: Int64?
            let overallFraction: Double?
            let shouldClearTotal: Bool
            let speed: Double
            let shouldAppendHistory: Bool
            let activeTransferSeconds: TimeInterval
            let segments: [SegmentSnapshot]
            let pairAudioLabels: Bool
            let shouldVerify: Bool
        }
        var patches: [ProgressPatch] = []
        patches.reserveCapacity(pendingProgress.count)

        for (id, pending) in pendingProgress {
            guard isCurrentExecution(id, pending.generation) else { continue }
            let progress = pending.progress
            guard let idx = tasks.firstIndex(where: { $0.id == id }),
                tasks[idx].status == .running
            else { continue }
            let current = tasks[idx]
            let sample = progressSamples[id] ?? (now, progress.receivedBytes)
            let elapsed = now.timeIntervalSince(sample.date)
            var speed: Double
            var shouldAppendHistory: Bool
            if let ytDlpSpeed = progress.speed, ytDlpSpeed > 0 {
                // yt-dlp reports an instantaneous per-line speed that jitters
                // wildly (the readout restarts on every progress line, and
                // buffering bursts spike it). A heavy exponential moving
                // average keeps the displayed speed, the history chart and
                // the derived remaining time calm without lagging real
                // changes for long.
                let previous = lastKnownSpeeds[id]
                speed = previous.map { $0 * 0.75 + ytDlpSpeed * 0.25 } ?? ytDlpSpeed
                progressSamples[id] = (now, progress.receivedBytes)
                shouldAppendHistory = true
            } else if elapsed >= 0.5 {
                speed = max(0, Double(progress.receivedBytes - sample.bytes) / elapsed)
                progressSamples[id] = (now, progress.receivedBytes)
                shouldAppendHistory = true
            } else {
                speed = current.bytesPerSecond
                shouldAppendHistory = false
            }
            // Between pipeline phases (yt-dlp download → FFmpeg remux) the
            // reported speed drops to zero while bytes already transferred;
            // hold the last measured value, but only while bytes are still
            // advancing — otherwise a genuinely stalled transfer would keep
            // showing a stale "live" speed next to a frozen progress bar.
            if speed > 0 {
                lastKnownSpeeds[id] = speed
            } else if progress.receivedBytes > current.receivedBytes,
                let last = lastKnownSpeeds[id]
            {
                speed = last
            }
            let segments = progress.segments.map(SegmentSnapshot.init)
            // Active-transfer accounting (product-spec §4.1 speed-column semantics):
            // seconds accumulate only while bytes actually advance AND the
            // engine kept reporting. A quiet gap above the threshold means
            // a stall, retry wait or post-transfer phase, so it is excluded
            // outright instead of being truncated into the denominator.
            // Continuous transfers flush far more often than the threshold;
            // pause/resume boundaries re-seed the accumulator instead.
            let accumulator =
                activeTransferAccumulators[id]
                ?? (now, progress.receivedBytes, current.activeTransferDuration)
            var activeSeconds = accumulator.seconds
            if progress.receivedBytes > accumulator.bytes {
                let gap = now.timeIntervalSince(accumulator.date)
                if gap > 0 && gap <= 1.5 {
                    activeSeconds += gap
                }
            }
            activeTransferAccumulators[id] = (
                now, max(accumulator.bytes, progress.receivedBytes), activeSeconds
            )
            let pairAudioLabels =
                transientPairAudioURLs[id] != nil && segments.count == 2
            // The transfer already reached its known total: anything still
            // reporting "speed" belongs to post-transfer work (yt-dlp remux,
            // ffprobe validation) or to a retry attempt re-reading bytes
            // that were already counted. Letting those values through
            // showed a terrifying live speed next to a 100% progress bar
            // that never settled. Pin the readout to zero and let the
            // speed chart decay to the baseline; the UI presents this
            // phase as "finishing"/"verifying" instead.
            let transferComplete =
                progress.totalBytes.map { progress.receivedBytes >= $0 && $0 > 0 } ?? false
            if transferComplete {
                speed = 0
                shouldAppendHistory = true
                lastKnownSpeeds[id] = nil
            }
            let shouldVerify =
                current.browserSubmissionType != "youtube.extractor"
                && (progress.totalBytes.map { progress.receivedBytes >= $0 } ?? false)
            // A stored total the transfer has already outgrown has been
            // proven wrong (a poisoned draft estimate, or a stale yt-dlp
            // figure from a stream that never reports a real total). Mark
            // it for clearing so the UI degrades to the byte counter
            // instead of rendering >100% progress.
            let shouldClearTotal =
                progress.totalBytes == nil
                && (current.totalBytes.map { progress.receivedBytes > $0 } ?? false)
            patches.append(
                ProgressPatch(
                    index: idx,
                    receivedBytes: progress.receivedBytes,
                    totalBytes: progress.totalBytes,
                    overallFraction: progress.overallFraction,
                    shouldClearTotal: shouldClearTotal,
                    speed: speed,
                    shouldAppendHistory: shouldAppendHistory,
                    activeTransferSeconds: activeSeconds,
                    segments: segments,
                    pairAudioLabels: pairAudioLabels,
                    shouldVerify: shouldVerify
                ))
        }
        executions.clearPendingProgress()

        guard !patches.isEmpty else { return }

        // Phase 2: apply all patches in a single `tasks` write. This
        // fires @Published's objectWillChange exactly once, producing a
        // single Table re-render instead of one per task.
        var updated = tasks
        for patch in patches {
            updated[patch.index].receivedBytes = patch.receivedBytes
            // A drastically corrected total (e.g. SABR's 1KiB side file
            // replaced by the real stream size) invalidates the stored
            // stage-aware fraction as well — drop it so the incoming sample
            // re-derives the bar instead of keeping the stale maximum.
            let totalDrasticallyCorrected: Bool = {
                guard let newTotal = patch.totalBytes,
                    let oldTotal = updated[patch.index].totalBytes
                else { return false }
                return Double(abs(newTotal - oldTotal)) > Double(max(newTotal, oldTotal)) * 0.5
            }()
            // Never blank out an already-known total: speed-only samples and
            // pre-resolve phases carry a nil total, and overwriting the draft
            // estimate with nil makes the size column flicker to "unknown".
            if let totalBytes = patch.totalBytes {
                updated[patch.index].totalBytes = totalBytes
            } else if patch.shouldClearTotal {
                updated[patch.index].totalBytes = nil
            }
            if let overallFraction = patch.overallFraction {
                // A resumed yt-dlp attempt can replay earlier samples. Keep
                // the visual fraction monotonic across both internal retries
                // and user-triggered resume operations.
                var baseline = updated[patch.index].overallProgressFraction ?? 0
                if totalDrasticallyCorrected {
                    baseline = 0
                }
                updated[patch.index].overallProgressFraction = max(
                    baseline,
                    min(0.999, max(0, overallFraction))
                )
            } else if updated[patch.index].browserSubmissionType != "youtube.extractor" {
                // yt-dlp may emit speed-only lines while a format's total is
                // still unknown. Those samples must not discard the last
                // stage-aware fraction and expose the raw byte ratio again.
                updated[patch.index].overallProgressFraction = nil
            }
            updated[patch.index].bytesPerSecond = patch.speed
            updated[patch.index].updatedAt = Date()
            updated[patch.index].activeTransferDuration = patch.activeTransferSeconds
            if patch.shouldAppendHistory {
                // Timestamped samples drive the real 120-second rolling
                // window; trimming is time-based, never index-based.
                updated[patch.index].speedHistory.append(
                    SpeedSample(timestamp: now, bytesPerSecond: patch.speed)
                )
                updated[patch.index].speedHistory = SpeedHistoryPolicy.trimmed(
                    updated[patch.index].speedHistory,
                    now: now
                )
            }
            updated[patch.index].segments = patch.segments
            if patch.pairAudioLabels {
                updated[patch.index].segments[0].label = "视频轨"
                updated[patch.index].segments[1].label = "音频轨"
            }
            if patch.shouldVerify {
                updated[patch.index].status = .verifying
                updated[patch.index].bytesPerSecond = 0
            }
        }
        tasks = updated
        // Push the fresh values into the per-cell live models. The task
        // table itself never re-renders for progress; only the affected
        // cells do (see TaskTableSynchronizer).
        for patch in patches {
            tableSynchronizer.updateLive(updated[patch.index])
        }
        scheduleStatusExport()
    }

    /// True unless a newer execution owns this task id (a stale engine
    /// callback racing a stuck-pause fallback plus a resume).
    private func isCurrentExecution(_ id: UUID, _ generation: Int?) -> Bool {
        guard let generation else { return true }
        return executions[id].generation == generation
    }

    func finish(_ id: UUID, result: DownloadResult, execution generation: Int? = nil) {
        guard isCurrentExecution(id, generation) else { return }
        autoRenameAttempts[id] = nil
        update(id) {
            $0.status = .completed
            $0.receivedBytes = result.byteCount
            $0.totalBytes = result.byteCount
            $0.overallProgressFraction = nil
            $0.bytesPerSecond = 0
            // The final engine flush may race the completion notification
            // through the progress throttle; settle the snapshot so the
            // detail panel never shows a finished task's segments as
            // partially downloaded.
            $0.settleSegmentProgress()
            // Record the parallelism the transfer actually used so the
            // detail panel can show reality (e.g. "serial" for a yt-dlp run)
            // instead of the configured maximum.
            $0.usedParallelRequests = result.usedParallelRequests
            $0.sha256 = result.sha256
            $0.verification = result.verification
            $0.errorCode = nil
            $0.errorMessage = nil
            $0.errorRecommendation = nil
            $0.errorCategory = nil
            let duration = Date().timeIntervalSince($0.startedAt ?? $0.createdAt)
            $0.totalDuration = duration
            // Average download speed = bytes ÷ accumulated active-transfer
            // seconds (excluding pauses, parsing, remux and verification; AI
            // handover doc §4.2). Legacy rows that never accumulated active
            // time fall back to the wall-clock basis instead of dividing by
            // zero.
            let activeSeconds =
                activeTransferAccumulators[id]?.seconds
                ?? $0.activeTransferDuration
            $0.averageSpeed =
                activeSeconds > 0
                ? Double(result.byteCount) / activeSeconds
                : (duration > 0 ? Double(result.byteCount) / duration : nil)
        }
        // Unified dual-channel path (AI handover doc §3.2): the ordinary log
        // records only structured fields such as the task ID and byte counts;
        // the title-derived filename stays in the private log only.
        let record = task(with: id)
        DownloadDiagnosticEventLog.shared.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "task.completed",
                stage: "completion",
                taskID: id.uuidString,
                backend: record?.browserSubmissionType == "youtube.extractor"
                    ? "youtubeExtractor" : "native",
                sourceKind: record?.sourceKind?.rawValue,
                host: record.flatMap { URLComponents(string: $0.sourceURL)?.host },
                errorCode: nil,
                byteCount: result.byteCount,
                correlationID: nil,
                urlExactFingerprint: nil,
                titleFingerprint: record.map { DiagnosticFingerprint.title($0.filename) } ?? nil,
                errorSummary: nil,
                fullURL: nil,
                filename: record?.filename,
                destinationPath: record?.destinationPath,
                fullErrorDescription: nil
            ))
        // Archive the site session of a successful authenticated download
        // so future manually-added URLs for the same domain can reuse the
        // login state — "log in once in Chrome, downloads keep working".
        if settings.rememberSiteSessions,
            let context = transientRequestContexts[id]?.value,
            let cookie = context.cookie, !cookie.isEmpty,
            let record = task(with: id),
            let sourceURL = URL(string: record.sourceURL) ?? transientSourceURLs[id]
        {
            // The full URL is passed so the store can bind the session to its
            // https origin; an http source is refused and simply not archived.
            sessionStore.store(url: sourceURL, cookie: cookie, userAgent: context.userAgent)
        }
        cleanUpExecution(id)
    }

    func finish(_ id: UUID, error: Error, execution generation: Int? = nil) {
        guard isCurrentExecution(id, generation) else { return }
        if pendingRemovals.contains(id) {
            update(id) {
                $0.status = .cancelled
                $0.bytesPerSecond = 0
            }
            cleanUpExecution(id)
            return
        }

        // Filename conflicts are recoverable: append a " (N)" suffix to the
        // destination and re-queue instead of parking the task in the manual
        // conflict state. The engine publishes exclusively and never
        // overwrites, so this only ever changes our own target name.
        if isFilenameConflictError(error), autoRenameConflictedDestination(id) {
            cleanUpExecution(id)
            return
        }
        // Failure-path dual channel (AI handover doc §3.2): the ordinary log
        // keeps only the sanitized error summary and fingerprint; the
        // title-derived filename, full path and full error description go to
        // the private log only.
        let failedRecord = task(with: id)
        DownloadDiagnosticEventLog.recordFailure(
            event: "task.failed",
            stage: "completion",
            taskID: id,
            backend: failedRecord?.browserSubmissionType == "youtube.extractor"
                ? "youtubeExtractor" : "native",
            sourceKind: failedRecord?.sourceKind?.rawValue,
            url: failedRecord.flatMap { URL(string: $0.sourceURL) },
            destination: failedRecord.map { URL(fileURLWithPath: $0.destinationPath) },
            error: error
        )
        // Produce one structured diagnosis for every failure type so the
        // detail panel shows a precise category and an actionable next
        // step instead of a raw message.
        let diagnosis = diagnoseFailure(error, for: id)
        // Authentication-class failures drive the session lifecycle: flag
        // the stored session as expired and guide the user to refresh it.
        if diagnosis?.category == .authentication,
            let task = task(with: id),
            let sourceURL = URL(string: task.sourceURL),
            let host = sourceURL.host
        {
            let hadStoredSession = sessionStore.lookup(url: sourceURL) != nil
            sessionStore.markAuthFailed(domain: host)
            enqueueSessionAlert(domain: host, expired: hadStoredSession, taskID: id)
        }
        update(id) {
            $0.bytesPerSecond = 0
            $0.errorRecommendation = diagnosis?.recommendation
            $0.errorCategory = diagnosis?.category.rawValue
            if let engineError = error as? IDMError {
                let friendly = ErrorPresentation.describe(engineError)
                $0.errorCode = engineError.code
                $0.errorMessage = friendly.message
                switch engineError {
                case .paused:
                    $0.status = .paused
                    // A user pause is a control action, not a failure: keep
                    // the detail panel's error area empty for it instead of
                    // showing a "PAUSED / task paused" card.
                    $0.errorCode = nil
                    $0.errorMessage = nil
                case .cancelled:
                    $0.status = .cancelled
                    $0.errorCode = nil
                    $0.errorMessage = nil
                case .filenameConflict:
                    $0.status = .filenameConflict
                case .pathNotWritable, .storageError:
                    $0.status = .storageError
                case .resourceChanged, .sidecarCorrupt:
                    $0.status = .needsRestart
                default:
                    $0.status = .failed
                }
            } else if let ffmpegError = error as? FFmpegError {
                $0.status = .failed
                $0.errorCode = ffmpegError.code
                $0.errorMessage = ffmpegError.localizedDescription
                if ffmpegError == .cancelled {
                    $0.status = .cancelled
                }
            } else if let youtubeError = error as? YouTubeDownloadError {
                $0.status = .failed
                $0.errorCode = youtubeError.code
                $0.errorMessage = youtubeError.localizedDescription
            } else {
                $0.status = .failed
                $0.errorCode = "NETWORK_ERROR"
                $0.errorMessage = ErrorPresentation.describe(error).message
            }
        }
        // After setting the task error state, check whether a yt-dlp
        // update might fix a YouTube download failure. Two-stage guard:
        // 1) Synchronous: look for YouTube protocol-change signatures in
        //    the process output — those strongly suggest an update helps.
        // 2) Async: if no specific signature matched, compare the installed
        //    version against the latest GitHub release. Only recommend an
        //    update when the binary is actually outdated, avoiding the
        //    frustrating "update → same version → still broken" loop.
        if let youtubeError = error as? YouTubeDownloadError {
            let processOutput = YouTubeDownloadError.lastProcessOutput
            if let reason = YTDlpManager.shouldRecommendUpdate(
                errorCode: youtubeError.code,
                errorMessage: youtubeError.localizedDescription,
                processOutput: processOutput
            ) {
                let currentVersion = YTDlpManager.currentVersionSync()
                ytdlpManager.alert = .updateRecommended(
                    currentVersion: currentVersion,
                    reason: reason
                )
            } else if youtubeError.code == "YTDLP_PROCESS_FAILED" {
                // Only the unclassified bucket warrants an async version
                // check; every precisely-classified failure (site policy,
                // network, auth, toolchain) has its own remedy and an
                // update suggestion would be noise.
                Task { [weak self] in
                    guard let self else { return }
                    if let reason = await YTDlpManager.outdatedUpdateReason() {
                        let currentVersion = YTDlpManager.currentVersionSync()
                        self.ytdlpManager.alert = .updateRecommended(
                            currentVersion: currentVersion,
                            reason: reason
                        )
                    }
                }
            }
        }
        YouTubeDownloadError.lastProcessOutput = nil
        cleanUpExecution(id)
    }

    /// Builds a structured diagnosis for a failed task. Returns nil for
    /// non-failures (pause/cancel) so no recommendation is stored.
    func diagnoseFailure(_ error: Error, for id: UUID) -> ErrorDiagnosis? {
        if let engineError = error as? IDMError {
            switch engineError {
            case .paused, .cancelled: return nil
            default: break
            }
        }
        let record = task(with: id)
        let domain = record.flatMap { URLComponents(string: $0.sourceURL)?.host }
        let context = DownloadErrorAnalyzer.Context(
            domain: domain,
            sourceKind: record?.sourceKind,
            proxyEnabled: settings.proxyEnabled,
            processOutput: YouTubeDownloadError.lastProcessOutput
        )
        return DownloadErrorAnalyzer.diagnose(error: error, context: context)
    }

    func cleanUpExecution(_ id: UUID) {
        executions[id].transitionToken = nil
        executions[id].task = nil
        // Bump (not remove) so generation numbers are never reused: start()
        // counts from the existing value, so a stranded callback from any
        // prior execution can never match the current one.
        executions[id].generation += 1
        executions[id].control = nil
        progressSamples[id] = nil
        activeTransferAccumulators[id] = nil
        lastKnownSpeeds[id] = nil
        executions[id].pendingProgress = nil
        settleStopOnEmptyQueues(for: id)
        checkCompletionActionAfterSettle()
        if let status = task(with: id)?.status {
            if status.isTerminal {
                transientPairAudioURLs[id] = nil
                transientPairCIDs[id] = nil
                transientRequestContexts[id] = nil
                // Completed/cancelled tasks can never resume; failed tasks
                // keep the unredacted original link so a retry within the same
                // session can reuse it (consistent with the Vault's retention
                // policy for failed tasks; otherwise the retry would run the
                // redacted URL, e.g. a YouTube link missing its v=).
                if status == .completed || status == .cancelled {
                    transientSourceURLs[id] = nil
                }
            }
            // Completed and cancelled tasks can never resume, so their
            // unredacted URL should not linger in the vault until TTL.
            // Failed tasks keep theirs so a later retry (even after a
            // restart) can reuse the original link.
            if status == .completed || status == .cancelled {
                sourceURLVault.remove(ids: [id])
            }
        }
        tryPersistOrPresentError()
        scheduleQueuedTasks()
    }

    /// Both the engine's preflight/exclusive-publish check and FFmpeg's
    /// remux/merge output guard surface "the final name is already taken"
    /// through these two error cases.
    private func isFilenameConflictError(_ error: Error) -> Bool {
        if let engineError = error as? IDMError, case .filenameConflict = engineError {
            return true
        }
        return error as? FFmpegError == .outputAlreadyExists
    }

    /// Resolves a filename conflict by picking the next free `name (N).ext`
    /// candidate (checked against both files on disk and reserved task
    /// destinations) and re-queueing the task. Returns false when no rename
    /// is possible, leaving the caller to surface the manual conflict state.
    private func autoRenameConflictedDestination(_ id: UUID) -> Bool {
        guard let task = task(with: id), !task.isCLIManaged,
            autoRenameAttempts[id, default: 0] < AppModel.maximumAutoRenameAttempts
        else { return false }
        let current = URL(fileURLWithPath: task.destinationPath).standardizedFileURL
        guard let renamed = try? availableDestination(for: current, automaticRename: true),
            renamed != current
        else { return false }
        autoRenameAttempts[id, default: 0] += 1
        // Filenames are often derived from video titles (AI handover doc
        // §3.2): the ordinary log keeps only the task ID and fingerprint; the
        // old and new filenames stay in the private log under the same
        // event id.
        DownloadDiagnosticEventLog.shared.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "download.filenameRenamed",
                stage: "download",
                taskID: id.uuidString,
                backend: nil,
                sourceKind: nil,
                host: nil,
                errorCode: nil,
                byteCount: nil,
                correlationID: nil,
                urlExactFingerprint: nil,
                titleFingerprint: DiagnosticFingerprint.title(renamed.lastPathComponent),
                errorSummary: nil,
                fullURL: nil,
                filename: "\(current.lastPathComponent) → \(renamed.lastPathComponent)",
                destinationPath: renamed.path,
                fullErrorDescription: nil
            ))
        update(id) {
            $0.destinationPath = renamed.path
            $0.status = .queued
            $0.errorCode = nil
            $0.errorMessage = nil
        }
        return true
    }

    /// Re-resolves a site-adapter (Bilibili) DASH-pair task to fresh signed
    /// track URLs after a restart, when its transient pair URLs are gone.
    /// Returns nil when re-resolution is not needed (in-session resume already
    /// has the pair URL, or the task is not a supported site-adapter page);
    /// throws the adapter error when the page can no longer be resolved, so the
    /// caller surfaces a meaningful login/site-policy failure.
    ///
    /// The signed track URLs stay transient: they are re-derived here and kept
    /// in memory only. The login cookie is restored from SessionStore (page
    /// origin); without it the adapter resolves as a guest and the exact track
    /// may be unavailable, in which case resume fails explicitly.
    func reresolveSiteAdapterPair(
        id: UUID,
        record: AppTask
    ) async throws -> DownloadRequest? {
        guard record.sourceKind == .dash,
            transientPairAudioURLs[id] == nil,
            let pageURLString = record.pageURL,
            let pageURL = URL(string: pageURLString),
            BilibiliPlayurlAdapter.supports(pageURL)
        else { return nil }
        // Restore the archived page-origin login cookie (best effort). The
        // adapter fills the CDN referer/UA fallback for the track requests.
        let restoredContext: DownloadRequestContext?
        if let stored = sessionStore.lookup(url: pageURL),
            let cookie = sessionStore.cookieHeader(for: stored)
        {
            restoredContext = DownloadRequestContext(
                cookie: cookie,
                referer: pageURL.absoluteString,
                userAgent: stored.userAgent
            )
        } else {
            restoredContext = DownloadRequestContext(
                cookie: nil,
                referer: pageURL.absoluteString,
                userAgent: nil
            )
        }
        let option = try await SiteMediaResumeResolver(adapter: bilibiliAdapter).resolve(
            record: record, pageURL: pageURL, context: restoredContext)
        try Task.checkCancellation()
        let resolvedContext =
            option.requestContext
            ?? restoredContext
            ?? DownloadRequestContext(
                cookie: nil, referer: pageURL.absoluteString, userAgent: nil)
        transientSourceURLs[id] = option.videoURL
        transientPairAudioURLs[id] = option.audioURL
        if let cid = record.mediaCID { transientPairCIDs[id] = cid }
        transientRequestContexts[id] = TransientRequestContext(
            value: resolvedContext,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        )
        return DownloadRequest(
            url: option.videoURL,
            destination: URL(fileURLWithPath: record.destinationPath),
            sourceKind: .dash,
            maximumParallelRequests: record.maximumParallelRequests,
            expectedSHA256: nil,
            taskID: id,
            requestContext: resolvedContext,
            rateLimiter: sharedRateLimiter,
            pairAudioURL: option.audioURL,
            pairCID: record.mediaCID,
            backend: .native
        )
    }

    func requiresBrowserRefetch(_ task: AppTask) -> Bool {
        guard task.errorCode == "NEEDS_REFETCH" else { return false }
        if task.sourceKind == .hls,
            existingHLSInputResult(at: hlsInputURL(for: task)) != nil
        {
            // A complete raw HLS input is an independent recovery boundary;
            // it can be remuxed without reusing the redacted browser URL.
            return false
        }
        // A site-adapter (Bilibili) DASH pair is re-resolvable from its
        // persisted page URL, so a stale NEEDS_REFETCH marker (e.g. left by an
        // earlier app version that force-failed pairs) must not block resume.
        if Self.isTransientDASHPair(task),
            let pageURL = task.pageURL.flatMap(URL.init(string:)),
            BilibiliPlayurlAdapter.supports(pageURL)
        {
            return false
        }
        return true
    }
}
