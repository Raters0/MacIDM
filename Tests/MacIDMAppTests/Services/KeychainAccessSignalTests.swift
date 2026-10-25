import Foundation
import XCTest

@testable import MacIDMApp

@MainActor
final class KeychainAccessSignalTests: XCTestCase {

    /// The confirmation-window fix depends on this window being open exactly
    /// while the credential access runs: the login-Keychain approval dialog
    /// appears inside the access, and the frontmost application still reports
    /// the browser at that moment.
    func testSignalIsRaisedDuringTheCredentialAccessAndClearedAfter() async throws {
        let signal = KeychainAccessSignal.shared
        XCTAssertFalse(signal.isInFlight)
        let release = DispatchSemaphore(value: 0)
        let readThread = ThreadIsMainRecorder()
        let access = Task {
            await signal.access { () -> String in
                readThread.record()
                release.wait()
                return "cookie"
            }
        }

        try await waitForInFlight(signal)
        XCTAssertTrue(signal.isInFlight, "signal was down while the credential access ran")

        release.signal()
        let value = await access.value
        XCTAssertEqual(value, "cookie")
        XCTAssertFalse(signal.isInFlight, "signal stayed raised after the access returned")
        XCTAssertEqual(readThread.wasOnMainThread, false, "credential read ran on the main thread")
    }

    func testNestedAccessesKeepTheSignalRaisedUntilTheLastOneReturns() async {
        let signal = KeychainAccessSignal.shared
        let release = DispatchSemaphore(value: 0)
        let outer = Task {
            await signal.access {
                release.wait()
                return "outer"
            }
        }
        let inner = await signal.access { "inner" }
        XCTAssertEqual(inner, "inner")
        XCTAssertTrue(signal.isInFlight, "inner access cleared the outer one's signal")

        release.signal()
        _ = await outer.value
        XCTAssertFalse(signal.isInFlight)
    }

    func testFinishingTheLastAccessPostsTheRestoreNotification() async {
        let received = expectation(forNotification: .macIDMCredentialAccessFinished, object: nil)
        _ = await KeychainAccessSignal.shared.access { "cookie" }
        await fulfillment(of: [received], timeout: 5)
    }

    /// The approval dialog this mechanism exists for came from the semantic-title
    /// KEY, which lives in the other Keychain store. Every store has to mark the
    /// window, or the confirmation panel classifies that dialog as a user app
    /// switch and sinks under the browser.
    func testCredentialStoreMarksTheWindowAroundItsRead() {
        let store = KeychainCredentialStore(
            serviceName: "MacIDM Signal Test \(UUID().uuidString)",
            itemLabel: "MacIDM 测试凭据"
        )
        let finished = expectation(forNotification: .macIDMCredentialAccessFinished, object: nil)

        XCTAssertNil(store.loadPassword(username: "absent-account-\(UUID().uuidString)"))

        XCTAssertFalse(KeychainAccessSignal.shared.isInFlight, "read left the window marked")
        wait(for: [finished], timeout: 2)
    }

    private func waitForInFlight(_ signal: KeychainAccessSignal) async throws {
        for _ in 0..<200 {
            if signal.isInFlight { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("credential access never reported as in flight")
    }
}

/// Records the thread the credential closure ran on, from a nonisolated context.
final class ThreadIsMainRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?

    var wasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record() {
        lock.lock()
        recorded = Thread.isMainThread
        lock.unlock()
    }
}
