import Foundation
import IDMEngine

enum YouTubeDownloadError: Error, Equatable, Sendable {
    case toolUnavailable
    case toolLaunchFailed
    case invalidRequest
    case processFailed
    case botCheckBlocked
    case nChallengeFailed
    case geoBlocked
    case ageRestricted
    case privateVideo
    case copyrightClaimed
    case videoUnavailable
    case liveStreamEnded
    /// Currently live or upcoming stream: the product accepts only VOD/ended
    /// replays.
    case liveStreamUnsupported
    /// Live probe could not determine the status (process error/timeout/decode
    /// failure): a fail-closed retryable error, so a possibly-active live
    /// stream is never downloaded as an endless VOD (§3.2).
    case liveStatusUnknown
    case networkFailure
    case extractorUnsupported
    case mediaNotProduced
    case ffmpegUnavailable
    case stalled
    /// Process-group cleanup exceeded the settle budget (§3): a diagnosable
    /// failure, never silently treated as success, and never routed into the
    /// stall retry — leftover processes could interfere with the next attempt.
    case processCleanupFailed

    /// Transient storage for the last yt-dlp process output, used by
    /// `YTDlpManager.shouldRecommendUpdate` to detect YouTube protocol
    /// changes. This is a best-effort diagnostic hint set on the failure
    /// path and read immediately after by the MainActor error handler.
    /// Protected by an NSLock to prevent data races on concurrent access.
    private static let _lastOutputLock = NSLock()
    nonisolated(unsafe) private static var _lastProcessOutput: String?

    static var lastProcessOutput: String? {
        get {
            _lastOutputLock.lock()
            defer { _lastOutputLock.unlock() }
            return _lastProcessOutput
        }
        set {
            _lastOutputLock.lock()
            _lastProcessOutput = newValue
            _lastOutputLock.unlock()
        }
    }
}

extension YouTubeDownloadError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .toolUnavailable:
            String(localized: "YouTube 下载需要已安装 yt-dlp（Debug 环境可执行 brew install yt-dlp）。")
        case .toolLaunchFailed:
            String(
                localized:
                    "yt-dlp 已找到但无法启动（可能是文件损坏或系统限制）。请在设置的 yt-dlp 页面重新下载安装。")
        case .invalidRequest:
            String(localized: "YouTube 下载请求无效。")
        case .processFailed:
            String(localized: "YouTube 媒体提取失败；可尝试更新 yt-dlp 或稍后重试。")
        case .botCheckBlocked:
            String(
                localized:
                    "YouTube 风控验证拦截了本次请求：请在浏览器中保持 YouTube 登录状态（下载组件会从 Chrome 读取登录 Cookie），稍后重试；若仍失败可尝试更新 yt-dlp。"
            )
        case .nChallengeFailed:
            String(
                localized:
                    "YouTube 下载需要 JavaScript 运行时（Node.js 或 Deno）来解密视频签名。请安装 Node.js（brew install node）或 Deno（brew install deno）后重试。"
            )
        case .geoBlocked:
            String(localized: "该视频在你的地区不可用（地区限制）。可尝试配置代理后重试。")
        case .ageRestricted:
            String(localized: "该视频有年龄限制。请在 Chrome 中登录 YouTube 账号后重试。")
        case .privateVideo:
            String(localized: "该视频是私密视频，仅所有者或被授权账号可访问。")
        case .copyrightClaimed:
            String(localized: "该视频因版权问题被限制下载。")
        case .videoUnavailable:
            String(localized: "视频不可用：可能已被删除、下架或链接无效。")
        case .liveStreamEnded:
            String(localized: "该直播回放尚未生成或不可用。")
        case .liveStreamUnsupported:
            String(localized: "正在直播或即将开始的直播暂不支持下载，MacIDM 只接受已结束的点播/回放。")
        case .liveStatusUnknown:
            String(localized: "无法确认 YouTube 内容的直播状态，为避免误下载已中止；请稍后重试。")
        case .networkFailure:
            String(
                localized: "网络连接失败。请检查网络连通性；若访问 YouTube 需要代理，请在设置中配置代理后重试。"
            )
        case .extractorUnsupported:
            String(localized: "yt-dlp 不支持该链接。请确认链接指向有效的视频页面。")
        case .mediaNotProduced:
            String(localized: "YouTube 提取器没有生成可用的视频文件。")
        case .ffmpegUnavailable:
            String(localized: "YouTube 视频需要 FFmpeg 完成 MP4 校验和发布。")
        case .stalled:
            String(localized: "YouTube 下载超时或长时间无进度")
        case .processCleanupFailed:
            String(
                localized: "yt-dlp 进程组未能在预算内完成清理，为避免残留进程干扰已中止本次下载；请稍后重试。"
            )
        }
    }

    var code: String {
        switch self {
        case .toolUnavailable: "YTDLP_NOT_FOUND"
        case .toolLaunchFailed: "YTDLP_LAUNCH_FAILED"
        case .invalidRequest: "YTDLP_INVALID_REQUEST"
        case .processFailed: "YTDLP_PROCESS_FAILED"
        case .botCheckBlocked: "YTDLP_BOT_CHECK"
        case .nChallengeFailed: "YTDLP_N_CHALLENGE_FAILED"
        case .geoBlocked: "YTDLP_GEO_BLOCKED"
        case .ageRestricted: "YTDLP_AGE_RESTRICTED"
        case .privateVideo: "YTDLP_PRIVATE_VIDEO"
        case .copyrightClaimed: "YTDLP_COPYRIGHT"
        case .videoUnavailable: "YTDLP_VIDEO_UNAVAILABLE"
        case .liveStreamEnded: "YTDLP_LIVE_ENDED"
        case .liveStreamUnsupported: "YTDLP_LIVE_UNSUPPORTED"
        case .liveStatusUnknown: "YTDLP_LIVE_STATUS_UNKNOWN"
        case .networkFailure: "YTDLP_NETWORK_ERROR"
        case .extractorUnsupported: "YTDLP_UNSUPPORTED_URL"
        case .mediaNotProduced: "YTDLP_NO_MEDIA"
        case .ffmpegUnavailable: "YTDLP_FFMPEG_UNAVAILABLE"
        case .stalled: "YTDLP_STALLED"
        case .processCleanupFailed: "YTDLP_CLEANUP_FAILED"
        }
    }
}

/// Runs the site-maintained YouTube extractor for the current Debug build.
///
/// YouTube increasingly serves browser playback through SABR/UMP rather than
/// stable MP4 URLs. The browser extension therefore submits the page URL and
/// its short-lived, user-authorized request context; yt-dlp resolves the
/// current player protocol and FFmpeg validates/publishes the resulting MP4.
struct YouTubeDownloadRunner: YouTubeDownloadRunning, Sendable {
    /// Explicitly pinned executable (tests and diagnostics). Production
    /// leaves this nil so every run re-resolves the current binary.
    private let injectedExecutableURL: URL?
    /// Optional seam for the default-path resolution done at the start of
    /// every run. Production leaves this nil and resolves via
    /// YTDlpManager; unit tests use it to simulate binaries that appear,
    /// disappear, or swap locations while the runner is alive.
    private let defaultExecutableResolver: (@Sendable () -> URL?)?
    private let ffmpegRemuxer: (any FFmpegRemuxing)?
    /// Dual-channel diagnostic sink; injected so unit tests never touch the
    /// user's real private log file.
    private let diagnosticLog: YouTubeDiagnosticEventLog
    /// Live-probe budget: on par with the inspection layer's format listing;
    /// short values are injected so unit tests cover the timeout branch.
    /// 120 s: current YouTube extraction must solve JS challenges — full `-J`
    /// extraction can take 60–90 s in practice — so a shorter budget would
    /// kill the probe before its JSON output completes and misclassify it as
    /// unknown.
    private let liveProbeTimeout: TimeInterval
    /// Stall budget for one download attempt; short values are injected so
    /// unit tests cover the stall/retry scenarios.
    private let downloadAttemptTimeout: TimeInterval

    init(
        executableURL: URL? = nil,
        ffmpegRemuxer: (any FFmpegRemuxing)?,
        defaultExecutableResolver: (@Sendable () -> URL?)? = nil,
        diagnosticLog: YouTubeDiagnosticEventLog = .shared,
        liveProbeTimeout: TimeInterval = 120,
        downloadAttemptTimeout: TimeInterval = 30
    ) {
        self.injectedExecutableURL = executableURL
        self.defaultExecutableResolver = defaultExecutableResolver
        self.ffmpegRemuxer = ffmpegRemuxer
        self.diagnosticLog = diagnosticLog
        self.liveProbeTimeout = liveProbeTimeout
        self.downloadAttemptTimeout = downloadAttemptTimeout
    }

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let fileManager = FileManager.default
        guard request.backend == .youtubeExtractor,
            request.sourceKind == .http,
            let scheme = request.url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw YouTubeDownloadError.invalidRequest
        }
        // Resolve the executable at task start, not at runner creation.
        // The app keeps this runner for its whole lifetime, so a path
        // captured in init goes stale as soon as yt-dlp is installed,
        // updated, or swapped in place (2026-08-25 incident: the runner
        // kept launching a managed binary an in-app update had replaced).
        let executableURL = resolveExecutable()
        guard let executableURL else {
            AppLogger.shared.warning(.youtube, "yt-dlp executable not found at task start")
            throw YouTubeDownloadError.toolUnavailable
        }
        // The path itself is the useful diagnostic (managed/bundled/system
        // location); it carries no URL query, cookie, or auth material. The
        // home prefix is still replaced so the username never reaches the
        // regular log (§3.3 tool-path audit).
        AppLogger.shared.info(
            .youtube,
            "yt-dlp binary resolved for task \(request.taskID): \(YouTubeOutputSanitizer.userSafePath(executableURL.path))"
        )
        // YouTube pages get the dedicated flow (Chrome cookie store,
        // .youtube.com cookie domain); every other site runs through
        // yt-dlp's generic extractor as a fallback backend.
        let isYouTube = isYouTubePage(request.url)
        guard !fileManager.fileExists(atPath: request.destination.path) else {
            throw IDMError.filenameConflict(request.destination.path)
        }
        guard let ffmpegRemuxer else { throw YouTubeDownloadError.ffmpegUnavailable }

        let workingDirectory = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(request.taskID.uuidString).macidm.youtube", isDirectory: true)
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var preserveWorkingDirectory = false
        defer {
            // Only remove the working directory on success. Preserve it on
            // pause, cancel, AND failure so the user can inspect partial
            // downloads or retry without re-downloading from scratch.
            if !preserveWorkingDirectory {
                try? fileManager.removeItem(at: workingDirectory)
            }
        }

        do {
            // Non-YouTube site domains also need the leading dot: the
            // Netscape format asserts that a domain with
            // domain_specified=TRUE starts with ".", or yt-dlp rejects the
            // whole cookie file (invalid Netscape format cookies file).
            let cookieDomain = isYouTube ? ".youtube.com" : ".\(request.url.host ?? "localhost")"
            let cookieFile = try writeCookieFile(
                request.requestContext?.cookie,
                domain: cookieDomain,
                in: workingDirectory
            )
            defer {
                if let cookieFile { try? fileManager.removeItem(at: cookieFile) }
            }

            // The extension/App inspect path encodes the user's variant pick
            // in a MacIDM-owned URL fragment `height=<n>[&itag=<id>[&a=1]]`.
            // Parse it with URLComponents and strip it before handing the
            // URL to yt-dlp. The variant URL was built by replacing any page
            // fragment (e.g. `#t=90`) wholesale, so the selection never
            // depends on string concatenation.
            var downloadURL = request.url
            var heightConstraint = ""
            var selectedITag: Int?
            var selectedHasAudio = false
            if let fragment = request.url.fragment,
                var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            {
                let selection = Self.parseMacIDMFragment(fragment)
                if let height = selection.height {
                    heightConstraint = "[height<=\(height)]"
                }
                selectedITag = selection.itag
                selectedHasAudio = selection.hasAudio
                if selection.height != nil || selection.itag != nil {
                    components.fragment = nil
                    downloadURL = components.url ?? request.url
                }
            }
            let formatString = Self.formatSelector(
                itag: selectedITag,
                hasAudio: selectedHasAudio,
                heightConstraint: heightConstraint
            )

            // Live defense (three-state, §3.2): when a legacy task is
            // enqueued directly or bypasses inspection, an ongoing live
            // stream must not be downloaded as an endless VOD. Shares the
            // same classification rules as the inspection layer
            // (YouTubeLiveClassifier); probe failures no longer pass
            // unconditionally: when yt-dlp produces an error output the
            // network/auth/tool diagnostic categories are preserved, and
            // when the status cannot be determined it fails closed as a
            // retryable inspection error.
            if isYouTube {
                let probeStart = Date()
                let outcome = try await probeLiveStatus(
                    executableURL: executableURL,
                    url: downloadURL,
                    cookieFile: cookieFile,
                    request: request
                )
                switch outcome {
                case .allowed(let stderr):
                    // stderr from a successful probe (cookie-loading notices,
                    // runtime warnings) is not discarded either: when
                    // non-empty, one diagnostic event is recorded with only
                    // structured markers on the ordinary line; the raw text
                    // goes to the private log after credential redaction
                    // (round 4 R3).
                    if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recordDiagnostic(
                            request: request,
                            selectionITag: selectedITag,
                            event: "ytdlp.liveProbeNote",
                            stage: "liveProbe",
                            category: nil,
                            exitStatus: 0,
                            attempt: 0,
                            startedAt: probeStart,
                            output: stderr,
                            cookieFile: cookieFile,
                            excerptOverride: "stderrPresent=true"
                        )
                    }
                case .blocked(let phase, let stderr):
                    let classification: YouTubeDownloadError =
                        phase == .replayNotReady ? .liveStreamEnded : .liveStreamUnsupported
                    // The blocked-case stderr also goes to private
                    // diagnostics; the ordinary line keeps only the safe
                    // phase marker.
                    var blockedOutput = "livePhase=\(phase.rawValue)"
                    if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blockedOutput += "\nstderr: |\n\(stderr)"
                    }
                    recordDiagnostic(
                        request: request,
                        selectionITag: selectedITag,
                        event: "ytdlp.liveBlocked",
                        stage: "liveProbe",
                        category: classification.code,
                        exitStatus: 0,
                        attempt: 0,
                        startedAt: probeStart,
                        output: blockedOutput,
                        cookieFile: cookieFile,
                        excerptOverride: "livePhase=\(phase.rawValue)"
                    )
                    throw classification
                case .processFailed(let exitStatus, let output):
                    // The probe captured yt-dlp's real error: use the main
                    // download's classifier to preserve the network/auth/
                    // stale-tool categories instead of misreporting "live
                    // unsupported".
                    let classification = Self.classifyProcessError(output: output)
                    YouTubeDownloadError.lastProcessOutput = output
                    recordDiagnostic(
                        request: request,
                        selectionITag: selectedITag,
                        event: "ytdlp.liveProbeFailed",
                        stage: "liveProbe",
                        category: classification.code,
                        exitStatus: exitStatus,
                        attempt: 0,
                        startedAt: probeStart,
                        output: output,
                        cookieFile: cookieFile
                    )
                    throw classification
                case .unknown(let info):
                    // Live status unknowable (timeout/process error/empty
                    // stdout/invalid JSON/unknown fields): without proof the
                    // content is not live, abort safely with a retryable
                    // error; the ordinary line records only the reason code
                    // and structured fields — the raw context goes to the
                    // private log after redaction (round 2 §P2-1).
                    recordDiagnostic(
                        request: request,
                        selectionITag: selectedITag,
                        event: "ytdlp.liveProbeUnknown",
                        stage: "liveProbe",
                        category: YouTubeDownloadError.liveStatusUnknown.code,
                        exitStatus: nil,
                        attempt: 0,
                        startedAt: probeStart,
                        output: info.combinedContext,
                        cookieFile: cookieFile,
                        excerptOverride: "reason=\(info.reason.rawValue)"
                    )
                    throw YouTubeDownloadError.liveStatusUnknown
                case .launchFailed:
                    // Toolchain problems keep their own categories (matching
                    // the main download's launch-failure logic).
                    let classification: YouTubeDownloadError =
                        FileManager.default.isExecutableFile(atPath: executableURL.path)
                        ? .toolLaunchFailed : .toolUnavailable
                    recordDiagnostic(
                        request: request,
                        selectionITag: selectedITag,
                        event: "ytdlp.liveProbeLaunchFailed",
                        stage: "liveProbe",
                        category: classification.code,
                        exitStatus: nil,
                        attempt: 0,
                        startedAt: probeStart,
                        output: "",
                        cookieFile: cookieFile
                    )
                    throw classification
                }
            }

            let arguments = YouTubeCommandBuilder.buildDownloadArguments(
                downloadURL: downloadURL,
                formatString: formatString,
                workingDirectory: workingDirectory,
                isYouTube: isYouTube,
                cookieFile: cookieFile,
                request: request
            )

            AppLogger.shared.info(.youtube, "yt-dlp process started for task: \(request.taskID)")
            // Retry loop: a silent hang (no output at all for the attempt
            // timeout) almost always means a stuck connection, and a short
            // kill+retry recovers far faster than waiting out a multi-minute
            // stall. A non-zero exit with real output is classified
            // immediately — retrying known failures only wastes time.
            let maxAttempts = 3
            let attemptTimeout = downloadAttemptTimeout
            // Fresh classification context for this run: a stale static
            // output from a previous task must never leak into this run's
            // stall/failure classification.
            YouTubeDownloadError.lastProcessOutput = nil
            // Across retries the progress bar must never move backwards: a
            // resumed attempt may re-report from a lower byte count.
            let progressBridge = RetryProgressBridge(inner: progress)
            var attempt = 0
            var successOutput = ""
            let downloadStart = Date()
            while true {
                attempt += 1
                let attemptStart = Date()
                do {
                    let candidate = try await YouTubeProcessOperation(
                        executableURL: executableURL,
                        arguments: arguments,
                        control: control,
                        progress: { progressBridge.emit($0) },
                        stallTimeout: attemptTimeout
                    ).run()
                    if candidate.exitStatus == 0 {
                        // Keep the raw output of a successful exit: when the
                        // exit code is 0 yet no artifact appears, the cause
                        // cannot be located without it (a diagnostic gap on
                        // the silent-success path).
                        successOutput = candidate.text
                        break
                    }
                    // Non-zero exit with output — fast-fail with a precise
                    // classification instead of retrying. The raw output
                    // never enters the regular log: one structured event is
                    // derived and dispatched to both sinks (regular sanitized
                    // line + private diagnostic record).
                    let classification = Self.classifyProcessError(output: candidate.text)
                    YouTubeDownloadError.lastProcessOutput = candidate.text
                    recordDiagnostic(
                        request: request,
                        selectionITag: selectedITag,
                        event: "ytdlp.processFailed",
                        stage: "download",
                        category: classification.code,
                        exitStatus: candidate.exitStatus,
                        attempt: attempt,
                        startedAt: attemptStart,
                        output: candidate.text,
                        cookieFile: cookieFile
                    )
                    throw classification
                } catch let error as YouTubeDownloadError where error == .stalled {
                    guard attempt < maxAttempts else {
                        // Final attempt: classify from any partial output the
                        // stalled process produced (e.g. network signatures);
                        // otherwise surface the stall itself.
                        let partial = YouTubeDownloadError.lastProcessOutput
                        let hasPartial =
                            partial?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            == false
                        let classification =
                            hasPartial
                            ? Self.classifyProcessError(output: partial ?? "")
                            : error
                        recordDiagnostic(
                            request: request,
                            selectionITag: selectedITag,
                            event: "ytdlp.stalledFinal",
                            stage: "stallRetry",
                            category: classification.code,
                            exitStatus: nil,
                            attempt: attempt,
                            startedAt: attemptStart,
                            output: partial ?? "",
                            cookieFile: cookieFile
                        )
                        throw classification
                    }
                    AppLogger.shared.warning(
                        .youtube,
                        "yt-dlp attempt \(attempt)/\(maxAttempts) produced no output for \(Int(attemptTimeout))s, killing and retrying"
                    )
                }
            }
            AppLogger.shared.info(.youtube, "yt-dlp process completed successfully")
            guard let mediaURL = producedMedia(in: workingDirectory),
                let size = try? fileManager.attributesOfItem(atPath: mediaURL.path)[.size] as? NSNumber,
                size.int64Value > 0
            else {
                // Exit code 0 but no usable artifact: record the raw output
                // to private diagnostics (the ordinary line keeps only
                // structured fields), or this failure can never be located
                // (§5.4 diagnostic classification).
                YouTubeDownloadError.lastProcessOutput = successOutput
                recordDiagnostic(
                    request: request,
                    selectionITag: selectedITag,
                    event: "ytdlp.noMedia",
                    stage: "download",
                    category: YouTubeDownloadError.mediaNotProduced.code,
                    exitStatus: 0,
                    attempt: attempt,
                    startedAt: downloadStart,
                    output: successOutput,
                    cookieFile: cookieFile
                )
                throw YouTubeDownloadError.mediaNotProduced
            }
            AppLogger.shared.info(
                .youtube,
                "yt-dlp produced media: \(mediaURL.lastPathComponent) (\(size.int64Value) bytes)"
            )

            AppLogger.shared.info(.youtube, "FFmpeg remux started for YouTube media")
            // Final frame carries the measured average instead of zero so
            // the last progress sample never blanks out the speed column
            // during the remux phase.
            let elapsed = Date().timeIntervalSince(downloadStart)
            let averageSpeed = elapsed > 0 ? Double(size.int64Value) / elapsed : 0
            progress(
                DownloadProgress(
                    receivedBytes: size.int64Value,
                    totalBytes: size.int64Value,
                    speed: averageSpeed,
                    // yt-dlp has finished all network tracks, but FFmpeg
                    // remux and ffprobe validation still have to succeed.
                    // Reserve the real 100% state for AppModel.finish().
                    overallFraction: 0.99
                ))
            let remuxed = try await ffmpegRemuxer.remux(
                FFmpegRemuxRequest(
                    inputURL: mediaURL,
                    outputURL: request.destination,
                    outputKind: .mp4,
                    control: control
                )
            )
            AppLogger.shared.info(.youtube, "FFmpeg remux completed: \(remuxed.byteCount) bytes")
            return DownloadResult(
                destination: remuxed.destination,
                byteCount: remuxed.byteCount,
                sha256: remuxed.sha256,
                usedParallelRequests: 1,
                resumed: false,
                verification: "yt-dlp-ffmpeg-ffprobe"
            )
        } catch {
            // Preserve partial downloads on ALL error paths (pause, cancel,
            // failure, stall). The working directory may contain a partial
            // download that the user can inspect or retry from.
            // Error descriptions may embed paths/file names (e.g.
            // IDMError.filenameConflict): sanitize for the regular log
            // first; the full description already went to the private log
            // via the dual-channel failure event.
            AppLogger.shared.error(
                .youtube,
                "YouTube download failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? DownloadDiagnosticEventLog.errorCode(for: error))"
            )
            preserveWorkingDirectory = true
            throw error
        }
    }

    /// Classifies yt-dlp process output into a precise error instead of
    /// the generic "process failed" bucket. Ordered most-specific first;
    /// the same signature table feeds `DownloadErrorAnalyzer` so UI copy
    /// stays consistent between the runner and the diagnosis layer.
    static func classifyProcessError(output: String) -> YouTubeDownloadError {
        let lower = output.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let patterns: [(YouTubeDownloadError, [String])] = [
            (.botCheckBlocked, ["sign in to confirm", "confirm you're not a bot", "login required"]),
            (.nChallengeFailed, ["n challenge solving failed", "the page needs to be reloaded"]),
            (
                .geoBlocked,
                ["not available in your country", "geo-restricted", "not available in your territory"]
            ),
            (.ageRestricted, ["age-restricted", "confirm your age", "age gate"]),
            (.privateVideo, ["private video", "this video is private"]),
            (
                .copyrightClaimed, ["copyright", "blocked it in your country", "content blocked"]
            ),
            (
                .videoUnavailable,
                ["video unavailable", "has been removed", "no longer available", "does not exist"]
            ),
            (
                .liveStreamEnded,
                ["live stream recording is not available", "this live event has ended"]
            ),
            (
                .networkFailure,
                [
                    "connection refused", "name or service not known", "network is unreachable",
                    "connection reset", "timed out", "temporary failure in name resolution",
                ]
            ),
            (.extractorUnsupported, ["unsupported url", "no suitable extractor"]),
        ]
        for (error, signatures) in patterns {
            if signatures.contains(where: { lower.contains($0) }) {
                return error
            }
        }
        return .processFailed
    }

    typealias FragmentSelection = YouTubeCommandBuilder.FragmentSelection

    /// Parses `height=<n>[&itag=<id>[&a=1]]` from the variant fragment.
    static func parseMacIDMFragment(_ fragment: String) -> FragmentSelection {
        YouTubeCommandBuilder.parseMacIDMFragment(fragment)
    }

    /// Builds the yt-dlp format selector from validated selection fields.
    static func formatSelector(
        itag: Int?,
        hasAudio: Bool,
        heightConstraint: String
    ) -> String {
        YouTubeCommandBuilder.formatSelector(
            itag: itag,
            hasAudio: hasAudio,
            heightConstraint: heightConstraint
        )
    }

    /// Extracts the YouTube video ID (`?v=`, `/shorts/<id>`, `/live/<id>`,
    /// `youtu.be/<id>`) for resource fingerprinting.
    static func youTubeVideoID(from url: URL) -> String? {
        YouTubeCommandBuilder.youTubeVideoID(from: url)
    }

    private static func cookieCount(_ cookie: String?) -> Int? {
        YouTubeCommandBuilder.cookieCount(cookie)
    }

    /// Three-state live-probe result (§3.2 / rounds 2 §P1-1, P2-1): `nil` no
    /// longer stands for every probe failure at once.
    enum LiveProbeOutcome: Sendable {
        /// Explicitly VOD or an ended replay; download may proceed. Carries
        /// stderr when non-empty for diagnostics.
        case allowed(stderr: String)
        /// Explicitly currently live/upcoming/replay not ready; must be blocked.
        case blocked(YouTubeLivePhase, stderr: String)
        /// yt-dlp exited non-zero with output: preserves the network/auth/tool
        /// diagnostic categories.
        case processFailed(exitStatus: Int32, output: String)
        /// Live status unknowable: carries a stable reason and the raw context
        /// (for the private log).
        case unknown(LiveProbeUnknown)
        /// yt-dlp process launch failed: a toolchain problem; keeps its own
        /// diagnostic category.
        case launchFailed
    }

    /// Unknown-state diagnostic context (round 2 §P2-1): the ordinary log
    /// records only the reason code; the raw content goes to the private log
    /// after credential redaction.
    struct LiveProbeUnknown: Sendable {
        enum Reason: String, Sendable {
            /// Probe was killed on timeout (conventional exit code -1).
            case timeout
            /// Process launch/runtime error.
            case processError
            /// Exited successfully but stdout was empty.
            case emptyStdout
            /// stdout cannot be decoded as the live-field JSON.
            case invalidJSON
            /// JSON decodes but the live fields are missing/contradictory/
            /// unknown (classifier returns unknown).
            case liveStatusUnknown
        }

        let reason: Reason
        let stdout: String?
        let stderr: String?
        let errorDescription: String?

        /// Full context for the private log (credential-redacted uniformly
        /// before writing).
        var combinedContext: String {
            var parts: [String] = ["reason=\(reason.rawValue)"]
            if let errorDescription, !errorDescription.isEmpty {
                parts.append("error: \(errorDescription)")
            }
            if let stdout, !stdout.isEmpty { parts.append("stdout: |\n\(stdout)") }
            if let stderr, !stderr.isEmpty { parts.append("stderr: |\n\(stderr)") }
            return parts.joined(separator: "\n")
        }
    }

    /// Live-semantics probe before the download starts: reuses the inspection
    /// layer's `-J --simulate` and the same cookie/proxy configuration. JSON
    /// is parsed from stdout only (round 2 §P1-1): yt-dlp's `-J` output goes
    /// to stdout while cookie-loading/runtime notices may land on stderr —
    /// mixing them into the parse would misjudge a legitimate VOD as unknown;
    /// only the failure branch merges both streams for classification and
    /// private diagnostics.
    private func probeLiveStatus(
        executableURL: URL,
        url: URL,
        cookieFile: URL?,
        request: DownloadRequest
    ) async throws -> LiveProbeOutcome {
        var arguments = [
            "-J", "--simulate", "--no-warnings", "--no-playlist",
            "--ignore-config", "--no-cache-dir",
        ]
        if let userAgent = request.requestContext?.userAgent, !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = request.requestContext?.referer, !referer.isEmpty {
            arguments += ["--add-headers", "Referer: \(referer)"]
        }
        // Cookie supply matches the main download: YouTube pages pull the
        // Chrome login state, with the explicit cookie file layered on top.
        arguments += ["--cookies-from-browser", "chrome"]
        if let cookieFile {
            arguments += ["--cookies", cookieFile.path]
        }
        if let proxyURL = YTDlpManager.currentProxyURLString() {
            arguments += ["--proxy", proxyURL]
        }
        arguments += [url.absoluteString]

        // Process-level error classification: launch failures keep the
        // toolchain category; cancellation propagates; everything else
        // becomes unknown.
        let result: (Int32, String, String)
        do {
            result = try await YouTubeInspectProcess(
                executableURL: executableURL,
                arguments: arguments
            ).run(timeout: liveProbeTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch MediaInspectionError.youTubeToolUnavailable {
            return .launchFailed
        } catch MediaInspectionError.processCleanupFailed {
            // Cleanup failure keeps its own blocking category (§4 contract)
            // and must not be misreported as an unknowable live status.
            throw YouTubeDownloadError.processCleanupFailed
        } catch {
            return .unknown(
                LiveProbeUnknown(
                    reason: .processError,
                    stdout: nil,
                    stderr: nil,
                    errorDescription: error.localizedDescription
                ))
        }
        let (exitStatus, stdout, stderr) = result
        // Conventional exit code -1: killed on timeout.
        if exitStatus < 0 {
            return .unknown(
                LiveProbeUnknown(
                    reason: .timeout, stdout: stdout, stderr: stderr, errorDescription: nil))
        }
        // Non-zero exit: merge both streams for error classification and
        // private diagnostics.
        guard exitStatus == 0 else {
            let combined = [stdout, stderr]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            return .processFailed(exitStatus: exitStatus, output: combined)
        }
        // Success branch: parse stdout only; non-empty stderr is kept as
        // diagnostic context, not for JSON decoding.
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStdout.isEmpty else {
            return .unknown(
                LiveProbeUnknown(
                    reason: .emptyStdout, stdout: stdout, stderr: stderr, errorDescription: nil))
        }
        guard
            let probe = try? JSONDecoder().decode(
                YouTubeLiveStateProbe.self, from: Data(trimmedStdout.utf8))
        else {
            return .unknown(
                LiveProbeUnknown(
                    reason: .invalidJSON, stdout: stdout, stderr: stderr, errorDescription: nil))
        }
        let phase = YouTubeLiveClassifier.phase(probe.state)
        if YouTubeLiveClassifier.isBlocked(phase) { return .blocked(phase, stderr: stderr) }
        // Missing/contradictory/unknown-enum fields: must not pass as VOD;
        // likewise classified unknown (round 2 §P1-2).
        guard YouTubeLiveClassifier.isAllowed(phase) else {
            return .unknown(
                LiveProbeUnknown(
                    reason: .liveStatusUnknown,
                    stdout: stdout,
                    stderr: stderr,
                    errorDescription: "livePhase=\(phase.rawValue)"
                ))
        }
        return .allowed(stderr: stderr)
    }

    /// Derives one structured diagnostic event and dispatches it to both
    /// sinks: the regular log receives only sanitized fields, the private
    /// diagnostic log keeps the full URL, cookie-file path and raw (but
    /// credential-redacted) yt-dlp output under the same event id
    /// Write failures are silent — logging must never
    /// disturb the download pipeline.
    private func recordDiagnostic(
        request: DownloadRequest,
        selectionITag: Int?,
        event: String,
        stage: String,
        category: String?,
        exitStatus: Int32?,
        attempt: Int,
        startedAt: Date,
        output: String,
        cookieFile: URL?,
        excerptOverride: String? = nil
    ) {
        let fullURL = request.url.absoluteString
        diagnosticLog.record(
            YouTubeDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: event,
                stage: stage,
                taskID: request.taskID.uuidString,
                category: category,
                exitStatus: exitStatus,
                attempt: attempt,
                durationMs: Int64(Date().timeIntervalSince(startedAt) * 1000),
                ytDlpVersion: YTDlpManager.currentVersionSync(),
                cookieSupplied: request.requestContext?.cookie?.isEmpty == false,
                cookieCount: Self.cookieCount(request.requestContext?.cookie),
                cookieFileCreated: cookieFile != nil,
                proxyConfigured: YTDlpManager.currentProxyURLString() != nil,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(fullURL),
                resourceFingerprint: DiagnosticFingerprint.resource(
                    videoID: Self.youTubeVideoID(from: request.url),
                    itag: selectionITag
                ),
                // The ordinary excerpt is derived from the raw output by
                // default; some events (like the unknown probe) may show
                // only a safe structured summary in the ordinary log,
                // explicitly specified by the caller (round 2 §P2-1).
                sanitizedExcerpt: excerptOverride
                    ?? YouTubeOutputSanitizer.sanitizedExcerpt(from: output),
                fullURL: fullURL,
                cookieFilePath: cookieFile?.path,
                rawOutput: YouTubeOutputSanitizer.redactCredentials(in: output)
            )
        )
    }

    private func producedMedia(in directory: URL) -> URL? {
        YouTubeArtifactPublisher.producedMedia(in: directory)
    }

    private func writeCookieFile(_ cookie: String?, domain: String, in directory: URL) throws -> URL? {
        try YouTubeCommandBuilder.writeCookieFile(cookie, domain: domain, in: directory)
    }

    private func isYouTubePage(_ url: URL) -> Bool {
        // Single-video-page check delegates to the inspection layer's single
        // implementation (§4.5): `/watch` must carry a non-empty `v`; bare
        // `/live/` and `/shorts/` prefixes are rejected — consistent with
        // the media.inspect entry point.
        YouTubeMediaInspector.isYouTubePage(url)
    }

    private func resolveExecutable() -> URL? {
        if let injectedExecutableURL { return injectedExecutableURL }
        if let defaultExecutableResolver { return defaultExecutableResolver() }
        return Self.locateExecutable(environment: ProcessInfo.processInfo.environment)
    }

    private static func locateExecutable(environment: [String: String]) -> URL? {
        // Delegate to YTDlpManager so the runner shares the app-wide
        // resolution order (env override → managed update → bundled →
        // system installs).
        YTDlpManager.locateExecutable(environment: environment)
    }
}

struct YouTubeProcessOutput: Sendable {
    let exitStatus: Int32
    let text: String
}

/// Wraps the progress callback across retry attempts so the reported
/// received-byte count is monotonic — a restarted yt-dlp attempt can
/// legitimately re-report from a lower offset, but the UI bar must not
/// jump backwards. While the byte count is pinned like that, the fresh
/// attempt's instantaneous speed is also suppressed: it measures a
/// re-transfer of bytes that are already accounted for, and surfacing it
/// showed a runaway speed next to a pinned 100% bar.
private final class RetryProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var highestReceived: Int64 = 0
    private var highestOverallFraction: Double = 0
    /// Last seen aggregate total; a drastic change signals a corrected
    /// capture, which must also un-pin the fraction clamp below.
    private var lastTotalBytes: Int64?
    private let inner: @Sendable (DownloadProgress) -> Void

    init(inner: @escaping @Sendable (DownloadProgress) -> Void) {
        self.inner = inner
    }

    func emit(_ sample: DownloadProgress) {
        lock.lock()
        // A substantially corrected aggregate total (e.g. the SABR 1KiB
        // side file replaced by the real stream's size) means the earlier
        // poisoned fraction clamp must be re-derived too, or the bar stays
        // pinned at the stale stage ceiling for the rest of the download.
        if let total = sample.totalBytes, let last = lastTotalBytes,
            Double(abs(total - last)) > Double(max(total, last)) * 0.5
        {
            highestOverallFraction = 0
        }
        if let total = sample.totalBytes {
            lastTotalBytes = total
        }
        let attemptRestarted = sample.receivedBytes < highestReceived
        let received = max(sample.receivedBytes, highestReceived)
        highestReceived = received
        let overallFraction = sample.overallFraction.map {
            highestOverallFraction = max(highestOverallFraction, $0)
            return highestOverallFraction
        }
        lock.unlock()
        inner(
            DownloadProgress(
                receivedBytes: received,
                totalBytes: sample.totalBytes,
                speed: attemptRestarted ? nil : sample.speed,
                overallFraction: overallFraction
            ))
    }
}

/// Internal (not private): deterministic tests of the cancellation race and
/// the output-channel fallback path (§8) need to inject failing PTY/pipe
/// setup and the launch barrier directly.
final class YouTubeProcessOperation: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let control: @Sendable () -> DownloadControl
    private let progress: @Sendable (DownloadProgress) -> Void
    /// Fallback output channel when openpty fails: a bare pipe — write-end
    /// ownership goes to the session, the read end is held by the reader
    /// thread. Not Foundation's Pipe: it keeps an extra internal handle on
    /// the write end, so after the session closes its write end a hidden
    /// copy survives and the read end never reaches EOF.
    /// Master side of the pseudo-terminal used for yt-dlp output. The
    /// PyInstaller-built yt-dlp block-buffers stdout when it is a pipe
    /// (PYTHONUNBUFFERED does not survive Process.environment in release
    /// builds), which made all progress lines arrive in one burst at
    /// process exit. A PTY looks like a terminal to the child, so Python
    /// line-buffers stdout and progress streams in real time. -1 means
    /// openpty failed and the fallback pipe is in use.
    private var masterFD: Int32 = -1
    private var fallbackReadFD: Int32 = -1
    private var fallbackWriteFD: Int32 = -1
    private let lock = NSLock()
    /// Unified process-group lifecycle wrapper (§3): the dedicated group is
    /// established at spawn; cancel/pause/stall-timeout all signal the whole
    /// group; descendants are no longer chased dynamically from the root PID.
    private var session: ManagedToolSession?
    private var continuation: CheckedContinuation<YouTubeProcessOutput, Error>?
    private var exitStatus: Int32?
    private var output = Data()
    private var readerFinished = false
    private var finished = false
    private var stopReason: DownloadControl?
    private var timer: DispatchSourceTimer?
    private var startTime = Date()
    /// Timestamp of the most recent output bytes (any output, including
    /// metadata lines during the resolve phase). Stall detection is
    /// activity-based: a process that keeps printing is not stalled, even
    /// when no download progress appears yet.
    private var lastOutputTime = Date()
    private var sigkillScheduled = false
    /// Set when a stall/timeout kill is already in flight: the finish happens
    /// only after the whole process tree is reaped, so the 500 ms timer can
    /// fire again before `finished` flips and must not start a second kill.
    private var killInProgress = false
    /// Set by forceKill: the final resume must surface the stall error even
    /// though the termination path normally maps stopReason=.cancel to
    /// IDMError.cancelled. finishIfReady checks this before the control
    /// mapping so the continuation ends exactly once with the right error.
    private var forcedStalled = false
    /// Early terminal state when cancellation arrives before the
    /// continuation is registered: withTaskCancellationHandler's onCancel may
    /// run before withCheckedThrowingContinuation stores the continuation,
    /// and resuming directly would lose the wakeup; record the result and
    /// resume immediately upon registration — never hang.
    private var earlyTermination: Error?
    private var formatTotals: [(received: Int64, total: Int64?)] = []
    private var currentFormatIndex = -1
    private var lastFormatReceived: Int64 = 0
    /// Set by a "[download] Destination:" line: yt-dlp announces every new
    /// format (video track, then audio track) with it. The next progress
    /// sample opens a fresh accounting slot, which is far more reliable than
    /// inferring switches from byte drops — estimated ("~") totals jitter
    /// during a download and make the derived received count dip within a
    /// single format, which used to be misread as a format switch.
    private var pendingFormatSwitch = false
    /// Highest stage-aware fraction emitted by this process. Raw byte totals
    /// can grow when yt-dlp reveals the audio track after video reaches 100%;
    /// keeping this separate from byte accounting prevents the UI bar from
    /// moving backwards while size labels remain truthful.
    private var highestOverallFraction: Double = 0
    /// Throttle for the periodic "progress sample" debug log line.
    private var lastProgressLogAt = Date.distantPast

    /// Maximum wall-clock time for the yt-dlp process before forced kill.
    private static let maxProcessDuration: TimeInterval = 60 * 30  // 30 minutes
    /// Grace period after SIGTERM before escalating to SIGKILL.
    private static let sigkillGrace: TimeInterval = 5

    /// If no output of any kind arrives for this long, the process is
    /// considered stalled (e.g. stuck on a dead connection or signature
    /// decryption) and will be force-killed. The runner layers its own
    /// retry loop on top of this timeout.
    private let stallTimeout: TimeInterval
    /// Test seam: injectable failing PTY/pipe setup and launch barrier, so
    /// the cancellation race and channel-fallback paths can be covered
    /// deterministically.
    private let openPTY: @Sendable (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private let fallbackPipe: @Sendable (UnsafeMutablePointer<Int32>) -> Int32
    private let startBarrier: (() -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void,
        stallTimeout: TimeInterval = 300,
        openPTY: @escaping @Sendable (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32 = {
            master, slave in
            openpty(master, slave, nil, nil, nil)
        },
        fallbackPipe: @escaping @Sendable (UnsafeMutablePointer<Int32>) -> Int32 = { pipe($0) },
        startBarrier: (() -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.control = control
        self.progress = progress
        self.stallTimeout = stallTimeout
        self.openPTY = openPTY
        self.fallbackPipe = fallbackPipe
        self.startBarrier = startBarrier
    }

    func run() async throws -> YouTubeProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let early = earlyTermination {
                    // Cancellation already ended this run before the
                    // continuation was registered: resume immediately,
                    // never lose the wakeup.
                    lock.unlock()
                    continuation.resume(throwing: early)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                start()
            }
        } onCancel: {
            requestStop(.cancel)
        }
    }

    private func start() {
        // If onCancel fired before start() was reached (Task already
        // cancelled), stopReason is set but no session exists. Don't launch
        // yt-dlp at all — just resume the continuation immediately.
        lock.lock()
        if let reason = stopReason {
            lock.unlock()
            finish(throwing: reason == .pause ? IDMError.paused : IDMError.cancelled)
            return
        }
        lock.unlock()
        // Test seam: the barrier stalls between "first cancel check" and
        // "channel/session creation"; a cancellation arriving here
        // deterministically enters the mustAbort branch (§8.1).
        startBarrier?()
        startTime = Date()
        lastOutputTime = Date()
        var master: Int32 = 0
        var slave: Int32 = 0
        let outputFD: Int32
        if openPTY(&master, &slave) == 0 {
            masterFD = master
            outputFD = slave
            AppLogger.shared.info(.youtube, "yt-dlp output channel: pty")
        } else {
            // pipe()'s return code must be checked (§5.3): on failure the
            // `[0,0]` initial values must not be mistaken for pipes.
            var fds: [Int32] = [-1, -1]
            guard fallbackPipe(&fds) == 0 else {
                AppLogger.shared.error(
                    .youtube,
                    "yt-dlp output channel unavailable: pty and pipe failed errno=\(errno)"
                )
                finish(throwing: YouTubeDownloadError.toolLaunchFailed)
                return
            }
            fallbackReadFD = fds[0]
            fallbackWriteFD = fds[1]
            outputFD = fallbackWriteFD
            AppLogger.shared.info(.youtube, "yt-dlp output channel: pipe (openpty failed)")
        }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        // yt-dlp needs a JS runtime (node/deno) for YouTube's n challenge;
        // macOS apps inherit a minimal PATH that omits Homebrew etc.
        YTDlpManager.augmentEnvironmentForJSRuntime(&env)
        // The PyInstaller-built yt-dlp block-buffers stdout when it is a
        // pipe; force unbuffered Python output so progress streams in real
        // time.
        env["PYTHONUNBUFFERED"] = "1"
        // The session owns the output descriptor from here on and closes it
        // after the spawn attempt, so the master read reaches EOF exactly
        // when the whole group is gone. Both stdout and stderr share the
        // PTY/pipe channel (duplicate-safe in the session).
        let session = ManagedToolSession(
            executableURL: executableURL,
            arguments: arguments,
            environment: env,
            stdoutFileDescriptor: outputFD,
            stderrFileDescriptor: outputFD,
            terminationGrace: Self.sigkillGrace,
            settleBudget: 5.0
        )
        lock.lock()
        self.session = session
        let mustAbort = stopReason != nil
        lock.unlock()
        // Cancellation racing start(): the session never runs, so it will
        // not close the descriptor it was given — the creator reclaims every
        // end that never transferred (§8.3): the output write end and
        // whichever read end exists (PTY master or pipe-fallback read FD),
        // each closed exactly once. Closing only the master used to leak the
        // fallback read FD because the reader thread never starts here.
        if mustAbort {
            close(outputFD)
            if masterFD >= 0 {
                close(masterFD)
                masterFD = -1
            }
            if fallbackReadFD >= 0 {
                close(fallbackReadFD)
                fallbackReadFD = -1
            }
            finishWithStopReason()
            return
        }
        // The whole process-group lifecycle (normal exit/pause/cancel/stall
        // kill/timeout) is concluded by the session's single state machine;
        // this only maps the result back to download-layer semantics.
        Task { [weak self] in
            guard let self else { return }
            let outcome = await session.run(timeout: .infinity)
            self.handleOutcome(outcome)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Read with read(2) directly: FileHandle.readData(ofLength:)
            // blocks until the requested byte count accumulates (or EOF),
            // which held every progress line hostage until 4 KiB gathered
            // and recreated the 0% -> 100% jump even on a PTY.
            let readFD: Int32 = self.masterFD >= 0 ? self.masterFD : self.fallbackReadFD
            var pendingLine = ""
            readLoop: while true {
                var buffer = [UInt8](repeating: 0, count: 4096)
                // EINTR retries; other read errors are recorded as
                // diagnosable channel failures, never masquerading as normal
                // EOF (§8.2).
                let outcome = buffer.withUnsafeMutableBytes { raw in
                    ChannelReader.read(
                        fileDescriptor: readFD, buffer: raw.baseAddress!, count: raw.count)
                }
                guard case .bytes(let bytesRead) = outcome else {
                    if case .channelFailure(let code) = outcome {
                        self.lock.lock()
                        let alreadyDone = self.finished
                        self.lock.unlock()
                        if !alreadyDone {
                            AppLogger.shared.warning(
                                .youtube, "yt-dlp output channel failure errno=\(code)")
                        }
                    }
                    break readLoop
                }
                let data = Data(bytes: buffer, count: bytesRead)
                self.lock.lock()
                self.output.append(data)
                self.lastOutputTime = Date()
                self.lock.unlock()

                pendingLine += String(decoding: data, as: UTF8.self)
                // Split on both \n and \r. yt-dlp may use \r (carriage
                // return) for progress updates even with --newline, and
                // PTY line discipline translates \n into \r\n. Without
                // splitting on \r, progress lines accumulate in pendingLine
                // and are never parsed until a \n arrives.
                let lineSeparators = CharacterSet(charactersIn: "\n\r")
                while let sepRange = pendingLine.rangeOfCharacter(from: lineSeparators) {
                    let line = String(pendingLine[..<sepRange.lowerBound])
                    // Use suffix(from:) instead of removeSubrange(...) to
                    // avoid a ClosedRange<String.Index> crash when the
                    // separator is the last character (upperBound == endIndex).
                    pendingLine = String(pendingLine[sepRange.upperBound...])
                    if !line.isEmpty {
                        self.emitProgress(from: line)
                    }
                }
            }
            if !pendingLine.isEmpty {
                self.emitProgress(from: pendingLine)
            }
            if self.masterFD >= 0 {
                close(self.masterFD)
                self.masterFD = -1
            } else if self.fallbackReadFD >= 0 {
                close(self.fallbackReadFD)
                self.fallbackReadFD = -1
            }
            self.lock.lock()
            self.readerFinished = true
            self.lock.unlock()
            // Part of the session's completion gate: the output-channel EOF
            // must be reported back to the session, or its continuation
            // never ends.
            session.markReaderFinished()
            self.finishIfReady()
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            switch self.control() {
            case .continue:
                // Check for stall or overall timeout even when the user
                // hasn't requested pause/cancel. yt-dlp can hang silently
                // on player response, signature decryption, or SABR/UMP
                // protocol negotiation with no output and no exit.
                // Stall is measured against ANY output (metadata lines
                // count), so a busy resolve phase is never misjudged.
                let now = Date()
                let elapsed = now.timeIntervalSince(self.startTime)
                let stalled = now.timeIntervalSince(self.lastOutputTime)
                if elapsed > Self.maxProcessDuration || stalled > self.stallTimeout {
                    self.forceKill(
                        elapsed > Self.maxProcessDuration
                            ? String(localized: "YouTube 下载超时（超过 30 分钟）")
                            : String(localized: "YouTube 下载长时间无输出，可能已卡死"))
                    return
                }
            case .pause: self.requestStop(.pause)
            case .cancel: self.requestStop(.cancel)
            }
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func emitProgress(from rawLine: String) {
        // A PTY child may colorize output; strip ANSI escape sequences so
        // the parsers see plain text.
        let ansiStripped = rawLine.replacingOccurrences(
            of: "\u{1b}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        let line = ansiStripped.trimmingCharacters(in: .whitespacesAndNewlines)
        // Format boundary: yt-dlp prints a Destination line before each
        // track's progress starts. Remember it so the aggregator opens a new
        // accounting slot at the next progress sample.
        if line.hasPrefix("[download] Destination") {
            pendingFormatSwitch = true
            return
        }
        // Both parsers feed the same aggregation so sequential video+audio
        // formats accumulate instead of resetting the bar to zero.
        if let sample = Self.parseTemplateLine(line) ?? Self.parseDefaultProgressLine(line) {
            aggregateAndEmit(sample)
        }
    }

    private typealias ProgressSample = YTDlpProgressParser.ProgressSample

    private static func parseTemplateLine(_ line: String) -> ProgressSample? {
        YTDlpProgressParser.parseTemplateLine(line)
    }

    /// Aggregates byte accounting across the sequentially downloaded formats
    /// (video, then audio). Format boundaries come from the "[download]
    /// Destination:" lines; the byte-drop heuristic only remains as a
    /// fallback and requires a substantial drop, because estimated ("~")
    /// totals jitter and make the derived received count dip within a single
    /// format — every such dip used to be misread as a new format, inflating
    /// the reported total and corrupting the percentage.
    private func aggregateAndEmit(_ sample: ProgressSample) {
        // Format boundaries apply even to speed-only samples: a new format
        // that reports "of Unknown" never carries byte accounting, but its
        // slot must still open so the aggregate total becomes unknown
        // instead of reusing the previous format's size.
        let announcedSwitch = pendingFormatSwitch
        if announcedSwitch {
            currentFormatIndex += 1
            formatTotals.append((received: 0, total: nil))
            pendingFormatSwitch = false
        }
        // Byte accounting is optional: a speed-only sample (unknown total)
        // must never reset the aggregation, only refresh the speed.
        if let received = sample.received {
            let formatTotal = sample.total

            // Multi-format aggregation: yt-dlp downloads video and audio
            // formats sequentially. A real format restarts near zero, so a
            // drop past 50% is the fallback switch signal; small dips are
            // estimate jitter and stay within the current format. A switch
            // already announced by a Destination line is never applied twice.
            let substantialDrop =
                !announcedSwitch
                && lastFormatReceived > 0
                && Double(received) < Double(lastFormatReceived) * 0.5
            if currentFormatIndex >= 0 && substantialDrop {
                currentFormatIndex += 1
                formatTotals.append((received: 0, total: nil))
            } else if currentFormatIndex < 0 {
                currentFormatIndex = 0
                formatTotals.append((received: 0, total: nil))
            }
            lastFormatReceived = received
            if currentFormatIndex < formatTotals.count {
                formatTotals[currentFormatIndex].received = received
                // Capture the total once from the first reliable value so a
                // fluctuating "~" estimate never moves it. Two exceptions
                // replace the capture: the finished format's exact
                // "100% of X" line, and deviations beyond 50% — those are
                // not jitter ("~" estimates drift a few percent) but a
                // wrong capture, e.g. a tiny SABR side file fixing 1KiB
                // before the real stream's much larger totals arrive on
                // the same accounting slot.
                if let t = formatTotal, t > 0 {
                    let captured = formatTotals[currentFormatIndex].total
                    let isExactFinal = !sample.isEstimatedTotal && (sample.percent ?? 0) >= 100
                    let substantialCorrection =
                        captured.map { Double(abs(t - $0)) > Double(max(t, $0)) * 0.5 } ?? true
                    if captured == nil || isExactFinal || substantialCorrection {
                        formatTotals[currentFormatIndex].total = t
                        // A wrong capture poisons the fraction clamp too: the
                        // SABR 1KiB side file reports "100%" first, pinning
                        // highestOverallFraction at the stage ceiling (82%)
                        // and freezing the bar for the whole video track.
                        // When the capture is replaced by a substantially
                        // different total, re-derive the clamp — the
                        // stagedOverallFraction call below re-raises it to
                        // the honest value immediately.
                        if substantialCorrection && !isExactFinal {
                            highestOverallFraction = 0
                        }
                    }
                }
            }
        }

        let aggregateReceived = formatTotals.reduce(Int64(0)) { $0 + $1.received }
        // The overall total is only known once every discovered format has
        // reported one: a started format with an unknown size (SABR streams
        // report "of Unknown") would otherwise let a tiny completed side
        // file masquerade as the whole download's size, pinning progress
        // at >100%.
        let totalsKnown = !formatTotals.isEmpty && !formatTotals.contains { $0.total == nil }
        let aggregateTotal = totalsKnown ? formatTotals.reduce(Int64(0)) { $0 + ($1.total ?? 0) } : 0
        let totalBytes: Int64? = aggregateTotal > 0 ? aggregateTotal : nil
        let overallFraction: Double?
        if formatTotals.indices.contains(currentFormatIndex) {
            overallFraction = stagedOverallFraction(
                received: formatTotals[currentFormatIndex].received,
                total: formatTotals[currentFormatIndex].total,
                formatIndex: currentFormatIndex
            )
        } else {
            // Some yt-dlp versions emit a speed-only line before the first
            // usable byte sample or Destination announcement.
            overallFraction = nil
        }

        progress(
            DownloadProgress(
                receivedBytes: aggregateReceived,
                totalBytes: totalBytes,
                speed: sample.speed,
                overallFraction: overallFraction
            ))

        // Rate-limited visibility into what yt-dlp actually reports: one
        // sample line every 5s keeps the log useful for "progress stuck"
        // investigations without flooding it during fast downloads.
        let now = Date()
        if now.timeIntervalSince(lastProgressLogAt) >= 5 {
            lastProgressLogAt = now
            AppLogger.shared.debug(
                .youtube,
                "progress sample: received=\(aggregateReceived) total=\(totalBytes.map(String.init) ?? "unknown") speed=\(sample.speed.map { Int($0) }.map(String.init) ?? "nil")"
            )
        }
    }

    /// yt-dlp normally downloads a video track followed by an audio track.
    /// A per-track 100% line is therefore not whole-task completion. Give the
    /// first two tracks stable portions of the overall bar and retain a small
    /// tail for remux/verification. Single-file fallbacks reach 82% before
    /// post-processing instead of falsely flashing 100%.
    private func stagedOverallFraction(
        received: Int64,
        total: Int64?,
        formatIndex: Int
    ) -> Double? {
        YTDlpProgressParser.stagedOverallFraction(
            received: received,
            total: total,
            formatIndex: formatIndex,
            highestOverallFraction: &highestOverallFraction
        )
    }

    private static func parseDefaultProgressLine(_ line: String) -> ProgressSample? {
        YTDlpProgressParser.parseDefaultProgressLine(line)
    }

    private static func byteMultiplier(_ unit: String) -> Double {
        YTDlpProgressParser.byteMultiplier(unit)
    }

    /// Mapping point for the end of the session lifecycle: every completion
    /// path (normal exit, pause, cancel, stall kill, timeout, launch
    /// failure, cleanup failure) enters the existing finish gate here.
    private func handleOutcome(_ outcome: ManagedToolOutcome) {
        if outcome.launchFailed {
            // A launch failure only means "not installed" when the file is
            // actually missing or not executable. Anything else (corrupt
            // binary, ENOEXEC, permissions) is a distinct launch failure —
            // mapping it to toolUnavailable told users to run
            // `brew install yt-dlp` on machines where yt-dlp was present.
            AppLogger.shared.error(
                .youtube,
                "yt-dlp process launch failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(outcome.launchFailureDescription) ?? "SANITIZE_FAILED")"
            )
            if FileManager.default.isExecutableFile(atPath: executableURL.path) {
                finish(throwing: YouTubeDownloadError.toolLaunchFailed)
            } else {
                finish(throwing: YouTubeDownloadError.toolUnavailable)
            }
            return
        }
        if outcome.cleanupFailed {
            // Cleanup-budget exhaustion is a diagnosable failure: never
            // silently treated as success, never routed into the stall
            // retry — terminate this download directly (§3).
            AppLogger.shared.error(.youtube, "yt-dlp toolCleanupFailed=true scope=download")
            finish(throwing: YouTubeDownloadError.processCleanupFailed)
            return
        }
        lock.lock()
        exitStatus = outcome.exitStatus ?? -1
        lock.unlock()
        finishIfReady()
    }

    /// Stopped before launch (pause/cancel arrived before launching): finish
    /// directly with the stop reason.
    private func finishWithStopReason() {
        lock.lock()
        let reason = stopReason
        lock.unlock()
        finish(throwing: reason == .pause ? IDMError.paused : IDMError.cancelled)
    }

    private func requestStop(_ reason: DownloadControl) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        let sessionRef = session
        let alreadyScheduled = sigkillScheduled
        sigkillScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        // Whole-group termination semantics (§3): SIGTERM the session's
        // dedicated process group; if it still has not exited after the
        // grace period, SIGKILL the whole group and wait for reaping. The
        // finish gate stays with the session (group empty + reader EOF)
        // via finishIfReady; if descendants still hold the PTY slave, the
        // master never sees EOF until they are killed — group membership is
        // unaffected by reparenting to launchd, so nothing is missed.
        guard let sessionRef else {
            finishWithStopReason()
            return
        }
        sessionRef.setTerminationGrace(Self.sigkillGrace)
        sessionRef.requestCancel()
    }

    /// Kills the entire process tree and fails the attempt with a
    /// stall/timeout error. Used when the stall/timeout detector fires.
    /// The continuation only resumes via finishIfReady — i.e. after the tree
    /// has exited and the output reader reached EOF — so the next retry
    /// attempt can never overlap a still-dying previous one.
    private func forceKill(_ message: String) {
        lock.lock()
        guard !finished, !killInProgress else {
            lock.unlock()
            return
        }
        killInProgress = true
        forcedStalled = true
        let sessionRef = session
        // Preserve whatever the stalled process did print so the runner's
        // final attempt can classify it (network signatures, login walls).
        // Overwrite unconditionally: a stalled attempt with no output must
        // not inherit a stale static output from an earlier attempt/task,
        // which would misclassify the stall (e.g. as videoUnavailable).
        let partial = String(decoding: self.output, as: UTF8.self)
        lock.unlock()
        YouTubeDownloadError.lastProcessOutput = partial
        AppLogger.shared.warning(.youtube, "YouTube download stalled or timed out: \(message)")
        guard let sessionRef else {
            finish(throwing: YouTubeDownloadError.stalled)
            return
        }
        // Short grace: a stalled process usually ignores SIGTERM, so
        // escalate quickly to a whole-group SIGKILL; afterwards the
        // session's completion gate (group empty + reader EOF) concludes
        // via finishIfReady.
        sessionRef.setTerminationGrace(1.0)
        sessionRef.requestCancel()
    }

    private func finishIfReady() {
        lock.lock()
        guard !finished, readerFinished, let exitStatus else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let output = String(decoding: self.output, as: UTF8.self)
        let reason = stopReason
        let stalled = forcedStalled
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        if stalled {
            // Stall/timeout kill takes finish priority over the pause/cancel
            // mapping: keeps the termination path from misreporting an
            // internal timeout as a user cancel.
            continuation?.resume(throwing: YouTubeDownloadError.stalled)
        } else if case .pause? = reason {
            continuation?.resume(throwing: IDMError.paused)
        } else if case .cancel? = reason {
            continuation?.resume(throwing: IDMError.cancelled)
        } else {
            continuation?.resume(returning: YouTubeProcessOutput(exitStatus: exitStatus, text: output))
        }
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            // Cancellation arrived before the continuation was registered:
            // record the terminal state and resume immediately upon
            // registration.
            earlyTermination = error
        }
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(throwing: error)
    }
}
