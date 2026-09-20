import Foundation

/// Explicit separate-audio HLS entry: a variant media playlist plus its
/// audio rendition playlist (from `EXT-X-MEDIA`), muxed into one MP4.
public struct HLSPairDownloadRequest: Sendable {
    public let videoURL: URL
    public let audioURL: URL
    public let destination: URL
    public let outputKind: FFmpegOutputKind
    public let maximumParallelRequests: Int
    public let taskID: UUID
    public let requestContext: DownloadRequestContext?
    public let expectedSHA256: String?
    public let rateLimiter: (any DownloadRateLimiting)?

    public init(
        videoURL: URL,
        audioURL: URL,
        destination: URL,
        outputKind: FFmpegOutputKind = .mp4,
        maximumParallelRequests: Int = 8,
        taskID: UUID = UUID(),
        requestContext: DownloadRequestContext? = nil,
        rateLimiter: (any DownloadRateLimiting)? = nil,
        expectedSHA256: String? = nil
    ) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.destination = destination
        self.outputKind = outputKind
        self.maximumParallelRequests = maximumParallelRequests
        self.taskID = taskID
        self.requestContext = requestContext
        self.rateLimiter = rateLimiter
        self.expectedSHA256 = expectedSHA256
    }
}
