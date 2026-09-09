import Foundation

/// Shared column order for SQL selection, binding, and decoding.
enum AppTaskColumn: Int32, CaseIterable {
    case id
    case sourceUrl
    case destinationPath
    case maximumParallelRequests
    case expectedSha256
    case sourceKind
    case browserClientId
    case browserSubmissionType
    case browserSubmissionKey
    case createdAt
    case updatedAt
    case status
    case receivedBytes
    case totalBytes
    case bytesPerSecond
    case speedHistoryJson
    case sha256
    case verification
    case errorCode
    case errorMessage
    case segmentsJson
    case isArchived
    case averageSpeed
    case totalDuration
    case category
    case priority
    case startedAt
    case mediaDuration
    case queueId
    case pageUrl
    case errorRecommendation
    case errorCategory
    case usedParallelRequests
    case mimeType
    case activeTransferDuration
    case mediaCid
    case selectedQuality
    var sqlName: String {
        switch self {
        case .id: "id"
        case .sourceUrl: "source_url"
        case .destinationPath: "destination_path"
        case .maximumParallelRequests: "maximum_parallel_requests"
        case .expectedSha256: "expected_sha256"
        case .sourceKind: "source_kind"
        case .browserClientId: "browser_client_id"
        case .browserSubmissionType: "browser_submission_type"
        case .browserSubmissionKey: "browser_submission_key"
        case .createdAt: "created_at"
        case .updatedAt: "updated_at"
        case .status: "status"
        case .receivedBytes: "received_bytes"
        case .totalBytes: "total_bytes"
        case .bytesPerSecond: "bytes_per_second"
        case .speedHistoryJson: "speed_history_json"
        case .sha256: "sha256"
        case .verification: "verification"
        case .errorCode: "error_code"
        case .errorMessage: "error_message"
        case .segmentsJson: "segments_json"
        case .isArchived: "is_archived"
        case .averageSpeed: "average_speed"
        case .totalDuration: "total_duration"
        case .category: "category"
        case .priority: "priority"
        case .startedAt: "started_at"
        case .mediaDuration: "media_duration"
        case .queueId: "queue_id"
        case .pageUrl: "page_url"
        case .errorRecommendation: "error_recommendation"
        case .errorCategory: "error_category"
        case .usedParallelRequests: "used_parallel_requests"
        case .mimeType: "mime_type"
        case .activeTransferDuration: "active_transfer_duration"
        case .mediaCid: "media_cid"
        case .selectedQuality: "selected_quality"
        }
    }
    static var selection: String { allCases.map(\.sqlName).joined(separator: ", ") }
    static var placeholders: String { allCases.map { _ in "?" }.joined(separator: ", ") }
    static var updates: String {
        allCases.filter { $0 != .id }.map { "\($0.sqlName) = excluded.\($0.sqlName)" }.joined(separator: ", ")
    }
}
