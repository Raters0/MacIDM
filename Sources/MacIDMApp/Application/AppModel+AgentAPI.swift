import Foundation
import IDMEngine

/// Local control surface for external tools and AI agents.
///
/// Commands arrive over `MonitorHTTPServer` (localhost-only HTTP) and are
/// mapped onto the same task-lifecycle primitives the UI uses: adding
/// downloads, pausing, resuming, cancelling, removing, and reading or
/// adjusting a bounded subset of settings.
extension AppModel {

    func handleAgentCommand(
        _ command: MonitorHTTPServer.AgentCommand
    ) async -> MonitorHTTPServer.AgentResponse {
        switch command {
        case .addDownload(let url, let filename, let directory, let start, let parallel):
            return await agentAddDownload(
                urlString: url,
                filename: filename,
                directory: directory,
                start: start,
                parallel: parallel
            )
        case .pauseTask(let id):
            return agentTaskAction(id: id, action: "pause")
        case .resumeTask(let id):
            return agentTaskAction(id: id, action: "resume")
        case .cancelTask(let id):
            return agentTaskAction(id: id, action: "cancel")
        case .removeTask(let id, let deleteFile):
            return agentRemoveTask(id: id, deleteFile: deleteFile)
        case .getSettings:
            return MonitorHTTPServer.AgentResponse(
                ok: true,
                message: nil,
                taskID: nil,
                destination: nil,
                task: nil,
                settings: settingsSnapshot()
            )
        case .updateSettings(let body):
            return agentUpdateSettings(body: body)
        }
    }

    // MARK: - Add download

    private func agentAddDownload(
        urlString: String,
        filename: String?,
        directory: String?,
        start: Bool?,
        parallel: Int?
    ) async -> MonitorHTTPServer.AgentResponse {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return failure(String(localized: "无效的下载 URL（仅支持 http/https）"))
        }

        // YouTube page URLs must go through the yt-dlp extractor backend;
        // the native HTTP engine would only fetch the HTML shell.
        let isYouTubePage = Self.isYouTubePageURL(url)
        let backend: DownloadBackend = isYouTubePage ? .youtubeExtractor : .native

        let sourceKind = sourceKindForURL(url)
        let resolvedFilename: String
        if let filename, !filename.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedFilename = InputValidator.safeFilename(filename)
        } else if isYouTubePage {
            // No browser page title exists on this path; ask yt-dlp for the
            // real video title so the finished file has a meaningful name.
            let title = await YouTubeMediaInspector().fetchTitle(url: url)
            let stem = title?.isEmpty == false ? title! : String(localized: "YouTube 视频")
            resolvedFilename = InputValidator.safeFilename(stem + ".mp4")
        } else {
            // Probe before naming: CDN paths are often opaque segments
            // ("/seg/7f3a9b21") that make meaningless filenames, while the
            // server usually provides the real name via Content-Disposition.
            // Mirror the browser-takeover path and let the probed resource
            // info win; fall back to URL-derived naming when probing fails.
            var probedName: String?
            if sourceKind == .http {
                let probeRequest = DownloadRequest(
                    url: url,
                    destination: URL(
                        fileURLWithPath: settings.downloadDirectory, isDirectory: true
                    )
                    .appendingPathComponent("download"),
                    maximumParallelRequests: settings.maximumParallelRequests
                )
                if let info = try? await browserProbe(probeRequest) {
                    probedName = DownloadNaming.suggestedFilename(
                        url: info.finalURL,
                        sourceKind: sourceKind,
                        filenameHint: nil,
                        pageTitle: nil,
                        resourceInfo: info
                    )
                }
            }
            resolvedFilename =
                probedName
                ?? DownloadNaming.suggestedFilename(
                    url: url,
                    sourceKind: sourceKind,
                    filenameHint: nil,
                    pageTitle: nil,
                    resourceInfo: nil
                )
        }

        let directoryPath =
            directory?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? directory!.trimmingCharacters(in: .whitespaces)
            : settings.downloadDirectory
        let destination = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent(resolvedFilename)

        let parallelRequests =
            parallel.map { value in
                min(32, max(1, value))
            } ?? settings.maximumParallelRequests
        let startImmediately = start ?? settings.autoStartDownloads

        do {
            try addDownload(
                urlString: trimmed,
                destination: destination,
                maximumParallelRequests: parallelRequests,
                expectedSHA256: nil,
                startImmediately: startImmediately,
                sourceKind: sourceKind,
                automaticRename: true,
                backend: backend
            )
        } catch {
            return failure(String(localized: "新增下载失败：\(error.localizedDescription)"))
        }

        // addDownload inserts the new task at the front of the list.
        guard let created = tasks.first else {
            return failure(String(localized: "任务创建后未找到对应记录"))
        }
        return MonitorHTTPServer.AgentResponse(
            ok: true,
            message: startImmediately
                ? String(localized: "已开始下载")
                : String(localized: "已加入队列（暂停状态）"),
            taskID: created.id.uuidString,
            destination: created.destinationPath,
            task: taskSnapshot(created, formatter: ISO8601DateFormatter()),
            settings: nil
        )
    }

    // MARK: - Task lifecycle

    private func agentTaskAction(
        id: String,
        action: String
    ) -> MonitorHTTPServer.AgentResponse {
        guard let taskID = UUID(uuidString: id), let target = task(with: taskID) else {
            return failure(String(localized: "未找到任务 \(id)"))
        }
        // Lifecycle functions silently skip CLI-managed tasks; report the
        // reason instead of pretending the action was executed.
        guard !target.isCLIManaged else {
            return failure(String(localized: "该任务由 CLI 管理，请在 CLI 中执行 \(action) 操作"))
        }
        switch action {
        case "pause": pause(taskID)
        case "resume": resume(taskID)
        case "cancel": cancel(taskID)
        default: return failure(String(localized: "未知操作 \(action)"))
        }
        tryPersistOrPresentError()
        exportStatus()
        // Re-read the task after the action so agents observe the new
        // status instead of a pre-action snapshot.
        let updated = task(with: taskID) ?? target
        return MonitorHTTPServer.AgentResponse(
            ok: true,
            message: String(localized: "\(action) 已执行"),
            taskID: id,
            destination: nil,
            task: taskSnapshot(updated, formatter: ISO8601DateFormatter()),
            settings: nil
        )
    }

    private func agentRemoveTask(
        id: String,
        deleteFile: Bool
    ) -> MonitorHTTPServer.AgentResponse {
        guard let taskID = UUID(uuidString: id), let task = task(with: taskID) else {
            return failure(String(localized: "未找到任务 \(id)"))
        }
        // remove() silently skips CLI-managed and active tasks; report the
        // reason instead of pretending the record was deleted.
        guard !task.isCLIManaged else {
            return failure(
                String(
                    localized:
                        "该任务由 CLI 管理，请使用 macidm remove \(taskID.uuidString.lowercased()) 删除"
                )
            )
        }
        guard !task.status.isActive else {
            return failure(String(localized: "任务仍在运行，请先取消任务再删除"))
        }
        remove(taskID, deletingFile: deleteFile)
        exportStatus()
        return MonitorHTTPServer.AgentResponse(
            ok: true,
            message: deleteFile
                ? String(localized: "记录与文件已删除")
                : String(localized: "记录已删除"),
            taskID: id,
            destination: nil,
            task: nil,
            settings: nil
        )
    }

    // MARK: - Settings

    func settingsSnapshot() -> MonitorHTTPServer.SettingsSnapshot {
        MonitorHTTPServer.SettingsSnapshot(
            downloadDirectory: settings.downloadDirectory,
            maximumParallelRequests: settings.maximumParallelRequests,
            simultaneousDownloads: settings.simultaneousDownloads,
            speedLimitKBps: settings.speedLimitKBps,
            autoStartDownloads: settings.autoStartDownloads,
            organizeByCategory: settings.organizeByCategory,
            archiveOnDelete: settings.archiveOnDelete,
            notificationSoundsEnabled: settings.notificationSoundsEnabled,
            clipboardAutoDetect: settings.clipboardAutoDetect,
            ytdlpAutoCheckUpdates: settings.ytdlpAutoCheckUpdates,
            colorScheme: settings.colorScheme.rawValue
        )
    }

    private func agentUpdateSettings(body: Data) -> MonitorHTTPServer.AgentResponse {
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else {
            return failure(String(localized: "settings 请求体必须是 JSON 对象"))
        }

        var applied: [String] = []
        if let value = payload["downloadDirectory"] as? String,
            !value.trimmingCharacters(in: .whitespaces).isEmpty
        {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory)
            guard exists && isDirectory.boolValue else {
                return failure(String(localized: "downloadDirectory 不是已存在的目录：\(trimmed)"))
            }
            settings.downloadDirectory = trimmed
            applied.append("downloadDirectory")
        }
        if let value = payload["maximumParallelRequests"] as? NSNumber {
            settings.maximumParallelRequests = value.intValue
            applied.append("maximumParallelRequests")
        }
        if let value = payload["simultaneousDownloads"] as? NSNumber {
            settings.simultaneousDownloads = value.intValue
            applied.append("simultaneousDownloads")
        }
        if let value = payload["speedLimitKBps"] as? NSNumber {
            settings.speedLimitKBps = value.intValue
            rebuildSharedRateLimiter()
            applied.append("speedLimitKBps")
        }
        if let value = payload["autoStartDownloads"] as? Bool {
            settings.autoStartDownloads = value
            applied.append("autoStartDownloads")
        }
        if let value = payload["organizeByCategory"] as? Bool {
            settings.organizeByCategory = value
            applied.append("organizeByCategory")
        }
        if let value = payload["archiveOnDelete"] as? Bool {
            settings.archiveOnDelete = value
            applied.append("archiveOnDelete")
        }
        if let value = payload["notificationSoundsEnabled"] as? Bool {
            settings.notificationSoundsEnabled = value
            applied.append("notificationSoundsEnabled")
        }
        if let value = payload["clipboardAutoDetect"] as? Bool {
            settings.clipboardAutoDetect = value
            applied.append("clipboardAutoDetect")
        }
        if let value = payload["ytdlpAutoCheckUpdates"] as? Bool {
            settings.ytdlpAutoCheckUpdates = value
            applied.append("ytdlpAutoCheckUpdates")
        }
        if let value = payload["mediaInFlightRequests"] as? NSNumber {
            settings.mediaInFlightRequests = value.intValue
            applied.append("mediaInFlightRequests")
        }

        guard !applied.isEmpty else {
            return failure(String(localized: "请求体中没有可识别的设置项"))
        }
        return MonitorHTTPServer.AgentResponse(
            ok: true,
            message: String(localized: "已更新：\(applied.joined(separator: ", "))"),
            taskID: nil,
            destination: nil,
            task: nil,
            settings: settingsSnapshot()
        )
    }

    // MARK: - Helpers

    private func failure(_ message: String) -> MonitorHTTPServer.AgentResponse {
        MonitorHTTPServer.AgentResponse(
            ok: false,
            message: message,
            taskID: nil,
            destination: nil,
            task: nil,
            settings: nil
        )
    }
}
