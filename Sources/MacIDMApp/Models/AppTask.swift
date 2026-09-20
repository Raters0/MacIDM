import Foundation
import IDMEngine

enum AppTaskStatus: String, Codable, CaseIterable, Sendable {
    case takeoverPending
    case takeoverConflict
    case queued
    case probing
    case running
    case pausing
    case paused
    case cancelling
    case cancelled
    case verifying
    case completed
    case failed
    case needsRestart
    case filenameConflict
    case storageError

    var isActive: Bool {
        switch self {
        case .probing, .running, .pausing, .cancelling, .verifying:
            true
        default:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed, .storageError, .takeoverConflict:
            true
        default:
            false
        }
    }

    /// Statuses whose speed chart must freeze at the last real sample: no
    /// transfer is running or about to run, so advancing the window with the
    /// wall clock would only drag a stale curve sideways and keep presenting
    /// a nonzero "current" speed for a stopped task (needsRestart is not
    /// terminal, but its transfer has ended just as definitively).
    var freezesSpeedChart: Bool {
        isTerminal || self == .needsRestart || self == .paused
    }

    var title: String {
        switch self {
        case .takeoverPending: String(localized: "等待浏览器确认")
        case .takeoverConflict: String(localized: "浏览器接管冲突")
        case .queued: String(localized: "排队中")
        case .probing: String(localized: "正在探测")
        case .running: String(localized: "下载中")
        case .pausing: String(localized: "正在暂停")
        case .paused: String(localized: "已暂停")
        case .cancelling: String(localized: "正在取消")
        case .cancelled: String(localized: "已取消")
        case .verifying: String(localized: "正在验证")
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "失败")
        case .needsRestart: String(localized: "需要重新下载")
        case .filenameConflict: String(localized: "文件名冲突")
        case .storageError: String(localized: "存储错误")
        }
    }
}

/// One timestamped speed sample for the rolling speed window (product-spec §4.1).
/// Legacy `[Double]` histories carry no time, so they are dropped at read time
/// rather than being given fabricated timestamps.
struct SpeedSample: Hashable, Sendable {
    var timestamp: Date
    var bytesPerSecond: Double
}

/// Encodes the timestamp as epoch seconds (full sub-second precision)
/// instead of relying on the surrounding encoder's date strategy: the
/// store's `.iso8601` setting truncates to whole seconds, which would
/// collapse several 300 ms-apart samples onto one chart coordinate.
extension SpeedSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case bytesPerSecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let epoch = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSinceReferenceDate: epoch)
        bytesPerSecond = try container.decode(Double.self, forKey: .bytesPerSecond)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp.timeIntervalSinceReferenceDate, forKey: .timestamp)
        try container.encode(bytesPerSecond, forKey: .bytesPerSecond)
    }
}

/// Pure rolling-window policy for speed samples, independent of AppModel so
/// the trim/cap behavior stays unit-testable (product-spec §4.3 speed-curve semantics).
enum SpeedHistoryPolicy {
    /// The chart presents a real most-recent-120-seconds window.
    static let window: TimeInterval = 120
    /// Hard point cap defends against abnormally high-frequency reporting
    /// even when every sample carries a distinct timestamp.
    static let maximumSamples = 240

    /// Unified sample policy (product-spec §4.3): samples may arrive out of
    /// order (callback races and persistence reads can both reorder them), so
    /// this layer sorts them stably by timestamp, drops infinite/negative
    /// speeds, then trims the window and caps the points. Appending and
    /// persistence loading share this single entry point, and the chart's
    /// rightmost point and the accessibility "current" value always use the
    /// newest timestamp.
    static func trimmed(_ samples: [SpeedSample], now: Date) -> [SpeedSample] {
        let cutoff = now.addingTimeInterval(-window)
        var result = sanitized(samples).filter { $0.timestamp >= cutoff }
        if result.count > maximumSamples {
            result.removeFirst(result.count - maximumSamples)
        }
        return result
    }

    /// Sort and sanitize (product-spec §4.3): out-of-order samples are put
    /// back in stable ascending timestamp order (the curve never folds back to
    /// the left); non-finite/negative speeds and non-finite timestamps are
    /// dropped.
    static func sanitized(_ samples: [SpeedSample]) -> [SpeedSample] {
        samples
            .filter {
                $0.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && $0.bytesPerSecond.isFinite && $0.bytesPerSecond >= 0
            }
            // Swift's sorted is not guaranteed stable; samples sharing a
            // timestamp must neither be merged nor reordered, so the
            // comparison pairs each element with its original index to keep
            // the ascending order stable.
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Persistence-read policy (product-spec §4.3): sanitize, sort, and apply
    /// only the hard point cap — never run the 120-second trim for finished
    /// tasks against the current wall clock, or completed history snapshots
    /// would be wrongly emptied; the real rolling window belongs only to the
    /// append path's `trimmed(_:now:)`.
    static func loaded(_ samples: [SpeedSample]) -> [SpeedSample] {
        var result = sanitized(samples)
        if result.count > maximumSamples {
            result.removeFirst(result.count - maximumSamples)
        }
        return result
    }

    /// Right edge of the charted window (product-spec §4.3): active tasks
    /// track the wall clock so the curve keeps advancing even while speed
    /// callbacks are silent; terminal tasks freeze at their final sample so
    /// a detail view opened later still shows the completion snapshot.
    /// The terminal reference time must come from the last valid sanitized
    /// sample (§5): a trailing sample with a newer timestamp but invalid speed
    /// must not freeze the reference time; with no valid samples it falls
    /// back to `now`.
    static func windowReference(samples: [SpeedSample], now: Date, isTerminal: Bool) -> Date {
        guard isTerminal else { return now }
        return sanitized(samples).last?.timestamp ?? now
    }

    /// Samples inside the window ending at `reference`; anything older than
    /// `reference - window` has left the window and must not be drawn. The
    /// input also goes through the unified sort/sanitize pass (§10): history
    /// samples read back out of order must not fold the curve back or misalign
    /// the "current" value.
    static func windowSamples(_ samples: [SpeedSample], reference: Date) -> [SpeedSample] {
        let cutoff = reference.addingTimeInterval(-window)
        return sanitized(samples).filter { $0.timestamp >= cutoff && $0.timestamp <= reference }
    }

    /// Numeric basis of the accessibility summary: it must share the same
    /// visible-window samples as the chart and must not read back the full
    /// history (product-spec §4.3) — after 120 seconds of silence, old
    /// samples have already left the curve and VoiceOver must no longer
    /// announce them. When the window is empty, current speed and peak are
    /// both 0. After sorting, the array's last element carries the newest
    /// timestamp (§10).
    static func visibleSummary(_ visible: [SpeedSample]) -> (current: Double, peak: Double) {
        let values = visible.map(\.bytesPerSecond)
        return (values.last ?? 0, values.max() ?? 0)
    }
}

struct SegmentSnapshot: Codable, Hashable, Identifiable, Sendable {
    let index: Int
    var receivedBytes: Int64
    var totalBytes: Int64?
    /// Optional human-readable label for the segment (e.g., the localized
    /// "video track" / "audio track" labels for DASH-pair tasks). When nil,
    /// the UI falls back to the localized "Segment N" label.
    var label: String?

    var id: Int { index }

    var displayLabel: String {
        label ?? String(localized: "分段 \(index + 1)")
    }

    init(_ progress: DownloadSegmentProgress) {
        index = progress.index
        receivedBytes = progress.receivedBytes
        totalBytes = progress.totalBytes
    }

    init(index: Int, receivedBytes: Int64, totalBytes: Int64?) {
        self.index = index
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    var fractionCompleted: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

struct AppTask: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: String
    /// The user-facing page URL the download was submitted from (e.g. a
    /// YouTube watch page including its `v=` identifier). `sourceURL` is
    /// redacted for storage and can lose query parameters, so this keeps
    /// the original address for display and diagnostics.
    var pageURL: String? = nil
    var destinationPath: String
    var maximumParallelRequests: Int
    let expectedSHA256: String?
    var sourceKind: DownloadSourceKind? = nil
    let browserClientID: String?
    /// Mutable so a failed native task can be switched over to the yt-dlp
    /// fallback backend ("youtube.extractor") and re-queued.
    var browserSubmissionType: String?
    let browserSubmissionKey: String?
    let createdAt: Date
    /// The instant the task first entered `.running` (not merely queued).
    /// Used for total-duration so queue wait time is excluded. nil before
    /// the first run and in legacy rows loaded from older persistence.
    var startedAt: Date?
    var updatedAt: Date
    var status: AppTaskStatus
    var receivedBytes: Int64
    var totalBytes: Int64?
    var bytesPerSecond: Double
    /// Timestamped speed samples behind the detail panel's real 120-second
    /// rolling window. The X axis is derived from these timestamps, never
    /// from the array index.
    var speedHistory: [SpeedSample]
    var sha256: String?
    var verification: String?
    var errorCode: String?
    var errorMessage: String?
    /// Actionable next-step suggestion produced by `DownloadErrorAnalyzer`
    /// for the current failure, shown beneath the error message.
    var errorRecommendation: String? = nil
    /// `ErrorDiagnosis.Category.rawValue` of the current failure; drives
    /// the context-specific action buttons in the detail panel.
    var errorCategory: String? = nil
    var segments: [SegmentSnapshot]
    /// Runtime-only stage-aware progress used by multi-resource backends such
    /// as yt-dlp. SQLite intentionally does not persist it; recovered tasks
    /// fall back to durable byte accounting until a worker reports again.
    var overallProgressFraction: Double? = nil
    var isArchived: Bool = false
    /// Transient UI flag: true when a completed task's destination file is
    /// no longer present on disk. Not persisted to SQLite.
    var fileMissing: Bool = false
    var averageSpeed: Double?
    /// Cumulative seconds spent in active network transfer (bytes actually
    /// advancing). Queueing, user pauses, retry waits, page/yt-dlp parsing,
    /// remux and ffprobe/verification never accumulate here, so
    /// `averageSpeed = receivedBytes / activeTransferDuration` is a true
    /// transfer average rather than a whole-pipeline wall-clock average.
    var activeTransferDuration: TimeInterval = 0
    var totalDuration: TimeInterval?
    /// Media duration in seconds (video/audio length), distinct from
    /// `totalDuration` which measures download wall-clock time.
    var mediaDuration: TimeInterval?
    /// A user-selected category override. nil keeps the filename-based rule.
    var categoryOverride: DownloadCategory? = nil
    /// The declared MIME type captured at submission time (browser takeover
    /// or new-download draft). Only used as a classification fallback when
    /// the filename carries no recognized extension.
    var mimeType: String? = nil
    /// Queue priority is intentionally small and optional for legacy JSON
    /// compatibility. Higher values are scheduled first; nil means normal.
    var priority: Int? = 0
    /// Owning download queue. nil places the task in the implicit main
    /// queue, which predates user-defined queues and needs no migration.
    var queueID: UUID? = nil
    /// The parallelism the transfer actually used, recorded at completion.
    /// Engines legitimately finish with fewer connections than configured
    /// (single-connection servers, yt-dlp runs), so the detail panel shows
    /// this instead of the configured maximum once the task has ended.
    var usedParallelRequests: Int? = nil
    /// Site-adapter (Bilibili) re-resolution identity, persisted so a paused
    /// DASH-pair task can be re-resolved to fresh signed track URLs after a
    /// restart instead of being forced into NEEDS_REFETCH. `mediaCID` is the
    /// Bilibili cid; `selectedQuality` is the chosen playurl quality id (qn). Both
    /// are non-secret and durable; the signed track URLs stay transient and
    /// are re-derived from `pageURL` + the archived site session on resume.
    var mediaCID: String? = nil
    var selectedQuality: Int? = nil

    /// Short, stable identifier for support reports and redacted display.
    /// Derived deterministically from the task UUID (first 5 bytes rendered
    /// as 8 Crockford base32 characters), so it needs no extra persistence,
    /// survives restarts, and never reveals the filename or URL.
    var jobID: String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var value: UInt64 = 0
        withUnsafeBytes(of: id.uuid) { raw in
            for byte in raw.prefix(5) {
                value = (value << 8) | UInt64(byte)
            }
        }
        var chars: [Character] = []
        for shift in stride(from: 35, through: 0, by: -5) {
            chars.append(alphabet[Int((value >> UInt64(shift)) & 0x1F)])
        }
        return String(chars)
    }

    /// The name shown in lists: the filename, or the Job ID when the user
    /// enabled filename redaction.
    func displayName(redacted: Bool) -> String {
        redacted ? jobID : filename
    }

    // Sorting helpers for Table column comparators
    var sortSize: Int64 { totalBytes ?? 0 }
    var sortSpeed: Double { averageSpeed ?? bytesPerSecond }
    var sortDuration: TimeInterval { totalDuration ?? 0 }

    var filename: String {
        URL(fileURLWithPath: destinationPath).lastPathComponent
    }

    /// Category inferred from the filename and declared MIME type, ignoring
    /// any user override. Powers the "Auto" preview in the detail panel.
    var detectedCategory: DownloadCategory {
        DownloadCategory(filename: filename, mimeType: mimeType)
    }

    var category: DownloadCategory {
        categoryOverride ?? detectedCategory
    }

    var queuePriority: Int {
        min(100, max(-100, priority ?? 0))
    }

    /// CLI-owned rows are mirrored into the App database for visibility, but
    /// their worker and control plane remain in the CLI process.
    var isCLIManaged: Bool {
        browserSubmissionType == "cli"
    }

    var fractionCompleted: Double {
        if status == .completed { return 1 }
        // 非完成态封顶 99%：最后 1% 留给“验证/收尾”，只有真正完成才跳
        // 100%。这样即使估算总量偏小、receivedBytes 超过它，进度条也停在 99%
        // 而非谎报完成；用户看到 99%+“正在验证”即知接近完成，100% 是完成
        // 的专属信号。
        if let overallProgressFraction {
            return min(0.99, max(0, overallProgressFraction))
        }
        guard let totalBytes, totalBytes > 0 else {
            return 0
        }
        return min(0.99, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    /// A completed task had every byte verified before publication, so all
    /// of its segments finished. Snap any segment still reporting a
    /// shortfall: legacy rows can carry split-parent snapshots whose totals
    /// were never shrunk when the coordinator divided the segment, which
    /// made the detail panel show a finished download as "9/12 completed".
    mutating func settleSegmentProgress() {
        guard status == .completed, !segments.isEmpty else { return }
        segments = segments.map { segment in
            guard let total = segment.totalBytes, total > 0,
                segment.receivedBytes < total
            else { return segment }
            var settled = segment
            settled.receivedBytes = total
            return settled
        }
    }

    /// The parallelism to display: actual behavior first, configuration
    /// only as a fallback before the transfer starts. While active, the
    /// engine's segment list is the real concurrency (yt-dlp reports no
    /// segments because it transfers serially). After the run ends, the
    /// recorded result wins; legacy rows without one keep the setting.
    var effectiveParallelism: Int {
        if status.isActive {
            return segments.isEmpty ? 1 : segments.count
        }
        if status.isTerminal {
            return usedParallelRequests ?? maximumParallelRequests
        }
        return maximumParallelRequests
    }

    var redactedSourceURL: String {
        // Prefer the preserved page URL: identifiers like YouTube's `v=`
        // survive there (auth-looking parameters were already stripped at
        // storage time). The raw sourceURL keeps its legacy full-redaction
        // treatment because signed CDN URLs live there.
        if let pageURL, var components = URLComponents(string: pageURL) {
            components.user = nil
            components.password = nil
            return components.string ?? String(localized: "已隐藏地址")
        }
        guard var components = URLComponents(string: sourceURL) else {
            return String(localized: "无效地址")
        }
        components.query = components.query == nil ? nil : "<redacted>"
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? String(localized: "已隐藏地址")
    }

    /// The redacted download source itself (query replaced), independent
    /// of `pageURL`. Shown as a second detail line only when it differs
    /// from the preserved page URL.
    var redactedRawSourceURL: String {
        guard var components = URLComponents(string: sourceURL) else {
            return String(localized: "无效地址")
        }
        components.query = components.query == nil ? nil : "<redacted>"
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? String(localized: "已隐藏地址")
    }
}

enum DownloadCategory: String, CaseIterable, Codable, Sendable {
    case archive
    case document
    case image
    case audio
    case video
    case application
    case other

    /// Extension-first classification. The extension list stays aligned with
    /// the browser extension's takeover list (DEFAULT_SETTINGS.extensions);
    /// when the filename has no recognized extension the MIME type decides,
    /// so extension-less CDN URLs still land in the right category.
    ///
    /// SYNC NOTICE: the extension/MIME tables below are mirrored in the
    /// browser extension at
    /// `BrowserExtension/chrome/src/shared/category.js` (extensionsByCategory
    /// / mimeByCategory, same file's top comment). When adding a format or
    /// MIME here, make the same change there — otherwise the extension will
    /// display one category while the App stores another. MIME-only mapping
    /// helpers live in `categoryForMIMEType` at the bottom of this enum.
    init(filename: String, mimeType: String? = nil) {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz",
            "zst", "lz4", "lzma", "cab", "arj", "lzh", "wim", "esd",
            "egg", "alz":
            self = .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "xlsb", "ppt", "pptx",
            "txt", "md", "epub", "csv", "rtf", "odt", "ods", "odp",
            "pages", "numbers", "key", "mobi", "azw", "azw3", "djvu",
            "chm", "tex", "wps", "json", "xml", "yaml", "html":
            self = .document
        case "jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "bmp",
            "tiff", "tif", "ico", "avif", "jxl", "raw", "cr2", "nef",
            "arw", "dng", "orf", "psd", "ai", "eps":
            self = .image
        case "mp3", "aac", "flac", "wav", "m4a", "ogg", "opus", "wma",
            "aiff", "aif", "ape", "dts", "ac3", "m4b", "amr", "mid",
            "midi", "dsf", "dff":
            self = .audio
        case "mp4", "mov", "mkv", "webm", "avi", "m4v", "flv", "mpg",
            "mpeg", "wmv", "ts", "m2ts", "mts", "vob", "3gp", "ogv",
            "rmvb", "mxf":
            self = .video
        case "dmg", "pkg", "app", "exe", "msi", "msix", "appx", "apk",
            "aab", "xapk", "ipa", "deb", "rpm", "iso", "appimage",
            "flatpak", "snap", "jar", "crx", "xpi", "vsix":
            self = .application
        default:
            self = Self.categoryForMIMEType(mimeType)
        }
    }

    private static func categoryForMIMEType(_ mimeType: String?) -> DownloadCategory {
        guard let type = mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
            !type.isEmpty
        else { return .other }
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        switch type {
        case "application/zip", "application/x-rar-compressed", "application/vnd.rar",
            "application/x-7z-compressed", "application/x-tar", "application/gzip",
            "application/x-bzip2", "application/x-xz", "application/zstd",
            "application/x-zstd", "application/x-lz4", "application/x-lzma":
            return .archive
        case "application/pdf", "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "text/plain", "text/markdown", "text/csv", "application/epub+zip",
            "application/vnd.apple.pages", "application/vnd.apple.numbers",
            "application/vnd.apple.keynote", "application/x-mobipocket-ebook",
            "application/vnd.amazon.mobi8-ebook", "application/vnd.ms-htmlhelp",
            "application/x-tex", "application/json", "application/xml",
            "text/xml", "text/yaml", "text/html":
            return .document
        case "application/vnd.android.package-archive", "application/x-apple-diskimage",
            "application/x-msdownload", "application/x-msi",
            "application/vnd.debian.binary-package", "application/x-rpm",
            "application/x-diskcopy":
            return .application
        default:
            // application/octet-stream carries no semantic meaning beyond
            // "binary file"; it intentionally lands in .other.
            return .other
        }
    }

    var title: String {
        switch self {
        case .archive: String(localized: "压缩包")
        case .document: String(localized: "文档")
        case .image: String(localized: "图片")
        case .audio: String(localized: "音频")
        case .video: String(localized: "视频")
        case .application: String(localized: "应用程序")
        case .other: String(localized: "其他")
        }
    }

    var systemImage: String {
        switch self {
        case .archive: "archivebox"
        case .document: "doc"
        case .image: "photo"
        case .audio: "music.note"
        case .video: "film"
        case .application: "shippingbox"
        case .other: "tray"
        }
    }
}

enum SidebarFilter: Hashable {
    case all
    case active
    case completed
    case history
    case today
    case yesterday
    case thisWeek
    case category(DownloadCategory)
    /// Tasks of one queue; nil selects the implicit main queue.
    case queue(UUID?)

    var title: String {
        switch self {
        case .all: String(localized: "全部下载")
        case .active: String(localized: "进行中")
        case .completed: String(localized: "已完成")
        case .history: String(localized: "历史记录")
        case .today: String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .thisWeek: String(localized: "本周")
        case .category(let category): category.title
        case .queue: String(localized: "队列")
        }
    }

    func matches(_ task: AppTask, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return !task.isArchived
        case .active:
            return !task.isArchived && !task.status.isTerminal
        case .completed:
            return !task.isArchived && task.status == .completed
        case .history:
            // History is a complete timeline of every download the user
            // ever added — live, archived, and terminal alike — so adding
            // a task records it immediately instead of only on deletion.
            return true
        case .today:
            return !task.isArchived && calendar.isDateInToday(task.createdAt)
        case .yesterday:
            return !task.isArchived && calendar.isDateInYesterday(task.createdAt)
        case .thisWeek:
            guard !task.isArchived else { return false }
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            else { return false }
            return task.createdAt >= weekStart
        case .category(let category):
            return !task.isArchived && task.category == category
        case .queue(let queueID):
            return !task.isArchived && task.queueID == queueID && !task.isCLIManaged
        }
    }
}
