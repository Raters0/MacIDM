import Foundation
import IDMEngine
import UniformTypeIdentifiers

enum DownloadNaming {
    /// Placeholder base names shared with the extension's `smartMediaName`
    /// generic filter (technical spec §8.1): a hint whose stem is one of these
    /// carries no information and never wins over the page title. The two
    /// lists must stay identical; cross-end tests lock them together.
    static func isGenericFilename(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return true }
        let base = URL(fileURLWithPath: value)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        return [
            "download", "media", "video", "audio",
            "index", "master", "playlist", "manifest",
        ].contains(base)
    }

    static func nonEmptyPageTitle(_ value: String?) -> String? {
        let title = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    /// Trailing brand names the extension's `stripBrandSuffix` drops without a
    /// host match (technical spec §8.1). Chinese sites append their brand in
    /// CJK ("某视频_哔哩哔哩", "某视频 - 抖音"), which never equals a host
    /// token, so both ends carry the same list; the cross-end test locks them
    /// together. Lowercased for comparison.
    private static let brandTailTokens: Set<String> = [
        "抖音", "哔哩哔哩", "bilibili", "优酷", "爱奇艺", "腾讯视频", "youtube",
    ]

    /// Generic media words a site may append after its brand in a title tail
    /// ("…-哔哩哔哩视频", "… - YouTube 视频", "… - 抖音精选"). Mirrors the
    /// extension's BRAND_TAIL_MEDIA_WORDS; the cross-end test locks both lists.
    private static let brandTailMediaWords: Set<String> = [
        "视频", "媒体", "影片", "频道", "精选", "首页", "官方",
        "video", "videos", "media", "channel", "home", "official",
    ]

    /// True when a title tail is branding only: one or more brand tokens with
    /// optional generic media words in between. At least one brand token is
    /// required, and nothing may follow, so a real tail is never truncated —
    /// neither "- 官方视频" (no brand) nor "- 哔哩哔哩弹幕网" (content after the
    /// brand).
    private static func isBrandOnlyTail(_ segment: String) -> Bool {
        var rest = trimmedLowercased(segment)
        var sawBrand = false
        while !rest.isEmpty {
            if let token = brandTailTokens.first(where: { rest.hasPrefix($0) }) {
                rest = afterPrefix(rest, token)
                sawBrand = true
            } else if let word = brandTailMediaWords.first(where: { rest.hasPrefix($0) }) {
                rest = afterPrefix(rest, word)
            } else {
                break
            }
        }
        return sawBrand && rest.isEmpty
    }

    private static func trimmedLowercased(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func afterPrefix(_ value: String, _ prefix: String) -> String {
        String(value.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that make a title page-level chrome when they are all it
    /// contains ("精选", "首页"). Mirrors the extension's PAGE_CHROME_WORDS.
    private static let pageChromeWords: Set<String> = ["精选", "首页", "homepage", "home"]

    /// List/playlist-page markers: a segment that names the page rather than
    /// one media item. Deliberately unambiguous multi-character entries only —
    /// matched per separator-delimited segment, never as a substring, so real
    /// titles such as "订阅经济", "如何收藏这部电影" or "收藏 | 教程" survive.
    private static let pageChromeMarkers: Set<String> = [
        "稍后再看", "稍后观看", "自动连播", "收藏夹", "播放列表", "追番", "追剧",
        "watch later", "watchlater", "playlist", "subscriptions", "trending",
    ]

    private static let titleSegmentSeparators = CharacterSet(
        charactersIn: " \t|·–—-_/、,，:：()（）[]【】")

    /// True when a page title names the page instead of the media: every
    /// segment is a chrome word, or one segment is a list-page marker. A real
    /// composite reaches the App through the overlay's cross-origin iframe
    /// fallback, where no proximity title is available, and would otherwise
    /// become the disk name ("…| 中国坐标-raters-稍后再看.mp4").
    ///
    /// The extension runs a wider gate before synthesis (`isGenericOrBrandTitle`
    /// also rejects any surviving brand token). That test is deliberately NOT
    /// mirrored here: on the extension a false positive only falls back to a
    /// placeholder hint, while here it would discard the last usable name —
    /// a page titled "YouTube Rewind 2018" with a placeholder hint would
    /// degrade to "media.mp4".
    static func isPageChromeTitle(_ value: String?) -> Bool {
        guard let title = nonEmptyPageTitle(value) else { return false }
        // "抖音精选", "哔哩哔哩", "YouTube": the whole title decomposes into
        // brand tokens and generic media words, so it names the site, not the
        // media. Reusing the tail rule keeps this exact-match — a title that
        // merely contains a brand word ("YouTube Rewind 2018") is kept.
        if isBrandOnlyTail(title) { return true }
        let segments = title.lowercased()
            .components(separatedBy: Self.titleSegmentSeparators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }
        if segments.allSatisfy({ Self.pageChromeWords.contains($0) }) { return true }
        return segments.contains(where: { Self.pageChromeMarkers.contains($0) })
    }

    /// True when one separator-delimited segment is list-page chrome.
    private static func isChromeSegment(_ segment: String) -> Bool {
        let lowered = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        return pageChromeMarkers.contains(lowered) || pageChromeWords.contains(lowered)
    }

    /// Strips trailing site-brand segments (" - Hanime1.me", "| Example",
    /// "_bilibili") from a page title before it enters the naming chain. A
    /// segment is removed when it matches one of the page hosts (full host,
    /// host without "www.", or the host's first label) or a known brand token,
    /// so real titles containing separators ("Love is War - Episode 3") are
    /// never truncated. Stripping repeats because sites stack tails: Bilibili's
    /// og:title/document.title reads "标题_哔哩哔哩_bilibili", and a single
    /// pass would leave the CJK brand in the disk name while the extension's
    /// display name had already dropped it (technical spec §8.1).
    static func semanticPageTitle(_ value: String?, hosts: [String?]) -> String? {
        guard let title = nonEmptyPageTitle(value) else { return nil }
        let separators: Set<Character> = ["-", "\u{2013}", "\u{2014}", "|", "\u{00B7}", "_"]
        let hostTokens = Set(
            hosts.compactMap { $0?.lowercased() }.flatMap { host -> [String] in
                let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let firstLabel = withoutWWW.split(separator: ".").first.map(String.init) ?? withoutWWW
                return [host, withoutWWW, firstLabel]
            }.filter { !$0.isEmpty })
        var result = title
        while let separatorIndex = result.lastIndex(where: { separators.contains($0) }) {
            let suffix = result[result.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = result[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep at least a readable stem; refuse to strip a title down to
            // one or two characters.
            guard !suffix.isEmpty, stem.count >= 3 else { break }
            let lowered = suffix.lowercased()
            guard hostTokens.contains(lowered) || Self.isBrandOnlyTail(suffix) else {
                break
            }
            result = stem
        }
        // Trim trailing list-page chrome the same way brand tails are trimmed
        // ("…| 中国坐标-raters-稍后再看" → "…| 中国坐标-raters"). Trimming beats
        // discarding: a composite page title still carries the content title at
        // the front, while discarding would hand the name back to a
        // placeholder hint ("Bilibili 媒体.mp4").
        while let separatorIndex = result.lastIndex(where: { separators.contains($0) }) {
            let suffix = result[result.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = result[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty, stem.count >= 3, Self.isChromeSegment(suffix) else { break }
            result = stem
        }
        // Whatever survived may still name the page rather than the media;
        // dropping it here lets the chain fall through to the hint,
        // Content-Disposition and the URL tail.
        guard !isPageChromeTitle(result) else { return nil }
        return result
    }

    static func filenameWithOutputExtension(
        _ filename: String,
        sourceKind: DownloadSourceKind,
        url: URL,
        resourceInfo: ResourceInfo?,
        backend: DownloadBackend = .native
    ) -> String {
        let safe = InputValidator.safeFilename(filename)
        let currentExtension = URL(fileURLWithPath: safe).pathExtension
        let extensionName: String
        switch sourceKind {
        case .hls, .dash:
            extensionName = "mp4"
        case .http:
            // Product contract (technical-spec §3.4): YouTube downloads are
            // uniformly output as MP4 by yt-dlp + FFmpeg; the UI picks a
            // quality/codec variant, and the source variant's container (e.g.
            // VP9's webm) must not enter the final filename — a container
            // suffix carried by the title is also overridden to mp4.
            if backend == .youtubeExtractor {
                extensionName = "mp4"
                break
            }
            let knownExtensions: Set<String> = [
                "mp4", "m4v", "webm", "mov", "mkv", "avi", "wmv", "flv",
                "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav",
                "zip", "rar", "7z", "gz", "tar",
                "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                "exe", "dmg", "pkg", "iso", "img",
                "ts", "m3u8", "mpd", "m4s",
                "txt", "csv", "json", "xml", "html", "htm",
                "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff",
            ]
            if !currentExtension.isEmpty && knownExtensions.contains(currentExtension.lowercased()) {
                return safe
            }
            extensionName = resourceInfo?.mimeType?.lowercased().hasPrefix("audio/") == true ? "m4a" : "mp4"
        }
        let stem =
            currentExtension.isEmpty
            ? safe
            : String(safe.dropLast(currentExtension.count + 1))
        return InputValidator.safeFilename(stem + "." + extensionName)
    }

    static func suggestedFilename(
        url: URL,
        sourceKind: DownloadSourceKind,
        filenameHint: String?,
        pageTitle: String?,
        resourceInfo: ResourceInfo?,
        label: String? = nil,
        hintSource: FilenameHintSource = .urlPath
    ) -> String {
        let rawHint = filenameHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneric = Self.isGenericFilename(rawHint)
        // Naming trust model (technical spec §8.1): only a browser-resolved or
        // title-derived hint outranks the page title. A URL-tail hint (sniffed
        // candidates like "407788-1080p.mp4") ranks below it — the title is what
        // the user recognized in the sniff panel, so it must also be the name
        // that lands on disk.
        var candidate: String?
        if !isGeneric && hintSource != .urlPath { candidate = rawHint }
        if candidate == nil {
            candidate = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if candidate == nil, !isGeneric { candidate = rawHint }
        if candidate == nil {
            candidate = resourceInfo?.suggestedFilename
        }
        if candidate == nil || Self.isGenericFilename(candidate) {
            // Signed blob URLs (GitHub release assets, Azure SAS…) hide the
            // real name in a response-content-disposition query parameter;
            // recover it locally before falling back to opaque path tails.
            candidate = Self.filenameFromContentDispositionQuery(of: url)
        }
        if candidate == nil || Self.isGenericFilename(candidate) {
            candidate = pageTitle ?? url.lastPathComponent.removingPercentEncoding
        }
        if candidate == nil || candidate == "" || candidate == "." {
            candidate = pageTitle ?? "media"
        }
        var base = InputValidator.safeFilename(candidate)
        if let label, sourceKind != .http, !label.isEmpty {
            let suffix = InputValidator.safeFilename(label)
            if base == "download" || base == "media.mp4" {
                base = suffix
            } else if !base.localizedCaseInsensitiveContains(suffix) {
                base = base + "-" + suffix
            }
        }
        switch sourceKind {
        case .hls, .dash:
            base = URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent
            return InputValidator.safeFilename(base + ".mp4")
        case .http:
            let currentExt = URL(fileURLWithPath: base).pathExtension.lowercased()
            // Real extensions are kept verbatim — including ones outside any
            // media list (AppImage, apk, deb…): Content-Disposition and the
            // browser's filename hint are authoritative. Only domain-TLD and
            // version-number tails (".io", ".tv", "…1.14.16") are stripped.
            if Self.isRealFileExtension(currentExt) {
                return base
            }
            let extensionName: String
            if resourceInfo?.mimeType?.lowercased().hasPrefix("audio/") == true {
                extensionName = "m4a"
            } else if Self.isRealFileExtension(url.pathExtension.lowercased()) {
                extensionName = url.pathExtension.lowercased()
            } else {
                // Extension-less media streams were the original reason this
                // fallback exists; ordinary files rarely reach it because
                // probes carry a Content-Disposition name.
                extensionName = "mp4"
            }
            // Strip the invalid extension from base before appending the correct one
            let stem = currentExt.isEmpty ? base : String(base.dropLast(currentExt.count + 1))
            return InputValidator.safeFilename(stem + "." + extensionName)
        }
    }

    /// Extension-looking suffixes that are really domain TLDs; page titles
    /// ending in them ("obsidian.io", "watch on twitch.tv") must not be
    /// mistaken for filenames.
    private static let domainLikeExtensions: Set<String> = [
        "com", "net", "org", "io", "me", "tv", "co", "cc", "to", "fm",
        "gg", "am", "la", "so", "ai", "dev", "xyz", "info", "online",
        "site", "shop", "store", "cloud", "link", "live", "world", "today",
    ]

    /// True when a suffix can be trusted as a file extension: at least two
    /// letters, not purely numeric (version tails like "16" in "1.14.16"),
    /// and not a well-known domain TLD.
    static func isRealFileExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count >= 2 && !ext.allSatisfy(\.isNumber)
            && !domainLikeExtensions.contains(ext)
    }

    /// Completes extension-less filenames from the MIME the server or the
    /// browser reported (e.g. GitHub codeload zips named "v0.8.95"). Returns
    /// nil for unknown or semantically empty types like octet-stream.
    static func fileExtensionForMIMEType(_ mimeType: String?) -> String? {
        guard
            let type = mimeType?.lowercased().split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces),
            !type.isEmpty
        else { return nil }
        switch type {
        case "application/zip": return "zip"
        case "application/x-7z-compressed": return "7z"
        case "application/vnd.rar", "application/x-rar-compressed": return "rar"
        case "application/gzip", "application/x-gzip": return "gz"
        case "application/x-tar": return "tar"
        case "application/x-bzip2": return "bz2"
        case "application/x-xz": return "xz"
        case "application/zstd", "application/x-zstd": return "zst"
        case "application/pdf": return "pdf"
        case "application/vnd.android.package-archive": return "apk"
        case "application/x-apple-diskimage": return "dmg"
        case "application/x-msdownload", "application/x-dosexec": return "exe"
        case "application/x-msi", "application/x-ms-installer": return "msi"
        case "application/vnd.debian.binary-package": return "deb"
        case "application/x-rpm": return "rpm"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/avif": return "avif"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "audio/mpeg": return "mp3"
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/x-aiff": return "aiff"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "video/x-matroska": return "mkv"
        case "video/quicktime": return "mov"
        case "video/x-msvideo": return "avi"
        case "video/mpeg": return "mpg"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "text/csv": return "csv"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        default: return nil
        }
    }

    /// Signed blob URLs carry the intended filename in a
    /// `response-content-disposition` query parameter instead of the path
    /// (GitHub release assets, Azure SAS, S3 presigned…). Recovering it here
    /// needs no network round-trip.
    static func filenameFromContentDispositionQuery(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return nil }
        for item in items where item.name.lowercased() == "response-content-disposition" {
            if let name = parseContentDispositionFilename(item.value ?? ""), !name.isEmpty {
                return InputValidator.safeFilename(name)
            }
        }
        return nil
    }

    /// Extracts the filename from a Content-Disposition header value,
    /// preferring RFC 6266 `filename*` over plain `filename`.
    private static func parseContentDispositionFilename(_ header: String) -> String? {
        var fallback: String?
        for rawPart in header.split(separator: ";") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            let lowered = part.lowercased()
            if lowered.hasPrefix("filename*=") {
                // charset'language'percent-encoded-value
                let value = String(part.dropFirst("filename*=".count))
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                let encoded = pieces.count == 3 ? String(pieces[2]) : value
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            } else if lowered.hasPrefix("filename=") {
                var value = String(part.dropFirst("filename=".count)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { fallback = value }
            }
        }
        return fallback
    }

}
