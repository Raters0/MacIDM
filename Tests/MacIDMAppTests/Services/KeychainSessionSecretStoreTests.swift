import XCTest

@testable import MacIDMApp

/// Exercises the real Keychain, following the established pattern in
/// `KeychainCredentialStoreTests`: unique account names, cleanup in `tearDown`,
/// and a skip rather than a failure when the Keychain is locked or the signed-in
/// environment forbids item creation.
final class KeychainSessionSecretStoreTests: XCTestCase {
    private let store = KeychainSessionSecretStore()
    private var domains: [String] = []

    override func tearDown() {
        for domain in domains {
            store.removeValue(forDomain: domain)
        }
        domains.removeAll()
        super.tearDown()
    }

    private func uniqueDomain() -> String {
        let domain = "macidm-test-\(UUID().uuidString.prefix(8)).example"
        domains.append(domain)
        return domain
    }

    func testSaveReadBackAndDeleteRoundTrip() throws {
        let domain = uniqueDomain()
        do {
            try store.save("sid=keychain", forDomain: domain)
        } catch {
            throw XCTSkip("Keychain 不可用（可能被锁定）：\(error.localizedDescription)")
        }
        XCTAssertEqual(store.value(forDomain: domain), "sid=keychain")

        // Saving again replaces the value instead of stacking a second item.
        try store.save("sid=rotated", forDomain: domain)
        XCTAssertEqual(store.value(forDomain: domain), "sid=rotated")

        store.removeValue(forDomain: domain)
        XCTAssertNil(store.value(forDomain: domain))
    }

    func testMissingItemLoadsNil() {
        XCTAssertNil(store.value(forDomain: "macidm-test-absent.example"))
    }

    func testEmptyDomainIsRejected() {
        XCTAssertThrowsError(try store.save("sid=x", forDomain: ""))
        XCTAssertNil(store.value(forDomain: ""))
    }
}
