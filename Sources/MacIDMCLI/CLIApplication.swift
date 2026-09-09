import Foundation
import IDMEngine

enum CLIApplication {
    static func execute(_ arguments: CLIArguments) async throws -> Int32 {
        switch arguments.command {
        case .inspect(let urlString, let mediaKindHint):
            return try await runInspect(
                urlString: urlString,
                mediaKindHint: mediaKindHint,
                json: arguments.json
            )

        case .add(let urlString, let output, let parallel, let hash, let foreground):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard let url = URL(string: urlString) else { throw IDMError.invalidURL }
            if CLIURLSafety.hasTransientMaterial(url), !foreground {
                throw CLIError.usage(
                    "带签名参数的 URL 不会写入磁盘；请使用 --foreground，或先去除 URL 查询参数。"
                )
            }
            let destination = output ?? defaultDestination(for: url)
            let id = UUID()
            let record = StoredTask(
                id: id,
                url: url.absoluteString,
                destination: destination.standardizedFileURL.path,
                parallelRequests: parallel,
                expectedSHA256: hash,
                createdAt: Date(),
                updatedAt: Date(),
                status: .queued,
                desiredAction: .run,
                receivedBytes: 0,
                totalBytes: nil,
                sha256: nil,
                errorCode: nil,
                errorMessage: nil,
                workerPID: nil
            )
            try store.create(record)
            if foreground, CLIURLSafety.hasTransientMaterial(url) {
                store.rememberTransientURL(url, for: id)
            }
            if foreground {
                try await CLIWorker.run(id: id, store: store)
            } else {
                try CLIWorker.launch(id: id, arguments: arguments)
            }
            CLIOutput.emitTask(try requireTask(id, store: store), json: arguments.json)
            return 0

        case .status(let id):
            let store = try TaskStore(directory: arguments.stateDirectory)
            if let id {
                CLIOutput.emitTask(try requireTask(id, store: store), json: arguments.json)
            } else {
                let tasks = try store.list()
                if arguments.json {
                    CLIOutput.emitJSON(tasks.map(CLIOutput.taskDictionary))
                } else if tasks.isEmpty {
                    print("No downloads.")
                } else {
                    for task in tasks {
                        print(CLIOutput.taskLine(task))
                    }
                }
            }
            return 0

        case .pause(let id):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard store.hasLocalRecord(id) else {
                throw CLIError.usage("该任务由 MacIDM App 管理，请在 App 中暂停。")
            }
            let task = try requireTask(id, store: store)
            // Pausing a terminal or already-settling task silently flipped
            // failed tasks into "paused" (the de-facto retry path). Pause is
            // for active work only; failed tasks retry via resume directly.
            let pauseBlocked: Set<StoredStatus> = [
                .completed, .cancelled, .paused, .failed,
                .storageError, .filenameConflict, .needsRestart, .cancelling,
            ]
            if !pauseBlocked.contains(task.status) {
                _ = try store.mutate(id) {
                    $0.desiredAction = .pause
                    $0.status = CLIWorker.isAlive($0.workerPID) ? .pausing : .paused
                    if $0.status == .paused {
                        $0.workerPID = nil
                    }
                }
            } else if [.failed, .storageError, .filenameConflict, .needsRestart].contains(task.status) {
                throw CLIError.usage("任务已结束（\(task.status.rawValue)），pause 不适用；如需重试请使用 resume。")
            }
            CLIOutput.emitTask(try requireTask(id, store: store), json: arguments.json)
            return 0

        case .resume(let id):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard store.hasLocalRecord(id) else {
                throw CLIError.usage("该任务由 MacIDM App 管理，请在 App 中继续。")
            }
            let task = try requireTask(id, store: store)
            guard task.errorCode != "NEEDS_REFETCH" else {
                throw CLIError.usage("该任务的签名地址未持久化，请重新使用原始 URL 提交。")
            }
            let needsWorker =
                !CLIWorker.isAlive(task.workerPID)
                && task.status != .completed
                && task.status != .cancelled
            if needsWorker {
                _ = try store.mutate(id) {
                    $0.desiredAction = .run
                    $0.status = .queued
                    $0.workerPID = nil
                }
                try CLIWorker.launch(id: id, arguments: arguments)
            }
            CLIOutput.emitTask(try requireTask(id, store: store), json: arguments.json)
            return 0

        case .cancel(let id):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard store.hasLocalRecord(id) else {
                throw CLIError.usage("该任务由 MacIDM App 管理，请在 App 中取消。")
            }
            let task = try requireTask(id, store: store)
            if task.status != .completed && task.status != .cancelled {
                _ = try store.mutate(id) {
                    $0.desiredAction = .cancel
                    $0.status = .cancelling
                }
                if task.workerPID == nil {
                    _ = try store.mutate(id) {
                        $0.status = .cancelled
                        $0.workerPID = nil
                    }
                }
            }
            CLIOutput.emitTask(try requireTask(id, store: store), json: arguments.json)
            return 0

        case .remove(let id, let deleteFile):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard store.hasLocalRecord(id) else {
                throw CLIError.usage("该任务由 MacIDM App 管理，请在 App 中删除。")
            }
            let task = try requireTask(id, store: store)
            guard [.completed, .cancelled, .failed, .storageError].contains(task.status) else {
                throw CLIError.usage("任务尚未结束，请先取消或暂停后再删除。")
            }
            guard !CLIWorker.isAlive(task.workerPID) else {
                throw CLIError.usage("任务的 worker 进程仍在运行，请先取消任务。")
            }
            try store.remove(id, deleteFile: deleteFile)
            print("已删除任务 \(id.uuidString.lowercased())")
            return 0

        case .run(let id):
            let store = try TaskStore(directory: arguments.stateDirectory)
            guard store.hasLocalRecord(id) else {
                throw CLIError.usage("该任务由 MacIDM App 管理，请在 App 中继续。")
            }
            guard let task = try store.load(id) else {
                throw CLIError.taskNotFound
            }
            guard task.errorCode != "NEEDS_REFETCH" else {
                throw CLIError.usage("该任务的签名地址未持久化，请重新使用原始 URL 提交。")
            }
            do {
                try await CLIWorker.run(id: id, store: store)
            } catch WorkerClaimError.alreadyRunning, WorkerClaimError.terminal {
                return 0
            }
            return 0

        case .watch(let interval):
            return CLIWatch.run(interval: interval)

        case .logs(let follow, let lines):
            return CLILogs.run(follow: follow, lines: lines)

        case .appStatus:
            return CLIAppStatus.run(json: arguments.json)

        case .help:
            print(CLIArguments.usage)
            return 0
        }
    }

    private static func requireTask(_ id: UUID, store: TaskStore) throws -> StoredTask {
        guard let task = try store.load(id) else { throw CLIError.taskNotFound }
        return task
    }

    private static func defaultDestination(for url: URL) -> URL {
        let raw = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = InputValidator.safeFilename(raw)
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
    }

    // MARK: - Inspect

    private static func runInspect(
        urlString: String,
        mediaKindHint: String?,
        json: Bool
    ) async throws -> Int32 {
        guard let url = URL(string: urlString) else { throw IDMError.invalidURL }
        let mediaKind = mediaKindHint ?? autoDetectMediaKind(url)

        let inspection: MediaInspection
        do {
            switch mediaKind {
            case "hls":
                let inspector = HLSMediaInspector()
                inspection = try await inspector.inspect(
                    url: url, requestContext: nil, mediaKind: .hls)
            case "dash":
                let inspector = DASHMediaInspector()
                inspection = try await inspector.inspect(
                    url: url, requestContext: nil, mediaKind: .dash)
            case "youtube":
                inspection = try await inspectYouTube(url: url)
            case "http":
                inspection = try await inspectHTTP(url: url)
            default:
                throw CLIError.usage("--media-kind must be one of: hls, dash, youtube, http")
            }
        } catch let error as MediaInspectionError {
            if json {
                CLIOutput.emitJSON([
                    "ok": false,
                    "error": error.errorDescription ?? "Unknown error",
                ])
            } else {
                print("解析失败：\(error.errorDescription ?? "Unknown error")")
            }
            return 1
        }

        if json {
            let variantsArray: [[String: Any]] = inspection.variants.map { variant in
                var dict: [String: Any] = [
                    "url": variant.url.absoluteString,
                    "label": variant.label,
                ]
                if let bandwidth = variant.bandwidth { dict["bandwidth"] = bandwidth }
                if let width = variant.width { dict["width"] = width }
                if let height = variant.height { dict["height"] = height }
                if let codecs = variant.codecs { dict["codecs"] = codecs }
                if let size = variant.estimatedSize { dict["estimatedSize"] = size }
                if let duration = variant.duration { dict["duration"] = duration }
                return dict
            }
            CLIOutput.emitJSON([
                "ok": true,
                "mediaKind": mediaKind,
                "variants": variantsArray,
            ])
        } else {
            print("媒体类型：\(mediaKind.uppercased())")
            print("可用画质（\(inspection.variants.count) 项）：")
            for (index, variant) in inspection.variants.enumerated() {
                print("  \(index + 1). \(variant.label)")
                if variant.estimatedSize != nil || variant.duration != nil {
                    var extras: [String] = []
                    if let size = variant.estimatedSize {
                        extras.append(formatBytes(size))
                    }
                    if let duration = variant.duration {
                        extras.append(formatDuration(duration))
                    }
                    print("     \(extras.joined(separator: " · "))")
                }
            }
        }
        return 0
    }

    private static func autoDetectMediaKind(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.contains("youtube.com") || host == "youtu.be" {
            return "youtube"
        }
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") {
            return "hls"
        }
        if path.hasSuffix(".mpd") {
            return "dash"
        }
        return "http"
    }

    private static func inspectHTTP(url: URL) async throws -> MediaInspection {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaInspectionError.invalidPlaylist("无法获取 HTTP 响应")
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "未知"
        let totalBytes = httpResponse.expectedContentLength
        var label = contentType
        if totalBytes > 0 {
            label += " · \(formatBytes(totalBytes))"
        }
        return MediaInspection(
            mediaKind: .http,
            variants: [
                MediaVariant(
                    url: url,
                    label: label,
                    bandwidth: nil,
                    width: nil,
                    height: nil,
                    codecs: nil,
                    estimatedSize: totalBytes > 0 ? totalBytes : nil
                )
            ]
        )
    }

    private static func inspectYouTube(url: URL) async throws -> MediaInspection {
        guard let ytDlpPath = locateYTDlp() else {
            throw MediaInspectionError.youTubeToolUnavailable
        }
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-J", "--simulate", "--no-warnings", "--no-playlist",
            "--ignore-config", "--no-cache-dir",
            "--remote-components", "ejs:github",
            url.absoluteString,
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        process.environment = env

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let output = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus != 0 {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message =
                        detail.isEmpty
                        ? "yt-dlp 退出码 \(proc.terminationStatus)"
                        : detail
                    continuation.resume(
                        throwing: MediaInspectionError.invalidPlaylist(message))
                    return
                }
                do {
                    let info = try JSONDecoder().decode(CLIYouTubeInfo.self, from: Data(output.utf8))
                    let variants = info.formats
                        .filter { ($0.vcodec ?? "none") != "none" && ($0.height ?? 0) > 0 }
                        .sorted { ($0.height ?? 0, $0.tbr ?? 0) > ($1.height ?? 0, $1.tbr ?? 0) }
                        .prefix(20)
                        .map { format -> MediaVariant in
                            let res = format.height.map { "\($0)p" } ?? "未知"
                            let size = format.filesize ?? format.filesizeApprox
                            return MediaVariant(
                                url: url,
                                label: "\(res)\(size.map { " · ~\(formatBytes($0))" } ?? "")",
                                bandwidth: format.tbr.map { Int($0 * 1000) },
                                width: format.width,
                                height: format.height,
                                codecs: format.vcodec,
                                estimatedSize: size
                            )
                        }
                    if variants.isEmpty {
                        continuation.resume(throwing: MediaInspectionError.invalidPlaylist("YouTube 视频没有可用的视频格式"))
                    } else {
                        continuation.resume(returning: MediaInspection(mediaKind: .http, variants: Array(variants)))
                    }
                } catch {
                    continuation.resume(throwing: MediaInspectionError.invalidPlaylist("无法解析 yt-dlp 输出"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: MediaInspectionError.youTubeToolUnavailable)
            }
        }
    }

    private static func locateYTDlp() -> String? {
        // Mirror the GUI app's resolution order: env override, the
        // Application Support copy written by in-app updates, then
        // standard system installs.
        let managedCopy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacIDM/yt-dlp").path
        let candidates = [
            ProcessInfo.processInfo.environment["MACIDM_YTDLP_PATH"],
            managedCopy,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/yt-dlp").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1_024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var size = value
        var unit = "B"
        for next in units {
            if size < 1_024 { break }
            size /= 1_024
            unit = next
        }
        return size >= 100 ? String(format: "%.0f %@", size, unit) : String(format: "%.1f %@", size, unit)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct CLIYouTubeInfo: Decodable {
    let formats: [CLIYouTubeFormat]
}

private struct CLIYouTubeFormat: Decodable {
    let formatId: String?
    let ext: String?
    let width: Int?
    let height: Int?
    let vcodec: String?
    let acodec: String?
    let tbr: Double?
    let filesize: Int64?
    let filesizeApprox: Int64?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext, width, height, vcodec, acodec, tbr, filesize
        case filesizeApprox = "filesize_approx"
    }
}
