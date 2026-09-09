import Foundation

@testable import MacIDMApp

/// In-memory stand-in for the Keychain, so session tests never create or read
/// real Keychain items. Path isolation (`AppSupportPaths` / an injected
/// directory) cannot cover the Keychain: it is one namespace per user, so a
/// test that stores a credential through the production store would leave it
/// behind for the whole account.
///
/// Mirrors the failure modes the production store can hit — a refused save, a
/// save refused for one domain only, and a value that reads back differently —
/// because all three decide whether plaintext may be dropped from disk.
final class FakeSessionSecretStore: SessionSecretStore, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    /// When set, every `save` throws it, standing in for a locked or
    /// unavailable Keychain.
    var saveError: Error?
    /// Selective counterpart to `saveError`: only these domains are refused, so
    /// a migration can half-succeed the way a real Keychain sometimes does.
    var failingDomains: Set<String> = []
    /// When set, a saved value reads back differently, standing in for an item
    /// that was accepted but cannot be trusted.
    var corruptedReadback = false

    var values: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func save(_ value: String, forDomain domain: String) throws {
        if let saveError { throw saveError }
        if failingDomains.contains(domain) { throw Failure() }
        lock.lock()
        storage[domain] = value
        lock.unlock()
    }

    func value(forDomain domain: String) -> String? {
        lock.lock()
        let stored = storage[domain]
        lock.unlock()
        guard let stored else { return nil }
        return corruptedReadback ? "\(stored)-different" : stored
    }

    func removeValue(forDomain domain: String) {
        lock.lock()
        storage.removeValue(forKey: domain)
        lock.unlock()
    }
}
