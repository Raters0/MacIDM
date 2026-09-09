import Foundation
import XCTest

@testable import MacIDMApp

@MainActor
final class SessionStoreTests: XCTestCase {

    private func makeStore() throws -> (SessionStore, URL, FakeSessionSecretStore) {
        let directory = try makeDirectory()
        let secrets = FakeSessionSecretStore()
        return (SessionStore(directory: directory, secrets: secrets), directory, secrets)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-session-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The production reuse path is scheme-aware; tests resolve through the same
    /// door with a canonical https URL for the host they mean.
    private func httpsSession(_ store: SessionStore, host: String) -> StoredSession? {
        store.lookup(url: URL(string: "https://\(host)")!)
    }

    private func writtenJSON(at directory: URL) throws -> String {
        try String(
            contentsOf: directory.appendingPathComponent("sessions.json"), encoding: .utf8)
    }

    private func writeLegacyRecord(
        domain: String,
        cookie: String?,
        updatedAt: Date,
        at directory: URL
    ) throws {
        try writeLegacyRecords([(domain: domain, cookie: cookie)], updatedAt: updatedAt, at: directory)
    }

    /// Writes records in the current on-disk shape (scheme bound to https), for
    /// tests that model what this build persists rather than a legacy upgrade.
    private func writeSessionRecords(
        _ records: [(domain: String, cookie: String?)],
        updatedAt: Date,
        at directory: URL
    ) throws {
        let stamp = ISO8601DateFormatter().string(from: updatedAt)
        let body = records.map { record in
            let cookieField = record.cookie.map { "\"cookieHeader\": \"\($0)\", " } ?? ""
            return
                "{\"domain\": \"\(record.domain)\", \"scheme\": \"https\", \(cookieField)\"updatedAt\": \"\(stamp)\"}"
        }.joined(separator: ", ")
        try "[\(body)]".write(
            to: directory.appendingPathComponent("sessions.json"), atomically: true,
            encoding: .utf8)
    }

    /// Writes a whole legacy `sessions.json` in one go; `writeLegacyRecord`
    /// replaces the file, so a multi-record scenario needs this.
    private func writeLegacyRecords(
        _ records: [(domain: String, cookie: String?)],
        updatedAt: Date,
        at directory: URL
    ) throws {
        let stamp = ISO8601DateFormatter().string(from: updatedAt)
        let body = records.map { record in
            let cookieField = record.cookie.map { "\"cookieHeader\": \"\($0)\", " } ?? ""
            return "{\(cookieField)\"domain\": \"\(record.domain)\", \"updatedAt\": \"\(stamp)\"}"
        }.joined(separator: ", ")
        try "[\(body)]".write(
            to: directory.appendingPathComponent("sessions.json"), atomically: true,
            encoding: .utf8)
    }

    // MARK: - Round trip

    func testStoreKeepsTheCredentialOutOfTheMetadataFile() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            store.store(domain: "example.com", cookie: "sid=abc123; theme=dark", userAgent: nil),
            .stored)

        XCTAssertNotNil(httpsSession(store, host: "example.com"))
        XCTAssertEqual(secrets.values["example.com"], "sid=abc123; theme=dark")
        let fileText = try writtenJSON(at: directory)
        XCTAssertFalse(fileText.contains("sid=abc123"), "cookie value reached sessions.json")
        XCTAssertFalse(fileText.contains("cookieHeader"), "legacy cookie field was re-written")
    }

    func testCookieHeaderResolvesThroughTheSecretStore() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "sid=xyz", userAgent: "UA/1.0")
        XCTAssertEqual(httpsSession(store, host: "example.com").flatMap(store.cookieHeader(for:)), "sid=xyz")
        XCTAssertNil(httpsSession(store, host: "other.org").flatMap(store.cookieHeader(for:)))
    }

    func testLookupStaysOnTheStoredHost() throws {
        // A raw Cookie header has no Domain/Path/Secure attributes, so replaying
        // it to a sibling subdomain could disclose a host-only credential.
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "sid=abc", userAgent: nil)
        XCTAssertNotNil(httpsSession(store, host: "example.com"))
        XCTAssertNil(
            httpsSession(store, host: "www.example.com"),
            "www.example.com is a different session key, not an alias")
        XCTAssertNil(httpsSession(store, host: "cdn.example.com"))
        XCTAssertNil(httpsSession(store, host: "notexample.com"))
    }

    func testSubdomainSessionsAreIndependent() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "site=parent", userAgent: nil)
        store.store(domain: "cdn.example.com", cookie: "site=child", userAgent: nil)
        XCTAssertEqual(httpsSession(store, host: "cdn.example.com").flatMap(store.cookieHeader(for:)), "site=child")
        XCTAssertNil(
            httpsSession(store, host: "api.example.com").flatMap(store.cookieHeader(for:)),
            "a parent session must not supply credentials to a sibling")
        XCTAssertEqual(httpsSession(store, host: "example.com").flatMap(store.cookieHeader(for:)), "site=parent")
    }

    func testNormalizationKeepsWWWButDropsCaseAndLegalPort() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "www.Example.COM:8443", cookie: "sid=abc", userAgent: nil)
        XCTAssertEqual(store.sessions.map(\.domain), ["www.example.com"])
        XCTAssertNotNil(httpsSession(store, host: "www.example.com"))
        XCTAssertNil(
            httpsSession(store, host: "example.com"),
            "www.example.com and example.com are two different session keys")
    }

    func testHTTPSourceIsRefusedAndNeverArchived() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(
            store.store(
                url: URL(string: "http://example.com/video.mp4")!, cookie: "sid=abc",
                userAgent: nil),
            .rejectedScheme
        )
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(secrets.values.isEmpty, "an http capture must not leave a credential behind")
        XCTAssertNil(store.lookup(url: URL(string: "http://example.com/video.mp4")!))
    }

    func testHTTPURLNeverReceivesAnHTTPSCapturedSession() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(url: URL(string: "https://example.com/video.mp4")!, cookie: "sid=tls", userAgent: nil)
        XCTAssertNil(store.lookup(url: URL(string: "http://example.com/video.mp4")!))
        XCTAssertNotNil(store.lookup(url: URL(string: "https://example.com/video.mp4")!))
    }

    func testLegacyRecordWithoutSchemeIsListedButNeverReused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        try writeLegacyRecords(
            [(domain: "example.com", cookie: "sid=migrated")], updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        // The credential survives in the Keychain and the row stays listed...
        XCTAssertEqual(secrets.values["example.com"], "sid=migrated")
        XCTAssertEqual(store.sessions.map(\.domain), ["example.com"])
        // ...but without a proven scheme it is never handed out automatically.
        XCTAssertNil(store.lookup(url: URL(string: "https://example.com/video.mp4")!))

        // Re-pasting is the user's https confirmation; afterwards the session
        // works again and the legacy plaintext state is gone.
        XCTAssertEqual(
            store.store(domain: "example.com", cookie: "sid=fresh", userAgent: nil),
            .stored
        )
        XCTAssertEqual(
            httpsSession(store, host: "example.com").flatMap(store.cookieHeader(for:)),
            "sid=fresh"
        )
    }

    func testMarkAuthFailedSetsExpiryFlag() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "sid=abc", userAgent: nil)
        store.markAuthFailed(domain: "example.com")
        XCTAssertNotNil(httpsSession(store, host: "example.com")?.lastAuthFailureAt)
    }

    func testSessionsPersistAcrossInstances() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "sid=abc", userAgent: "UA")

        let reloaded = SessionStore(directory: directory, secrets: secrets)
        let session = try XCTUnwrap(httpsSession(reloaded, host: "example.com"))
        XCTAssertEqual(session.userAgent, "UA")
        XCTAssertEqual(reloaded.cookieHeader(for: session), "sid=abc")
    }

    func testRemoveAndRemoveAllDeleteTheCredential() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "a.com", cookie: "x=1", userAgent: nil)
        store.store(domain: "b.com", cookie: "y=2", userAgent: nil)

        store.remove(domain: "a.com")
        XCTAssertNil(httpsSession(store, host: "a.com"))
        XCTAssertNil(secrets.values["a.com"], "cookie outlived its session entry")
        XCTAssertNotNil(httpsSession(store, host: "b.com"))

        store.removeAll()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(secrets.values.isEmpty, "removeAll left credentials behind")
    }

    func testEmptyCookieIsIgnored() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(
            store.store(domain: "example.com", cookie: "   ", userAgent: nil), .emptyCookie)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(secrets.values.isEmpty)
    }

    // MARK: - Domain safety

    func testPublicSuffixAndIPLikeKeysAreRefused() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A session keyed on `co.uk` would attach its cookie to every .co.uk
        // site, and an IP key shares no subdomain relationship.
        for host in ["com", "co.uk", "127.0.0.1", "0x7f.0.0.1", "10.0.0.5", "localhost", "nas"] {
            XCTAssertEqual(
                store.store(domain: host, cookie: "sid=abc", userAgent: nil), .rejectedDomain,
                "\(host) must not hold a session")
        }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(secrets.values.isEmpty)
    }

    // MARK: - Lifetime

    func testSessionOlderThanTheHardCapIsDropped() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        let stale = Date().addingTimeInterval(-(SessionStore.maximumSessionLifetime + 60))
        try writeLegacyRecord(
            domain: "example.com", cookie: "sid=old", updatedAt: stale, at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        XCTAssertNil(httpsSession(store, host: "example.com"))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(secrets.values["example.com"], "expired session kept its credential")
        XCTAssertFalse(try writtenJSON(at: directory).contains("sid=old"))
    }

    func testSessionWithinTheHardCapSurvives() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        let recent = Date().addingTimeInterval(-(SessionStore.maximumSessionLifetime - 3600))
        try writeSessionRecords(
            [(domain: "example.com", cookie: "sid=ok")], updatedAt: recent, at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        XCTAssertNotNil(httpsSession(store, host: "example.com"))
        XCTAssertEqual(
            httpsSession(store, host: "example.com").flatMap(store.cookieHeader(for:)), "sid=ok")
    }

    // MARK: - Migration off plaintext

    func testLegacyPlaintextCookieMigratesToTheSecretStore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        try writeLegacyRecord(
            domain: "example.com", cookie: "sid=legacy", updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        XCTAssertEqual(secrets.values["example.com"], "sid=legacy")
        // The scheme of a legacy row cannot be proven, so the migrated value is
        // kept but never handed out until the user re-captures it.
        XCTAssertNil(store.lookup(url: URL(string: "https://example.com/video.mp4")!))
        XCTAssertFalse(
            try writtenJSON(at: directory).contains("sid=legacy"),
            "migration left the plaintext on disk")
        XCTAssertTrue(store.domainsNeedingReauthorization.isEmpty)
    }

    func testFailedMigrationKeepsPlaintextAndSurvivesRestart() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        secrets.saveError = FakeSessionSecretStore.Failure()
        try writeLegacyRecord(
            domain: "example.com", cookie: "sid=stuck", updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        // Not silently lost: the credential is still in memory this run (the
        // store keeps it pending) and on disk...
        XCTAssertEqual(store.cookieHeader(for: store.sessions[0]), "sid=stuck")
        // ...it is reported, and the plaintext stays on disk until the Keychain
        // is proven to hold the value.
        XCTAssertEqual(store.domainsNeedingReauthorization, ["example.com"])
        XCTAssertTrue(
            try writtenJSON(at: directory).contains("sid=stuck"),
            "a failed migration deleted the plaintext the user has no way to recover")

        // The next launch, with a working Keychain, recovers it and only then
        // clears the file.
        let healthy = FakeSessionSecretStore()
        let relaunched = SessionStore(directory: directory, secrets: healthy)
        XCTAssertEqual(healthy.values["example.com"], "sid=stuck")
        // The relaunched store keeps the row for re-capture; reuse needs the
        // user's https confirmation, which the re-paste path provides.
        XCTAssertNil(relaunched.lookup(url: URL(string: "https://example.com/video.mp4")!))
        XCTAssertTrue(relaunched.domainsNeedingReauthorization.isEmpty)
        XCTAssertFalse(
            try writtenJSON(at: directory).contains("sid=stuck"),
            "the plaintext outlived a successful migration")
    }

    func testPartialMigrationKeepsOnlyTheUnmigratedPlaintext() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        secrets.failingDomains = ["b.example.com"]
        try writeLegacyRecords(
            [(domain: "a.example.com", cookie: "sid=ok"), (domain: "b.example.com", cookie: "sid=stuck")],
            updatedAt: Date(),
            at: directory
        )

        let store = SessionStore(directory: directory, secrets: secrets)
        let fileText = try writtenJSON(at: directory)
        XCTAssertFalse(fileText.contains("sid=ok"), "a migrated session kept its plaintext")
        XCTAssertTrue(fileText.contains("sid=stuck"), "the un-migrated session lost its cookie")
        XCTAssertEqual(store.domainsNeedingReauthorization, ["b.example.com"])
        // Both rows are scheme-less after a legacy load, so neither is reused
        // until the user re-captures; the disk assertions above are the point.
        XCTAssertNil(store.lookup(url: URL(string: "https://a.example.com/video.mp4")!))
        XCTAssertNil(store.lookup(url: URL(string: "https://b.example.com/video.mp4")!))
    }

    func testPendingPlaintextSurvivesLaterWrites() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        secrets.saveError = FakeSessionSecretStore.Failure()
        try writeLegacyRecord(
            domain: "example.com", cookie: "sid=stuck", updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        // Any later persistence of unrelated state must not drop the pending
        // credential on its way past the file.
        secrets.saveError = nil
        store.store(domain: "other.org", cookie: "sid=fresh", userAgent: nil)
        XCTAssertTrue(try writtenJSON(at: directory).contains("sid=stuck"))
        XCTAssertEqual(store.cookieHeader(for: store.sessions[0]), "sid=stuck")
    }

    func testMigrationRequiresReadbackBeforeDroppingPlaintext() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        secrets.corruptedReadback = true
        try writeLegacyRecord(
            domain: "example.com", cookie: "sid=verify", updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        XCTAssertEqual(store.domainsNeedingReauthorization, ["example.com"])
        // An unverified item may not be trusted as the migrated credential, so
        // the in-memory value is what this run resolves (via the session row)...
        XCTAssertEqual(store.cookieHeader(for: store.sessions[0]), "sid=verify")
        // ...but it is never handed out automatically while the scheme is
        // unproven.
        XCTAssertNil(store.lookup(url: URL(string: "https://example.com/video.mp4")!))
        // ...and the plaintext must stay on disk, because that is the only copy
        // the next launch can migrate.
        XCTAssertTrue(
            try writtenJSON(at: directory).contains("sid=verify"),
            "an unverified migration dropped the only durable copy")
    }

    func testFreshStoreFailureDoesNotRecordASession() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        secrets.saveError = FakeSessionSecretStore.Failure()
        let store = SessionStore(directory: directory, secrets: secrets)

        let outcome = store.store(domain: "example.com", cookie: "sid=nope", userAgent: nil)
        guard case .secretStorageFailed = outcome else {
            XCTFail("expected secretStorageFailed, got \(outcome)")
            return
        }
        XCTAssertTrue(store.sessions.isEmpty, "session recorded without its credential")
        XCTAssertNil(httpsSession(store, host: "example.com").flatMap(store.cookieHeader(for:)))
    }

    func testUnsafeLegacyKeyIsDroppedWithItsCredential() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = FakeSessionSecretStore()
        // Simulates an older build that accepted a bare public suffix.
        try secrets.save("sid=broad", forDomain: "co.uk")
        try writeLegacyRecord(
            domain: "co.uk", cookie: "sid=broad", updatedAt: Date(), at: directory)

        let store = SessionStore(directory: directory, secrets: secrets)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(secrets.values["co.uk"], "an over-broad session outlived its key")
        XCTAssertNil(httpsSession(store, host: "anything.co.uk").flatMap(store.cookieHeader(for:)))
    }

    func testLookupAfterCredentialLossBehavesLikeNoCookie() throws {
        let (store, directory, secrets) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.store(domain: "example.com", cookie: "sid=gone", userAgent: nil)
        // The Keychain item disappears (user deleted it in Keychain Access).
        secrets.removeValue(forDomain: "example.com")
        let session = httpsSession(store, host: "example.com")
        XCTAssertNotNil(session, "the metadata entry is still listed")
        XCTAssertNil(store.cookieHeader(for: session!))
    }
}
