import Foundation

/// Unified artifact publication and verification service used across all download executors
/// (direct HTTP/HTTPS downloads, HLS, DASH, and FFmpeg remuxing).
///
/// Ensures strict Fail-Closed security:
/// - When `expectedSHA256 == nil`: `hasher` is NOT called (0 hasher invocations and no extra whole-file hash read pass),
///   publishes immediately, and returns `DownloadResult` with `sha256: nil` and transparent verification status.
/// - When `expectedSHA256 != nil`: calls `hasher` exactly once and performs constant-time equality check.
///   If verification fails, deletes `temporary`, throws `IDMError.verificationFailed`, and leaves `destination` untouched.
public struct ArtifactVerifier: Sendable {
    public typealias Hasher = @Sendable (URL) throws -> String

    private let hasher: Hasher

    public init(hasher: Hasher? = nil) {
        if let hasher {
            self.hasher = hasher
        } else {
            self.hasher = { try FileSupport.sha256(url: $0) }
        }
    }

    public func verifyAndPublish(
        temporary: URL,
        destination: URL,
        expectedSHA256: String?,
        sidecar: URL? = nil,
        byteCount: Int64,
        usedParallelRequests: Int,
        resumed: Bool,
        defaultVerification: String = "range-and-size",
        synchronizeParentDirectory: Bool = true
    ) throws -> DownloadResult {
        if let expected = expectedSHA256 {
            let actualHash = try hasher(temporary)
            guard FileSupport.constantTimeEquals(actualHash.lowercased(), expected.lowercased()) else {
                try? FileManager.default.removeItem(at: temporary)
                throw IDMError.verificationFailed(expected: expected, actual: actualHash)
            }
            try FileSupport.exclusivePublish(
                from: temporary,
                to: destination,
                synchronizeParentDirectory: synchronizeParentDirectory
            )
            if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
            return DownloadResult(
                destination: destination,
                byteCount: byteCount,
                sha256: actualHash,
                usedParallelRequests: usedParallelRequests,
                resumed: resumed,
                verification: "sha256"
            )
        } else {
            try FileSupport.exclusivePublish(
                from: temporary,
                to: destination,
                synchronizeParentDirectory: synchronizeParentDirectory
            )
            if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
            return DownloadResult(
                destination: destination,
                byteCount: byteCount,
                sha256: nil,
                usedParallelRequests: usedParallelRequests,
                resumed: resumed,
                verification: defaultVerification
            )
        }
    }
}
