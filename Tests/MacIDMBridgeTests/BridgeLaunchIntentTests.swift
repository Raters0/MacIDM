import Foundation
import XCTest

@testable import MacIDMBridge

/// Covers the quit-intent marker that stops the Native Messaging Host from
/// resurrecting an App the user deliberately closed, plus the pure launch /
/// user-intent decisions the Host relies on.
final class BridgeLaunchIntentTests: XCTestCase {
    func testRecordThenReadQuitIntentRoundTrips() throws {
        let directory = temporaryDirectory(prefix: "midm-quit-intent")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(BridgeLaunchIntent.hasQuitIntent(in: directory))

        let quitDate = Date(timeIntervalSince1970: 1_700_000_000)
        BridgeLaunchIntent.recordQuitIntent(pid: 4242, now: quitDate, in: directory)

        XCTAssertTrue(BridgeLaunchIntent.hasQuitIntent(in: directory))
        let marker = try XCTUnwrap(BridgeLaunchIntent.quitIntent(in: directory))
        XCTAssertEqual(marker.pid, 4242)
        XCTAssertEqual(marker.quitAt, quitDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testClearQuitIntentRemovesMarker() throws {
        let directory = temporaryDirectory(prefix: "midm-quit-clear")
        defer { try? FileManager.default.removeItem(at: directory) }

        BridgeLaunchIntent.recordQuitIntent(in: directory)
        XCTAssertTrue(BridgeLaunchIntent.hasQuitIntent(in: directory))

        BridgeLaunchIntent.clearQuitIntent(in: directory)
        XCTAssertFalse(BridgeLaunchIntent.hasQuitIntent(in: directory))
        // Clearing an absent marker is a no-op, never a crash.
        BridgeLaunchIntent.clearQuitIntent(in: directory)
        XCTAssertFalse(BridgeLaunchIntent.hasQuitIntent(in: directory))
    }

    func testCorruptMarkerIsTreatedAsAbsent() throws {
        let directory = temporaryDirectory(prefix: "midm-quit-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let url = BridgeLaunchIntent.markerURL(in: directory)
        try Data("not-json".utf8).write(to: url)

        // A garbled marker must never wedge the Host into refusing launches.
        XCTAssertFalse(BridgeLaunchIntent.hasQuitIntent(in: directory))
        XCTAssertNil(BridgeLaunchIntent.quitIntent(in: directory))
    }

    func testMarkerFileIsOwnerOnly() throws {
        let directory = temporaryDirectory(prefix: "midm-quit-perm")
        defer { try? FileManager.default.removeItem(at: directory) }

        BridgeLaunchIntent.recordQuitIntent(in: directory)
        let url = BridgeLaunchIntent.markerURL(in: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testShouldRelaunchDecisionTable() {
        // No marker: cold start / crash keeps the original relaunch behavior.
        XCTAssertTrue(
            BridgeLaunchIntent.shouldRelaunchApp(quitIntentPresent: false, requestUserInitiated: false))
        XCTAssertTrue(
            BridgeLaunchIntent.shouldRelaunchApp(quitIntentPresent: false, requestUserInitiated: true))
        // Marker + background traffic: the user quit on purpose — stay closed.
        XCTAssertFalse(
            BridgeLaunchIntent.shouldRelaunchApp(quitIntentPresent: true, requestUserInitiated: false))
        // Marker + explicit user action: wake the App again.
        XCTAssertTrue(
            BridgeLaunchIntent.shouldRelaunchApp(quitIntentPresent: true, requestUserInitiated: true))
    }

    func testUserInitiatedClassificationByType() {
        XCTAssertTrue(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "app.activate")))
        XCTAssertTrue(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "download.create")))
        XCTAssertTrue(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "download.enqueue")))
        // Confirmation-poll retries are background traffic and must not wake
        // a deliberately quit App; only the first enqueue is user-driven.
        XCTAssertFalse(
            BridgeLaunchIntent.isUserInitiatedRequest(
                request(type: "download.enqueue", payload: ["poll": .bool(true)])))
        XCTAssertTrue(
            BridgeLaunchIntent.isUserInitiatedRequest(
                request(type: "download.enqueue", payload: ["poll": .bool(false)])))

        // Inspection defers to the explicit flag: manual parse wakes, an
        // automatic page parse does not.
        XCTAssertTrue(
            BridgeLaunchIntent.isUserInitiatedRequest(
                request(type: "media.inspect", payload: ["userInitiated": .bool(true)])))
        XCTAssertFalse(
            BridgeLaunchIntent.isUserInitiatedRequest(
                request(type: "media.inspect", payload: ["userInitiated": .bool(false)])))
        XCTAssertFalse(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "media.inspect")))

        // Background status probing and takeover bookkeeping never wake a
        // deliberately quit App.
        XCTAssertFalse(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "ping")))
        XCTAssertFalse(BridgeLaunchIntent.isUserInitiatedRequest(request(type: "download.abandon")))
        XCTAssertFalse(
            BridgeLaunchIntent.isUserInitiatedRequest(request(type: "download.browserCancelled")))
    }

    private func request(
        type: String,
        payload: [String: JSONValue] = [:]
    ) -> MessageRequest {
        MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "test:\(type)",
            type: type,
            payload: payload
        )
    }

    private func temporaryDirectory(prefix: String) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}
