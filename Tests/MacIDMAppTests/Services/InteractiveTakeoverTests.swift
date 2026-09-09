import Foundation
import MacIDMBridge
import XCTest

@testable import MacIDMApp

@MainActor
final class InteractiveTakeoverTests: XCTestCase {
    private let secret = Data(repeating: 9, count: 32)
    private let client = "chrome:interactive-fixture"

    private func fixture() throws -> (AppModel, MessageRequest, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults())
        )
        model.newDownloadPresenter = { _ in }
        addTeardownBlock { @MainActor in
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        let request = MessageRequest(
            requestId: UUID().uuidString, idempotencyKey: "profile:download-42", type: "download.enqueue",
            payload: [
                "url": .string("https://example.test/file.zip"), "browserDownloadId": .number(42),
                "interactive": .bool(true),
            ]
        )
        try MessageValidator.validate(request)
        return (model, request, directory)
    }

    func testConfirmationCreatesOnlyPendingTaskAndACKHonorsManualStart() async throws {
        let (model, request, directory) = try fixture()
        var presentationCount = 0
        model.newDownloadPresenter = { _ in presentationCount += 1 }
        let first = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
        XCTAssertEqual(first.type, "download.confirmationPending")
        XCTAssertTrue(model.tasks.isEmpty)
        let replay = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
        XCTAssertEqual(replay.type, "download.confirmationPending")
        XCTAssertEqual(presentationCount, 1)
        let draft = try XCTUnwrap(model.pendingDownloadDrafts.values.first)
        try model.addDownload(
            urlString: "https://example.test/user-selected.zip",
            destination: directory.appendingPathComponent("selected.zip"),
            maximumParallelRequests: 2, expectedSHA256: nil, startImmediately: false,
            takeoverDraftID: draft.takeoverDraftID
        )
        XCTAssertEqual(model.tasks.first?.status, .takeoverPending)
        XCTAssertTrue(model.executions.tasks.isEmpty)
        model.clearPendingDownloadDraft(draft)
        let ready = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
        XCTAssertEqual(ready.type, "download.readyForTakeover")
        let id = try XCTUnwrap(model.tasks.first?.id)
        XCTAssertEqual(model.transientSourceURLs[id]?.absoluteString, "https://example.test/user-selected.zip")
        let ack = MessageRequest(
            requestId: UUID().uuidString, idempotencyKey: "profile:download-42:cancel",
            type: "download.browserCancelled",
            payload: [
                "taskId": .string(id.uuidString), "browserDownloadId": .number(42),
                "takeoverToken": try XCTUnwrap(ready.payload?["takeoverToken"]),
            ]
        )
        let accepted = await model.handleBrowserBridgeRequest(ack, clientID: client, secret: secret)
        XCTAssertEqual(accepted.type, "download.accepted")
        XCTAssertEqual(model.task(with: id)?.status, .paused)
        XCTAssertTrue(model.executions.tasks.isEmpty)
        let duplicate = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
        XCTAssertEqual(duplicate.type, "download.readyForTakeover")
        XCTAssertEqual(model.tasks.count, 1)
    }

    func testClosedDraftAndAbandonedDraftCannotSubmitLate() async throws {
        for closeWindow in [true, false] {
            let (model, request, directory) = try fixture()
            _ = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
            let draft = try XCTUnwrap(model.pendingDownloadDrafts.values.first)
            if closeWindow {
                model.clearPendingDownloadDraft(draft)
            } else {
                let abandon = MessageRequest(
                    requestId: UUID().uuidString, idempotencyKey: "abandon", type: "download.abandon",
                    payload: [
                        "browserDownloadId": .number(42), "originalIdempotencyKey": .string(request.idempotencyKey),
                    ]
                )
                _ = await model.handleBrowserBridgeRequest(abandon, clientID: client, secret: secret)
            }
            XCTAssertThrowsError(
                try model.addDownload(
                    urlString: draft.url.absoluteString, destination: directory.appendingPathComponent("late.zip"),
                    maximumParallelRequests: 1, expectedSHA256: nil, startImmediately: true,
                    takeoverDraftID: draft.takeoverDraftID
                ))
            XCTAssertTrue(model.tasks.isEmpty)
            let response = await model.handleBrowserBridgeRequest(request, clientID: client, secret: secret)
            XCTAssertEqual(response.error?.code, "TAKEOVER_ABANDONED")
        }
    }
}
