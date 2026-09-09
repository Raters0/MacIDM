import Foundation
import XCTest

@testable import MacIDMApp

final class SourceURLVaultTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMVaultTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testStoreAndLoadRoundTrip() throws {
        let vault = SourceURLVault(directory: directory)
        let id = UUID()
        let url = URL(string: "https://cdn.example.com/video.mp4?sig=secret-token")!

        vault.store(id: id, url: url)
        let entries = vault.load()

        XCTAssertEqual(entries[id]?.url, url.absoluteString)
        XCTAssertGreaterThan(entries[id]?.expiresAt ?? .distantPast, Date())
    }

    func testExpiredEntriesAreDropped() {
        let vault = SourceURLVault(directory: directory)
        let id = UUID()
        vault.store(
            id: id,
            url: URL(string: "https://cdn.example.com/file.bin?sig=x")!,
            ttl: -1
        )

        XCTAssertTrue(vault.load().isEmpty)
    }

    func testRemoveDropsOnlyRequestedEntries() {
        let vault = SourceURLVault(directory: directory)
        let kept = UUID()
        let dropped = UUID()
        vault.store(id: kept, url: URL(string: "https://a.example.com/1?sig=x")!)
        vault.store(id: dropped, url: URL(string: "https://a.example.com/2?sig=x")!)

        vault.remove(ids: [dropped])
        let entries = vault.load()

        XCTAssertNotNil(entries[kept])
        XCTAssertNil(entries[dropped])
    }

    func testVaultFileIsWrittenWithTightenedPermissions() throws {
        let vault = SourceURLVault(directory: directory)
        vault.store(id: UUID(), url: URL(string: "https://a.example.com/f?sig=x")!)

        let attributes = try FileManager.default.attributesOfItem(atPath: vault.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }
}
