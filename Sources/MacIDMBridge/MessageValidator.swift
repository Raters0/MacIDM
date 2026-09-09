import Foundation

public enum BridgeError: LocalizedError, Equatable {
    case invalidMessage(String)
    case messageTooLarge
    case protocolVersionMismatch
    case unauthenticatedClient
    case connectionFailed
    case connectionClosed
    case ioFailure(String)
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidMessage(let detail): "Invalid bridge message: \(detail)"
        case .messageTooLarge: "Bridge message exceeds 256 KiB"
        case .protocolVersionMismatch: "MacIDM protocol version is not supported"
        case .unauthenticatedClient: "Bridge client authentication failed"
        case .connectionFailed: "MacIDM App bridge is unavailable"
        case .connectionClosed: "Bridge connection closed unexpectedly"
        case .ioFailure(let detail): "Bridge I/O failed: \(detail)"
        case .keychainFailure(let status): "Keychain operation failed with status \(status)"
        }
    }
}

public enum MessageValidator {
    private static let allowedTypes: Set<String> = [
        "ping",
        "download.create",
        "download.enqueue",
        "media.inspect",
        "download.abandon",
        "download.browserCancelled",
        "download.browserCancelFailed",
    ]

    public static func validate(_ request: MessageRequest) throws {
        guard request.protocolVersion == MacIDMProtocol.version else {
            throw BridgeError.protocolVersionMismatch
        }
        guard UUID(uuidString: request.requestId) != nil else {
            throw BridgeError.invalidMessage("requestId must be a UUID")
        }
        try validateString(request.idempotencyKey, field: "idempotencyKey", maximumBytes: 512)
        guard allowedTypes.contains(request.type) else {
            throw BridgeError.invalidMessage("unsupported type")
        }

        switch request.type {
        case "ping":
            guard request.payload.isEmpty else {
                throw BridgeError.invalidMessage("ping payload must be empty")
            }
        case "download.create":
            try validateDownloadCreate(request.payload)
        case "download.enqueue":
            try validateDownloadEnqueue(request.payload)
        case "media.inspect":
            try validateMediaInspect(request.payload)
        case "download.abandon":
            try validateAbandon(request.payload)
        case "download.browserCancelled", "download.browserCancelFailed":
            try validateCancellationResult(request.payload)
        default:
            throw BridgeError.invalidMessage("unsupported type")
        }
    }

    private static func validateDownloadEnqueue(_ payload: [String: JSONValue]) throws {
        let allowedFields = Set([
            "url", "filenameHint", "mediaKind", "mime", "totalBytes", "referrer", "requestContext",
            "tabId", "interactive", "pageTitle", "pairVideoUrl", "pairAudioUrl", "pairCid", "pairNote",
            "duration", "estimatedSize", "browserDownloadId",
        ])
        guard Set(payload.keys).isSubset(of: allowedFields) else {
            throw BridgeError.invalidMessage("download.enqueue contains unsupported fields")
        }
        if payload["browserDownloadId"] != nil, payload["interactive"]?.boolValue != true {
            throw BridgeError.invalidMessage("browserDownloadId requires interactive takeover")
        }
        var normalized = payload
        if let mediaKind = normalized.removeValue(forKey: "mediaKind") {
            guard let value = mediaKind.stringValue,
                value == "http" || value == "hls" || value == "dash" || value == "youtube"
            else {
                throw BridgeError.invalidMessage("mediaKind must be http, hls, dash, or youtube")
            }
        }
        if let interactive = normalized.removeValue(forKey: "interactive") {
            guard interactive.boolValue != nil else {
                throw BridgeError.invalidMessage("interactive must be a boolean")
            }
        }
        if let pageTitle = normalized.removeValue(forKey: "pageTitle") {
            guard let value = pageTitle.stringValue else {
                throw BridgeError.invalidMessage("pageTitle must be a string")
            }
            try validateString(value, field: "pageTitle", maximumBytes: 600)
        }
        if normalized["browserDownloadId"] == nil { normalized["browserDownloadId"] = .number(0) }
        try validateDownloadCreate(normalized)
    }

    private static func validateMediaInspect(_ payload: [String: JSONValue]) throws {
        let allowedFields = Set(["url", "mediaKind", "mime", "referrer", "requestContext", "tabId"])
        guard Set(payload.keys).isSubset(of: allowedFields) else {
            throw BridgeError.invalidMessage("media.inspect contains unsupported fields")
        }
        guard let mediaKind = payload["mediaKind"]?.stringValue,
            mediaKind == "hls" || mediaKind == "dash" || mediaKind == "youtube"
        else {
            throw BridgeError.invalidMessage("media.inspect supports hls, dash, or youtube")
        }
        var normalized = payload
        normalized.removeValue(forKey: "mediaKind")
        normalized["browserDownloadId"] = .number(0)
        try validateDownloadCreate(normalized)
    }

    private static func validateDownloadCreate(_ payload: [String: JSONValue]) throws {
        let allowedFields = Set([
            "browserDownloadId", "url", "filenameHint", "mime", "totalBytes", "referrer",
            "requestContext", "tabId", "pageTitle", "pairVideoUrl", "pairAudioUrl", "pairCid", "pairNote",
            "duration", "estimatedSize",
        ])
        guard Set(payload.keys).isSubset(of: allowedFields) else {
            throw BridgeError.invalidMessage("download.create contains unsupported fields")
        }
        guard let rawURL = payload["url"]?.stringValue,
            let components = URLComponents(string: rawURL),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host != nil
        else {
            throw BridgeError.invalidMessage("url must be HTTP(S)")
        }
        try validateString(rawURL, field: "url", maximumBytes: 8_192)
        guard let browserDownloadId = payload["browserDownloadId"]?.intValue, browserDownloadId >= 0 else {
            throw BridgeError.invalidMessage("browserDownloadId must be non-negative")
        }
        if let tabID = payload["tabId"] {
            guard let value = tabID.intValue, value >= 0 else {
                throw BridgeError.invalidMessage("tabId must be non-negative")
            }
        }
        if let filename = payload["filenameHint"]?.stringValue {
            try validateFilename(filename)
        } else if payload["filenameHint"] != nil {
            throw BridgeError.invalidMessage("filenameHint must be a string")
        }
        if let pageTitle = payload["pageTitle"] {
            guard let value = pageTitle.stringValue else {
                throw BridgeError.invalidMessage("pageTitle must be a string")
            }
            try validateString(value, field: "pageTitle", maximumBytes: 600)
        }
        if let totalBytes = payload["totalBytes"], totalBytes != .null {
            guard let value = totalBytes.int64Value, value >= 0 else {
                throw BridgeError.invalidMessage("totalBytes must be non-negative or null")
            }
        }
        let pairVideoURL = try validateOptionalHTTPURL(payload["pairVideoUrl"], field: "pairVideoUrl")
        let pairAudioURL = try validateOptionalHTTPURL(payload["pairAudioUrl"], field: "pairAudioUrl")
        if (pairVideoURL == nil) != (pairAudioURL == nil) {
            throw BridgeError.invalidMessage("pairVideoUrl and pairAudioUrl must be supplied together")
        }
        if let pairCID = payload["pairCid"] {
            guard let value = pairCID.stringValue else {
                throw BridgeError.invalidMessage("pairCid must be a string")
            }
            try validateString(value, field: "pairCid", maximumBytes: 128)
        }
        if let pairNote = payload["pairNote"] {
            guard let value = pairNote.stringValue else {
                throw BridgeError.invalidMessage("pairNote must be a string")
            }
            try validateString(value, field: "pairNote", maximumBytes: 512)
        }
        for field in ["mime", "referrer"] {
            if let value = payload[field] {
                guard let string = value.stringValue else {
                    throw BridgeError.invalidMessage("\(field) must be a string")
                }
                // Keep the outer referrer limit aligned with the engine's
                // DownloadRequestContext limit. Otherwise the bridge would
                // accept a request that App later rejects after it has
                // already crossed the process boundary.
                let maximumBytes = 4_096
                try validateString(string, field: field, maximumBytes: maximumBytes)
            }
        }
        if let referrer = payload["referrer"]?.stringValue, !referrer.isEmpty {
            guard let scheme = URL(string: referrer)?.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                throw BridgeError.invalidMessage("referrer must be HTTP(S)")
            }
        }
        if let context = payload["requestContext"] {
            guard case .object(let object) = context else {
                throw BridgeError.invalidMessage("requestContext must be an object")
            }
            let allowed = Set(["cookie", "referer", "userAgent", "authorization"])
            guard Set(object.keys).isSubset(of: allowed) else {
                throw BridgeError.invalidMessage("requestContext contains unsupported fields")
            }
            for (key, value) in object {
                guard let string = value.stringValue else {
                    throw BridgeError.invalidMessage("requestContext.\(key) must be a string")
                }
                let maximumBytes: Int
                switch key {
                case "cookie": maximumBytes = 16_384
                case "referer", "authorization": maximumBytes = 4_096
                case "userAgent": maximumBytes = 4_096
                default: maximumBytes = 0
                }
                try validateString(
                    string,
                    field: "requestContext.\(key)",
                    maximumBytes: maximumBytes
                )
                guard !string.contains("\r"), !string.contains("\n") else {
                    throw BridgeError.invalidMessage("requestContext.\(key) contains a line break")
                }
            }
            if let referer = object["referer"]?.stringValue {
                guard let scheme = URL(string: referer)?.scheme?.lowercased(),
                    scheme == "http" || scheme == "https"
                else {
                    throw BridgeError.invalidMessage("requestContext.referer must be HTTP(S)")
                }
            }
        }
    }

    private static func validateCancellationResult(_ payload: [String: JSONValue]) throws {
        let allowedFields = Set(["taskId", "browserDownloadId", "takeoverToken", "errorCode"])
        guard Set(payload.keys).isSubset(of: allowedFields) else {
            throw BridgeError.invalidMessage("cancellation result contains unsupported fields")
        }
        guard UUID(uuidString: payload["taskId"]?.stringValue ?? "") != nil else {
            throw BridgeError.invalidMessage("taskId must be a UUID")
        }
        guard let browserDownloadId = payload["browserDownloadId"]?.intValue, browserDownloadId >= 0 else {
            throw BridgeError.invalidMessage("browserDownloadId must be non-negative")
        }
        guard let token = payload["takeoverToken"]?.stringValue else {
            throw BridgeError.invalidMessage("takeoverToken is required")
        }
        try validateString(token, field: "takeoverToken", maximumBytes: 256)
        if let errorCode = payload["errorCode"] {
            guard let string = errorCode.stringValue else {
                throw BridgeError.invalidMessage("errorCode must be a string")
            }
            try validateString(string, field: "errorCode", maximumBytes: 128)
        }
    }

    private static func validateAbandon(_ payload: [String: JSONValue]) throws {
        let allowedFields = Set(["browserDownloadId", "originalIdempotencyKey"])
        guard Set(payload.keys).isSubset(of: allowedFields) else {
            throw BridgeError.invalidMessage("download.abandon contains unsupported fields")
        }
        guard let browserDownloadId = payload["browserDownloadId"]?.intValue,
            browserDownloadId >= 0
        else {
            throw BridgeError.invalidMessage("browserDownloadId must be non-negative")
        }
        guard let key = payload["originalIdempotencyKey"]?.stringValue, !key.isEmpty else {
            throw BridgeError.invalidMessage("originalIdempotencyKey is required")
        }
        try validateString(key, field: "originalIdempotencyKey", maximumBytes: 512)
    }

    private static func validateOptionalHTTPURL(
        _ value: JSONValue?,
        field: String
    ) throws -> String? {
        guard let value else { return nil }
        guard let rawURL = value.stringValue,
            let components = URLComponents(string: rawURL),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host != nil
        else {
            throw BridgeError.invalidMessage(field + " must be HTTP(S)")
        }
        try validateString(rawURL, field: field, maximumBytes: 8_192)
        return rawURL
    }

    private static func validateFilename(_ value: String) throws {
        try validateString(value, field: "filenameHint", maximumBytes: 255)
        let controls = CharacterSet.controlCharacters
        guard value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
            value.rangeOfCharacter(from: controls) == nil
        else {
            throw BridgeError.invalidMessage("filenameHint contains a path or control character")
        }
    }

    private static func validateString(_ value: String, field: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw BridgeError.invalidMessage("\(field) is empty or too long")
        }
    }
}
