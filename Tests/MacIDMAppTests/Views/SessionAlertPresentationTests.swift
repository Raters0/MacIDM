import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

/// Fully local, non-networked download runner for presentation tests.
/// Eliminates all socket I/O, leaks, and hanging background tasks.
/// Conforms to production invariants by creating the real local destination file.
private final class ControlledTestDownloadRunner: AppDownloadRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var startedRequests: [DownloadRequest] = []

    private func record(_ request: DownloadRequest) {
        lock.lock()
        defer { lock.unlock() }
        startedRequests.append(request)
    }

    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        record(request)

        // Ensure parent directory exists and write payload with propagating try
        let destinationDir = request.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let dummyData = Data(repeating: 0x41, count: 1024)
        try dummyData.write(to: request.destination, options: .atomic)

        return DownloadResult(
            destination: request.destination,
            byteCount: 1024,
            sha256: "fake-sha256",
            usedParallelRequests: 1,
            resumed: false,
            verification: "test"
        )
    }

    var recordedRequests: [DownloadRequest] {
        lock.lock()
        defer { lock.unlock() }
        return startedRequests
    }
}

@MainActor
final class SessionAlertPresentationTests: XCTestCase {

    private func makeIsolatedEnvironment() throws -> (
        AppModel,
        URL,
        FakeSessionSecretStore,
        SessionStore,
        ControlledTestDownloadRunner
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSessionAlertTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = makeIsolatedDefaults()
        let fakeSecrets = FakeSessionSecretStore()
        let fakeRunner = ControlledTestDownloadRunner()
        let sessionStoreDirectory = directory.appendingPathComponent("sessions", isDirectory: true)
        let sessionStore = SessionStore(directory: sessionStoreDirectory, secrets: fakeSecrets)
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: fakeRunner,
            sessionStore: sessionStore
        )
        return (model, directory, fakeSecrets, sessionStore, fakeRunner)
    }

    private func createTestTask(model: AppModel, urlString: String, destinationDirectory: URL) throws -> UUID {
        let filename = URL(string: urlString)?.lastPathComponent ?? "file.bin"
        let destination = destinationDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try model.addDownload(
            urlString: urlString,
            destination: destination,
            maximumParallelRequests: 1,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first { $0.sourceURL == urlString })
        return task.id
    }

    func testAuthFailureTriggersSessionAlertWhenNoAlertIsActive() throws {
        let (model, directory, fakeSecrets, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskID = try createTestTask(
            model: model,
            urlString: "https://example.com/protected/video.mp4",
            destinationDirectory: directory
        )

        XCTAssertNil(model.sessionAlert)
        model.finish(taskID, error: IDMError.httpStatus(401))

        let alert = try XCTUnwrap(model.sessionAlert)
        XCTAssertEqual(alert.domain, "example.com")
        XCTAssertFalse(alert.expired, "no previous session existed, so expired should be false")
        XCTAssertEqual(alert.taskID, taskID)
        XCTAssertTrue(fakeSecrets.values.isEmpty, "test must not touch real keychain and fake secrets start empty")
    }

    func testExpiredFlagIsAccurateBasedOnPriorStoredSession() throws {
        let (model, directory, fakeSecrets, sessionStore, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            sessionStore.store(
                url: URL(string: "https://example.com/protected/video.mp4")!,
                cookie: "session=valid_token",
                userAgent: nil
            ),
            .stored
        )
        XCTAssertEqual(fakeSecrets.values["example.com"], "session=valid_token")

        let taskID = try createTestTask(
            model: model,
            urlString: "https://example.com/protected/video.mp4",
            destinationDirectory: directory
        )

        model.finish(taskID, error: IDMError.httpStatus(403))

        let alert = try XCTUnwrap(model.sessionAlert)
        XCTAssertEqual(alert.domain, "example.com")
        XCTAssertTrue(alert.expired, "a stored session existed prior to failure, so expired should be true")
        XCTAssertEqual(alert.taskID, taskID)
    }

    func testConvertingAlertToCookiePasteFlowTransitionsCleanlyAndResumesTask() async throws {
        let (model, directory, fakeSecrets, _, fakeRunner) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskID = try createTestTask(
            model: model,
            urlString: "https://example.com/protected/video.mp4",
            destinationDirectory: directory
        )
        model.finish(taskID, error: IDMError.httpStatus(401))

        let alert = try XCTUnwrap(model.sessionAlert)
        XCTAssertEqual(model.task(with: taskID)?.status, .failed)

        // User clicks "粘贴 Cookie"
        model.requestManualCookiePaste(domain: alert.domain, retryTaskID: alert.taskID)

        // Alert is cleared; Sheet binding is active
        XCTAssertNil(model.sessionAlert)
        XCTAssertEqual(model.cookiePasteDomain, "example.com")
        XCTAssertEqual(model.cookiePasteRetryTaskID, taskID)

        // Submit pasted cookie via production method
        let outcome = model.submitManualCookie(
            domain: "example.com",
            cookie: "session=fresh_token",
            userAgent: nil,
            retryTaskID: model.cookiePasteRetryTaskID
        )

        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(fakeSecrets.values["example.com"], "session=fresh_token")
        // Sheet initiated dismissal
        XCTAssertNil(model.cookiePasteDomain)
        XCTAssertNil(model.cookiePasteRetryTaskID)

        // Wait until task reaches stable completed state and downloadTasks dictionary is completely cleared
        for _ in 0..<50 {
            if model.task(with: taskID)?.status == .completed && model.executions[taskID].task == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            model.task(with: taskID)?.status, .completed, "resumed task must complete cleanly via local runner")
        XCTAssertNil(
            model.executions[taskID].task, "all background download tasks must be completely cleared before cleanup")
        XCTAssertTrue(fakeRunner.recordedRequests.contains(where: { $0.taskID == taskID }))

        let taskRecord = try XCTUnwrap(model.task(with: taskID))
        let destinationURL = URL(fileURLWithPath: taskRecord.destinationPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destinationURL.path),
            "destination file must physically exist on disk"
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(fileSize, 1024, "destination file size must strictly match 1024 bytes")
    }

    func testDuplicateDismissalCallbacksDoNotSkipQueuedAlerts() async throws {
        let (model, directory, _, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstTaskID = try createTestTask(
            model: model,
            urlString: "https://a.example.com/video1.mp4",
            destinationDirectory: directory
        )
        let secondTaskID = try createTestTask(
            model: model,
            urlString: "https://b.example.com/video2.mp4",
            destinationDirectory: directory
        )
        let thirdTaskID = try createTestTask(
            model: model,
            urlString: "https://c.example.com/video3.mp4",
            destinationDirectory: directory
        )

        model.finish(firstTaskID, error: IDMError.httpStatus(401))
        model.finish(secondTaskID, error: IDMError.httpStatus(401))
        model.finish(thirdTaskID, error: IDMError.httpStatus(401))

        XCTAssertEqual(model.sessionAlert?.domain, "a.example.com")
        XCTAssertEqual(model.pendingSessionAlerts.count, 2)

        // Simulate identical production Binding setter: MainWindowView calls handleSessionAlertBindingDismissal() with NO task ID
        model.handleSessionAlertBindingDismissal()
        // Duplicate callbacks in the same event loop turn must be strictly idempotent
        model.handleSessionAlertBindingDismissal()
        model.handleSessionAlertBindingDismissal()

        // Before the next main-actor turn, sessionAlert was cleared but no immediate dequeue happened
        XCTAssertNil(model.sessionAlert)

        // Advance to next main-actor turn
        try await Task.sleep(nanoseconds: 10_000_000)

        // Only the second alert is presented; third alert remains safely in queue (NO skipping)
        XCTAssertEqual(model.sessionAlert?.domain, "b.example.com")
        XCTAssertEqual(model.sessionAlert?.taskID, secondTaskID)
        XCTAssertEqual(model.pendingSessionAlerts.count, 1)

        // Dismiss second alert via production binding method
        model.handleSessionAlertBindingDismissal()
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(model.sessionAlert?.domain, "c.example.com")
        XCTAssertEqual(model.sessionAlert?.taskID, thirdTaskID)
        XCTAssertEqual(model.pendingSessionAlerts.count, 0)
    }

    func testSwitchingAlertToCookieSheetDoesNotAdvanceQueueOnBindingDismissal() async throws {
        let (model, directory, _, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstTaskID = try createTestTask(
            model: model,
            urlString: "https://a.example.com/video1.mp4",
            destinationDirectory: directory
        )
        let secondTaskID = try createTestTask(
            model: model,
            urlString: "https://b.example.com/video2.mp4",
            destinationDirectory: directory
        )

        model.finish(firstTaskID, error: IDMError.httpStatus(401))
        model.finish(secondTaskID, error: IDMError.httpStatus(401))

        XCTAssertEqual(model.sessionAlert?.domain, "a.example.com")
        XCTAssertEqual(model.pendingSessionAlerts.count, 1)

        // Primary button action transitions to CookiePasteSheet
        model.requestManualCookiePaste(domain: "a.example.com", retryTaskID: firstTaskID)

        // System closes Alert A, triggering the production Binding setter set(nil)
        model.handleSessionAlertBindingDismissal()

        // Advance main-actor turn
        try await Task.sleep(nanoseconds: 10_000_000)

        // Must NOT pop Alert B while CookiePasteSheet is active
        XCTAssertNil(model.sessionAlert)
        XCTAssertEqual(model.cookiePasteDomain, "a.example.com")
        XCTAssertEqual(model.pendingSessionAlerts.count, 1, "queued alert remains buffered")
    }

    func testTwoPhaseCookiePasteSheetDismissalDoesNotSurfaceAlertUntilDidDismiss() async throws {
        let (model, directory, _, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstTaskID = try createTestTask(
            model: model,
            urlString: "https://a.example.com/video1.mp4",
            destinationDirectory: directory
        )
        let secondTaskID = try createTestTask(
            model: model,
            urlString: "https://b.example.com/video2.mp4",
            destinationDirectory: directory
        )

        model.finish(firstTaskID, error: IDMError.httpStatus(401))
        XCTAssertEqual(model.sessionAlert?.domain, "a.example.com")

        // User enters CookiePasteSheet for first task
        model.requestManualCookiePaste(domain: "a.example.com", retryTaskID: firstTaskID)
        XCTAssertNil(model.sessionAlert)
        XCTAssertEqual(model.cookiePasteDomain, "a.example.com")

        // While CookiePasteSheet is open, a second auth failure occurs
        model.finish(secondTaskID, error: IDMError.httpStatus(401))
        XCTAssertNil(model.sessionAlert, "no alert may pop while sheet is active")
        XCTAssertEqual(model.pendingSessionAlerts.count, 1)

        // Phase 1: User saves or clicks Cancel -> requestDismissCookiePasteSheet is called
        let outcome = model.submitManualCookie(
            domain: "a.example.com",
            cookie: "sid=token",
            userAgent: nil,
            retryTaskID: firstTaskID
        )
        XCTAssertEqual(outcome, .stored)
        XCTAssertNil(model.cookiePasteDomain)
        // Crucial check: Next alert must NOT be presented yet while sheet is animating away
        XCTAssertNil(model.sessionAlert, "alert must remain nil until onDismiss lifecycle fires")
        XCTAssertEqual(model.pendingSessionAlerts.count, 1)

        // Phase 2: SwiftUI onDismiss callback fires -> cookiePasteSheetDidDismiss
        model.cookiePasteSheetDidDismiss()

        // Turn advance
        try await Task.sleep(nanoseconds: 10_000_000)

        // Now the second alert is presented cleanly
        XCTAssertEqual(model.sessionAlert?.domain, "b.example.com")
        XCTAssertEqual(model.sessionAlert?.taskID, secondTaskID)
        XCTAssertTrue(model.pendingSessionAlerts.isEmpty)

        // Duplicate onDismiss calls must be idempotent
        model.cookiePasteSheetDidDismiss()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(model.sessionAlert?.domain, "b.example.com")
    }

    func testDuplicateFailureForSameTaskIsDeduplicated() throws {
        let (model, directory, _, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let taskID = try createTestTask(
            model: model,
            urlString: "https://repeat.example.com/video.mp4",
            destinationDirectory: directory
        )

        model.finish(taskID, error: IDMError.httpStatus(401))
        XCTAssertEqual(model.sessionAlert?.domain, "repeat.example.com")

        model.finish(taskID, error: IDMError.httpStatus(401))
        XCTAssertEqual(model.pendingSessionAlerts.count, 0, "must not enqueue duplicate for same taskID")
    }

    func testPendingAlertsQueueIsBoundedAndTracksDroppedCount() throws {
        let (model, directory, _, _, _) = try makeIsolatedEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let activeTaskID = try createTestTask(
            model: model,
            urlString: "https://initial.example.com/video.mp4",
            destinationDirectory: directory
        )
        model.finish(activeTaskID, error: IDMError.httpStatus(401))
        XCTAssertEqual(model.sessionAlert?.domain, "initial.example.com")
        XCTAssertEqual(model.droppedSessionAlertsCount, 0)

        // Flood 30 distinct failures while 1 alert is already displayed
        for i in 1...30 {
            let taskID = try createTestTask(
                model: model,
                urlString: "https://host\(i).example.com/video.mp4",
                destinationDirectory: directory
            )
            model.finish(taskID, error: IDMError.httpStatus(401))
        }

        XCTAssertEqual(
            model.pendingSessionAlerts.count,
            AppModel.maximumPendingSessionAlerts,
            "queue must be capped at maximumPendingSessionAlerts (20)"
        )
        XCTAssertEqual(
            model.droppedSessionAlertsCount,
            10,
            "must accurately count dropped alerts that exceeded queue capacity"
        )
    }
}
