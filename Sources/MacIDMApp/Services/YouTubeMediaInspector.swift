import Foundation
import IDMEngine

extension MediaInspectionError {
    /// Stable classification code shared by diagnostic events and protocol
    /// error codes (matching the MEDIA_* mapping in AppModel). Used for
    /// logging/diagnostics only, never carrying raw output.
    var diagnosticCode: String {
        switch self {
        case .unsupportedLiveStream: "MEDIA_UNSUPPORTED"
        case .liveStatusUnknown: "MEDIA_LIVE_STATUS_UNKNOWN"
        case .invalidPlaylist: "MEDIA_INVALID"
        case .youTubeToolUnavailable: "MEDIA_TOOL_UNAVAILABLE"
        case .authenticationRequired: "MEDIA_AUTH_REQUIRED"
        case .cookieContextUnavailable: "MEDIA_COOKIE_UNAVAILABLE"
        case .networkOrProxyFailure: "MEDIA_NETWORK_FAILURE"
        case .toolUpdateSuggested: "MEDIA_TOOL_UPDATE_SUGGESTED"
        case .noFormats: "MEDIA_NO_FORMATS"
        case .processCleanupFailed: "MEDIA_CLEANUP_FAILED"
        }
    }
}

/// Inspects YouTube pages by invoking `yt-dlp -J --simulate` to list
/// available formats without downloading. The returned variants match
/// the same `MediaVariant` shape used by HLS/DASH inspectors so the
/// browser extension Popup can display them identically.
///
/// YouTube is not a `DownloadSourceKind` case (it is a `DownloadBackend`),
/// so this inspector is used directly by `AppModel.inspectBrowserMedia`
/// when `mediaKind == "youtube"` rather than going through
/// `CompositeMediaInspector`.
struct YouTubeMediaInspector: MediaInspecting {
    private let executableURL: URL?
    /// Dual-channel diagnostic log; injected so unit tests never touch the
    /// user's real private log file.
    private let diagnosticLog: YouTubeDiagnosticEventLog

    init(
        executableURL: URL? = nil,
        diagnosticLog: YouTubeDiagnosticEventLog = .shared
    ) {
        self.executableURL =
            executableURL
            ?? Self.locateExecutable(environment: ProcessInfo.processInfo.environment)
        self.diagnosticLog = diagnosticLog
    }

    var isExecutableAvailable: Bool { executableURL != nil }

    func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        guard let executableURL else {
            throw MediaInspectionError.youTubeToolUnavailable
        }
        guard Self.isYouTubePage(url) else {
            throw MediaInspectionError.invalidPlaylist(String(localized: "URL 不是 YouTube 页面"))
        }

        let inspectStart = Date()
        let (exitStatus, output, stderr, cookieMode) = try await runListFormats(
            executableURL: executableURL,
            url: url,
            requestContext: requestContext
        )

        guard exitStatus == 0 else {
            // Raw stderr may contain URLs, query parameters, paths, or
            // signature context — never passed through: classify into a
            // finite, structured, localized error category first; only the
            // category itself (with its safe wording) crosses the Bridge
            // (see the YouTube inspection section of the public technical specification).
            let category = Self.classifyProcessFailure(stderr: stderr, exitStatus: exitStatus)
            // Inspection failures share the same structured events and dual
            // logs as download failures: the ordinary log carries only the
            // safe summary; the private log keeps the full URL and raw stderr
            // under the same event id (see the diagnostics section of the public technical specification).
            recordInspectDiagnostic(
                url: url,
                requestContext: requestContext,
                event: "media.inspectFailed",
                category: category.diagnosticCode,
                exitStatus: exitStatus,
                cookieFileCreated: cookieMode == .explicitFile,
                startedAt: inspectStart,
                output: stderr
            )
            throw category
        }

        guard let data = output.data(using: .utf8) else {
            throw MediaInspectionError.invalidPlaylist(String(localized: "yt-dlp 未返回有效文本"))
        }

        let info: YouTubeVideoInfo
        do {
            info = try JSONDecoder().decode(YouTubeVideoInfo.self, from: data)
        } catch {
            throw MediaInspectionError.invalidPlaylist(String(localized: "无法解析 yt-dlp 输出"))
        }

        // Live semantics share the same classification as the execution layer
        // (§3.3 / round 2 §P1-2): currently live, upcoming, and
        // not-yet-generated replays are blocked at inspection;
        // missing/contradictory/unknown-enum fields become unknown, equally
        // blocked, mapped to a retryable inspection error; only explicit
        // ended replays and plain VOD proceed.
        let livePhase = YouTubeLiveClassifier.phase(
            YouTubeLiveState(
                isLive: info.isLive, wasLive: info.wasLive, liveStatus: info.liveStatus))
        if YouTubeLiveClassifier.isBlocked(livePhase) {
            AppLogger.shared.warning(
                .youtube,
                "media.inspect blocked live content phase=\(livePhase.rawValue) host=\(hostOf(url))"
            )
            throw MediaInspectionError.unsupportedLiveStream
        }
        guard YouTubeLiveClassifier.isAllowed(livePhase) else {
            AppLogger.shared.warning(
                .youtube,
                "media.inspect live status unknown phase=\(livePhase.rawValue) host=\(hostOf(url))"
            )
            throw MediaInspectionError.liveStatusUnknown
        }

        let variants = buildVariants(from: info, pageURL: url)
        guard !variants.isEmpty else {
            throw MediaInspectionError.noFormats
        }

        return MediaInspection(mediaKind: .http, variants: variants)
    }

    // MARK: - Variant construction

    private func buildVariants(from info: YouTubeVideoInfo, pageURL: URL) -> [MediaVariant] {
        let videoFormats = info.formats.filter { format in
            let codec = format.vcodec ?? "none"
            return codec != "none" && codec != "None" && (format.height ?? 0) > 0
        }

        return
            videoFormats
            .sorted { lhs, rhs in
                (rhs.height ?? 0, rhs.tbr ?? 0) < (lhs.height ?? 0, lhs.tbr ?? 0)
            }
            .prefix(20)
            .map { format in
                let bandwidth = Self.bandwidth(from: format)
                // Estimates align with the download side's actual selection:
                // with a verified itag, computed from that track's own size
                // (plus the best m4a audio track when audio is missing);
                // without an itag, falls back to the resolution-based
                // `bv*[ext=mp4][height<=h]+ba[ext=m4a]` scheme.
                let estimatedSize = Self.estimatedSize(for: format, in: info)
                // Unified slot grammar (resolution · frame rate · codec family ·
                // bitrate); size and container format stay out of the label and
                // are shown in the confirmation window's dedicated slots.
                let label = MediaVariantLabel.format(
                    width: format.width,
                    height: format.height,
                    fps: format.fps,
                    codecs: Self.codecsString(vcodec: format.vcodec, acodec: format.acodec),
                    bandwidth: bandwidth
                )

                // Encode the selection into a MacIDM-owned URL fragment so
                // the download path locks yt-dlp to exactly this quality:
                // `height` keeps the resolution-only compat path, and the
                // verified itag makes same-resolution codec/container picks
                // resolve to genuinely different formats. URLComponents
                // replaces any page fragment (e.g. `#t=90`) instead of
                // concatenating a second one.
                var variantURL = pageURL
                if let height = format.height,
                    var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
                {
                    var fragment = "height=\(height)"
                    if let itag = Self.validITag(format.formatId) {
                        fragment += "&itag=\(itag)"
                        if Self.hasAudioCodec(format.acodec) {
                            fragment += "&a=1"
                        }
                    }
                    components.fragment = fragment
                    variantURL = components.url ?? pageURL
                }

                return MediaVariant(
                    url: variantURL,
                    label: label,
                    bandwidth: bandwidth,
                    width: format.width,
                    height: format.height,
                    codecs: Self.codecsString(
                        vcodec: format.vcodec,
                        acodec: format.acodec
                    ),
                    estimatedSize: estimatedSize,
                    fileExtension: format.ext,
                    duration: info.duration
                )
            }
    }

    // MARK: - Title lookup

    /// Resolves the video title without downloading, used by submission
    /// paths that lack a browser page title (e.g. the agent control API).
    /// Returns nil when yt-dlp is missing or the lookup fails; callers are
    /// expected to fall back to a generic filename.
    func fetchTitle(
        url: URL,
        requestContext: DownloadRequestContext? = nil
    ) async -> String? {
        guard let executableURL, Self.isYouTubePage(url) else { return nil }
        // The height-selection fragment is stripped by the download runner;
        // it would only confuse the metadata lookup here.
        var lookupURL = url
        if url.fragment != nil,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.fragment = nil
            lookupURL = components.url ?? url
        }
        var arguments = [
            "--get-title",
            "--simulate",
            "--skip-download",
            "--no-warnings",
            "--no-playlist",
            "--ignore-config",
            "--no-cache-dir",
        ]
        if let userAgent = requestContext?.userAgent, !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = requestContext?.referer, !referer.isEmpty {
            arguments += ["--add-headers", "Referer: \(referer)"]
        }
        let cookieFile = try? writeCookieFile(requestContext?.cookie, domain: hostOf(lookupURL))
        if let cookieFile {
            arguments += ["--cookies", cookieFile.path]
        }
        defer {
            if let cookieFile {
                try? FileManager.default.removeItem(at: cookieFile)
            }
        }
        if let proxyURL = YTDlpManager.currentProxyURLString() {
            arguments += ["--proxy", proxyURL]
        }
        arguments += [lookupURL.absoluteString]

        guard
            let (exitStatus, output, _) = try? await YouTubeInspectProcess(
                executableURL: executableURL,
                arguments: arguments
            ).run(timeout: Self.titleTimeout),
            exitStatus == 0
        else { return nil }
        let title = output.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return title
    }

    // MARK: - yt-dlp process

    /// How cookies were actually supplied to yt-dlp for this inspection;
    /// used only by the safe diagnostic log (see the public technical specification), never in
    /// protocol messages.
    enum CookieMode: String {
        /// The extension supplied a cookie context and the temp cookie file
        /// was created.
        case explicitFile
        /// No cookie was supplied; yt-dlp runs anonymously (no Chrome DB read).
        case anonymous
    }

    private func runListFormats(
        executableURL: URL,
        url: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> (Int32, String, String, CookieMode) {
        var arguments = [
            "-J",
            "--simulate",
            "--no-warnings",
            "--no-playlist",
            "--ignore-config",
            "--no-cache-dir",
        ]
        if let userAgent = requestContext?.userAgent, !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = requestContext?.referer, !referer.isEmpty {
            arguments += ["--add-headers", "Referer: \(referer)"]
        }

        let cookieFile = try writeCookieFile(requestContext?.cookie, domain: hostOf(url))
        if let cookieFile {
            arguments += ["--cookies", cookieFile.path]
        }
        let cookieMode: CookieMode = cookieFile != nil ? .explicitFile : .anonymous
        defer {
            if let cookieFile {
                do {
                    try FileManager.default.removeItem(at: cookieFile)
                    AppLogger.shared.debug(.youtube, "media.inspect cookieFileCleaned=true")
                } catch {
                    AppLogger.shared.warning(.youtube, "media.inspect cookieFileCleaned=false")
                }
            }
        }
        // Record only boolean state, mode, and byte counts — never cookie
        // contents (see the public technical specification). cookieSupplied distinguishes "the
        // extension attached no cookie" from "a cookie was attached but the
        // temp file failed and was cleaned to empty".
        AppLogger.shared.debug(
            .youtube,
            "media.inspect cookieSupplied=\(requestContext?.cookie?.isEmpty == false)"
                + " cookieBytes=\(requestContext?.cookie?.utf8.count ?? 0)"
                + " cookieFileCreated=\(cookieFile != nil)"
                + " cookieMode=\(cookieMode.rawValue)"
        )
        if let proxyURL = YTDlpManager.currentProxyURLString() {
            arguments += ["--proxy", proxyURL]
        }

        arguments += [url.absoluteString]

        let (exitStatus, output, stderr) = try await YouTubeInspectProcess(
            executableURL: executableURL,
            arguments: arguments
        ).run(timeout: Self.inspectTimeout)
        return (exitStatus, output, stderr, cookieMode)
    }

    /// Classifies a failed yt-dlp output into a stable error category. Raw
    /// stderr may contain URLs, query parameters, paths, or other sensitive
    /// context and never enters error messages or logs — only the category
    /// itself (with its safe localized wording) crosses the Bridge.
    private static func classifyProcessFailure(
        stderr: String,
        exitStatus: Int32
    ) -> MediaInspectionError {
        let text = stderr.lowercased()

        // Process killed on timeout (conventional exit code -1): presented
        // as a network/proxy failure.
        if exitStatus < 0 {
            return .networkOrProxyFailure
        }

        // The cookie context itself is unusable by yt-dlp (temp-file format
        // or read failure), not a video or network problem: classified as
        // cookieContextUnavailable so the extension prompts the user to
        // check the site session (see the YouTube inspection section of the public technical specification).
        if text.contains("invalid netscape format")
            || text.contains("could not find cookie file")
            || text.contains("unable to read cookie")
        {
            return .cookieContextUnavailable
        }

        // Sign-in, bot check, age, or membership restrictions.
        if text.contains("sign in to confirm")
            || text.contains("not a bot")
            || text.contains("please sign in")
            || text.contains("sign in to continue")
            || text.contains("login required")
            || text.contains("age-restricted")
            || text.contains("confirm your age")
            || text.contains("members-only")
            || text.contains("members only")
            || text.contains("private video")
        {
            return .authenticationRequired
        }

        // The video itself is unavailable.
        if text.contains("video unavailable")
            || text.contains("this video is not available")
            || text.contains("video has been removed")
        {
            return .invalidPlaylist(String(localized: "视频不可用或已删除"))
        }

        // Network unreachable, proxy error, or timeout.
        if text.contains("timed out")
            || text.contains("timeout")
            || text.contains("connection refused")
            || text.contains("connection reset")
            || text.contains("failed to resolve")
            || text.contains("getaddrinfo")
            || text.contains("name or service not known")
            || text.contains("network is unreachable")
            || text.contains("no route to host")
            || text.contains("temporary failure")
            || text.contains("unable to download")
            || text.contains("proxy")
            || text.contains("http error 5")
        {
            return .networkOrProxyFailure
        }

        // The error evidence clearly points to outdated extraction rules
        // (player JS changes breaking signature/n-variable solving).
        if text.contains("nsig extraction failed")
            || text.contains("signature extraction failed")
            || text.contains("update yt-dlp")
            || text.contains("unable to extract")
        {
            return .toolUpdateSuggested
        }

        return .invalidPlaylist(String(localized: "yt-dlp 解析失败（退出码 \(exitStatus)）"))
    }

    // MARK: - Diagnostics

    /// Inspection failures share the same structured events as download
    /// failures: the ordinary log carries only the safe summary; the private
    /// log keeps the full URL and raw output under the same event id (raw
    /// output must never be returned over the Bridge/UI (see the diagnostics section of the public technical specification).
    private func recordInspectDiagnostic(
        url: URL,
        requestContext: DownloadRequestContext?,
        event: String,
        category: String,
        exitStatus: Int32?,
        cookieFileCreated: Bool,
        startedAt: Date,
        output: String
    ) {
        let fullURL = url.absoluteString
        diagnosticLog.record(
            YouTubeDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: event,
                stage: "inspect",
                taskID: nil,
                category: category,
                exitStatus: exitStatus,
                attempt: nil,
                durationMs: Int64(Date().timeIntervalSince(startedAt) * 1000),
                ytDlpVersion: YTDlpManager.currentVersionSync(),
                cookieSupplied: requestContext?.cookie?.isEmpty == false,
                cookieCount: requestContext?.cookie.flatMap {
                    $0.isEmpty ? nil : $0.split(separator: ";", omittingEmptySubsequences: true).count
                },
                cookieFileCreated: cookieFileCreated,
                proxyConfigured: YTDlpManager.currentProxyURLString() != nil,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(fullURL),
                resourceFingerprint: DiagnosticFingerprint.resource(
                    videoID: YouTubeDownloadRunner.youTubeVideoID(from: url),
                    itag: nil
                ),
                sanitizedExcerpt: YouTubeOutputSanitizer.sanitizedExcerpt(from: output),
                fullURL: fullURL,
                cookieFilePath: nil,
                rawOutput: YouTubeOutputSanitizer.redactCredentials(in: output)
            )
        )
    }

    // MARK: - Helpers

    /// YouTube extraction must solve JS challenges and can take 60–90 s in
    /// practice; a shorter budget would kill the process before output
    /// completes, causing systematic misclassification. Stays below the
    /// extension's 90 s budget.
    private static let inspectTimeout: TimeInterval = 85

    /// Title lookups go through the same player resolution as downloads;
    /// the budget matches the inspect timeout for the same reason.
    private static let titleTimeout: TimeInterval = 85

    private static func bandwidth(from format: YouTubeFormat) -> Int? {
        if let tbr = format.tbr, tbr > 0 {
            return Int(tbr * 1000)
        }
        if let vbr = format.vbr, vbr > 0 {
            return Int(vbr * 1000)
        }
        return nil
    }

    private func writeCookieFile(_ cookie: String?, domain: String) throws -> URL? {
        guard let cookie, !cookie.isEmpty else { return nil }
        // The Netscape format asserts that a domain with domain_specified=TRUE
        // must start with "." (http.cookiejar._really_load), or yt-dlp rejects
        // the whole cookie file with "invalid Netscape format cookies file"
        // and exit code 1. With a leading dot, cookies are sent to that host
        // and its subdomains, covering all of yt-dlp's requests to the page
        // host (www.youtube.com pages and the youtubei API share the domain).
        let cookieDomain = "." + domain
        let rows = cookie.split(separator: ";", omittingEmptySubsequences: true).compactMap { raw -> String? in
            let pair = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard !name.isEmpty, !name.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }),
                !value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" })
            else { return nil }
            return "\(cookieDomain)\tTRUE\t/\tTRUE\t0\t\(name)\t\(value)"
        }
        guard !rows.isEmpty else { return nil }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-youtube-inspect", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Per-inspect filename: concurrent inspections (popup + overlay, or
        // multiple tabs) must not overwrite each other's cookie file, and
        // one inspection's cleanup must not delete another's in-flight file.
        let fileURL = tempDir.appendingPathComponent("cookies-\(UUID().uuidString).txt")
        let body =
            "# Netscape HTTP Cookie File\n" + rows.joined(separator: "\n") + "\n"
        guard
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: body.data(using: .utf8),
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw MediaInspectionError.cookieContextUnavailable
        }
        return fileURL
    }

    private func hostOf(_ url: URL) -> String {
        url.host ?? "localhost"
    }

    // MARK: - Generic (non-YouTube) extraction

    /// What the generic fallback needs from `yt-dlp -J`: the resolved media
    /// URL plus display metadata. Every other site supported by yt-dlp's
    /// extractor library flows through this same shape.
    struct GenericExtraction: Sendable {
        let mediaURL: URL
        let title: String?
        let estimatedSize: Int64?
        let duration: TimeInterval?
    }

    /// Runs yt-dlp's generic extraction against any URL. Used as a fallback
    /// when the regular page probe finds no media candidates — yt-dlp
    /// understands thousands of sites' player-embedded media URLs.
    func inspectGeneric(
        url: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> GenericExtraction? {
        guard let executableURL else { return nil }
        var arguments = [
            "-J",
            "--simulate",
            "--no-warnings",
            "--no-playlist",
            "--ignore-config",
            "--no-cache-dir",
        ]
        if let userAgent = requestContext?.userAgent, !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = requestContext?.referer, !referer.isEmpty {
            arguments += ["--add-headers", "Referer: \(referer)"]
        }
        // Explicit cookie file only — never the Chrome store, which would
        // leak credentials to arbitrary third-party hosts.
        let cookieFile = try writeCookieFile(requestContext?.cookie, domain: hostOf(url))
        if let cookieFile {
            arguments += ["--cookies", cookieFile.path]
        }
        defer {
            if let cookieFile {
                try? FileManager.default.removeItem(at: cookieFile)
            }
        }
        if let proxyURL = YTDlpManager.currentProxyURLString() {
            arguments += ["--proxy", proxyURL]
        }
        arguments += [url.absoluteString]

        let inspectStart = Date()
        let (exitStatus, output, stderr) = try await YouTubeInspectProcess(
            executableURL: executableURL,
            arguments: arguments
        ).run(timeout: Self.inspectTimeout)
        // Generic-fallback failures also go to the dual logs, so private
        // diagnostics exist beyond the main download path
        // (see the diagnostics section of the public technical specification). Returning nil keeps the original semantics:
        // the caller degrades to no candidates.
        guard exitStatus == 0 else {
            recordInspectDiagnostic(
                url: url,
                requestContext: requestContext,
                event: "media.genericInspectFailed",
                category: MediaInspectionError.invalidPlaylist("").diagnosticCode,
                exitStatus: exitStatus,
                cookieFileCreated: cookieFile != nil,
                startedAt: inspectStart,
                output: stderr
            )
            return nil
        }
        guard let data = output.data(using: .utf8),
            let info = try? JSONDecoder().decode(GenericVideoInfo.self, from: data),
            let mediaURL = info.url.flatMap(URL.init(string:)),
            mediaURL.scheme == "http" || mediaURL.scheme == "https"
        else { return nil }
        let size = (info.filesize ?? info.filesizeApprox).flatMap { $0 > 0 ? $0 : nil }
        return GenericExtraction(
            mediaURL: mediaURL,
            title: info.title,
            estimatedSize: size,
            duration: info.duration
        )
    }

    /// Mirrors the download runner's selector semantics for the variant the
    /// user actually picks: with a verified itag the estimate is that track's
    /// own size plus the best m4a audio whenever the pick is video-only;
    /// without an itag it falls back to the height-capped
    /// `bv*[ext=mp4]+ba[ext=m4a]` mirror. Exact filesizes win; missing
    /// values fall back to duration * bitrate.
    private static func estimatedSize(for format: YouTubeFormat, in info: YouTubeVideoInfo) -> Int64? {
        guard validITag(format.formatId) != nil else {
            return mergedEstimatedSize(
                formats: info.formats,
                heightCap: format.height,
                duration: info.duration
            )
        }
        guard let videoSize = trackSize(of: format, duration: info.duration) else { return nil }
        if hasAudioCodec(format.acodec) { return videoSize }
        return videoSize + bestAudioTrackSize(formats: info.formats, duration: info.duration)
    }

    /// YouTube itags are pure digits; only such verified ids may travel in
    /// the variant fragment (the download runner re-validates before
    /// building the yt-dlp selector — page strings are never concatenated
    /// into command arguments).
    static func validITag(_ formatId: String?) -> Int? {
        guard let formatId, (1...5).contains(formatId.count),
            formatId.allSatisfy(\.isNumber), let value = Int(formatId), value > 0
        else { return nil }
        return value
    }

    private static func mergedEstimatedSize(
        formats: [YouTubeFormat],
        heightCap: Int?,
        duration: TimeInterval?
    ) -> Int64? {
        let cap = heightCap ?? 0
        let capped = formats.filter { format in
            let hasVideo = Self.isVideoCodec(format.vcodec) && (format.height ?? 0) > 0
            return hasVideo && (cap <= 0 || (format.height ?? 0) <= cap)
        }
        // Missing acodec counts as audio-less (video-only); yt-dlp only
        // writes the literal "none" when it actively detected no audio.
        let videoOnly = capped.filter { !Self.hasAudioCodec($0.acodec) }
        let progressive = capped.filter { Self.hasAudioCodec($0.acodec) }

        func best(_ pool: [YouTubeFormat]) -> YouTubeFormat? {
            pool.max {
                ($0.height ?? 0, $0.tbr ?? 0) < ($1.height ?? 0, $1.tbr ?? 0)
            }
        }

        // Selector order: mp4 video-only (+audio), mp4 progressive,
        // any video-only (+audio), any progressive.
        if let pick = best(videoOnly.filter({ $0.ext == "mp4" })),
            let size = trackSize(of: pick, duration: duration)
        {
            return size + bestAudioTrackSize(formats: formats, duration: duration)
        }
        if let pick = best(progressive.filter({ $0.ext == "mp4" })),
            let size = trackSize(of: pick, duration: duration)
        {
            return size
        }
        if let pick = best(videoOnly),
            let size = trackSize(of: pick, duration: duration)
        {
            return size + bestAudioTrackSize(formats: formats, duration: duration)
        }
        if let pick = best(progressive) {
            return trackSize(of: pick, duration: duration)
        }
        return nil
    }

    /// Best audio-only track size, preferring m4a to match `ba[ext=m4a]`.
    /// Returns 0 when no audio track can be sized — an audio-less estimate
    /// still beats none, and the missing share is typically under 5%.
    private static func bestAudioTrackSize(
        formats: [YouTubeFormat],
        duration: TimeInterval?
    ) -> Int64 {
        let audios = formats.filter {
            !Self.isVideoCodec($0.vcodec) && Self.hasAudioCodec($0.acodec)
        }
        let m4a = audios.filter { $0.ext == "m4a" }
        let pool = m4a.isEmpty ? audios : m4a
        guard let audio = pool.max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }) else { return 0 }
        return trackSize(of: audio, duration: duration) ?? 0
    }

    /// yt-dlp marks absent codecs with the literal string "none".
    private static func isVideoCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec != "none" && codec != "None"
    }

    /// Same "none" convention for audio tracks, except a missing field is
    /// treated as audio-less rather than audio-present.
    private static func hasAudioCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec != "none" && codec != "None"
    }

    private static func trackSize(of format: YouTubeFormat, duration: TimeInterval?) -> Int64? {
        if let size = format.filesize, size > 0 { return size }
        if let size = format.filesizeApprox, size > 0 { return size }
        if let duration, duration > 0, let tbr = format.tbr, tbr > 0 {
            return Int64((duration * tbr * 1000 / 8).rounded())
        }
        return nil
    }

    private static func codecsString(vcodec: String?, acodec: String?) -> String? {
        var parts: [String] = []
        if let vcodec, vcodec != "none", vcodec != "None" {
            parts.append(vcodec)
        }
        if let acodec, acodec != "none", acodec != "None" {
            parts.append(acodec)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    static func isYouTubePage(_ url: URL) -> Bool {
        guard
            let host = url.host?.lowercased().replacingOccurrences(
                of: "^www\\.", with: "", options: .regularExpression
            )
        else { return false }
        if host == "youtu.be" {
            // Require an actual video-ID path component; "/" alone is not a
            // video page and would only fail deep inside yt-dlp.
            // "/<id>" splits to a single component — no leading empty
            // segment to drop.
            let videoID = url.path.split(separator: "/").first.map(String.init)
            return Self.isValidVideoID(videoID)
        }
        // /live/<id> is a single-video page like /watch and /shorts: ended
        // live replays go through the same inspection chain; an ongoing live
        // stream is classified by yt-dlp's own error as a live-type error, so
        // the discovery layer neither pre-creates candidates doomed to fail
        // nor silently drops downloadable replays. Bare prefix paths without
        // a video ID (/live/, /shorts/) do not count as video pages.
        return (host == "youtube.com" || host.hasSuffix(".youtube.com"))
            && Self.isSingleVideoURL(url)
    }

    /// Single-video-page check (§4.5): `/watch` must carry a valid `v`
    /// parameter; otherwise shallow acceptance and deep rejection would
    /// return different error categories from different entry points. The
    /// execution layer (YouTubeDownloadRunner) delegates to this same
    /// implementation so both layers agree.
    static func isSingleVideoURL(_ url: URL) -> Bool {
        let path = url.path
        if path == "/watch" {
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "v" }?
                .value
            return isValidVideoID(v)
        }
        for prefix in ["/shorts/", "/live/"] where path.hasPrefix(prefix) {
            // Only the first segment is the ID (matching the extension's
            // regex); extra path segments do not participate.
            let component = String(path.dropFirst(prefix.count))
                .split(separator: "/").first.map(String.init)
            return isValidVideoID(component)
        }
        return false
    }

    /// Minimal video-ID rules (§4.3, mirroring the extension's
    /// youTubeVideoIDFromURL): conservative charset and a length floor
    /// (≥5); not the strict 11 characters YouTube commonly uses today, to
    /// avoid rejecting historical short IDs. Missing/malformed IDs map
    /// stably to MEDIA_INVALID at the entry point without calling yt-dlp.
    static func isValidVideoID(_ candidate: String?) -> Bool {
        guard let candidate, candidate.count >= 5 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return candidate.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func locateExecutable(environment: [String: String]) -> URL? {
        // Delegate to YTDlpManager so inspection shares the app-wide
        // resolution order (env override → managed update → bundled →
        // system installs).
        YTDlpManager.locateExecutable(environment: environment)
    }

}

// MARK: - yt-dlp inspect process

/// Runs `yt-dlp -J` through the shared `ManagedToolSession` lifecycle:
/// dedicated process group at spawn, explicit state machine (no
/// cancel-before-launch race), single finish gate, group-wide TERM→KILL.
/// Internal (not private): the download execution layer's live probe
/// reuses this same process wrapper.
final class YouTubeInspectProcess: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    /// Barrier for deterministic cancel-before-launch race testing: stalls
    /// the launch path between "launching recorded" and "actually spawned"
    /// (see the public technical specification).
    private let launchBarrier: (() -> Void)?
    private let session: ManagedToolSession
    /// Incrementally read output buffers: the full `-J` JSON can reach
    /// several MB, far beyond the pipe buffer; reading the pipes only after
    /// the process exits would leave yt-dlp stuck in write-blocking until
    /// timeout.
    private let dataLock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var readersFinished = 0

    init(
        executableURL: URL,
        arguments: [String],
        launchBarrier: (() -> Void)? = nil,
        terminationGrace: TimeInterval = 3.0,
        settleBudget: TimeInterval = 5.0,
        groupLivenessProbe: (@Sendable (pid_t) -> ProcessTree.GroupState)? = nil
    ) throws {
        self.executableURL = executableURL
        self.arguments = arguments
        self.launchBarrier = launchBarrier
        // A pipe() failure must surface explicitly (§5.3): the initial
        // `[0, 0]` values must not be mistaken for pipes, or later code
        // would close stdin and break the completion gate.
        let pipes = try Self.makeOutputPipes()
        // The session owns the write ends and closes them after spawn; the
        // reader threads below own the read ends.
        session = ManagedToolSession(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.toolEnvironment(),
            stdoutFileDescriptor: pipes.stdout[1],
            stderrFileDescriptor: pipes.stderr[1],
            terminationGrace: terminationGrace,
            settleBudget: settleBudget,
            launchBarrier: launchBarrier,
            groupLivenessProbe: groupLivenessProbe
        )
        startReader(fileDescriptor: pipes.stdout[0], isStdout: true)
        startReader(fileDescriptor: pipes.stderr[0], isStdout: false)
    }

    /// Creates the two output pipes (§5.3): any `pipe()` failure raises a
    /// diagnosable error; when the second pipe fails, the first pipe's two
    /// FDs must be closed first — zero leaks. The `pipeCall` seam exists only
    /// for fault testing.
    static func makeOutputPipes(
        pipeCall: (UnsafeMutablePointer<Int32>) -> Int32 = { pipe($0) }
    ) throws -> (stdout: [Int32], stderr: [Int32]) {
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        guard pipeCall(&stdoutPipe) == 0 else {
            throw ManagedToolLaunchError(detail: "pipe(stdout) errno=\(errno)")
        }
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipeCall(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            throw ManagedToolLaunchError(detail: "pipe(stderr) errno=\(errno)")
        }
        return (stdoutPipe, stderrPipe)
    }

    private static func toolEnvironment() -> [String: String] {
        var overrides: [String: String] = [:]
        // yt-dlp needs a JS runtime (node/deno) for YouTube's n challenge.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        YTDlpManager.augmentEnvironmentForJSRuntime(&env)
        for (key, value) in env {
            overrides[key] = value
        }
        return overrides
    }

    /// Blocking-reads one pipe until EOF; EOF arrives only after the last
    /// write end in the group closes (the whole group is cleaned up) — it is
    /// part of the completion gate. EINTR retries; other read errors are
    /// recorded as diagnosable channel failures, never masquerading as
    /// normal EOF (§8.2).
    private func startReader(fileDescriptor: Int32, isStdout: Bool) {
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            readLoop: while true {
                let outcome = buffer.withUnsafeMutableBytes { raw in
                    ChannelReader.read(
                        fileDescriptor: fileDescriptor,
                        buffer: raw.baseAddress!,
                        count: raw.count
                    )
                }
                switch outcome {
                case .bytes(let count):
                    self?.append(Data(bytes: buffer, count: count), isStdout: isStdout)
                case .channelFailure(let code):
                    AppLogger.shared.warning(
                        .youtube, "media.inspect output channel failure errno=\(code)")
                    break readLoop
                case .endOfFile:
                    break readLoop
                }
            }
            close(fileDescriptor)
            self?.readerFinished()
        }
    }

    private func append(_ chunk: Data, isStdout: Bool) {
        dataLock.lock()
        if isStdout {
            stdoutData.append(chunk)
        } else {
            stderrData.append(chunk)
        }
        dataLock.unlock()
    }

    private func readerFinished() {
        dataLock.lock()
        readersFinished += 1
        let all = readersFinished >= 2
        dataLock.unlock()
        if all {
            session.markReaderFinished()
        }
    }

    func run(timeout: TimeInterval) async throws -> (Int32, String, String) {
        let outcome = await withTaskCancellationHandler(
            operation: {
                await session.run(timeout: timeout)
            },
            onCancel: {
                // Swift cancellation must really end the child process:
                // AppModel.withTimeout relies on cancelAll() to end the
                // operation immediately; otherwise the 15 s UI budget waits
                // for the longer internal process timeout. requestCancel is
                // safe in every state.
                self.session.requestCancel()
            }
        )
        if outcome.launchFailed {
            throw MediaInspectionError.youTubeToolUnavailable
        }
        if outcome.cancelled {
            throw CancellationError()
        }
        if outcome.cleanupFailed {
            // Cleanup-budget exhaustion is a blocking failure (§4): throw
            // immediately; title lookup, quality inspection, generic
            // fallback, and the live pre-check must not parse or merge this
            // tool run's output; blocking semantics match the download path
            // — never silently treated as success.
            AppLogger.shared.error(
                .youtube,
                "media.inspect toolCleanupFailed=true scope=inspect"
            )
            throw MediaInspectionError.processCleanupFailed
        }
        let (output, stderr) = decodedOutput()
        if outcome.timedOut {
            return (-1, output, stderr)
        }
        return (outcome.exitStatus ?? -1, output, stderr)
    }

    private func decodedOutput() -> (String, String) {
        dataLock.lock()
        defer { dataLock.unlock() }
        return (
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}

// MARK: - yt-dlp JSON model

private struct YouTubeVideoInfo: Decodable {
    let formats: [YouTubeFormat]
    /// Top-level duration (seconds), identical across quality variants;
    /// the per-format duration is often missing, so every variant is filled
    /// from here for the confirmation window and extension tooltip.
    let duration: TimeInterval?
    /// Live-semantics fields: distinguish currently
    /// live, upcoming, and ended replays.
    let isLive: Bool?
    let wasLive: Bool?
    let liveStatus: String?

    enum CodingKeys: String, CodingKey {
        case formats
        case duration
        case isLive = "is_live"
        case wasLive = "was_live"
        case liveStatus = "live_status"
    }
}

/// Flat `-J` payload fields shared by every extractor (generic fallback).
private struct GenericVideoInfo: Decodable {
    let url: String?
    let title: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let duration: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case filesize
        case filesizeApprox = "filesize_approx"
        case duration
    }
}

private struct YouTubeFormat: Decodable {
    let formatId: String?
    let ext: String?
    let width: Int?
    let height: Int?
    let vcodec: String?
    let acodec: String?
    let tbr: Double?
    let vbr: Double?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let resolution: String?
    let fps: Double?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext
        case width
        case height
        case vcodec
        case acodec
        case tbr
        case vbr
        case filesize
        case filesizeApprox = "filesize_approx"
        case resolution
        case fps
    }
}
