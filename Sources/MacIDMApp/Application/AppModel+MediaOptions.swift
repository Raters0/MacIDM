import Foundation
import IDMEngine

extension AppModel {
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
        filenameHintSource: FilenameHintSource = .urlPath,
        sourceKind: DownloadSourceKind = .http,
        requestContext: DownloadRequestContext? = nil,
        pageTitle: String? = nil,
        mimeType: String? = nil
    ) async throws -> [DownloadMediaOption] {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else { throw IDMError.invalidURL }
        // The quality list must reflect the login state the download itself
        // will use: a manually typed URL carries no browser context, so the
        // stored site session stands in before any outbound request. Without
        // it, inspection resolves as a guest (guest-quality list, "missing
        // tracks") while the actual download runs logged in. Delivery stays
        // same-origin (DownloadRequestContext.apply), so a page-host session
        // never leaks to a cross-origin media CDN.
        let effectiveContext = await inspectionRequestContext(for: url, existing: requestContext)
        if BilibiliPlayurlAdapter.supports(url) {
            let playurlOptions = try await bilibiliAdapter.resolve(
                pageURL: url,
                requestContext: effectiveContext
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
                        label: displayLabel,
                        hintSource: filenameHintSource
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
                        label: title,
                        hintSource: filenameHintSource
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
                try await YouTubeMediaInspector(liveStatusCache: .shared).inspect(
                    url: url,
                    requestContext: effectiveContext,
                    mediaKind: .http
                )
            }
            guard let inspection, !inspection.variants.isEmpty else { return fallback }
            return inspection.variants.map { variant in
                // The audio-only variant ("只要声音") is the one m4a
                // exception to the "YouTube outputs MP4" naming contract.
                let suggested = DownloadNaming.suggestedFilename(
                    url: url,
                    sourceKind: .http,
                    filenameHint: filenameHint,
                    pageTitle: title,
                    resourceInfo: nil,
                    label: variant.label,
                    hintSource: filenameHintSource
                )
                return DownloadMediaOption(
                    url: variant.url,
                    sourceKind: .http,
                    filename: variant.fileExtension == "m4a"
                        ? DownloadNaming.replacingExtension(of: suggested, with: "m4a")
                        : suggested,
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
                filenameHintSource: filenameHintSource,
                pageTitle: pageTitle,
                requestContext: effectiveContext
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
                        resourceInfo: nil,
                        hintSource: filenameHintSource
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
            requestContext: effectiveContext
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
                        resourceInfo: info,
                        hintSource: filenameHintSource
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
            requestContext: effectiveContext
        )
        // A raw <title> usually carries the site brand ("… - Hanime1.me");
        // strip it against the page hosts before it becomes the filename base.
        let strippedDiscoveryTitle = DownloadNaming.semanticPageTitle(
            discovery?.title,
            hosts: [url.host, discovery?.pageURL.host]
        )
        let discoveredTitle = strippedDiscoveryTitle ?? pageTitle
        var options: [DownloadMediaOption] = []
        for candidate in discovery?.candidates ?? [] {
            if candidate.sourceKind == .hls || candidate.sourceKind == .dash {
                let inspected = try await inspectDownloadOptions(
                    url: candidate.url,
                    sourceKind: candidate.sourceKind,
                    filenameHint: nil,
                    pageTitle: discoveredTitle,
                    requestContext: effectiveContext
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
                            pageTitle: discoveredTitle,
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
                filenameHintSource: filenameHintSource,
                pageTitle: pageTitle,
                requestContext: effectiveContext
            )
        {
            return fallback
        }
        guard !options.isEmpty else { throw WebPageMediaDiscoveryError.noCandidates }
        return options
    }

    /// Inspection-time stand-in for a browser context: a manually typed URL
    /// has no cookie of its own, so the stored site session (captured by an
    /// extension download or pasted by hand) fills in exactly like start()
    /// does for the download itself. Only a missing cookie is filled — an
    /// explicit browser context still wins field by field — and an
    /// unreadable credential falls through to no-session rather than an
    /// empty Cookie header that reads as "logged in".
    /// The credential read runs off-main (see ``SessionStore/resolvedCookieHeader(for:)``):
    /// this resolves while the confirmation window is already on screen.
    func inspectionRequestContext(
        for url: URL,
        existing: DownloadRequestContext?
    ) async -> DownloadRequestContext {
        if let existing, let cookie = existing.cookie, !cookie.isEmpty {
            return existing
        }
        guard let stored = sessionStore.lookup(url: url),
            let cookie = await sessionStore.resolvedCookieHeader(for: stored),
            !cookie.isEmpty
        else { return existing ?? DownloadRequestContext() }
        return DownloadRequestContext(
            cookie: cookie,
            referer: existing?.referer,
            userAgent: existing?.userAgent ?? stored.userAgent
        )
    }

    /// Asks yt-dlp to resolve a playable media URL for `url` (any site).
    /// Bounded to 15s like the YouTube format listing: a slow or stuck
    /// fallback must never block the new-download dialog. Returns nil on
    /// any failure so the caller keeps its original error path.
    private func ytdlpGenericFallback(
        url: URL,
        filenameHint: String?,
        filenameHintSource: FilenameHintSource = .urlPath,
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
                    resourceInfo: nil,
                    hintSource: filenameHintSource
                ),
                label: String(localized: "yt-dlp 提取"),
                requestContext: requestContext,
                estimatedSize: extraction.estimatedSize,
                duration: extraction.duration
            )
        ]
    }
}
