import Darwin
import Foundation

/// Bounded retries for transient transport failures. A retry re-enters the
/// normal download route, so ranged/HLS/DASH sidecars are used as the resume
/// boundary instead of silently discarding already committed bytes.
///
/// Defaults follow the product spec's "retry: 5 attempts" setting: up to 5 attempts
/// with exponential backoff from 1 second, capped at 8 seconds per wait, so a
/// flaky connection gets several real chances before the task is given up.
public struct DownloadRetryPolicy: Sendable {
    /// Storage-class failures that clear on their own once the user frees
    /// space or the system releases file descriptors: the volume ran out of
    /// room (ENOSPC) or the process/system open-file limit was hit (EMFILE,
    /// ENFILE). Retrying resumes from the committed checkpoint, so recovered
    /// capacity revives the task instead of leaving it permanently failed.
    /// Deliberately excluded: the creation-time capacity pre-check (it fails
    /// fast with no committed bytes to protect) and hardware I/O errors,
    /// which retrying cannot fix.
    private static let transientPOSIXStorageCodes: Set<Int32> = [ENOSPC, EMFILE, ENFILE]

    public let maxAttempts: Int
    public let baseDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64

    public init(
        maxAttempts: Int = 5,
        baseDelayNanoseconds: UInt64 = 1_000_000_000,
        maximumDelayNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maximumDelayNanoseconds = max(baseDelayNanoseconds, maximumDelayNanoseconds)
    }

    public func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? IDMError {
            switch error {
            case .httpStatus(let status):
                return [408, 425, 429, 500, 502, 503, 504].contains(status)
            case .responseTooShort:
                return true
            case .sidecarCorrupt:
                // A checkpoint invariant failure mid-transfer does not prove
                // the on-disk sidecar is corrupt: the last flushed checkpoint
                // is still a valid resume boundary, so re-entering the normal
                // route recovers instead of failing the task outright.
                return true
            case .storageError(_, let code?):
                return Self.transientPOSIXStorageCodes.contains(code)
            default:
                return false
            }
        }

        if let dashError = error as? DASHDownloadError {
            switch dashError {
            case .resumeCorrupt:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        // Storage failures raised by Foundation instead of the POSIX sink:
        // Cocoa's file-write-out-of-space and raw POSIX errnos are the same
        // transient class as the tagged IDMError above.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
            let code = Int32(exactly: nsError.code),
            Self.transientPOSIXStorageCodes.contains(code)
        {
            return true
        }
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed,
            NSURLErrorCallIsActive,
            // TLS handshakes fail transiently when traffic crosses an
            // unstable proxy node or a CDN resets the session. A handshake
            // failure carries no committed bytes, so retrying with backoff
            // is always safe and turns one flaky second into a recoverable
            // pause instead of a terminal task failure.
            NSURLErrorSecureConnectionFailed,
        ].contains(nsError.code)
    }

    public func delayNanoseconds(beforeAttempt attempt: Int) -> UInt64 {
        guard attempt > 1 else { return 0 }
        let exponent = min(attempt - 2, 10)
        let multiplier = UInt64(1 << exponent)
        let (delay, overflow) = baseDelayNanoseconds.multipliedReportingOverflow(by: multiplier)
        let capped = min(overflow ? maximumDelayNanoseconds : delay, maximumDelayNanoseconds)
        // Full jitter: subtract a uniform random fraction in [0, capped) so
        // concurrent retries do not synchronise on the same backoff slot.
        let jitter = UInt64.random(in: 0..<max(capped, 1))
        return capped - jitter
    }
}

extension DownloadRetryPolicy {
    /// True when a failure means the destination volume is full: a write
    /// that hit ENOSPC (tagged by the sink or raised by Foundation) or the
    /// creation-time capacity pre-check. Retries cannot outlast a full disk,
    /// so the App parks such tasks and resumes them once space returns.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if let error = error as? IDMError {
            guard case .storageError(let message, let code) = error else { return false }
            return code == ENOSPC || message == FileSupport.insufficientCapacityMessage
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)
    }
}
