import Foundation
import IDMEngine

protocol AppDownloadRunning: Sendable {
    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult
}

protocol YouTubeDownloadRunning: Sendable {
    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult
}

struct EngineDownloadRunner: AppDownloadRunning {
    private let dashMerger: (any FFmpegMerging)?
    private let youtubeDownloader: (any YouTubeDownloadRunning)?
    private let policyLearner: ConnectionPolicyLearner?
    /// Dual-channel diagnostic log; injected so unit tests never touch the user's
    /// real private log file.
    private let diagnosticLog: DownloadDiagnosticEventLog

    init(
        dashMerger: (any FFmpegMerging)? = nil,
        youtubeDownloader: (any YouTubeDownloadRunning)? = nil,
        connectionPolicyLearner: ConnectionPolicyLearner? = nil,
        diagnosticLog: DownloadDiagnosticEventLog = .shared
    ) {
        self.dashMerger = dashMerger
        self.youtubeDownloader = youtubeDownloader
        self.policyLearner = connectionPolicyLearner
        self.diagnosticLog = diagnosticLog
    }

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        // Unified dual-channel path: the ordinary log carries
        // only structured fields such as task/host/fingerprint; full URLs, file
        // names, and paths are correlated only in the private log under the same
        // task ID.
        diagnosticLog.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "download.started",
                stage: "download",
                taskID: request.taskID.uuidString,
                backend: request.backend.rawValue,
                sourceKind: request.sourceKind.rawValue,
                host: request.url.host,
                errorCode: nil,
                byteCount: nil,
                correlationID: nil,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(request.url.absoluteString),
                titleFingerprint: DiagnosticFingerprint.title(
                    request.destination.lastPathComponent),
                errorSummary: nil,
                fullURL: request.url.absoluteString,
                filename: request.destination.lastPathComponent,
                destinationPath: request.destination.path,
                fullErrorDescription: nil
            ))

        if request.backend == .youtubeExtractor {
            guard let youtubeDownloader else {
                throw YouTubeDownloadError.toolUnavailable
            }
            return try await youtubeDownloader.run(
                request,
                control: control,
                progress: progress
            )
        }
        let engine = DownloadEngine(
            hlsExecutor: HLSDownloadExecutor(merger: dashMerger),
            dashExecutor: DASHDownloadExecutor(merger: dashMerger),
            connectionPolicyLearner: policyLearner
        )
        do {
            let result = try await engine.download(
                request,
                control: control,
                progress: progress
            )
            diagnosticLog.record(
                DownloadDiagnosticEvent(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    event: "download.completed",
                    stage: "download",
                    taskID: request.taskID.uuidString,
                    backend: request.backend.rawValue,
                    sourceKind: request.sourceKind.rawValue,
                    host: request.url.host,
                    errorCode: nil,
                    byteCount: result.byteCount,
                    correlationID: nil,
                    urlExactFingerprint: DiagnosticFingerprint.urlExact(
                        request.url.absoluteString),
                    titleFingerprint: DiagnosticFingerprint.title(
                        request.destination.lastPathComponent),
                    errorSummary: nil,
                    fullURL: nil,
                    filename: request.destination.lastPathComponent,
                    destinationPath: nil,
                    fullErrorDescription: nil
                ))
            return result
        } catch {
            DownloadDiagnosticEventLog.recordFailure(
                to: diagnosticLog,
                event: "download.failed",
                stage: "download",
                taskID: request.taskID,
                backend: request.backend.rawValue,
                sourceKind: request.sourceKind.rawValue,
                url: request.url,
                destination: request.destination,
                error: error
            )
            throw error
        }
    }
}
