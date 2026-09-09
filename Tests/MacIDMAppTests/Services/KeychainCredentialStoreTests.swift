import XCTest

@testable import MacIDMApp

final class KeychainCredentialStoreTests: XCTestCase {
    private let store = KeychainCredentialStore()
    private var usernames: [String] = []

    override func tearDown() {
        for username in usernames {
            store.delete(username: username)
        }
        usernames.removeAll()
        super.tearDown()
    }

    private func uniqueUsername() -> String {
        let username = "macidm-test-\(UUID().uuidString.prefix(8))"
        usernames.append(username)
        return username
    }

    func testSaveLoadDeleteRoundTrip() throws {
        let username = uniqueUsername()
        do {
            try store.save(username: username, password: "hunter2")
        } catch {
            throw XCTSkip("Keychain 不可用（可能被锁定）：\(error.localizedDescription)")
        }

        XCTAssertEqual(store.loadPassword(username: username), "hunter2")

        // Saving again must update in place, not duplicate.
        try store.save(username: username, password: "rotated")
        XCTAssertEqual(store.loadPassword(username: username), "rotated")

        store.delete(username: username)
        XCTAssertNil(store.loadPassword(username: username))
    }

    func testMissingItemLoadsNil() {
        XCTAssertNil(store.loadPassword(username: "macidm-test-nonexistent"))
    }

    func testEmptyUsernameIsRejected() {
        XCTAssertThrowsError(try store.save(username: "", password: "x"))
        XCTAssertNil(store.loadPassword(username: ""))
    }
}
