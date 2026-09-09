import Foundation
import Security

/// Stores the cookie value captured for one site.
///
/// Keeping the value out of `sessions.json` is the whole point: that JSON is
/// read by tests, copied into support bundles and opened while debugging,
/// whereas a Keychain item is encrypted at rest and ACL-bound to this app.
protocol SessionSecretStore: Sendable {
    func save(_ value: String, forDomain domain: String) throws
    func value(forDomain domain: String) -> String?
    func removeValue(forDomain domain: String)
}

/// Keychain-backed cookie storage: one generic-password item per registrable
/// domain, so a session can be resolved or deleted without ever writing the
/// value to the app's support directory.
struct KeychainSessionSecretStore: SessionSecretStore {
    static let service = "MacIDM Site Session"

    func save(_ value: String, forDomain domain: String) throws {
        guard !domain.isEmpty else {
            throw KeychainCredentialStore.KeychainError.unhandled(status: errSecParam)
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: domain,
        ]
        var attributes = base
        // After first unlock rather than WhenUnlocked: a queued media download
        // may still need its session after the screen locks.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrLabel as String] = String(localized: "MacIDM 站点会话 Cookie")

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainCredentialStore.KeychainError.unhandled(status: status)
            }
        default:
            throw KeychainCredentialStore.KeychainError.unhandled(status: addStatus)
        }
    }

    func value(forDomain domain: String) -> String? {
        guard !domain.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: domain,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeValue(forDomain domain: String) {
        guard !domain.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: domain,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
