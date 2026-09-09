import Foundation

public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case http
    case https
    case socks5
}

public struct ProxyCredentialReference: Codable, Equatable, Hashable, Sendable {
    public let keychainAccount: String

    public init(keychainAccount: String) throws {
        guard !keychainAccount.isEmpty,
            keychainAccount.utf8.count <= 256,
            !keychainAccount.contains(where: { $0.isNewline || $0.isWhitespace })
        else { throw ProxyValidationError.invalidCredentialReference }
        self.keychainAccount = keychainAccount
    }
}

public struct ProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public let kind: ProxyKind
    public let host: String
    public let port: Int
    public let credentialReference: ProxyCredentialReference?

    public init(
        kind: ProxyKind,
        host: String,
        port: Int,
        credentialReference: ProxyCredentialReference? = nil
    ) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, normalizedHost.utf8.count <= 253,
            !normalizedHost.contains(where: { $0.isWhitespace || $0.isNewline }),
            !normalizedHost.contains(":"),
            !normalizedHost.contains("/"),
            !normalizedHost.contains("\\"),
            URL(string: kind.rawValue + "://" + normalizedHost)?.host != nil
        else { throw ProxyValidationError.invalidHost }
        guard (1...65_535).contains(port) else { throw ProxyValidationError.invalidPort }
        self.kind = kind
        self.host = normalizedHost
        self.port = port
        self.credentialReference = credentialReference
    }
}

public enum ProxyValidationError: Error, Equatable, Sendable {
    case invalidHost
    case invalidPort
    case invalidCredentialReference
}

extension ProxyValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHost: "代理主机名无效。"
        case .invalidPort: "代理端口必须在 1 到 65535 之间。"
        case .invalidCredentialReference: "代理凭据引用无效。"
        }
    }
}
