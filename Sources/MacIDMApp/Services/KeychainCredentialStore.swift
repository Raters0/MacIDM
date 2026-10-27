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

    /// 独立的钥匙串 service 命名空间：代理凭据用默认值，语义判断服务的
    /// API KEY 用 `semanticTitle`（互不覆盖，删除互不影响）。
    enum PresetService {
        static let proxy = KeychainCredentialStore()
        static let semanticTitle = KeychainCredentialStore(
            serviceName: "MacIDM Semantic Title",
            itemLabel: String(localized: "MacIDM 语义判断服务 KEY")
        )
    }

    private let serviceName: String
    private let itemLabel: String

    init(serviceName: String = KeychainCredentialStore.service, itemLabel: String = "MacIDM 代理凭据") {
        self.serviceName = serviceName
        self.itemLabel = itemLabel
    }

    /// Mark the window around every access: a freshly built bundle's code
    /// identity is not in the stored item's login-Keychain ACL yet, so the call
    /// can raise the system approval dialog, and the confirmation panel has to
    /// tell that dialog apart from the user switching apps.
    private func credentialAccess<T>(_ body: () throws -> T) rethrows -> T {
        KeychainAccessSignal.shared.begin()
        defer { KeychainAccessSignal.shared.end() }
        return try body()
    }

    /// Persists (or replaces) the password for `username`.
    func save(username: String, password: String) throws {
        guard !username.isEmpty else { throw KeychainError.unhandled(status: errSecParam) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: username,
        ]
        var attributes = base
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = itemLabel

        let addStatus = credentialAccess { SecItemAdd(attributes as CFDictionary, nil) }
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: Data(password.utf8)
            ]
            let updateStatus = credentialAccess {
                SecItemUpdate(base as CFDictionary, update as CFDictionary)
            }
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
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return credentialAccess {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func delete(username: String) {
        guard !username.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: username,
        ]
        _ = credentialAccess { SecItemDelete(query as CFDictionary) }
    }
}
