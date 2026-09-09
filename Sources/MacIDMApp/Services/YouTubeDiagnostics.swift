import CryptoKit
import Foundation

// Structured diagnostic events and dual-channel logging for the YouTube
// download pipeline (see the public technical specification).
//
// Each event is generated once: common fields such as error category, stage,
// task ID, attempt, and timings are carried by `YouTubeDiagnosticEvent`, and
// the two sinks each decide which fields to emit —
// - the regular log `macidm.log` (via AppLogger): structured fields plus a
//   sanitized, bounded excerpt; the default entry point for AI/support
//   troubleshooting;
// - the private diagnostic log (separate file, default `macidm-private.log`):
//   under the same event id, keeps full URLs (including query/fragment),
//   local paths, and raw yt-dlp output (credential values are still redacted);
//   read only by task/time window when the regular log lacks evidence.
//
// Raw credential values — cookies, Authorization, proxy passwords, bridge
// tokens, etc. — never reach disk on either side; both sinks record only
// presence, source, counts, byte sizes, and cleanup state.

/// Structured diagnostic event for one yt-dlp process failure (or final stall).
struct YouTubeDiagnosticEvent: Sendable {
    /// Correlation ID shared by both logs.
    let id: String
    let timestamp: Date
    /// Event name, e.g. `ytdlp.processFailed` / `ytdlp.stalledFinal`.
    let event: String
    /// Stage: `download` (download attempt failed) or `stallRetry` (killed
    /// with no output).
    let stage: String
    let taskID: String?
    /// `YouTubeDownloadError.code` classification result.
    let category: String?
    let exitStatus: Int32?
    let attempt: Int?
    let durationMs: Int64?
    let ytDlpVersion: String?
    let cookieSupplied: Bool
    /// Cookie key-value pair count (no raw values).
    let cookieCount: Int?
    let cookieFileCreated: Bool
    let proxyConfigured: Bool
    /// Short SHA-256 fingerprint of the full URL: tells whether two records
    /// share the same URL.
    let urlExactFingerprint: String?
    /// Short SHA-256 fingerprint of the canonical resource identity (video
    /// ID + itag): still correlates the same logical resource after
    /// signature/expiry changes.
    let resourceFingerprint: String?
    /// Sanitized, bounded excerpt; nil when sanitization fails (fail closed).
    let sanitizedExcerpt: String?

    // The fields below go to the private diagnostic log only.
    let fullURL: String?
    let cookieFilePath: String?
    /// Raw yt-dlp output (credential values redacted), truncated to the
    /// limit before writing.
    let rawOutput: String?

    var privateDetailAvailable: Bool {
        !(rawOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || fullURL != nil
    }
}

/// Short SHA-256 fingerprints for URLs/titles/resources. Fingerprints exist
/// for log correlation, not as a substitute for the raw value (the private
/// log keeps the full original URL), and never for authentication or request
/// deduplication.
enum DiagnosticFingerprint {
    static func sha256HexPrefix(_ value: String, length: Int = 16) -> String? {
        guard let data = value.data(using: .utf8), !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex.count >= length else { return nil }
        return String(hex.prefix(length))
    }

    /// Computed over the unmodified full URL; two records' exact fingerprints
    /// match ⇔ the URLs are identical (including query/fragment).
    static func urlExact(_ url: String) -> String? {
        sha256HexPrefix(url)
    }

    /// Canonical resource identity: YouTube video ID + selected itag. Query
    /// changes on signed URLs do not affect this fingerprint, so records of
    /// the same video at the same quality remain correlated.
    static func resource(videoID: String?, itag: Int?) -> String? {
        guard let videoID, !videoID.isEmpty else { return nil }
        var identity = "youtube|\(videoID)"
        if let itag { identity += "|itag\(itag)" }
        return sha256HexPrefix(identity)
    }

    /// Short fingerprint of the full title: the regular log correlates
    /// repeated titles through it without writing the title text.
    static func title(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sha256HexPrefix(trimmed)
    }
}

/// Raw yt-dlp output → a bounded excerpt usable in the regular log. Minimum
/// rules: keep stable error lines and remove credential
/// values; drop URL query values and fragments (keep host, path, and query
/// key names); replace user and temp directories with placeholders; strip
/// control characters; enforce a length limit; fail closed on sanitization
/// failure (return nil, keeping only structured fields).
enum YouTubeOutputSanitizer {
    static let excerptLimit = 300
    /// Regular-log excerpts sanitize broadly: any credential-looking
    /// key/value has its value wiped.
    private static let credentialPattern =
        #"(?i)\b(authorization|password|passwd|token|bearer|x-api-key|sid|session)\b(\s*[:=]\s*)("(?:[^"]*)"|(?:bearer\s+)?[^\s;,]+)"#
    /// The private log sanitizes only explicit credential-class fields
    /// (Cookie headers, Authorization, proxy authentication, API keys,
    /// bridge tokens, passwords); a fully signed URL must not be rewritten
    /// merely because a query key is named token/sid/session
    /// Scheme prefixes match only
    /// bearer/basic/digest: a generalized "word + space" prefix would
    /// greedily swallow the next credential key on the same line and leave
    /// an adjacent secret unwashed (§3.4).
    private static let privateCredentialPattern =
        #"(?i)\b(proxy-authorization|authorization|x-api-key|x-macidm-token|macidm-token|password|passwd)\b(\s*[:=]\s*)("(?:[^"]*)"|(?:(?:bearer|basic|digest)\s+)?[^\s;,]+)"#
    /// Cookie headers are replaced whole-line: a cookie value itself
    /// contains multiple `;`-separated pairs, so per-pair matching
    /// inevitably leaks values — only line-level replacement is safe.
    private static let cookieHeaderPattern = #"(?i)\bcookie\s*:[^\n]*"#
    private static let ansiPattern = #"\u{1b}\[[0-9;?]*[A-Za-z]"#
    /// URL masking for the regular log: beyond http/https it also covers the
    /// proxy schemes the product allows (socks5/socks5h, round 4 R2);
    /// rebuilds keep only scheme/host/path and query key names, discarding
    /// userinfo and query values together — closing the gap where SOCKS5
    /// proxy passwords bypassed URL masking in the old HTTP(S)-only version.
    private static let urlPattern = #"(?:https?|socks5h?)://[^\s"'<>\\]+"#
    /// Account/password in URL userinfo: proxy URLs may be produced from
    /// product configuration (the product supports http, https, socks5;
    /// socks5h is also covered in case an underlying tool echoes it).
    /// Passwords are not preservable signed parameters — the private log
    /// keeps only the username (§3.4, round 2 §P1-3); percent-encoded
    /// credentials are matched too. Plain media URLs have no `@` in the
    /// authority and are unaffected.
    private static let userInfoPattern =
        #"\b((?:https?|socks5h?)://)([^/\s:@]+):[^/\s@]+@"#
    /// Local paths may contain spaces, Chinese and Latin characters,
    /// parentheses, and quotes (title-derived file names): the old regex
    /// stopped at whitespace and leaked title fragments, so common filename
    /// characters are allowed through to end-of-line and trailing
    /// punctuation is stripped afterwards; in mixed path/URL contexts,
    /// over-wash rather than leak title fragments.
    private static let pathCharClass = #"[^\n;,:：]*"#
    private static let homePathPattern = #"/Users/"# + pathCharClass
    private static let tmpPathPattern = #"(?:/private)?/(?:tmp|var/folders)/"# + pathCharClass
    private static let trailingPathPunctuation = CharacterSet(
        charactersIn: " \t.。，,;；:：、!！?？\"'”’)）]】>"
    )

    /// Returns a single-line, length-capped sanitized excerpt; nil when it
    /// cannot be sanitized safely.
    static func sanitizedExcerpt(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Look at the tail only: yt-dlp errors concentrate at the end of
        // the output.
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        let tail = lines.suffix(40)
        let interesting = tail.filter { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("warning") || lower.contains("traceback")
        }
        let candidates = interesting.isEmpty ? lines.suffix(3) : Array(interesting)
        let sanitizedLines = candidates.map { line in
            sanitizeLine(String(line))
        }
        let joined =
            sanitizedLines
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard !joined.isEmpty, !containsControlCharacters(joined) else { return nil }
        guard joined.count <= excerptLimit else {
            return String(joined.prefix(excerptLimit)) + "…"
        }
        return joined
    }

    /// Any error description (e.g. `localizedDescription`) → a safe excerpt
    /// for the regular log: underlying error text may embed full paths,
    /// file names, or URLs, so the regular log must sanitize first; the full
    /// error goes to the private log only. Fail closed
    /// on sanitization failure.
    static func sanitizedErrorSummary(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var summary = sanitizeLine(trimmed)
        summary = String(
            summary.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .map(Character.init))
        guard !summary.isEmpty else { return nil }
        guard summary.count <= excerptLimit else {
            return String(summary.prefix(excerptLimit)) + "…"
        }
        return summary
    }

    /// Minimal processing before writing the private log: redact only
    /// explicit credential-class field values and truncate; everything else
    /// stays as-is (fully signed URLs, paths, and raw error lines are all
    /// needed to reproduce the scene). All free text entering the private
    /// log (error descriptions, tool output, URLs) must pass through this
    /// function.
    static func redactCredentials(in text: String, limit: Int = 64 * 1024) -> String? {
        var redacted = text
        if let cookieHeader = try? NSRegularExpression(pattern: cookieHeaderPattern) {
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = cookieHeader.stringByReplacingMatches(
                in: redacted, options: [], range: range, withTemplate: "Cookie=<redacted>")
        }
        // URL userinfo passwords: processed before the general credential
        // pattern; keeps the username and host without touching the signed
        // query after the authority (token/sid/session etc.).
        if let userInfo = try? NSRegularExpression(pattern: userInfoPattern) {
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = userInfo.stringByReplacingMatches(
                in: redacted, options: [], range: range, withTemplate: "$1$2:<redacted>@")
        }
        if let regex = try? NSRegularExpression(pattern: privateCredentialPattern) {
            // Recompute the range on the already-shortened string; reusing
            // the old range would run out of bounds.
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted, options: [], range: range,
                withTemplate: "$1=<redacted>"
            )
        }
        guard redacted.count <= limit else {
            return String(redacted.prefix(limit)) + "\n…<truncated>"
        }
        return redacted
    }

    private static func sanitizeLine(_ line: String) -> String {
        var text = line
        if let ansiRegex = try? NSRegularExpression(pattern: ansiPattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = ansiRegex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "")
        }
        // URLs: keep scheme/host/path and query key names; drop query
        // values and fragments.
        if let urlRegex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = urlRegex.matches(in: text, options: [], range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text),
                    let url = URLComponents(string: String(text[matchRange]))
                else { continue }
                var template = "\(url.scheme ?? "https")://\(url.host ?? "host")\(url.path)"
                if let keys = url.queryItems?.map(\.name), !keys.isEmpty {
                    template += "?" + keys.map { $0 + "=…" }.joined(separator: "&")
                }
                text.replaceSubrange(matchRange, with: template)
            }
        }
        // Credential assignments: keep key names and presence, remove
        // values. Cookie headers are replaced whole-line (the multiple
        // `k=v` pairs inside the value cannot be matched pair-by-pair
        // safely).
        if let cookieHeader = try? NSRegularExpression(pattern: cookieHeaderPattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = cookieHeader.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "Cookie=<redacted>")
        }
        if let credentialRegex = try? NSRegularExpression(pattern: credentialPattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = credentialRegex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "$1=<redacted>")
        }
        // Local absolute paths: user and temp directories become
        // placeholders. Path bodies may contain spaces and title
        // characters, so allow through to end-of-line and strip trailing
        // punctuation — the old regex truncated at whitespace and leaked
        // titles.
        if let homeRegex = try? NSRegularExpression(pattern: homePathPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = homeRegex.matches(in: text, options: [], range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let matched = String(text[matchRange])
                let body = trimTrailingPunctuation(matched)
                let trailing = matched.suffix(matched.count - body.count)
                text.replaceSubrange(matchRange, with: "<home>/…" + trailing)
            }
        }
        if let tmpRegex = try? NSRegularExpression(pattern: tmpPathPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = tmpRegex.matches(in: text, options: [], range: range).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let matched = String(text[matchRange])
                let body = trimTrailingPunctuation(matched)
                let trailing = matched.suffix(matched.count - body.count)
                text.replaceSubrange(matchRange, with: "<tmp>/…" + trailing)
            }
        }
        // Control characters are removed entirely to prevent log injection.
        return String(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .map(Character.init))
    }

    /// After path matching lets text through to end-of-line, return the
    /// trailing punctuation/quotes/brackets to the sentence; the placeholder
    /// replaces only the path body itself.
    private static func trimTrailingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last, trailingPathPunctuation.contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Local tool/app-managed paths → a regular-log-safe form: the user's
    /// home prefix becomes a placeholder, keeping only the app-managed
    /// sub-path (no username or user content, §3.3 tool-path audit).
    static func userSafePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "<home>" + path.dropFirst(home.count) }
        return path
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Shared storage for private diagnostic files: 0600 permissions, size-based
/// rotation, and retention. One mechanism reused by every dual-channel event
/// log; never enters Git, test snapshots, crash
/// reports, automatic uploads, or default support bundles. Write failures
/// are dropped silently and never disturb the business pipeline.
final class PrivateDiagnosticFile: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let maximumBytes: UInt64
    private let archiveCount: Int
    private let retentionInterval: TimeInterval

    /// One writer per normalized path, shared globally (§4.1): the YouTube
    /// event log and the download lifecycle event log write to the same
    /// `macidm-private.log` by default; an instance-level lock serializes
    /// only a single writer, and two instances doing concurrent
    /// `seekToEnd`/rotation would interleave or drop lines. With per-path
    /// sharing, writes, permission repair, rotation, and retention live
    /// inside one serialized boundary; the rotation parameters of the first
    /// registration win.
    private static let registryLock = NSLock()
    /// Serialized by `registryLock`; `nonisolated(unsafe)` satisfies Swift 6
    /// global-mutable-state checking, matching
    /// `YouTubeDownloadError.lastProcessOutput`'s semantics.
    nonisolated(unsafe) private static var registry: [String: PrivateDiagnosticFile] = [:]

    static func sharedWriter(
        url: URL,
        maximumBytes: UInt64 = 1024 * 1024,
        archiveCount: Int = 3,
        retentionInterval: TimeInterval = 14 * 24 * 3600
    ) -> PrivateDiagnosticFile {
        let key = url.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let writer = PrivateDiagnosticFile(
            url: url,
            maximumBytes: maximumBytes,
            archiveCount: archiveCount,
            retentionInterval: retentionInterval
        )
        registry[key] = writer
        return writer
    }

    private init(
        url: URL,
        maximumBytes: UInt64,
        archiveCount: Int,
        retentionInterval: TimeInterval
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.archiveCount = max(1, archiveCount)
        self.retentionInterval = retentionInterval
    }

    /// Appends a pre-lined text block; permissions, rotation, and retention
    /// are maintained uniformly on the write path.
    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        do {
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if !fileManager.fileExists(atPath: url.path) {
                // Readable/writable by the current user only; recreation
                // after deletion keeps the same permission.
                fileManager.createFile(
                    atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            } else if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                permissions != 0o600
            {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            rotateIfNeeded()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            enforceRetention()
        } catch {
            // Diagnostic write failures must stay silent: logging never
            // disturbs the download pipeline.
        }
    }

    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? UInt64,
            size > maximumBytes
        else { return }
        try? fileManager.removeItem(at: archiveURL(generation: archiveCount))
        for generation in stride(from: archiveCount - 1, through: 1, by: -1) {
            let source = archiveURL(generation: generation)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: archiveURL(generation: generation + 1))
        }
        do {
            try fileManager.moveItem(at: url, to: archiveURL(generation: 1))
        } catch {
            try? Data().write(to: url, options: .atomic)
            return
        }
        fileManager.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
    }

    /// Deletes rotated archives past the retention interval; the active
    /// file is never deleted by age.
    private func enforceRetention() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for generation in 1...archiveCount {
            let archive = archiveURL(generation: generation)
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: archive.path),
                let modified = attributes[.modificationDate] as? Date, modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: archive)
        }
    }

    private func archiveURL(generation: Int) -> URL {
        url.appendingPathExtension("\(generation)")
    }
}

/// Dual-channel writer: regular sink (default AppLogger → macidm.log) +
/// private diagnostic file. Thread-safe; write failures are dropped
/// silently and never disturb the download pipeline. The private file uses
/// current-user-only permissions (0600), size-based rotation, and retention,
/// and never enters Git, test snapshots, crash reports, automatic uploads, or
/// default support bundles (no `macidm.log` reader touches it).
final class YouTubeDiagnosticEventLog: @unchecked Sendable {
    static let shared = YouTubeDiagnosticEventLog()

    /// Enabled by default in the current local Debug product; a distributed
    /// release must re-decide the default and how users are informed
    /// in the current local Debug product.
    static var enabledByDefault: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private let privateFile: PrivateDiagnosticFile
    private let regularSink: @Sendable (String) -> Void
    private let formatter: ISO8601DateFormatter
    private let enabled: Bool

    static func defaultPrivateLogURL() -> URL {
        // Tests are redirected to the isolated support directory so fixture
        // diagnostics never land in the user's private log.
        AppSupportPaths.supportDirectory().appendingPathComponent("macidm-private.log")
    }

    init(
        privateLogURL: URL = YouTubeDiagnosticEventLog.defaultPrivateLogURL(),
        regularSink: @escaping @Sendable (String) -> Void = { AppLogger.shared.warning(.youtube, $0) },
        enabled: Bool = YouTubeDiagnosticEventLog.enabledByDefault,
        maximumBytes: UInt64 = 1024 * 1024,
        archiveCount: Int = 3,
        retentionInterval: TimeInterval = 14 * 24 * 3600
    ) {
        self.privateFile = PrivateDiagnosticFile.sharedWriter(
            url: privateLogURL,
            maximumBytes: maximumBytes,
            archiveCount: archiveCount,
            retentionInterval: retentionInterval
        )
        self.regularSink = regularSink
        self.enabled = enabled
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Derives two outputs from one event: the regular log carries only
    /// structured fields and a sanitized excerpt; the private log keeps the
    /// full private fields and raw output under the same event id. The
    /// regular structured event always goes to the regular sink; `enabled`
    /// (the private toggle) controls only the private-file write — when
    /// Release disables the private log, the regular log still keeps the
    /// failure excerpt.
    func record(_ event: YouTubeDiagnosticEvent) {
        regularSink(regularLine(for: event))
        guard enabled else { return }
        privateFile.append(privateEntry(event))
    }

    // MARK: - Regular sink

    private func regularLine(for event: YouTubeDiagnosticEvent) -> String {
        var parts: [String] = [
            "event=\(event.event)", "eventId=\(event.id)",
        ]
        if let taskID = event.taskID { parts.append("task=\(taskID)") }
        parts.append("stage=\(event.stage)")
        if let category = event.category { parts.append("category=\(category)") }
        if let exitStatus = event.exitStatus { parts.append("exit=\(exitStatus)") }
        if let attempt = event.attempt { parts.append("attempt=\(attempt)") }
        if let durationMs = event.durationMs { parts.append("durationMs=\(durationMs)") }
        if let version = event.ytDlpVersion, !version.isEmpty {
            parts.append("ytDlpVersion=\(version)")
        }
        parts.append("cookieSupplied=\(event.cookieSupplied)")
        if let cookieCount = event.cookieCount { parts.append("cookieCount=\(cookieCount)") }
        parts.append("cookieFileCreated=\(event.cookieFileCreated)")
        parts.append("proxyConfigured=\(event.proxyConfigured)")
        if let urlFP = event.urlExactFingerprint { parts.append("urlExactFingerprint=\(urlFP)") }
        if let resourceFP = event.resourceFingerprint {
            parts.append("resourceFingerprint=\(resourceFP)")
        }
        parts.append("privateDetailAvailable=\(event.privateDetailAvailable)")
        // Fail closed: omit the excerpt when sanitization fails, keeping only
        // structured fields.
        if let excerpt = event.sanitizedExcerpt {
            parts.append("excerpt=\(excerpt.replacingOccurrences(of: "|", with: "/"))")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Private sink

    private func privateEntry(_ event: YouTubeDiagnosticEvent) -> String {
        var lines: [String] = []
        lines.append(
            "\(formatter.string(from: event.timestamp)) eventId=\(event.id) event=\(event.event) stage=\(event.stage)"
        )
        var header: [String] = []
        if let taskID = event.taskID { header.append("task=\(taskID)") }
        if let category = event.category { header.append("category=\(category)") }
        if let exitStatus = event.exitStatus { header.append("exit=\(exitStatus)") }
        if let attempt = event.attempt { header.append("attempt=\(attempt)") }
        if header.isEmpty == false { lines.append("  " + header.joined(separator: " ")) }
        if let fullURL = event.fullURL {
            // Fully signed URLs are kept; only the userinfo
            // account/password is redacted (§3.4).
            lines.append(
                "  url: \(YouTubeOutputSanitizer.redactCredentials(in: fullURL) ?? fullURL)")
        }
        if let cookiePath = event.cookieFilePath { lines.append("  cookieFile: \(cookiePath)") }
        if let rawOutput = event.rawOutput,
            let redacted = YouTubeOutputSanitizer.redactCredentials(in: rawOutput),
            !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append("  output: |")
            for line in redacted.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
