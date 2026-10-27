import Foundation
import IDMEngine

extension AppModel {
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
        // 带音轨的提交合法形态：.dash（Bilibili m4s 直链 pair）与 .hls
        // （EXT-X-MEDIA 音频组，输入是媒体清单，HLS pair 执行器负责下载
        // + 合并）。其余 sourceKind 与音轨互斥。
        if pairAudioURL != nil, sourceKind != .dash, sourceKind != .hls {
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
        if let takeoverRecord {
            // A browser takeover is acknowledged to the extension, which then
            // cancels the browser's own download: persist first and roll back
            // on failure, so the download is never lost on both sides.
            do {
                try persistBrowserTakeovers()
                try persist()
            } catch {
                browserTakeovers.removeAll { $0.taskID == task.id }
                takeoverStore.release(path: takeoverRecord.reservationPath)
                try? persistBrowserTakeovers()
                tasks.removeAll { $0.id == task.id }
                transientSourceURLs[task.id] = nil
                transientPairAudioURLs[task.id] = nil
                transientPairCIDs[task.id] = nil
                transientRequestContexts[task.id] = nil
                sourceURLVault.remove(ids: [task.id])
                selectedTaskIDs.remove(task.id)
                tableSynchronizer.applyExternalSelection(selectedTaskIDs)
                if selectedTaskID == task.id { selectedTaskID = nil }
                tableSynchronizer.replaceAllLive(tasks)
                throw error
            }
        } else {
            // A manual add has no external party waiting on the write: it
            // rides the debounced async channel, and a failed write surfaces
            // the "无法保存任务状态" banner instead of blocking on disk I/O.
            tryPersistOrPresentError(immediate: true)
        }
        if startImmediately {
            scheduleQueuedTasks()
        }
    }
}
