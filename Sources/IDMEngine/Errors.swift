import Foundation

public enum IDMError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case invalidParallelRequests
    case invalidExpectedHash
    case pathNotWritable(String)
    case filenameConflict(String)
    case invalidContentRange
    case rangeIgnored
    case resourceChanged
    case authenticationRequired
    case httpStatus(Int)
    case storageError(String)
    case sidecarCorrupt
    case verificationFailed(expected: String, actual: String)
    case paused
    case cancelled
    case timedOut
    case responseTooShort
    case responseTooLong
    case resourceTooLarge(Int64)
}

extension IDMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .unsupportedScheme: "Only HTTP and HTTPS URLs are supported"
        case .invalidParallelRequests: "Parallel requests must be between 1 and 64"
        case .invalidExpectedHash: "Expected SHA-256 must contain exactly 64 hexadecimal characters"
        case .pathNotWritable(let path): "Destination directory is not writable: \(path)"
        case .filenameConflict(let path): "Destination already exists: \(path)"
        case .invalidContentRange: "Server returned an invalid Content-Range"
        case .rangeIgnored: "Server ignored a byte range request"
        case .resourceChanged: "Remote resource identity changed"
        case .authenticationRequired: "Authentication is required"
        case .httpStatus(let status): "HTTP request failed with status \(status)"
        case .storageError(let message): "Storage error: \(message)"
        case .sidecarCorrupt: "Resume metadata is invalid or does not match the temporary file"
        case .verificationFailed(let expected, let actual):
            "SHA-256 verification failed (expected \(expected), got \(actual))"
        case .paused: "Download paused"
        case .cancelled: "Download cancelled"
        case .timedOut: "Operation timed out"
        case .responseTooShort: "Server response ended before the requested range was complete"
        case .responseTooLong: "Server response exceeded the requested range"
        case .resourceTooLarge(let maximumBytes):
            "Remote resource exceeds the in-memory safety limit of \(maximumBytes / (1024 * 1024)) MiB"
        }
    }

    public var code: String {
        switch self {
        case .invalidURL: "INVALID_URL"
        case .unsupportedScheme: "UNSUPPORTED_SCHEME"
        case .invalidParallelRequests: "INVALID_PARALLEL_REQUESTS"
        case .invalidExpectedHash: "INVALID_SHA256"
        case .pathNotWritable: "PATH_NOT_WRITABLE"
        case .filenameConflict: "FILENAME_CONFLICT"
        case .invalidContentRange: "INVALID_CONTENT_RANGE"
        case .rangeIgnored: "RANGE_IGNORED"
        case .resourceChanged: "RESOURCE_CHANGED"
        case .authenticationRequired: "AUTH_REQUIRED"
        case .httpStatus: "HTTP_ERROR"
        case .storageError: "STORAGE_ERROR"
        case .sidecarCorrupt: "SIDECAR_CORRUPT"
        case .verificationFailed: "VERIFICATION_FAILED"
        case .paused: "PAUSED"
        case .cancelled: "CANCELLED"
        case .timedOut: "TIMED_OUT"
        case .responseTooShort: "RESPONSE_TOO_SHORT"
        case .responseTooLong: "RESPONSE_TOO_LONG"
        case .resourceTooLarge: "RESOURCE_TOO_LARGE"
        }
    }
}
