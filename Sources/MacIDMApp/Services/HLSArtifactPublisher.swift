import Foundation
import IDMEngine

/// Publishes completed HLS output, remuxing only when the engine returned raw media.
struct PublishedHLSArtifact {
    let result: DownloadResult
    /// ffprobe evidence for the file this call packaged. nil when the engine
    /// already returned a muxed MP4 — that path is the separate-audio pair
    /// merge, which fails closed rather than publishing a silent file.
    let probe: FFmpegProbeResult?
}

struct HLSArtifactPublisher {
    static func publish(
        _ result: DownloadResult,
        destination: URL,
        expectedSHA256: String?,
        remuxer: any FFmpegRemuxing,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> PublishedHLSArtifact {
        try Task.checkCancellation()
        switch control() {
        case .continue: break
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
        if result.artifactFormat == .mp4 {
            let verified = try ArtifactVerifier().verifyAndPublish(
                temporary: result.destination,
                destination: destination,
                expectedSHA256: expectedSHA256,
                byteCount: result.byteCount,
                usedParallelRequests: result.usedParallelRequests,
                resumed: result.resumed,
                defaultVerification: result.verification
            )
            return PublishedHLSArtifact(result: verified, probe: nil)
        }
        let remuxed = try await remuxer.remux(
            FFmpegRemuxRequest(
                inputURL: result.destination,
                outputURL: destination,
                outputKind: .mp4,
                expectedSHA256: expectedSHA256,
                control: control
            )
        )
        try? FileManager.default.removeItem(at: result.destination)
        return PublishedHLSArtifact(
            result: DownloadResult(
                destination: remuxed.destination,
                byteCount: remuxed.byteCount,
                sha256: remuxed.sha256,
                usedParallelRequests: result.usedParallelRequests,
                resumed: result.resumed,
                verification: "ffmpeg-ffprobe",
                artifactFormat: .mp4
            ),
            probe: remuxed.probe
        )
    }
}
