import Foundation
import IDMEngine

/// Structured diagnostic events for the download lifecycle.
///
/// Same dual-channel principle as `YouTubeDiagnosticEvent`: an event is
/// generated once; the ordinary log writes only task/event ID, host, stage,
/// error code, and fingerprints/lengths, never raw titles, file names, full
/// paths, or full URLs; the private log keeps the full original values of
/// those fields under the same event id.
struct DownloadDiagnosticEvent: Sendable {
    /// Correlation ID shared by both logs.
    let id: String
    let timestamp: Date
    /// Event name, e.g. `download.started` / `download.failed` / `ffmpeg.remuxFailed`.
    let event: String
    /// Stage: `download` / `remux` / `merge` / `completion`.
    let stage: String
    let taskID: String?
    /// `DownloadBackend.rawValue` (native / youtubeExtractor).
    let backend: String?
    /// `DownloadSourceKind.rawValue` (http / hls / dash).
    let sourceKind: String?
    let host: String?
    let errorCode: String?
    let byteCount: Int64?
    /// Structured correlation field (e.g. the size probe's probeId, round 6 P2):
    /// independent of free-text summary output, so correlation survives a
    /// missing summary or sanitizer failure.
    let correlationID: String?
    /// Short SHA-256 fingerprint of the full URL.
    let urlExactFingerprint: String?
    /// Title/filename fingerprint: the ordinary log correlates the same resource
    /// through it without writing the raw value.
    let titleFingerprint: String?
    /// Sanitized error summary; nil when sanitization fails (fail closed).
    let errorSummary: String?

    // The fields below go to the private diagnostic log only.
    let fullURL: String?
    let filename: String?
    let destinationPath: String?
    let fullErrorDescription: String?

    var privateDetailAvailable: Bool {
        fullURL != nil || filename != nil || destinationPath != nil
            || fullErrorDescription != nil
    }
}

/// Dual-channel writer for the download lifecycle: ordinary structured lines
/// plus private full original values. Shares the same private file and private
/// toggle semantics as `YouTubeDiagnosticEventLog`: ordinary lines always go to
/// the ordinary sink; the private toggle controls only the private file
/// The regular log carries only the sanitized summary.
final class DownloadDiagnosticEventLog: @unchecked Sendable {
    static let shared = DownloadDiagnosticEventLog()

    private let privateFile: PrivateDiagnosticFile
    private let regularSink: @Sendable (String) -> Void
    private let formatter: ISO8601DateFormatter
    private let enabled: Bool

    init(
        privateLogURL: URL = YouTubeDiagnosticEventLog.defaultPrivateLogURL(),
        regularSink: @escaping @Sendable (String) -> Void = { AppLogger.shared.info(.download, $0) },
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

    func record(_ event: DownloadDiagnosticEvent) {
        regularSink(regularLine(for: event))
        guard enabled else { return }
        privateFile.append(privateEntry(event))
    }

    /// Any failure error → stable error code (shared by the ordinary and private logs).
    static func errorCode(for error: Error) -> String {
        if let engineError = error as? IDMError { return engineError.code }
        if let ffmpegError = error as? FFmpegError { return ffmpegError.code }
        if let youtubeError = error as? YouTubeDownloadError { return youtubeError.code }
        return "UNKNOWN_ERROR"
    }

    /// One-shot dual-channel record for a failure path: the ordinary line carries
    /// only the sanitized summary and fingerprints; the private record keeps the
    /// full file name/path/error description.
    static func recordFailure(
        to log: DownloadDiagnosticEventLog = .shared,
        event: String,
        stage: String,
        taskID: UUID?,
        backend: String? = nil,
        sourceKind: String? = nil,
        url: URL? = nil,
        destination: URL? = nil,
        error: Error
    ) {
        log.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: event,
                stage: stage,
                taskID: taskID?.uuidString,
                backend: backend,
                sourceKind: sourceKind,
                host: url?.host,
                errorCode: errorCode(for: error),
                byteCount: nil,
                correlationID: nil,
                urlExactFingerprint: url.map { DiagnosticFingerprint.urlExact($0.absoluteString) }
                    ?? nil,
                titleFingerprint: destination.map {
                    DiagnosticFingerprint.title($0.lastPathComponent)
                } ?? nil,
                errorSummary: YouTubeOutputSanitizer.sanitizedErrorSummary(
                    error.localizedDescription),
                fullURL: url?.absoluteString,
                filename: destination?.lastPathComponent,
                destinationPath: destination?.path,
                fullErrorDescription: error.localizedDescription
            ))
    }

    /// Task lifecycle events (stall convergence, reduced-concurrency retry, file
    /// loss, etc., §3.3): the ordinary line carries only the task ID, state, and
    /// fingerprints; the full title-derived file name goes to the private log
    /// only, correlated by the same event ID.
    static func recordTaskLifecycle(
        to log: DownloadDiagnosticEventLog = .shared,
        event: String,
        taskID: UUID,
        filename: String,
        destinationPath: String?,
        summary: String? = nil
    ) {
        log.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: event,
                stage: "lifecycle",
                taskID: taskID.uuidString,
                backend: nil,
                sourceKind: nil,
                host: nil,
                errorCode: nil,
                byteCount: nil,
                correlationID: nil,
                urlExactFingerprint: nil,
                titleFingerprint: DiagnosticFingerprint.title(filename),
                errorSummary: summary.flatMap { YouTubeOutputSanitizer.sanitizedErrorSummary($0) },
                fullURL: nil,
                filename: filename,
                destinationPath: destinationPath,
                fullErrorDescription: summary
            ))
    }

    // MARK: - Regular sink

    private func regularLine(for event: DownloadDiagnosticEvent) -> String {
        var parts: [String] = [
            "event=\(event.event)", "eventId=\(event.id)",
        ]
        if let taskID = event.taskID { parts.append("task=\(taskID)") }
        parts.append("stage=\(event.stage)")
        if let backend = event.backend { parts.append("backend=\(backend)") }
        if let sourceKind = event.sourceKind { parts.append("kind=\(sourceKind)") }
        if let host = event.host { parts.append("host=\(host)") }
        if let errorCode = event.errorCode { parts.append("errorCode=\(errorCode)") }
        if let correlationID = event.correlationID { parts.append("probeId=\(correlationID)") }
        if let byteCount = event.byteCount { parts.append("bytes=\(byteCount)") }
        if let urlFP = event.urlExactFingerprint { parts.append("urlExactFingerprint=\(urlFP)") }
        if let titleFP = event.titleFingerprint { parts.append("titleFingerprint=\(titleFP)") }
        parts.append("privateDetailAvailable=\(event.privateDetailAvailable)")
        // Fail closed: omit the summary when sanitization fails, keeping only
        // structured fields.
        if let summary = event.errorSummary {
            parts.append("summary=\(summary.replacingOccurrences(of: "|", with: "/"))")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Private sink

    /// Private record: all free text (full URLs, error descriptions) must pass
    /// private credential sanitization, including proxy account passwords in
    /// URL userinfo; full signed queries and ordinary error context are kept.
    private func privateEntry(_ event: DownloadDiagnosticEvent) -> String {
        var lines: [String] = []
        lines.append(
            "\(formatter.string(from: event.timestamp)) eventId=\(event.id) event=\(event.event) stage=\(event.stage)"
        )
        var header: [String] = []
        if let taskID = event.taskID { header.append("task=\(taskID)") }
        if let errorCode = event.errorCode { header.append("errorCode=\(errorCode)") }
        if let correlationID = event.correlationID { header.append("probeId=\(correlationID)") }
        if let byteCount = event.byteCount { header.append("bytes=\(byteCount)") }
        if !header.isEmpty { lines.append("  " + header.joined(separator: " ")) }
        if let fullURL = event.fullURL {
            lines.append("  url: \(YouTubeOutputSanitizer.redactCredentials(in: fullURL) ?? fullURL)")
        }
        if let filename = event.filename { lines.append("  filename: \(filename)") }
        if let destinationPath = event.destinationPath {
            lines.append("  destination: \(destinationPath)")
        }
        if let fullError = event.fullErrorDescription {
            lines.append(
                "  error: \(YouTubeOutputSanitizer.redactCredentials(in: fullError) ?? fullError)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
