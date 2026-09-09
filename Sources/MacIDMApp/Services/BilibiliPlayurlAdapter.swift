import CryptoKit
import Foundation
import IDMEngine

struct BilibiliPlayurlOption: Equatable, Sendable {
    let title: String
    let videoURL: URL
    let audioURL: URL
    /// Stream requests often require the page Referer and a browser UA even
    /// when the public playurl API itself is accessible without cookies.
    /// This remains transient and is never part of AppTask persistence.
    let requestContext: DownloadRequestContext?
    let quality: Int?
    let width: Int?
    let height: Int?
    let bandwidth: Int64?
    let codecs: String?
    /// Total duration of the whole video (seconds), from playurl's
    /// dash.duration / time_length.
    let duration: Double?
    /// Estimated total size ((video+audio track bandwidth × duration) / 8);
    /// display hint only, never affects the download.
    let estimatedSize: Int64?
}

enum BilibiliPlayurlError: LocalizedError, Equatable {
    case unsupportedURL
    case invalidResponse
    case api(code: Int, message: String)
    case missingTracks

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return String(localized: "不是受支持的 Bilibili 视频地址。")
        case .invalidResponse:
            return String(localized: "Bilibili 播放接口返回了无法解析的数据。")
        case .api(let code, let message):
            if code == -10403 || code == -10401 {
                return String(localized: "Bilibili 拒绝了请求（需要登录或大会员权限）：") + message
            }
            return String(localized: "Bilibili 播放接口拒绝了请求（code \(code)）：") + message
        case .missingTracks:
            return String(
                localized: "Bilibili 未返回可下载的音视频轨道（可能需要登录或授权 Cookie）。"
            )
        }
    }
}

/// Bounded Bilibili page adapter. It consumes the public view/playurl API,
/// creates a transient video/audio pair, and deliberately does not attempt to
/// bypass login, DRM, or encrypted-only streams.
struct BilibiliPlayurlAdapter: Sendable {
    private let client: any HLSResourceClient
    private let clock: @Sendable () -> Date

    init(
        client: any HLSResourceClient = URLSessionHLSResourceClient(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.clock = clock
    }

    static func supports(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalized == "bilibili.com" || normalized.hasSuffix(".bilibili.com") else {
            return false
        }
        if url.path.range(of: #"^/video/(?:BV[0-9A-Za-z]+|av\d+)"#, options: .regularExpression) != nil {
            return true
        }
        // Bangumi (anime/drama): /bangumi/play/ssXXXX or /bangumi/play/epXXXX
        if url.path.range(of: #"^/bangumi/play/(?:ss\d+|ep\d+)"#, options: .regularExpression) != nil {
            return true
        }
        // The watch-later list page /list/watchlater/?bvid=BVxxx&oid=avid embeds
        // the same player; the video identity lives in the query parameters.
        // Supported only when the identity resolves, so the whole list page is
        // never treated as a single video.
        if url.path.range(of: #"^/list/watchlater/?"#, options: .regularExpression) != nil {
            return VideoIdentity(url: url) != nil
        }
        return false
    }

    /// Parses the `{cid}-1-{format_id}.m4s` track filename Bilibili uses for
    /// DASH segments and returns the `format_id` (the quality/codec
    /// identifier). Persisting it lets a re-resolve after restart pick the
    /// exact track a paused task was downloading. Mirrors the extension's
    /// `extractM4sInfo` shape; nil for any URL that is not an m4s track.
    static func m4sFormatID(in url: URL) -> Int? {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".m4s") else { return nil }
        let parts = name.dropLast(".m4s".count)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "1",
            Int(parts[0]) != nil, let formatID = Int(parts[2])
        else { return nil }
        return formatID
    }

    /// Whether the URL is a Bilibili upos mirror. upos serves byte ranges
    /// with a stable strong ETag, so downloads from it get segmented parallel
    /// transfer and verified resume; the default baseUrl (mcdn/PCDN edges)
    /// serves single streams without an ETag at all.
    static func isUposMirror(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasPrefix("upos-") && host.hasSuffix(".bilivideo.com")
    }

    func resolve(
        pageURL: URL,
        requestContext: DownloadRequestContext? = nil
    ) async throws -> [BilibiliPlayurlOption] {
        guard Self.supports(pageURL), let identity = VideoIdentity(url: pageURL) else {
            throw BilibiliPlayurlError.unsupportedURL
        }

        if identity.isBangumi {
            return try await resolveBangumi(
                identity: identity,
                pageURL: pageURL,
                requestContext: requestContext
            )
        }

        let view = try await fetchView(
            identity: identity,
            pageURL: pageURL,
            requestContext: requestContext
        )
        let metadata: BilibiliVideoMetadata
        do {
            let data = try JSONSerialization.data(withJSONObject: view["data"] ?? [:])
            metadata = try JSONDecoder().decode(BilibiliVideoMetadata.self, from: data)
        } catch { throw BilibiliPlayurlError.invalidResponse }
        let title = metadata.title ?? String(localized: "Bilibili 视频")
        let cid = try metadata.selectedCID(pageURL: pageURL)

        let playurl = try await fetchPlayurl(
            identity: identity,
            cid: cid,
            aid: metadata.aid,
            pageURL: pageURL,
            requestContext: requestContext
        )
        let parsed = try Self.parseOptions(playurl, title: title)
        let streamContext = Self.streamRequestContext(
            identity: identity,
            pageURL: pageURL,
            requestContext: requestContext
        )
        return parsed.map { option in
            BilibiliPlayurlOption(
                title: option.title,
                videoURL: option.videoURL,
                audioURL: option.audioURL,
                requestContext: streamContext,
                quality: option.quality,
                width: option.width,
                height: option.height,
                bandwidth: option.bandwidth,
                codecs: option.codecs,
                duration: option.duration,
                estimatedSize: option.estimatedSize
            )
        }
    }

    static func parseOptions(_ object: [String: Any], title: String) throws -> [BilibiliPlayurlOption] {
        let data = dictionary(object["data"]) ?? dictionary(object["result"]) ?? [:]
        guard let dash = dictionary(data["dash"])
        else { throw BilibiliPlayurlError.missingTracks }
        // Total duration prefers dash.duration (seconds); falls back to the
        // top-level time_length. The regular API's time_length is in seconds,
        // while the bangumi PGC API returns milliseconds; large values are
        // normalized.
        let duration = normalizedDuration(
            dashSeconds: doubleValue(dash["duration"]),
            timeLength: doubleValue(data["time_length"])
        )
        let audio = dictionaryArray(dash["audio"])
            .compactMap { item -> (url: URL, bandwidth: Int64?)? in
                guard let url = mediaURL(in: item) else { return nil }
                return (url: url, bandwidth: integer64(item["bandwidth"]))
            }
            .max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
        guard let audio else { throw BilibiliPlayurlError.missingTracks }

        let parsedVideos = dictionaryArray(dash["video"]).compactMap { item -> BilibiliPlayurlOption? in
            guard let videoURL = mediaURL(in: item) else { return nil }
            let videoBandwidth = integer64(item["bandwidth"])
            return BilibiliPlayurlOption(
                title: title,
                videoURL: videoURL,
                audioURL: audio.url,
                requestContext: nil,
                quality: integer(item["id"]),
                width: integer(item["width"]),
                height: integer(item["height"]),
                bandwidth: videoBandwidth,
                codecs: string(item["codecs"]),
                duration: duration,
                estimatedSize: estimatedTotalSize(
                    videoBandwidth: videoBandwidth,
                    audioBandwidth: audio.bandwidth,
                    duration: duration
                )
            )
        }
        guard !parsedVideos.isEmpty else { throw BilibiliPlayurlError.missingTracks }

        // Bilibili may return several Representation rows for the same
        // quality and codec (for example, the same AVC track through
        // different CDN entries). Keep the best bitrate for each selectable
        // quality/encoding combination, while preserving distinct codecs so
        // the user can choose between AVC, HEVC, AV1, and other formats.
        var bestByRepresentation: [String: BilibiliPlayurlOption] = [:]
        for option in parsedVideos {
            let key = representationKey(for: option)
            guard let existing = bestByRepresentation[key] else {
                bestByRepresentation[key] = option
                continue
            }
            if (option.bandwidth ?? 0) > (existing.bandwidth ?? 0) {
                bestByRepresentation[key] = option
            }
        }
        let videos = Array(bestByRepresentation.values)
        return videos.sorted { lhs, rhs in
            let leftHeight = lhs.height ?? 0
            let rightHeight = rhs.height ?? 0
            if leftHeight != rightHeight { return leftHeight > rightHeight }
            return (lhs.bandwidth ?? 0) > (rhs.bandwidth ?? 0)
        }
    }

    /// Shows only the codec family name (e.g. H.264); profile/level FourCCs
    /// such as avc1.640033 add no information for quality selection and no
    /// longer appear in the display layer (deduplication still uses the raw value).
    static func displayCodec(_ codecs: String?) -> String? {
        MediaVariantLabel.family(forCodecs: codecs)
    }

    /// Normalizes playurl duration fields to seconds: dash.duration and the
    /// regular time_length are seconds; the bangumi PGC time_length is
    /// milliseconds, so values over 100,000 are divided by 1000.
    static func normalizedDuration(dashSeconds: Double?, timeLength: Double?) -> Double? {
        guard let raw = dashSeconds ?? timeLength, raw > 0, raw.isFinite else { return nil }
        return raw >= 100_000 ? raw / 1000 : raw
    }

    /// Estimated total size: (video+audio) bandwidth bit/s × duration s / 8.
    /// Returns nil when any key input is missing; the UI then shows
    /// "size unknown".
    static func estimatedTotalSize(
        videoBandwidth: Int64?,
        audioBandwidth: Int64?,
        duration: Double?
    ) -> Int64? {
        guard let duration, duration > 0 else { return nil }
        let totalBandwidth = (videoBandwidth ?? 0) + (audioBandwidth ?? 0)
        guard totalBandwidth > 0 else { return nil }
        return Int64((Double(totalBandwidth) * duration / 8).rounded())
    }

    private static func representationKey(for option: BilibiliPlayurlOption) -> String {
        let quality = option.quality.map(String.init) ?? "unknown-quality"
        let width = option.width.map(String.init) ?? "unknown-width"
        let height = option.height.map(String.init) ?? "unknown-height"
        let normalizedCodec = (option.codecs ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let codec = normalizedCodec.isEmpty ? "unknown-codec" : normalizedCodec
        return [quality, width, height, codec].joined(separator: "|")
    }

    /// Bangumi (anime/drama) resolution: fetches season info, picks the
    /// matching episode, and calls the PGC playurl API. The response format
    /// is the same DASH structure as regular videos, so `parseOptions`
    /// handles it without modification.
    private func resolveBangumi(
        identity: VideoIdentity,
        pageURL: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> [BilibiliPlayurlOption] {
        // 1. Fetch season info to resolve ep_id / cid / title.
        var components = URLComponents(string: "https://api.bilibili.com/pgc/view/web/season")!
        components.queryItems = identity.queryItems
        let season = try await fetchJSON(
            url: components.url!,
            pageURL: pageURL,
            requestContext: requestContext,
            cookieOriginURL: components.url!
        )
        let result = dictionary(season["result"]) ?? [:]
        let seasonTitle = string(result["title"]) ?? String(localized: "Bilibili 番剧")
        let episodes = dictionaryArray(result["episodes"])

        // Pick the episode matching ep_id, or the first one for ss URLs.
        let episode: [String: Any]?
        if identity.queryName == "ep_id" {
            episode =
                episodes.first { String(integer($0["id"]) ?? 0) == identity.queryValue }
                ?? episodes.first
        } else {
            episode = episodes.first
        }
        guard let ep = episode,
            let cid = integer(ep["cid"]),
            let epId = integer(ep["id"])
        else { throw BilibiliPlayurlError.invalidResponse }

        let epTitle = string(ep["long_title"]) ?? string(ep["title"]) ?? seasonTitle
        let displayTitle = "\(seasonTitle) · \(epTitle)"

        // 2. Fetch the PGC playurl. The bangumi endpoint does not use WBI
        // signing; it accepts ep_id + cid directly.
        var playurlComponents = URLComponents(string: "https://api.bilibili.com/pgc/player/web/playurl")!
        var params: [String: String] = [
            "ep_id": String(epId),
            "cid": String(cid),
            "fnval": "4048",
            "fnver": "0",
            "fourk": "1",
            "otype": "json",
            "platform": "pc",
            "qn": "120",
        ]
        if let aid = integer(ep["aid"]) { params["avid"] = String(aid) }
        playurlComponents.queryItems = params.keys.sorted().map {
            URLQueryItem(name: $0, value: params[$0])
        }
        let playurl = try await fetchJSON(
            url: playurlComponents.url!,
            pageURL: pageURL,
            requestContext: requestContext,
            cookieOriginURL: playurlComponents.url!
        )
        let parsed = try Self.parseOptions(playurl, title: displayTitle)
        let streamContext = Self.streamRequestContext(
            identity: identity,
            pageURL: pageURL,
            requestContext: requestContext
        )
        return parsed.map { option in
            BilibiliPlayurlOption(
                title: option.title,
                videoURL: option.videoURL,
                audioURL: option.audioURL,
                requestContext: streamContext,
                quality: option.quality,
                width: option.width,
                height: option.height,
                bandwidth: option.bandwidth,
                codecs: option.codecs,
                duration: option.duration,
                estimatedSize: option.estimatedSize
            )
        }
    }

    private func fetchView(
        identity: VideoIdentity,
        pageURL: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
        components.queryItems = identity.queryItems
        return try await fetchJSON(
            url: components.url!,
            pageURL: pageURL,
            requestContext: requestContext,
            cookieOriginURL: components.url!
        )
    }

    private func fetchPlayurl(
        identity: VideoIdentity,
        cid: Int,
        aid: Int?,
        pageURL: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> [String: Any] {
        let navURL = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        let navKey = await fetchWBIMixinKey(
            url: navURL,
            pageURL: pageURL,
            requestContext: requestContext
        )
        var parameters: [String: String] = [
            "cid": String(cid),
            "fnval": "4048",
            "fnver": "0",
            "fourk": "1",
            "otype": "json",
            "platform": "pc",
            // Ask for the highest broadly supported web quality. qn=120 is
            // Bilibili's 4K level; qn=127 is 8K and can make a 4K account
            // fall back to a 480p/360p-only response when the video has no
            // 8K representation.
            "qn": "120",
            "wts": String(Int(clock().timeIntervalSince1970)),
        ]
        // The current public endpoint is more reliable with avid than bvid.
        // The view response supplies aid for BV pages, while the identity
        // fallback keeps fixture/older deployments compatible.
        if let aid {
            parameters["avid"] = String(aid)
        } else {
            parameters[identity.queryName] = identity.queryValue
        }
        if let key = navKey {
            parameters["w_rid"] = Self.wbiSignature(parameters: parameters, mixinKey: key)
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        components.queryItems = parameters.keys.sorted().map {
            URLQueryItem(name: $0, value: parameters[$0])
        }
        let fallback = {
            var fallbackComponents = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
            fallbackComponents.queryItems =
                parameters
                .filter { $0.key != "w_rid" && $0.key != "wts" }
                .keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
            return fallbackComponents.url!
        }
        do {
            let response = try await fetchJSON(
                url: components.url!,
                pageURL: pageURL,
                requestContext: requestContext,
                cookieOriginURL: components.url!
            )
            if Self.hasDASHTracks(response) {
                return response
            }
        } catch BilibiliPlayurlError.api {
        }
        // Some guest responses return code 0 with only a voucher rather than
        // DASH. Older/public deployments still expose the unsigned endpoint,
        // so retry once with the same bounded parameter set.
        return try await fetchJSON(
            url: fallback(),
            pageURL: pageURL,
            requestContext: requestContext,
            cookieOriginURL: fallback()
        )
    }

    private func fetchWBIMixinKey(
        url: URL,
        pageURL: URL,
        requestContext: DownloadRequestContext?
    ) async -> String? {
        guard
            let response = try? await client.fetch(
                HLSFetchRequest(
                    url: url,
                    requestContext: requestContext,
                    // The WBI key is a Bilibili API response. Keep the
                    // transient cookie scoped to that exact API origin; it
                    // must never be sent to the video CDN.
                    contextOriginURL: url
                )
            ),
            response.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else { return nil }
        // nav returns code -101 for a guest, but still includes wbi_img.
        return Self.wbiMixinKey(from: object)
    }

    private func fetchJSON(
        url: URL,
        pageURL: URL,
        requestContext: DownloadRequestContext?,
        cookieOriginURL: URL? = nil
    ) async throws -> [String: Any] {
        let response = try await client.fetch(
            HLSFetchRequest(
                url: url,
                requestContext: requestContext,
                contextOriginURL: cookieOriginURL ?? pageURL
            )
        )
        guard response.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let code = integer(object["code"])
        else { throw BilibiliPlayurlError.invalidResponse }
        guard code == 0 else {
            throw BilibiliPlayurlError.api(
                code: code,
                message: string(object["message"]) ?? String(localized: "未知错误")
            )
        }
        return object
    }

    private struct VideoIdentity: Sendable {
        let queryName: String
        let queryValue: String
        let queryItems: [URLQueryItem]
        let isBangumi: Bool
        /// The bare path of a list page (e.g. watch-later) is not a valid
        /// playback-page Referer; when the identity resolves, provides the
        /// canonical video-page path as a fallback for manually pasted URLs
        /// with no browser context.
        let canonicalPagePath: String?

        init?(url: URL) {
            let path = url.path
            if let match = path.range(of: #"/video/(BV[0-9A-Za-z]+)"#, options: .regularExpression) {
                let value = String(path[match]).replacingOccurrences(of: "/video/", with: "")
                queryName = "bvid"
                queryValue = value
                queryItems = [URLQueryItem(name: "bvid", value: value)]
                isBangumi = false
                canonicalPagePath = nil
                return
            }
            if let match = path.range(of: #"/video/(av\d+)"#, options: .regularExpression) {
                let value = String(path[match]).replacingOccurrences(of: "/video/av", with: "")
                queryName = "aid"
                queryValue = value
                queryItems = [URLQueryItem(name: "aid", value: value)]
                isBangumi = false
                canonicalPagePath = nil
                return
            }
            // Bangumi: /bangumi/play/ssXXXX (season) or /bangumi/play/epXXXX (episode)
            if let match = path.range(of: #"/bangumi/play/(ss\d+)"#, options: .regularExpression) {
                let value = String(path[match]).replacingOccurrences(of: "/bangumi/play/", with: "")
                queryName = "season_id"
                queryValue = value.replacingOccurrences(of: "ss", with: "")
                queryItems = [URLQueryItem(name: "season_id", value: queryValue)]
                isBangumi = true
                canonicalPagePath = nil
                return
            }
            if let match = path.range(of: #"/bangumi/play/(ep\d+)"#, options: .regularExpression) {
                let value = String(path[match]).replacingOccurrences(of: "/bangumi/play/", with: "")
                queryName = "ep_id"
                queryValue = value.replacingOccurrences(of: "ep", with: "")
                queryItems = [URLQueryItem(name: "ep_id", value: queryValue)]
                isBangumi = true
                canonicalPagePath = nil
                return
            }
            // Watch-later list page: /list/watchlater/?bvid=BVxxx&oid=avid.
            // The SPA updates both parameters when switching videos, so the
            // current URL always points to the entry being played. bvid wins;
            // oid is treated as avid only when missing (matching how
            // Bilibili's playurl request on that page behaves).
            if path.range(of: #"^/list/watchlater/?"#, options: .regularExpression) != nil {
                let urlQueryItems =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func parameter(_ name: String) -> String? {
                    urlQueryItems.first { $0.name == name }?.value
                }
                if let bvid = parameter("bvid"),
                    bvid.range(of: #"^BV[0-9A-Za-z]+$"#, options: .regularExpression) != nil
                {
                    self.queryName = "bvid"
                    queryValue = bvid
                    self.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
                    isBangumi = false
                    canonicalPagePath = "/video/\(bvid)/"
                    return
                }
                if let oid = parameter("oid") ?? parameter("avid"),
                    oid.range(of: #"^\d+$"#, options: .regularExpression) != nil
                {
                    queryName = "aid"
                    queryValue = oid
                    self.queryItems = [URLQueryItem(name: "aid", value: oid)]
                    isBangumi = false
                    canonicalPagePath = "/video/av\(oid)/"
                    return
                }
            }
            return nil
        }
    }

    private static let wbiPermutation = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 60, 7, 36, 24, 14, 44,
        37, 48, 38, 4, 59, 39, 56, 12, 55, 1, 13, 51, 17, 62, 22, 61,
        11, 54, 21, 16, 6, 26, 34, 20, 57, 30, 52, 41, 25, 63, 40, 0,
    ]

    /// Bilibili's public CDN commonly checks both Referer and User-Agent for
    /// the m4s track requests. A manually pasted page has no browser context,
    /// so use only the page URL (without query/fragment) and a fixed desktop
    /// UA; an explicitly supplied browser context still wins field by field.
    private static func streamRequestContext(
        identity: VideoIdentity,
        pageURL: URL,
        requestContext: DownloadRequestContext?
    ) -> DownloadRequestContext {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        // Keep the non-secret part selector so a manually submitted second
        // part remains the same part after persisting its fallback referer.
        if let part = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
            $0.name == "p"
        }),
            let value = part.value, let number = Int(value), number > 0
        {
            components?.queryItems = [URLQueryItem(name: "p", value: String(number))]
        }
        // List pages such as watch-later reduce to /list/watchlater/ once the
        // query is stripped — not a playback page; use the canonical video page
        // as the fallback Referer when the identity resolves.
        let fallbackReferer =
            identity.canonicalPagePath.map { "https://www.bilibili.com" + $0 }
            ?? components?.url?.absoluteString ?? pageURL.absoluteString
        return DownloadRequestContext(
            cookie: requestContext?.cookie,
            referer: requestContext?.referer ?? fallbackReferer,
            userAgent: requestContext?.userAgent ?? Self.fallbackUserAgent
        )
    }

    private static let fallbackUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.0 Safari/605.1.15"

    private static func wbiMixinKey(from nav: [String: Any]) -> String? {
        guard let data = dictionary(nav["data"]),
            let image = dictionary(data["wbi_img"]),
            let imgURL = string(image["img_url"]),
            let subURL = string(image["sub_url"])
        else { return nil }
        let imgName = URL(string: imgURL)?.deletingPathExtension().lastPathComponent ?? ""
        let subName = URL(string: subURL)?.deletingPathExtension().lastPathComponent ?? ""
        let raw = imgName + subName
        guard !raw.isEmpty else { return nil }
        let chars = Array(raw)
        return String(wbiPermutation.compactMap { index in chars[safe: index] }.prefix(32))
    }

    private static func wbiSignature(parameters: [String: String], mixinKey: String) -> String {
        let queryAllowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        let query = parameters.keys.sorted().map {
            "\($0)=\(parameters[$0]!.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? "")"
        }.joined(separator: "&")
        return SHA256.hash(data: Data((query + mixinKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func hasDASHTracks(_ object: [String: Any]) -> Bool {
        guard let data = dictionary(object["data"]),
            let dash = dictionary(data["dash"])
        else { return false }
        return !dictionaryArray(dash["video"]).isEmpty && !dictionaryArray(dash["audio"]).isEmpty
    }
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func dictionaryArray(_ value: Any?) -> [[String: Any]] {
    (value as? [[String: Any]]) ?? []
}

private func string(_ value: Any?) -> String? {
    value as? String
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
}

private func integer64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
}

private func mediaURL(in item: [String: Any]) -> URL? {
    let candidates =
        [item["baseUrl"], item["base_url"]].compactMap { $0 as? String }
        + ((item["backupUrl"] as? [String]) ?? (item["backup_url"] as? [String]) ?? [])
    let usable = candidates.compactMap(URL.init(string:)).filter { url in
        url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }
    // Prefer an upos mirror when the playurl offers one: the mcdn/PCDN baseUrl
    // only serves single streams (no strong ETag), while upos supports the
    // verified-resume range dialect.
    return usable.first { BilibiliPlayurlAdapter.isUposMirror($0) } ?? usable.first
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
