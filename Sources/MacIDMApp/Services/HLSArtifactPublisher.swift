import Foundation
import IDMEngine

/// Publishes completed HLS output, remuxing only when the engine returned raw media.
struct HLSArtifactPublisher {
    static func publish(
        _ result: DownloadResult,
        destination: URL,
        expectedSHA256: String?,
        remuxer: any FFmpegRemuxing,
        control: @escaping @Sendable () -> DownloadControl
    ) async throws -> DownloadResult {
        try Task.checkCancellation()
        switch control() {
        case .continue: break
        case .pause: throw IDMError.paused
        case .cancel: throw IDMError.cancelled
        }
        if result.artifactFormat == .mp4 {
            return try ArtifactVerifier().verifyAndPublish(
                temporary: result.destination,
                destination: destination,
                expectedSHA256: expectedSHA256,
                byteCount: result.byteCount,
                usedParallelRequests: result.usedParallelRequests,
                resumed: result.resumed,
                defaultVerification: result.verification
            )
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
        return DownloadResult(
            destination: remuxed.destination,
            byteCount: remuxed.byteCount,
            sha256: remuxed.sha256,
            usedParallelRequests: result.usedParallelRequests,
            resumed: result.resumed,
            verification: "ffmpeg-ffprobe",
            artifactFormat: .mp4
        )
    }
}
