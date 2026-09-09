import Foundation
import Security

/// Stores proxy credentials in the login Keychain as internet passwords.
///
/// Secrets never touch UserDefaults, logs, or the task database: settings
/// only persist the (non-secret) proxy username, which doubles as the
/// Keychain account name (`ProxyCredentialReference.keychainAccount`);
/// this store resolves it to the password at runtime. Items are encrypted
/// at rest by the Keychain and ACL-bound to this application.
struct KeychainCredentialStore: Sendable {
    enum KeychainError: LocalizedError, Equatable {
        case unhandled(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return String(
                    localized: "Keychain 操作失败（\(status)）：\(message ?? String(localized: "未知错误"))"
                )
            }
        }
    }

    static let service = "MacIDM Proxy"

    /// Persists (or replaces) the password for `username`.
    func save(username: String, password: String) throws {
        guard !username.isEmpty else { throw KeychainError.unhandled(status: errSecParam) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: username,
        ]
        var attributes = base
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = String(localized: "MacIDM 代理凭据")

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: Data(password.utf8)
            ]
            let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandled(status: updateStatus)
            }
        default:
            throw KeychainError.unhandled(status: addStatus)
        }
    }

    /// Loads the password for `username`, or nil when no item exists.
    func loadPassword(username: String) -> String? {
        guard !username.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(username: String) {
        guard !username.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: username,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
