import Foundation
import IDMEngine

/// Unified builder for yt-dlp command-line arguments, cookie authorization
/// files, and format selectors.
///
/// Keeps the original algorithm and argument order exactly as-is:
/// pure-functional argument assembly, Netscape cookie-file generation with
/// safety validation, and fragment/format selector parsing.
enum YouTubeCommandBuilder {
    /// Parsed result of the variant fragment (`#height=<n>[&itag=<id>[&a=1]]`).
    struct FragmentSelection: Equatable, Sendable {
        let height: Int?
        let itag: Int?
        let hasAudio: Bool
    }

    /// Parses `#height=<n>[&itag=<id>[&a=1]]`.
    /// Unknown keys and invalid values are ignored; only digit-validated
    /// positive integers take effect.
    static func parseMacIDMFragment(_ fragment: String) -> FragmentSelection {
        var height: Int?
        var itag: Int?
        var hasAudio = false
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1])
            switch key {
            case "height":
                if height == nil, let parsed = Int(value), parsed > 0 { height = parsed }
            case "itag":
                if itag == nil, (1...5).contains(value.count), value.allSatisfy(\.isNumber),
                    let parsed = Int(value), parsed > 0
                {
                    itag = parsed
                }
            case "a" where value == "1":
                hasAudio = true
            default:
                break
            }
        }
        return FragmentSelection(height: height, itag: itag, hasAudio: hasAudio)
    }

    /// Builds the yt-dlp format selector from validated options.
    static func formatSelector(
        itag: Int?,
        hasAudio: Bool,
        heightConstraint: String
    ) -> String {
        if let itag {
            return hasAudio ? "\(itag)" : "\(itag)+ba[ext=m4a]/\(itag)"
        }
        return
            heightConstraint.isEmpty
            ? "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
            : "bv*[ext=mp4]\(heightConstraint)+ba[ext=m4a]/b[ext=mp4]\(heightConstraint)/bv*\(heightConstraint)+ba/b"
    }

    /// Extracts the YouTube video ID (`?v=`, `/shorts/<id>`, `/live/<id>`, `youtu.be/<id>`).
    static func youTubeVideoID(from url: URL) -> String? {
        guard let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.replacingOccurrences(
            of: "^www\\.", with: "", options: .regularExpression)
        if host == "youtu.be" {
            return url.path.split(separator: "/").first.map(String.init)
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let v = items.first(where: { $0.name == "v" })?.value, !v.isEmpty
        {
            return v
        }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "shorts" || parts[0] == "live" else { return nil }
        return String(parts[1])
    }

    /// Counts the key-value pairs in a Cookie header.
    static func cookieCount(_ cookie: String?) -> Int? {
        guard let cookie, !cookie.isEmpty else { return nil }
        return cookie.split(separator: ";", omittingEmptySubsequences: true).count
    }

    /// Generates a temporary Netscape-format cookie file.
    static func writeCookieFile(_ cookie: String?, domain: String, in directory: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard let cookie, !cookie.isEmpty else { return nil }
        let rows = cookie.split(separator: ";", omittingEmptySubsequences: true).compactMap { raw -> String? in
            let pair = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard !name.isEmpty, !name.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }),
                !value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" })
            else { return nil }
            return "\(domain)\tTRUE\t/\tTRUE\t0\t\(name)\t\(value)"
        }
        guard !rows.isEmpty else { return nil }
        let url = directory.appendingPathComponent("cookies.txt")
        let body = "# Netscape HTTP Cookie File\n" + rows.joined(separator: "\n") + "\n"
        guard
            fileManager.createFile(
                atPath: url.path,
                contents: body.data(using: .utf8),
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw IDMError.storageError(String(localized: "无法创建 yt-dlp 临时授权文件"))
        }
        return url
    }

    /// Builds the full yt-dlp launch argument list, strictly preserving argument
    /// order and product behavior.
    static func buildDownloadArguments(
        downloadURL: URL,
        formatString: String,
        workingDirectory: URL,
        isYouTube: Bool,
        cookieFile: URL?,
        request: DownloadRequest
    ) -> [String] {
        var arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--no-playlist",
            "--newline",
            "--progress",
            "--continue",
            "--format", formatString,
            "--merge-output-format", "mp4",
            "--remux-video", "mp4",
            "--output", workingDirectory.appendingPathComponent("result.%(ext)s").path,
        ]
        if isYouTube {
            arguments += ["--cookies-from-browser", "chrome"]
        }
        if let cookieFile {
            arguments += ["--cookies", cookieFile.path]
        }
        if let userAgent = request.requestContext?.userAgent, !userAgent.isEmpty {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = request.requestContext?.referer, !referer.isEmpty {
            arguments += ["--add-headers", "Referer: \(referer)"]
        }
        if let proxyURL = YTDlpManager.currentProxyURLString() {
            arguments += ["--proxy", proxyURL]
        }
        arguments += [downloadURL.absoluteString]
        return arguments
    }
}
