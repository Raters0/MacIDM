import Foundation
import IDMEngine

/// A lazy `FFmpegRemuxing & FFmpegMerging` proxy that auto-detects an
/// ffmpeg/ffprobe pair on first use.
///
/// The App's synchronous initializer cannot `await` an autodetect pass, so
/// this proxy defers detection until the first HLS/DASH task actually runs.
/// On first invocation it calls `FFmpegToolchain.autodetect()`, builds a real
/// `FFmpegService`, and forwards every subsequent call to it. If detection
/// fails the proxy throws `FFmpegError.executableNotFound`, which surfaces to
/// the user as a normal "FFmpeg unavailable" task failure — the same outcome
/// as before, except now a working system ffmpeg is actually used instead of
/// silently ignored.
///
/// The actor serializes the one-time detection so concurrent first-calls
/// only detect once. After resolution, calls forward to the cached service.
actor FFmpegAutodetectProxy {
    private var resolved: FFmpegService?
    private var detectionFailed = false
    /// Dual-channel diagnostic log; injected so unit tests never touch the user's
    /// real private log file.
    private let diagnosticLog: DownloadDiagnosticEventLog

    init(diagnosticLog: DownloadDiagnosticEventLog = .shared) {
        self.diagnosticLog = diagnosticLog
    }

    private func resolve() async throws -> FFmpegService {
        if let resolved { return resolved }
        if detectionFailed { throw FFmpegError.executableNotFound("ffmpeg") }

        guard let toolchain = await FFmpegToolchain.autodetect() else {
            detectionFailed = true
            throw FFmpegError.executableNotFound("ffmpeg")
        }
        let service = FFmpegService(toolchain: toolchain)
        resolved = service
        return service
    }

    /// FFmpeg input/output file names are usually derived from the video title
    /// The ordinary log records only fingerprints and byte
    /// counts; full file names go to the private log under the same event id.
    private func recordFFmpegEvent(
        event: String,
        stage: String,
        outputURL: URL,
        byteCount: Int64? = nil,
        error: Error? = nil
    ) {
        diagnosticLog.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: event,
                stage: stage,
                taskID: nil,
                backend: nil,
                sourceKind: nil,
                host: nil,
                errorCode: error.map { DownloadDiagnosticEventLog.errorCode(for: $0) },
                byteCount: byteCount,
                correlationID: nil,
                urlExactFingerprint: nil,
                titleFingerprint: DiagnosticFingerprint.title(outputURL.lastPathComponent),
                errorSummary: error.flatMap {
                    YouTubeOutputSanitizer.sanitizedErrorSummary($0.localizedDescription)
                },
                fullURL: nil,
                filename: outputURL.lastPathComponent,
                destinationPath: error == nil ? nil : outputURL.path,
                fullErrorDescription: error?.localizedDescription
            ))
    }
}

extension FFmpegAutodetectProxy: FFmpegRemuxing {
    nonisolated func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        await recordFFmpegEvent(event: "ffmpeg.remuxStarted", stage: "remux", outputURL: request.outputURL)
        do {
            let result = try await resolve().remux(request)
            await recordFFmpegEvent(
                event: "ffmpeg.remuxCompleted", stage: "remux",
                outputURL: request.outputURL, byteCount: result.byteCount)
            return result
        } catch {
            await recordFFmpegEvent(
                event: "ffmpeg.remuxFailed", stage: "remux",
                outputURL: request.outputURL, error: error)
            throw error
        }
    }
}

extension FFmpegAutodetectProxy: FFmpegMerging {
    nonisolated func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
        await recordFFmpegEvent(event: "ffmpeg.mergeStarted", stage: "merge", outputURL: request.outputURL)
        do {
            let result = try await resolve().merge(request)
            await recordFFmpegEvent(
                event: "ffmpeg.mergeCompleted", stage: "merge",
                outputURL: request.outputURL, byteCount: result.byteCount)
            return result
        } catch {
            await recordFFmpegEvent(
                event: "ffmpeg.mergeFailed", stage: "merge",
                outputURL: request.outputURL, error: error)
            throw error
        }
    }
}
