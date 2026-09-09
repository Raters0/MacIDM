import AppKit
import Foundation
import IDMEngine
import MacIDMBridge

extension AppModel {
    func startBrowserBridge() {
        do {
            try browserBridge.start(model: self)
        } catch {
            browserBridgeStatus = .failed(error.localizedDescription)
        }
    }

    func clearPendingDownloadDraft(_ draft: DownloadDraft) {
        cancelInteractiveTakeoverDraft(draft.takeoverDraftID)
        pendingDownloadDrafts = pendingDownloadDrafts.filter { $0.value != draft }
    }

    func handleBrowserBridgeRequest(
        _ request: MessageRequest,
        clientID: String,
        secret: Data
    ) async -> MessageResponse {
        do {
            switch request.type {
            case "ping":
                return .ok(
                    requestId: request.requestId,
                    type: "pong",
                    payload: ["appVersion": .string("0.3.0")]
                )
            case "download.create":
                return try await prepareBrowserDownload(request, clientID: clientID, secret: secret)
            case "download.enqueue":
                if request.payload["interactive"]?.boolValue == true {
                    return try requestInteractiveBrowserDownload(request, clientID: clientID, secret: secret)
                }
                return try await enqueueBrowserDownload(request, clientID: clientID)
            case "media.inspect":
                return try await inspectBrowserMedia(request)
            case "download.abandon":
                return try abandonBrowserDownload(request, clientID: clientID)
            case "download.browserCancelled":
                return try confirmBrowserCancellation(request, clientID: clientID, secret: secret)
            case "download.browserCancelFailed":
                return try recordBrowserCancellationFailure(request, clientID: clientID, secret: secret)
            default:
                return .failure(
                    requestId: request.requestId,
                    code: "INVALID_MESSAGE",
                    retryable: false
                )
            }
        } catch BrowserTakeoverError.contextUnsupported {
            return .failure(
                requestId: request.requestId,
                code: "PERMISSION_REQUIRED",
                retryable: false,
                message: String(
                    localized:
                        "当前请求包含 MacIDM 无法安全重建的 Authorization 或无效上下文；Chrome 下载将继续。"
                )
            )
        } catch BrowserTakeoverError.destinationReserved {
            return .failure(
                requestId: request.requestId,
                code: "TAKEOVER_CONFLICT",
                retryable: false,
                message: BrowserTakeoverError.destinationReserved.localizedDescription
            )
        } catch BrowserTakeoverError.abandoned {
            return .failure(
                requestId: request.requestId,
                code: "TAKEOVER_ABANDONED",
                retryable: false,
                message: BrowserTakeoverError.abandoned.localizedDescription
            )
        } catch MediaInspectionError.unsupportedLiveStream {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_UNSUPPORTED",
                retryable: false,
                message: MediaInspectionError.unsupportedLiveStream.localizedDescription
            )
        } catch MediaInspectionError.liveStatusUnknown {
            // Live status cannot be confirmed: a retryable inspection error
            // that must not pass through as VOD (round 2 §P1-2).
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_LIVE_STATUS_UNKNOWN",
                retryable: true,
                message: MediaInspectionError.liveStatusUnknown.localizedDescription
            )
        } catch MediaInspectionError.authenticationRequired {
            // Structured media-inspection errors: login/bot check, cookie
            // context, tool, network and no-formats no longer collapse into
            // MEDIA_INVALID (AI handover doc §5.2). Messages use safe
            // localized copy and never pass raw yt-dlp stderr through.
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_AUTH_REQUIRED",
                retryable: false,
                message: MediaInspectionError.authenticationRequired.localizedDescription
            )
        } catch MediaInspectionError.cookieContextUnavailable {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_COOKIE_UNAVAILABLE",
                retryable: false,
                message: MediaInspectionError.cookieContextUnavailable.localizedDescription
            )
        } catch MediaInspectionError.youTubeToolUnavailable {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_TOOL_UNAVAILABLE",
                retryable: false,
                message: MediaInspectionError.youTubeToolUnavailable.localizedDescription
            )
        } catch MediaInspectionError.toolUpdateSuggested {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_TOOL_UPDATE_SUGGESTED",
                retryable: false,
                message: MediaInspectionError.toolUpdateSuggested.localizedDescription
            )
        } catch MediaInspectionError.networkOrProxyFailure {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_NETWORK_FAILURE",
                retryable: false,
                message: MediaInspectionError.networkOrProxyFailure.localizedDescription
            )
        } catch MediaInspectionError.noFormats {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_NO_FORMATS",
                retryable: false,
                message: MediaInspectionError.noFormats.localizedDescription
            )
        } catch MediaInspectionError.processCleanupFailed {
            // External-tool cleanup failure is its own error category (AI
            // handover doc §4): it does not masquerade as a network, proxy or
            // missing-tool error; retryable, and the copy carries no raw
            // yt-dlp output.
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_CLEANUP_FAILED",
                retryable: true,
                message: MediaInspectionError.processCleanupFailed.localizedDescription
            )
        } catch let error as ManagedToolLaunchError {
            // Initialization failures of the inspection process wrapper (e.g.
            // pipe setup / FD exhaustion) are tool-side infrastructure
            // failures and must not fall into the APP_REJECTED fallback and be
            // misreported as "App rejected".
            AppLogger.shared.error(
                .youtube,
                "media.inspect launch infrastructure failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.detail) ?? "SANITIZE_FAILED")"
            )
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_TOOL_UNAVAILABLE",
                retryable: true,
                message: MediaInspectionError.youTubeToolUnavailable.localizedDescription
            )
        } catch MediaInspectionError.invalidPlaylist(let detail) {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_INVALID",
                retryable: false,
                message: String(localized: "无法解析媒体播放列表：") + detail
            )
        } catch let error as BilibiliPlayurlError {
            return .failure(
                requestId: request.requestId,
                code: "MEDIA_INVALID",
                retryable: false,
                message: error.localizedDescription
            )
        } catch {
            return .failure(
                requestId: request.requestId,
                code: "APP_REJECTED",
                retryable: false,
                message: error.localizedDescription
            )
        }
    }

    func inspectBrowserMedia(_ request: MessageRequest) async throws -> MessageResponse {
        let rawMediaKind = request.payload["mediaKind"]?.stringValue ?? ""
        guard let rawURL = request.payload["url"]?.stringValue,
            let url = URL(string: rawURL)
        else {
            throw BridgeError.invalidMessage(String(localized: "media.inspect 需要有效的 URL"))
        }
        let requestContext = try browserRequestContext(from: request)
        let inspection: MediaInspection
        if rawMediaKind == "youtube" {
            let youTubeInspector = YouTubeMediaInspector()
            inspection = try await youTubeInspector.inspect(
                url: url,
                requestContext: requestContext,
                mediaKind: .http
            )
        } else if let mediaKind = DownloadSourceKind(rawValue: rawMediaKind),
            mediaKind == .hls || mediaKind == .dash
        {
            if mediaKind == .dash, BilibiliPlayurlAdapter.supports(url) {
                let options: [BilibiliPlayurlOption]
                do {
                    options = try await bilibiliAdapter.resolve(
                        pageURL: url,
                        requestContext: requestContext
                    )
                } catch {
                    throw MediaInspectionError.invalidPlaylist(error.localizedDescription)
                }
                inspection = MediaInspection(
                    mediaKind: .dash,
                    variants: options.map { option in
                        MediaVariant(
                            url: option.videoURL,
                            label: bilibiliOptionLabel(for: option),
                            bandwidth: option.bandwidth.flatMap { Int(exactly: $0) },
                            width: option.width,
                            height: option.height,
                            codecs: option.codecs,
                            pairAudioURL: option.audioURL,
                            estimatedSize: option.estimatedSize,
                            duration: option.duration
                        )
                    }
                )
            } else {
                inspection = try await mediaInspector.inspect(
                    url: url,
                    requestContext: requestContext,
                    mediaKind: mediaKind
                )
            }
        } else {
            throw BridgeError.invalidMessage(
                String(localized: "media.inspect 目前只支持 HLS、DASH 或 YouTube URL")
            )
        }
        let variants = inspection.variants.map { variant in
            var payload: [String: JSONValue] = [
                "url": .string(variant.url.absoluteString),
                "label": .string(variant.label),
            ]
            if let bandwidth = variant.bandwidth {
                payload["bandwidth"] = .number(Double(bandwidth))
            }
            if let width = variant.width {
                payload["width"] = .number(Double(width))
            }
            if let height = variant.height {
                payload["height"] = .number(Double(height))
            }
            if let codecs = variant.codecs {
                payload["codecs"] = .string(codecs)
            }
            if let estimatedSize = variant.estimatedSize {
                payload["estimatedSize"] = .number(Double(estimatedSize))
            }
            if let duration = variant.duration {
                payload["duration"] = .number(duration)
            }
            if let fileExtension = variant.fileExtension {
                payload["fileExtension"] = .string(fileExtension)
            }
            if let pairAudioURL = variant.pairAudioURL {
                payload["pairAudioUrl"] = .string(pairAudioURL.absoluteString)
            }
            if let pairCID = variant.pairCID {
                payload["pairCid"] = .string(pairCID)
            }
            return JSONValue.object(payload)
        }
        return .ok(
            requestId: request.requestId,
            type: "media.inspected",
            payload: [
                "mediaKind": .string(inspection.mediaKind.rawValue),
                "variants": .array(variants),
            ]
        )
    }

    /// Unified label for Bilibili options (quality · codec family · bitrate);
    /// carries no site prefix or "codec:" wording and shares the same slot
    /// grammar as variant labels from other sources.
    func bilibiliOptionLabel(for option: BilibiliPlayurlOption) -> String {
        let label = MediaVariantLabel.format(
            width: option.width,
            height: option.height,
            codecs: option.codecs,
            bandwidth: option.bandwidth.flatMap { Int(exactly: $0) }
        )
        return label.isEmpty ? String(localized: "视频") : label
    }

    /// Chrome's `DownloadItem.totalBytes` is 0 (and -1) while the size is
    /// still unknown, and a zero-byte estimate is equally meaningless for
    /// the confirmation card. Normalize both to nil so an older extension
    /// reporting 0 degrades to "size unknown" instead of a confident "0 KB".
    static func positiveSize(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    func requestInteractiveBrowserDownload(
        _ request: MessageRequest,
        clientID: String,
        secret: Data
    ) throws -> MessageResponse {
        let key = clientID + ":" + request.idempotencyKey
        let browserID = request.payload["browserDownloadId"]?.intValue
        if let browserID {
            try purgeExpiredAbandonedTakeovers()
            if abandonedTakeovers.contains(where: {
                $0.matches(clientID: clientID, idempotencyKey: request.idempotencyKey, browserDownloadID: browserID)
            }) {
                throw BrowserTakeoverError.abandoned
            }
            if let existing = browserTakeovers.first(where: {
                $0.authenticatedClientID == clientID && $0.idempotencyKey == request.idempotencyKey
            }) {
                guard existing.state != .conflict else { throw BrowserTakeoverError.destinationReserved }
                return try readyResponseForExistingTakeover(request, record: existing, secret: secret)
            }
            if pendingInteractiveTakeovers[key] != nil {
                _ = try validatedInteractiveTakeover(key)
                return .ok(requestId: request.requestId, type: "download.confirmationPending", payload: [:])
            }
            pendingInteractiveTakeovers[key] = PendingInteractiveTakeover(
                request: request, clientID: clientID, secret: secret, expiresAt: Date().addingTimeInterval(180)
            )
        }
        guard let rawURL = request.payload["url"]?.stringValue,
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else {
            throw BridgeError.invalidMessage("download.enqueue payload is incomplete")
        }
        let pairAudioURL = URL(string: request.payload["pairAudioUrl"]?.stringValue ?? "")
        let requestedSourceKind =
            DownloadSourceKind(rawValue: request.payload["mediaKind"]?.stringValue ?? "http") ?? .http
        let backend: DownloadBackend =
            request.payload["mediaKind"]?.stringValue == "youtube" ? .youtubeExtractor : .native
        // A browser candidate can lose its semantic field while crossing a
        // stale extension/service-worker boundary. Never treat a playlist URL
        // as an ordinary file just because mediaKind was omitted or degraded
        // to HTTP; that would publish the playlist bytes under an .mp4 name.
        let sourceKind = effectiveSourceKind(
            for: url,
            requested: requestedSourceKind,
            pairAudioURL: pairAudioURL,
            allowPageAdapters: true
        )
        let requestContext = try browserRequestContext(from: request)
        let draft: DownloadDraft
        if let existing = pendingDownloadDrafts[key] {
            draft = existing
        } else {
            // Stream candidates carry an estimatedSize estimate; browser
            // takeovers carry the download's real Content-Length as
            // totalBytes. Adopt whichever is present, marking the takeover
            // value as probed so the confirmation window shows it plainly.
            let streamEstimate = Self.positiveSize(request.payload["estimatedSize"]?.int64Value)
            let browserTotal = Self.positiveSize(request.payload["totalBytes"]?.int64Value)
            let estimatedSize = streamEstimate ?? browserTotal
            draft = DownloadDraft(
                url: url,
                filenameHint: request.payload["filenameHint"]?.stringValue,
                sourceKind: sourceKind,
                requestContext: requestContext,
                pageTitle: request.payload["pageTitle"]?.stringValue,
                mimeType: request.payload["mime"]?.stringValue,
                pairAudioURL: pairAudioURL,
                pairCID: request.payload["pairCid"]?.stringValue,
                backend: backend,
                estimatedSize: estimatedSize,
                duration: request.payload["duration"]?.doubleValue,
                sizeProbed: streamEstimate == nil && browserTotal != nil,
                takeoverDraftID: browserID == nil ? nil : key
            )
            pendingDownloadDrafts[key] = draft
        }
        // The confirmation opens in its own window; the main window is never
        // required, so a browser submission works even while it is closed.
        presentNewDownload(draft: draft)
        return .ok(
            requestId: request.requestId,
            type: browserID == nil ? "media.downloadRequested" : "download.confirmationPending",
            payload: [
                "filenameHint": .string(InputValidator.safeFilename(draft.filenameHint))
            ]
        )
    }

    func readyResponseForExistingTakeover(
        _ request: MessageRequest,
        record: BrowserTakeoverRecord,
        secret: Data
    ) throws -> MessageResponse {
        guard request.payload["browserDownloadId"]?.intValue == record.browserDownloadID else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        if record.startAfterTakeover == nil, let url = URL(string: request.payload["url"]?.stringValue ?? "") {
            transientSourceURLs[record.taskID] = url
        }
        if record.startAfterTakeover == nil, let context = try browserRequestContext(from: request) {
            transientRequestContexts[record.taskID] = TransientRequestContext(
                value: context,
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            )
        }
        let token = TakeoverToken.make(
            secret: secret,
            requestID: record.originalRequestID,
            browserDownloadID: record.browserDownloadID,
            taskID: record.taskID
        )
        return readyResponse(requestID: request.requestId, record: record, token: token)
    }

    func prepareBrowserDownload(
        _ request: MessageRequest,
        clientID: String,
        secret: Data
    ) async throws -> MessageResponse {
        // The probe below suspends the main actor for seconds; remember when
        // the request arrived so the final auto-select never overrides a
        // selection the user made in the meantime.
        let selectionIntent = Date()
        try purgeExpiredAbandonedTakeovers()
        if let existing = browserTakeovers.first(where: {
            $0.authenticatedClientID == clientID && $0.idempotencyKey == request.idempotencyKey
        }) {
            guard existing.state != .conflict else {
                throw BrowserTakeoverError.destinationReserved
            }
            return try readyResponseForExistingTakeover(
                request,
                record: existing,
                secret: secret
            )
        }

        guard let browserDownloadID = request.payload["browserDownloadId"]?.intValue else {
            throw BridgeError.invalidMessage("download.create payload is incomplete")
        }
        if abandonedTakeovers.contains(where: {
            $0.matches(
                clientID: clientID,
                idempotencyKey: request.idempotencyKey,
                browserDownloadID: browserDownloadID
            )
        }) {
            throw BrowserTakeoverError.abandoned
        }

        if pendingInteractiveTakeovers[clientID + ":" + request.idempotencyKey] != nil {
            _ = try validatedInteractiveTakeover(clientID + ":" + request.idempotencyKey)
            return .ok(requestId: request.requestId, type: "download.confirmationPending", payload: [:])
        }
        let requestContext = try browserRequestContext(from: request)
        guard let rawURL = request.payload["url"]?.stringValue,
            let url = URL(string: rawURL)
        else {
            throw BridgeError.invalidMessage("download.create payload is incomplete")
        }

        let taskID = UUID()
        let requestFilename = request.payload["filenameHint"]?.stringValue
        let usableRequestFilename = DownloadNaming.isGenericFilename(requestFilename) ? nil : requestFilename
        let initialFilename =
            usableRequestFilename
            ?? url.lastPathComponent.removingPercentEncoding
            ?? "download"
        let placeholderName = InputValidator.safeFilename(initialFilename)
        let placeholderDestination = URL(
            fileURLWithPath: settings.downloadDirectory,
            isDirectory: true
        ).appendingPathComponent(placeholderName)
        let probeRequest = DownloadRequest(
            url: url,
            destination: placeholderDestination,
            maximumParallelRequests: settings.maximumParallelRequests,
            taskID: taskID,
            requestContext: requestContext
        )
        let info = try await browserProbe(probeRequest)
        // The probe suspends the MainActor. Chrome may time out and send
        // download.abandon while it is in flight, or a duplicate create may
        // finish its own probe first. Re-check both barriers after the await
        // before reserving a path or creating a task.
        try purgeExpiredAbandonedTakeovers()
        if let existing = browserTakeovers.first(where: {
            $0.authenticatedClientID == clientID && $0.idempotencyKey == request.idempotencyKey
        }) {
            guard existing.state != .conflict else {
                throw BrowserTakeoverError.destinationReserved
            }
            return try readyResponseForExistingTakeover(
                request,
                record: existing,
                secret: secret
            )
        }
        if abandonedTakeovers.contains(where: {
            $0.matches(
                clientID: clientID,
                idempotencyKey: request.idempotencyKey,
                browserDownloadID: browserDownloadID
            )
        }) {
            throw BrowserTakeoverError.abandoned
        }
        if let browserSize = Self.positiveSize(request.payload["totalBytes"]?.int64Value),
            let probedSize = info.size,
            browserSize != probedSize
        {
            throw BridgeError.invalidMessage("browser and server sizes differ")
        }

        let preferredFilename =
            DownloadNaming.nonEmptyPageTitle(request.payload["pageTitle"]?.stringValue)
            ?? (DownloadNaming.isGenericFilename(info.suggestedFilename) ? nil : info.suggestedFilename)
            ?? usableRequestFilename
            ?? initialFilename
        let filename = DownloadNaming.filenameWithOutputExtension(
            InputValidator.safeFilename(preferredFilename),
            sourceKind: .http,
            url: info.finalURL,
            resourceInfo: info
        )
        let preferredDestination = URL(
            fileURLWithPath: settings.downloadDirectory,
            isDirectory: true
        ).appendingPathComponent(filename)
        let mimeType = request.payload["mime"]?.stringValue
        let destination: URL
        do {
            destination = try availableDestination(
                for: try categorizedDestination(for: preferredDestination, mimeType: mimeType),
                automaticRename: true
            )
        } catch {
            throw BrowserTakeoverError.destinationReserved
        }

        let reservation = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(filename).\(taskID.uuidString).macidm.takeover")
        try takeoverStore.reserve(path: reservation)
        let now = Date()
        let token = TakeoverToken.make(
            secret: secret,
            requestID: request.requestId,
            browserDownloadID: browserDownloadID,
            taskID: taskID
        )
        var task = AppTask(
            id: taskID,
            sourceURL: redactedURLForStorage(url),
            destinationPath: destination.path,
            maximumParallelRequests: settings.maximumParallelRequests,
            expectedSHA256: nil,
            browserClientID: clientID,
            browserSubmissionType: "download.create",
            browserSubmissionKey: request.idempotencyKey,
            createdAt: now,
            updatedAt: now,
            status: .takeoverPending,
            receivedBytes: 0,
            totalBytes: info.size,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.mimeType = mimeType
        // The takeover URL is the media request itself; the page the user
        // was on arrives as the referer.
        task.pageURL = pageURLFromReferer(requestContext?.referer, fallback: url)
        let record = BrowserTakeoverRecord(
            authenticatedClientID: clientID,
            idempotencyKey: request.idempotencyKey,
            originalRequestID: request.requestId,
            browserDownloadID: browserDownloadID,
            taskID: taskID,
            destinationPath: destination.path,
            reservationPath: reservation.path,
            tokenHash: TakeoverToken.hash(token),
            state: .appReady,
            updatedAt: now
        )
        tasks.insert(task, at: 0)
        browserTakeovers.append(record)
        transientSourceURLs[taskID] = url
        if let requestContext {
            transientRequestContexts[taskID] = TransientRequestContext(
                value: requestContext,
                expiresAt: now.addingTimeInterval(24 * 60 * 60)
            )
        }
        do {
            try persist()
            try persistBrowserTakeovers()
        } catch {
            tasks.removeAll { $0.id == taskID }
            browserTakeovers.removeAll { $0.taskID == taskID }
            transientSourceURLs[taskID] = nil
            transientRequestContexts[taskID] = nil
            takeoverStore.release(path: reservation.path)
            throw error
        }
        if lastUserSelectionChange <= selectionIntent {
            selectTasks([taskID])
        }
        takeoverLog?.append(
            event: "created",
            taskID: taskID,
            detail: "destination=\(destination.lastPathComponent) browserDownloadID=\(browserDownloadID)"
        )
        return readyResponse(requestID: request.requestId, record: record, token: token)
    }

    func enqueueBrowserDownload(
        _ request: MessageRequest,
        clientID: String
    ) async throws -> MessageResponse {
        // Selection guard for the same reason as prepareBrowserDownload: the
        // size probe can take seconds and must not steal the user's focus.
        let selectionIntent = Date()
        if let existing = tasks.first(where: {
            $0.browserClientID == clientID
                && $0.browserSubmissionType == request.type
                && $0.browserSubmissionKey == request.idempotencyKey
        }) {
            if let url = URL(string: request.payload["url"]?.stringValue ?? "") {
                transientSourceURLs[existing.id] = url
            }
            if let pairAudioURL = URL(string: request.payload["pairAudioUrl"]?.stringValue ?? "") {
                transientPairAudioURLs[existing.id] = pairAudioURL
                if let pairCID = request.payload["pairCid"]?.stringValue {
                    transientPairCIDs[existing.id] = pairCID
                }
            }
            if let context = try browserRequestContext(from: request) {
                transientRequestContexts[existing.id] = TransientRequestContext(
                    value: context,
                    expiresAt: Date().addingTimeInterval(24 * 60 * 60)
                )
            }
            if existing.errorCode == "NEEDS_REFETCH" {
                update(existing.id) {
                    $0.status = .queued
                    $0.errorCode = nil
                    $0.errorMessage = nil
                }
                try persist()
                scheduleQueuedTasks()
            }
            return .ok(
                requestId: request.requestId,
                type: "download.accepted",
                payload: ["taskId": .string(existing.id.uuidString)]
            )
        }

        guard let rawURL = request.payload["url"]?.stringValue,
            let url = URL(string: rawURL)
        else {
            throw BridgeError.invalidMessage("download.enqueue payload is incomplete")
        }
        let pairAudioURL = URL(string: request.payload["pairAudioUrl"]?.stringValue ?? "")
        let pairCID = request.payload["pairCid"]?.stringValue
        let requestedSourceKind =
            DownloadSourceKind(rawValue: request.payload["mediaKind"]?.stringValue ?? "http") ?? .http
        let backend: DownloadBackend =
            request.payload["mediaKind"]?.stringValue == "youtube" ? .youtubeExtractor : .native
        let sourceKind = effectiveSourceKind(
            for: url,
            requested: requestedSourceKind,
            pairAudioURL: pairAudioURL
        )
        let requestContext = try browserRequestContext(from: request)
        let taskID = UUID()
        let pageTitle = DownloadNaming.nonEmptyPageTitle(request.payload["pageTitle"]?.stringValue)
        var initialFilename =
            pageTitle
            ?? request.payload["filenameHint"]?.stringValue
            ?? url.lastPathComponent.removingPercentEncoding
            ?? "download"
        if DownloadNaming.isGenericFilename(initialFilename) {
            initialFilename = url.lastPathComponent.removingPercentEncoding ?? "download"
        }
        initialFilename = DownloadNaming.filenameWithOutputExtension(
            InputValidator.safeFilename(initialFilename),
            sourceKind: sourceKind,
            url: url,
            resourceInfo: nil,
            backend: backend
        )
        let placeholderName = InputValidator.safeFilename(initialFilename)
        let placeholderDestination = URL(
            fileURLWithPath: settings.downloadDirectory,
            isDirectory: true
        ).appendingPathComponent(placeholderName)
        let probeRequest = DownloadRequest(
            url: url,
            destination: placeholderDestination,
            sourceKind: sourceKind,
            maximumParallelRequests: settings.maximumParallelRequests,
            taskID: taskID,
            requestContext: requestContext,
            pairAudioURL: pairAudioURL,
            pairCID: pairCID,
            backend: backend
        )
        let info =
            sourceKind == .http && backend != .youtubeExtractor
            ? try await browserProbe(probeRequest)
            : nil
        if let browserSize = Self.positiveSize(request.payload["totalBytes"]?.int64Value),
            let probedSize = info?.size,
            browserSize != probedSize
        {
            throw BridgeError.invalidMessage("browser and server sizes differ")
        }

        let requestedFilename = request.payload["filenameHint"]?.stringValue
        let filenameCandidate: String
        if sourceKind == .hls || sourceKind == .dash {
            filenameCandidate = initialFilename
        } else {
            filenameCandidate =
                pageTitle
                ?? (DownloadNaming.isGenericFilename(info?.suggestedFilename) ? nil : info?.suggestedFilename)
                ?? (DownloadNaming.isGenericFilename(requestedFilename) ? nil : requestedFilename)
                ?? initialFilename
        }
        let filename = DownloadNaming.filenameWithOutputExtension(
            InputValidator.safeFilename(filenameCandidate),
            sourceKind: sourceKind,
            url: url,
            resourceInfo: info,
            backend: backend
        )
        let preferredDestination = URL(
            fileURLWithPath: settings.downloadDirectory,
            isDirectory: true
        ).appendingPathComponent(filename)
        let mimeType = request.payload["mime"]?.stringValue
        let destination: URL
        do {
            destination = try availableDestination(
                for: try categorizedDestination(for: preferredDestination, mimeType: mimeType),
                automaticRename: true
            )
        } catch {
            throw BrowserTakeoverError.destinationReserved
        }

        let now = Date()
        var task = AppTask(
            id: taskID,
            sourceURL: redactedURLForStorage(url),
            destinationPath: destination.path,
            maximumParallelRequests: settings.maximumParallelRequests,
            expectedSHA256: nil,
            sourceKind: sourceKind,
            browserClientID: clientID,
            browserSubmissionType: backend == .youtubeExtractor ? "youtube.extractor" : request.type,
            browserSubmissionKey: request.idempotencyKey,
            createdAt: now,
            updatedAt: now,
            status: .queued,
            receivedBytes: 0,
            totalBytes: info?.size,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.mimeType = mimeType
        // Extractor submissions receive the watch page directly (keep the
        // `v=` identifier); other submissions prefer the page referer.
        if backend == .youtubeExtractor {
            task.pageURL = Self.pageURLForStorage(url)
        } else {
            task.pageURL = pageURLFromReferer(requestContext?.referer, fallback: url)
        }
        // Persist the non-secret re-resolution identity (cid + chosen track
        // format_id) and archive the page-origin login cookie so a paused
        // Bilibili pair can be re-resolved after a restart. No-op for tasks
        // whose page URL is not a supported site-adapter page.
        recordSiteAdapterResumeContext(
            task: &task,
            downloadURL: url,
            pairCID: pairCID,
            requestContext: requestContext
        )
        tasks.insert(task, at: 0)
        transientSourceURLs[taskID] = url
        if let pairAudioURL {
            transientPairAudioURLs[taskID] = pairAudioURL
            if let pairCID { transientPairCIDs[taskID] = pairCID }
        }
        if let requestContext {
            transientRequestContexts[taskID] = TransientRequestContext(
                value: requestContext,
                expiresAt: now.addingTimeInterval(24 * 60 * 60)
            )
        }
        do {
            try persist()
        } catch {
            tasks.removeAll { $0.id == taskID }
            transientSourceURLs[taskID] = nil
            transientPairAudioURLs[taskID] = nil
            transientPairCIDs[taskID] = nil
            transientRequestContexts[taskID] = nil
            throw error
        }
        if lastUserSelectionChange <= selectionIntent {
            selectTasks([taskID])
        }
        scheduleQueuedTasks()
        return .ok(
            requestId: request.requestId,
            type: "download.accepted",
            payload: ["taskId": .string(taskID.uuidString)]
        )
    }

    /// Page URL preference helper: use the browser-reported referer when
    /// present (credentials stripped), otherwise fall back to the download
    /// URL itself.
    private func pageURLFromReferer(_ referer: String?, fallback: URL) -> String? {
        if let referer, !referer.isEmpty, let refererURL = URL(string: referer) {
            return Self.pageURLForStorage(refererURL)
        }
        return Self.pageURLForStorage(fallback)
    }

    func confirmBrowserCancellation(
        _ request: MessageRequest,
        clientID: String,
        secret: Data
    ) throws -> MessageResponse {
        let taskID = try browserTaskID(from: request)
        guard
            let index = browserTakeovers.firstIndex(where: {
                $0.taskID == taskID && $0.authenticatedClientID == clientID
            })
        else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        let record = browserTakeovers[index]
        guard request.payload["browserDownloadId"]?.intValue == record.browserDownloadID else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        if record.state == .browserCancelled {
            return .ok(
                requestId: request.requestId,
                type: "download.accepted",
                payload: ["taskId": .string(taskID.uuidString)]
            )
        }
        if record.state == .appCancelled {
            try validateToken(request, record: record, secret: secret)
            rememberAbandonedTakeover(
                clientID: clientID,
                idempotencyKey: record.idempotencyKey,
                browserDownloadID: record.browserDownloadID
            )
            takeoverStore.release(path: record.reservationPath)
            browserTakeovers.remove(at: index)
            try persistBrowserTakeovers()
            return .ok(
                requestId: request.requestId,
                type: "download.accepted",
                payload: ["taskId": .string(taskID.uuidString)]
            )
        }
        guard record.state == .appReady else { throw BrowserTakeoverError.invalidState }
        try validateToken(request, record: record, secret: secret)

        browserTakeovers[index].state = .browserCancelled
        browserTakeovers[index].updatedAt = Date()
        update(taskID) {
            $0.status = (record.startAfterTakeover ?? true) ? .queued : .paused
            $0.errorCode = nil
            $0.errorMessage = nil
        }
        takeoverStore.release(path: record.reservationPath)
        try persist()
        try persistBrowserTakeovers()
        takeoverLog?.append(event: "confirmed", taskID: taskID, detail: "浏览器下载已取消，任务进入队列")
        scheduleQueuedTasks()
        return .ok(
            requestId: request.requestId,
            type: "download.accepted",
            payload: ["taskId": .string(taskID.uuidString)]
        )
    }

    func abandonBrowserDownload(
        _ request: MessageRequest,
        clientID: String
    ) throws -> MessageResponse {
        try purgeExpiredAbandonedTakeovers()
        guard let browserDownloadID = request.payload["browserDownloadId"]?.intValue,
            let originalKey = request.payload["originalIdempotencyKey"]?.stringValue
        else {
            throw BridgeError.invalidMessage("download.abandon payload is incomplete")
        }
        let draftKey = clientID + ":" + originalKey
        pendingInteractiveTakeovers[draftKey] = nil
        pendingDownloadDrafts[draftKey] = nil
        guard
            let index = browserTakeovers.firstIndex(where: {
                $0.authenticatedClientID == clientID
                    && $0.idempotencyKey == originalKey
                    && $0.browserDownloadID == browserDownloadID
            })
        else {
            // Persist the barrier even when the App has not observed
            // download.create yet. This is the timeout race: a late create
            // must not be allowed to materialize an orphan task after Chrome
            // has already compensated the request.
            rememberAbandonedTakeover(
                clientID: clientID,
                idempotencyKey: originalKey,
                browserDownloadID: browserDownloadID
            )
            try persistBrowserTakeovers()
            return .ok(
                requestId: request.requestId,
                type: "download.abandoned",
                payload: [:]
            )
        }
        let record = browserTakeovers[index]
        guard record.state == .appReady,
            task(with: record.taskID)?.status == .takeoverPending
        else {
            return .ok(
                requestId: request.requestId,
                type: "download.abandoned",
                payload: ["taskId": .string(record.taskID.uuidString)]
            )
        }

        let removedTask = tasks.first(where: { $0.id == record.taskID })
        let previousAbandonedTakeovers = abandonedTakeovers
        rememberAbandonedTakeover(
            clientID: clientID,
            idempotencyKey: originalKey,
            browserDownloadID: browserDownloadID
        )
        tasks.removeAll { $0.id == record.taskID }
        browserTakeovers.remove(at: index)
        transientSourceURLs[record.taskID] = nil
        transientPairAudioURLs[record.taskID] = nil
        transientPairCIDs[record.taskID] = nil
        transientRequestContexts[record.taskID] = nil
        do {
            try persist()
            try persistBrowserTakeovers()
        } catch {
            if let removedTask { tasks.insert(removedTask, at: 0) }
            browserTakeovers.insert(record, at: min(index, browserTakeovers.count))
            abandonedTakeovers = previousAbandonedTakeovers
            throw error
        }
        takeoverStore.release(path: record.reservationPath)
        if selectedTaskID == record.taskID { selectedTaskID = nil }
        selectedTaskIDs.remove(record.taskID)
        takeoverLog?.append(event: "abandoned", taskID: record.taskID, detail: "Chrome 接管请求超时后补偿回收")
        return .ok(
            requestId: request.requestId,
            type: "download.abandoned",
            payload: ["taskId": .string(record.taskID.uuidString)]
        )
    }

    func recordBrowserCancellationFailure(
        _ request: MessageRequest,
        clientID: String,
        secret: Data
    ) throws -> MessageResponse {
        let taskID = try browserTaskID(from: request)
        guard
            let index = browserTakeovers.firstIndex(where: {
                $0.taskID == taskID && $0.authenticatedClientID == clientID
            })
        else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        let record = browserTakeovers[index]
        guard request.payload["browserDownloadId"]?.intValue == record.browserDownloadID else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        if record.state == .conflict {
            return .ok(
                requestId: request.requestId,
                type: "download.conflictRecorded",
                payload: ["taskId": .string(taskID.uuidString)]
            )
        }
        try validateToken(request, record: record, secret: secret)
        if record.state == .appCancelled {
            browserTakeovers[index].state = .conflict
            browserTakeovers[index].updatedAt = Date()
            update(taskID) {
                $0.status = .takeoverConflict
                $0.errorCode = request.payload["errorCode"]?.stringValue ?? "BROWSER_CANCEL_FAILED"
                $0.errorMessage = String(
                    localized: "已取消 MacIDM 任务，但 Chrome 下载未能取消；浏览器下载仍会继续。"
                )
            }
            try persist()
            try persistBrowserTakeovers()
            return .ok(
                requestId: request.requestId,
                type: "download.conflictRecorded",
                payload: ["taskId": .string(taskID.uuidString)]
            )
        }
        browserTakeovers[index].state = .conflict
        browserTakeovers[index].updatedAt = Date()
        update(taskID) {
            $0.status = .takeoverConflict
            $0.errorCode = request.payload["errorCode"]?.stringValue ?? "BROWSER_CANCEL_FAILED"
            $0.errorMessage = String(
                localized: "Chrome 下载取消失败；MacIDM 未开始写入，请保留浏览器下载。"
            )
        }
        try persist()
        try persistBrowserTakeovers()
        takeoverLog?.append(
            event: "conflict",
            taskID: taskID,
            detail: request.payload["errorCode"]?.stringValue ?? "BROWSER_CANCEL_FAILED"
        )
        return .ok(
            requestId: request.requestId,
            type: "download.conflictRecorded",
            payload: ["taskId": .string(taskID.uuidString)]
        )
    }

    func browserTaskID(from request: MessageRequest) throws -> UUID {
        guard let value = request.payload["taskId"]?.stringValue, let taskID = UUID(uuidString: value) else {
            throw BrowserTakeoverError.takeoverNotFound
        }
        return taskID
    }

    func validateToken(
        _ request: MessageRequest,
        record: BrowserTakeoverRecord,
        secret: Data
    ) throws {
        guard let received = request.payload["takeoverToken"]?.stringValue else {
            throw BrowserTakeoverError.invalidToken
        }
        let expected = TakeoverToken.make(
            secret: secret,
            requestID: record.originalRequestID,
            browserDownloadID: record.browserDownloadID,
            taskID: record.taskID
        )
        guard received == expected, TakeoverToken.hash(received) == record.tokenHash else {
            throw BrowserTakeoverError.invalidToken
        }
    }

    func readyResponse(
        requestID: String,
        record: BrowserTakeoverRecord,
        token: String
    ) -> MessageResponse {
        .ok(
            requestId: requestID,
            type: "download.readyForTakeover",
            payload: [
                "taskId": .string(record.taskID.uuidString),
                "takeoverToken": .string(token),
            ]
        )
    }

    func redactedURLForStorage(_ url: URL) -> String {
        DownloadURLPolicy.redactedForStorage(url.absoluteString)
    }

    func browserRequestContext(from request: MessageRequest) throws -> DownloadRequestContext? {
        guard case .some(.object(let values)) = request.payload["requestContext"],
            !values.isEmpty
        else { return nil }
        if values["authorization"] != nil {
            throw BrowserTakeoverError.contextUnsupported
        }
        return DownloadRequestContext(
            cookie: values["cookie"]?.stringValue,
            referer: values["referer"]?.stringValue,
            userAgent: values["userAgent"]?.stringValue
        )
    }

    func purgeExpiredAbandonedTakeovers() throws {
        let now = Date()
        let retained = abandonedTakeovers.filter { $0.expiresAt > now }
        guard retained.count != abandonedTakeovers.count else { return }
        abandonedTakeovers = retained
        try takeoverStore.saveAbandoned(retained)
    }

    func rememberAbandonedTakeover(
        clientID: String,
        idempotencyKey: String,
        browserDownloadID: Int,
        now: Date = Date()
    ) {
        let expiresAt = now.addingTimeInterval(Self.abandonedTakeoverRetention)
        if let index = abandonedTakeovers.firstIndex(where: {
            $0.matches(
                clientID: clientID,
                idempotencyKey: idempotencyKey,
                browserDownloadID: browserDownloadID
            )
        }) {
            abandonedTakeovers[index].expiresAt = max(
                abandonedTakeovers[index].expiresAt,
                expiresAt
            )
        } else {
            abandonedTakeovers.append(
                AbandonedBrowserTakeover(
                    authenticatedClientID: clientID,
                    idempotencyKey: idempotencyKey,
                    browserDownloadID: browserDownloadID,
                    expiresAt: expiresAt
                )
            )
        }
    }

    func persistBrowserTakeovers() throws {
        // Write the compensation barrier first. If the following record save
        // is interrupted, a late create is still rejected instead of being
        // allowed to create an orphan task.
        try takeoverStore.saveAbandoned(abandonedTakeovers)
        try takeoverStore.save(browserTakeovers)
    }

    func persistBrowserTakeoversOrPresentError() {
        do {
            try persistBrowserTakeovers()
        } catch {
            showError(error, title: String(localized: "无法保存浏览器接管状态"))
        }
    }

    func sweepStaleTakeovers() {
        let now = Date()
        var takeoversChanged = false
        let retainedAbandonedTakeovers = abandonedTakeovers.filter { $0.expiresAt > now }
        if retainedAbandonedTakeovers.count != abandonedTakeovers.count {
            abandonedTakeovers = retainedAbandonedTakeovers
            takeoversChanged = true
        }
        let staleTasks = tasks.filter {
            $0.status == .takeoverPending
                && now.timeIntervalSince(max($0.updatedAt, launchDate))
                    >= Self.takeoverPendingTimeout
        }
        guard !staleTasks.isEmpty else {
            if takeoversChanged { persistBrowserTakeoversOrPresentError() }
            return
        }
        for staleTask in staleTasks {
            if let index = browserTakeovers.firstIndex(where: { $0.taskID == staleTask.id }) {
                let record = browserTakeovers[index]
                rememberAbandonedTakeover(
                    clientID: record.authenticatedClientID,
                    idempotencyKey: record.idempotencyKey,
                    browserDownloadID: record.browserDownloadID,
                    now: now
                )
                takeoverStore.release(path: browserTakeovers[index].reservationPath)
                browserTakeovers.remove(at: index)
                takeoversChanged = true
            }
            update(staleTask.id) {
                $0.status = .failed
                $0.errorCode = "TAKEOVER_TIMEOUT"
                $0.errorMessage = String(localized: "等待浏览器确认超时；请从 Chrome 重新提交下载。")
                $0.bytesPerSecond = 0
            }
            takeoverLog?.append(event: "timeout", taskID: staleTask.id, detail: "等待浏览器确认超时")
        }
        tryPersistOrPresentError(immediate: true)
        if takeoversChanged {
            persistBrowserTakeoversOrPresentError()
        }
    }
}
