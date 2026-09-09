import Foundation

public enum MacIDMProtocol {
    public static let version = 1
    public static let maximumMessageSize = 256 * 1_024
    public static let maximumUDSFrameSize = 384 * 1_024
    public static let hostName = "com.macidm.host"
    public static let keychainService = "com.macidm.bridge"
    // v5 deliberately moves the Debug bridge token away from the legacy
    // login-keychain item, whose ad-hoc code-signing ACL caused an access
    // prompt after every local rebuild.
    public static let keychainAccount = "uds-token-v5"
}

public struct MessageRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestId: String
    public let idempotencyKey: String
    public let type: String
    public let payload: [String: JSONValue]

    public init(
        protocolVersion: Int = MacIDMProtocol.version,
        requestId: String,
        idempotencyKey: String,
        type: String,
        payload: [String: JSONValue]
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.idempotencyKey = idempotencyKey
        self.type = type
        self.payload = payload
    }
}

public struct MessageError: Codable, Equatable, Sendable {
    public let code: String
    public let retryable: Bool
    public let message: String?

    public init(code: String, retryable: Bool, message: String? = nil) {
        self.code = code
        self.retryable = retryable
        self.message = message
    }
}

public struct MessageResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestId: String
    public let status: String
    public let type: String?
    public let payload: [String: JSONValue]?
    public let error: MessageError?

    public init(
        protocolVersion: Int = MacIDMProtocol.version,
        requestId: String,
        status: String,
        type: String? = nil,
        payload: [String: JSONValue]? = nil,
        error: MessageError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.status = status
        self.type = type
        self.payload = payload
        self.error = error
    }

    public static func ok(
        requestId: String,
        type: String,
        payload: [String: JSONValue] = [:]
    ) -> MessageResponse {
        MessageResponse(requestId: requestId, status: "ok", type: type, payload: payload)
    }

    public static func failure(
        requestId: String,
        code: String,
        retryable: Bool,
        message: String? = nil
    ) -> MessageResponse {
        MessageResponse(
            requestId: requestId,
            status: "error",
            error: MessageError(code: code, retryable: retryable, message: message)
        )
    }
}

public enum MessageCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decodeRequest(_ data: Data) throws -> MessageRequest {
        guard data.count <= MacIDMProtocol.maximumMessageSize else {
            throw BridgeError.messageTooLarge
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys)
                == Set(["protocolVersion", "requestId", "idempotencyKey", "type", "payload"])
        else {
            throw BridgeError.invalidMessage("request envelope fields are invalid")
        }
        let request = try JSONDecoder().decode(MessageRequest.self, from: data)
        try MessageValidator.validate(request)
        return request
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder().encode(value)
        guard data.count <= MacIDMProtocol.maximumMessageSize else {
            throw BridgeError.messageTooLarge
        }
        return data
    }

    /// Best-effort correlation id for diagnostics: malformed envelopes still
    /// log against a stable id rather than being indistinguishable.
    public static func requestID(from data: Data) -> String {
        struct Partial: Decodable { let requestId: String? }
        return (try? JSONDecoder().decode(Partial.self, from: data).requestId) ?? UUID().uuidString
    }
}
