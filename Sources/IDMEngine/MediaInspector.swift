import Foundation

public struct MediaVariant: Sendable {
    public let url: URL
    public let label: String
    public let bandwidth: Int?
    public let width: Int?
    public let height: Int?
    public let codecs: String?
    public let pairAudioURL: URL?
    public let pairCID: String?
    public let estimatedSize: Int64?
    public let fileExtension: String?
    public let duration: Double?

    public init(
        url: URL,
        label: String,
        bandwidth: Int?,
        width: Int?,
        height: Int?,
        codecs: String?,
        pairAudioURL: URL? = nil,
        pairCID: String? = nil,
        estimatedSize: Int64? = nil,
        fileExtension: String? = nil,
        duration: Double? = nil
    ) {
        self.url = url
        self.label = label
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.codecs = codecs
        self.pairAudioURL = pairAudioURL
        self.pairCID = pairCID
        self.estimatedSize = estimatedSize
        self.fileExtension = fileExtension
        self.duration = duration
    }

    /// Unified size estimate: bandwidth (bit/s) × duration (seconds) / 8.
    /// Used only for display hints (sniffing slots / confirmation dialogs); it does not
    /// affect download behavior or verification.
    /// Invalid input (non-positive bandwidth/duration) and results exceeding Int64 degrade
    /// to nil (unknown).
    public static func estimatedSize(bandwidth: Int?, duration: Double?) -> Int64? {
        guard let bandwidth, bandwidth > 0, let duration, duration > 0 else { return nil }
        let bytes = Double(bandwidth) * duration / 8
        guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }
}

public struct MediaInspection: Sendable {
    public let mediaKind: DownloadSourceKind
    public let variants: [MediaVariant]

    public init(mediaKind: DownloadSourceKind, variants: [MediaVariant]) {
        self.mediaKind = mediaKind
        self.variants = variants
    }
}

public enum MediaInspectionError: LocalizedError, Equatable {
    case unsupportedLiveStream
    /// Live status cannot be confirmed (missing/contradictory fields, unknown enum): a
    /// retryable inspection error; must not be treated as VOD (see the public technical specification).
    case liveStatusUnknown
    case invalidPlaylist(String)
    case youTubeToolUnavailable
    /// The site requires login, human verification, age or account verification.
    case authenticationRequired
    /// Cookies are allowed for the request, but no usable context exists or the temporary
    /// cookie file cannot be created.
    case cookieContextUnavailable
    /// Network unreachable, proxy error, or timeout.
    case networkOrProxyFailure
    /// Error evidence clearly points to outdated extraction rules (e.g. nsig extraction failure).
    case toolUpdateSuggested
    /// The page was parsed successfully but has no usable non-DRM video formats.
    case noFormats
    /// The external tool's (e.g. yt-dlp) process group could not be confirmed cleaned up
    /// within budget: a distinct blocking error class that must not masquerade as a network,
    /// proxy, or missing-tool failure; this run's output must not be parsed or merged, and
    /// the caller may retry.
    case processCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedLiveStream:
            "正在直播或即将直播的内容暂不支持，MacIDM 只接受已结束的点播流（含已结束直播回放）。"
        case .liveStatusUnknown:
            "无法确认内容的直播状态，为避免误下载已中止检查；请稍后重试。"
        case .invalidPlaylist(let detail):
            "无法解析媒体播放列表：" + detail
        case .youTubeToolUnavailable:
            "YouTube 画质解析需要 yt-dlp"
        case .authenticationRequired:
            String(localized: "YouTube 要求登录或人机验证，无法解析画质。请先在浏览器登录该站点后重试。")
        case .cookieContextUnavailable:
            String(localized: "Cookie 上下文不可用，无法完成需要登录态的解析。")
        case .networkOrProxyFailure:
            String(localized: "网络或代理连接失败或超时，请检查网络后重试。")
        case .toolUpdateSuggested:
            String(localized: "yt-dlp 版本过旧，无法解析该页面，请更新后重试。")
        case .noFormats:
            String(localized: "解析成功，但该视频没有可下载的视频格式。")
        case .processCleanupFailed:
            String(
                localized: "解析工具的进程组未能在预算内完成清理，为避免残留进程干扰已中止本次检查；请稍后重试。"
            )
        }
    }
}

public protocol MediaInspecting: Sendable {
    func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection
}

public struct HLSMediaInspector: MediaInspecting {
    private let client: any HLSResourceClient
    private let parser: HLSParser

    /// Budget for the second fetch that backfills duration from a master playlist; on
    /// timeout it silently degrades to "size unknown".
    private static let subPlaylistProbeTimeout: TimeInterval = 8

    public init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        parser: HLSParser = HLSParser()
    ) {
        self.client = client
        self.parser = parser
    }

    public func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        guard mediaKind == .hls else {
            throw MediaInspectionError.invalidPlaylist("HLS 检查器收到不匹配的媒体类型")
        }
        let response = try await client.fetch(
            HLSFetchRequest(
                url: url,
                requestContext: requestContext,
                contextOriginURL: url
            )
        )
        guard let playlistText = String(data: response.data, encoding: .utf8) else {
            throw MediaInspectionError.invalidPlaylist("不是 UTF-8 文本")
        }
        do {
            switch try parser.parse(playlistText, baseURL: response.finalURL) {
            case .master(let master):
                let sortedVariants = master.variants
                    .sorted {
                        ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth)
                    }
                    .prefix(100)
                guard !sortedVariants.isEmpty else {
                    throw MediaInspectionError.invalidPlaylist("master playlist 没有变体")
                }
                // The master playlist itself carries no duration: fetch the sub-playlist
                // once more for the highest-bandwidth variant to get the total duration,
                // which all variants share for the bandwidth × duration / 8 estimate;
                // failures degrade silently.
                let highestBandwidthVariant = master.variants.max { $0.bandwidth < $1.bandwidth }
                let sharedDuration = await subPlaylistDuration(
                    for: highestBandwidthVariant?.url,
                    requestContext: requestContext
                )
                let variants = sortedVariants.map { variant in
                    MediaVariant(
                        url: variant.url,
                        label: label(for: variant),
                        bandwidth: variant.bandwidth,
                        width: variant.width,
                        height: variant.height,
                        codecs: variant.codecs,
                        estimatedSize: MediaVariant.estimatedSize(
                            bandwidth: variant.bandwidth > 0 ? variant.bandwidth : nil,
                            duration: sharedDuration
                        ),
                        duration: sharedDuration
                    )
                }
                return MediaInspection(mediaKind: .hls, variants: Array(variants))
            case .media(let media):
                guard media.isVideoOnDemand else {
                    throw MediaInspectionError.unsupportedLiveStream
                }
                let totalDuration = media.segments.map(\.duration).reduce(0, +)
                return MediaInspection(
                    mediaKind: .hls,
                    variants: [
                        MediaVariant(
                            url: response.finalURL,
                            label: "自动（单画质流，无多画质可选）",
                            bandwidth: nil,
                            width: nil,
                            height: nil,
                            codecs: nil,
                            duration: totalDuration > 0 ? totalDuration : nil
                        )
                    ]
                )
            }
        } catch let error as MediaInspectionError {
            throw error
        } catch {
            throw MediaInspectionError.invalidPlaylist(error.localizedDescription)
        }
    }

    /// Fetches the sub-playlist and computes the total duration (sum of EXTINF), with a
    /// timeout; any failure returns nil.
    private func subPlaylistDuration(
        for url: URL?,
        requestContext: DownloadRequestContext?
    ) async -> Double? {
        guard let url else { return nil }
        return await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                do {
                    let response = try await self.client.fetch(
                        HLSFetchRequest(
                            url: url,
                            requestContext: requestContext,
                            contextOriginURL: url
                        )
                    )
                    guard let text = String(data: response.data, encoding: .utf8) else { return nil }
                    guard case .media(let media) = try self.parser.parse(text, baseURL: response.finalURL),
                        media.isVideoOnDemand
                    else { return nil }
                    let total = media.segments.map(\.duration).reduce(0, +)
                    return total > 0 ? total : nil
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.subPlaylistProbeTimeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func label(for variant: HLSVariant) -> String {
        let label = MediaVariantLabel.format(
            width: variant.width,
            height: variant.height,
            codecs: variant.codecs,
            bandwidth: variant.bandwidth > 0 ? variant.bandwidth : nil
        )
        return label.isEmpty ? "自动（默认画质）" : label
    }
}

public struct DASHMediaInspector: MediaInspecting {
    private let client: any HLSResourceClient
    private let parser: DASHParser

    public init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        parser: DASHParser = DASHParser()
    ) {
        self.client = client
        self.parser = parser
    }

    public func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        guard mediaKind == .dash else {
            throw MediaInspectionError.invalidPlaylist("DASH 检查器收到不匹配的媒体类型")
        }
        let response = try await client.fetch(
            HLSFetchRequest(
                url: url,
                requestContext: requestContext,
                contextOriginURL: url
            )
        )
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw MediaInspectionError.invalidPlaylist("不是 UTF-8 文本")
        }
        do {
            let manifest = try parser.parse(text, baseURL: response.finalURL)
            let video = manifest.videoRepresentations.max(by: compare)
            let audio = manifest.audioRepresentations.max(by: compare)
            guard let selected = video ?? audio else {
                throw MediaInspectionError.invalidPlaylist("MPD 没有可用音视频 Representation")
            }
            let label = dashLabel(video: video, audio: audio)
            // The size estimate uses the combined "video + audio" total bandwidth; the
            // variant's bandwidth field keeps the selected top Representation's bandwidth so
            // the short-label semantics stay unpolluted by the total.
            let mergedBandwidth = Self.mergedBandwidth(video: video, audio: audio)
            return MediaInspection(
                mediaKind: .dash,
                variants: [
                    MediaVariant(
                        url: response.finalURL,
                        label: label,
                        bandwidth: selected.bandwidth > 0 ? selected.bandwidth : nil,
                        width: video?.width,
                        height: video?.height,
                        codecs: [video?.codecs, audio?.codecs]
                            .compactMap { $0 }
                            .joined(separator: ","),
                        estimatedSize: MediaVariant.estimatedSize(
                            bandwidth: mergedBandwidth,
                            duration: manifest.duration
                        ),
                        duration: manifest.duration
                    )
                ]
            )
        } catch let error as MediaInspectionError {
            throw error
        } catch DASHParserError.unsupportedLiveManifest {
            throw MediaInspectionError.unsupportedLiveStream
        } catch {
            throw MediaInspectionError.invalidPlaylist(error.localizedDescription)
        }
    }

    private func compare(_ lhs: DASHRepresentation, _ rhs: DASHRepresentation) -> Bool {
        (lhs.height ?? 0, lhs.bandwidth) < (rhs.height ?? 0, rhs.bandwidth)
    }

    /// Total bandwidth for size estimation: positive video and audio bandwidths are summed,
    /// or the single track's value when only one exists; returns nil (unknown) when all are
    /// invalid or the sum overflows.
    private static func mergedBandwidth(video: DASHRepresentation?, audio: DASHRepresentation?) -> Int? {
        var total = 0
        for bandwidth in [video?.bandwidth, audio?.bandwidth].compactMap({ $0 }) where bandwidth > 0 {
            let (sum, overflow) = total.addingReportingOverflow(bandwidth)
            if overflow { return nil }
            total = sum
        }
        return total > 0 ? total : nil
    }

    private func dashLabel(video: DASHRepresentation?, audio: DASHRepresentation?) -> String {
        let detail = MediaVariantLabel.format(
            width: video?.width,
            height: video?.height,
            codecs: video?.codecs,
            bandwidth: (video?.bandwidth ?? 0) > 0 ? video?.bandwidth : nil
        )
        let tracks = [video == nil ? nil : "视频", audio == nil ? nil : "音频"]
            .compactMap { $0 }
            .joined(separator: "+")
        if detail.isEmpty {
            return tracks.isEmpty ? "自动" : "自动 · " + tracks
        }
        return tracks.isEmpty ? detail : detail + " · " + tracks
    }
}

public struct CompositeMediaInspector: MediaInspecting {
    private let hls: HLSMediaInspector
    private let dash: DASHMediaInspector

    public init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        hlsParser: HLSParser = HLSParser(),
        dashParser: DASHParser = DASHParser()
    ) {
        hls = HLSMediaInspector(client: client, parser: hlsParser)
        dash = DASHMediaInspector(client: client, parser: dashParser)
    }

    public func inspect(
        url: URL,
        requestContext: DownloadRequestContext?,
        mediaKind: DownloadSourceKind
    ) async throws -> MediaInspection {
        switch mediaKind {
        case .hls: return try await hls.inspect(url: url, requestContext: requestContext, mediaKind: .hls)
        case .dash: return try await dash.inspect(url: url, requestContext: requestContext, mediaKind: .dash)
        case .http: throw MediaInspectionError.invalidPlaylist("直链不需要播放列表检查")
        }
    }
}
