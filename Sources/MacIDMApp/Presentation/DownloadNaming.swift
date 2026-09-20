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

    /// Strips a trailing site-brand segment (" - Hanime1.me", "| Example",
    /// "_bilibili") from a page title before it enters the naming chain. The
    /// segment is removed only when it matches one of the page hosts (full
    /// host, host without "www.", or the host's first label), so real titles
    /// containing separators ("Love is War - Episode 3") are never truncated.
    /// Underscore is included because Bilibili's og:title/document.title uses
    /// "标题_哔哩哔哩_bilibili"; the extension's stripBrandSuffix mirrors this
    /// rule so the two ends stay aligned (technical spec §8.1).
    static func semanticPageTitle(_ value: String?, hosts: [String?]) -> String? {
        guard let title = nonEmptyPageTitle(value) else { return nil }
        let separators: Set<Character> = ["-", "\u{2013}", "\u{2014}", "|", "_"]
        guard let separatorIndex = title.lastIndex(where: { separators.contains($0) }) else {
            return title
        }
        let suffix = title[title.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = title[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty, stem.count >= 3 else { return title }
        let hostTokens = hosts.compactMap { $0?.lowercased() }.flatMap { host -> [String] in
            let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let firstLabel = withoutWWW.split(separator: ".").first.map(String.init) ?? withoutWWW
            return [host, withoutWWW, firstLabel]
        }
        guard hostTokens.contains(where: { !$0.isEmpty && $0 == suffix.lowercased() }) else {
            return title
        }
        return stem
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
