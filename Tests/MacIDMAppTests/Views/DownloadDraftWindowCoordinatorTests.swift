import AppKit
import XCTest

@testable import MacIDMApp

final class MockRunningApp: RunningApplicationHandle, @unchecked Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    var isTerminated: Bool
    private(set) var activateCallCount = 0
    private(set) var lastActivateOptions: NSApplication.ActivationOptions?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        isTerminated: Bool = false
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isTerminated = isTerminated
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activateCallCount += 1
        lastActivateOptions = options
        return true
    }
}

@MainActor
final class DownloadDraftWindowCoordinatorTests: XCTestCase {
    private let currentPID: pid_t = 500
    private let externalPID: pid_t = 100

    func testSingleWindowCancelRestoresPreviousApplication() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let dummyWindow = NSObject()
        let windowID = ObjectIdentifier(dummyWindow)

        coordinator.prepareForWindowOpen(windowID: windowID, frontmostApp: chrome)
        XCTAssertEqual(coordinator.activeCount, 1)

        let restored = coordinator.windowWillClose(windowID: windowID)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.processIdentifier, externalPID)
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testSingleWindowSubmitDoesNotRestorePreviousApplication() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let dummyWindow = NSObject()
        let windowID = ObjectIdentifier(dummyWindow)

        coordinator.prepareForWindowOpen(windowID: windowID, frontmostApp: chrome)
        coordinator.markSubmitted(windowID: windowID)

        let restored = coordinator.windowWillClose(windowID: windowID)
        XCTAssertNil(restored, "成功创建下载时不得归还前台应用")
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testMultipleWindowsAllCancelledRestoresOnLastWindowClose() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let window1 = NSObject()
        let id1 = ObjectIdentifier(window1)
        let window2 = NSObject()
        let id2 = ObjectIdentifier(window2)

        // Open the 1st confirmation window
        coordinator.prepareForWindowOpen(windowID: id1, frontmostApp: chrome)
        XCTAssertEqual(coordinator.activeCount, 1)

        // Open the 2nd confirmation window; frontmostApp may now be MacIDM itself,
        // but the 1st window already recorded Chrome
        let macIDMApp = MockRunningApp(processIdentifier: currentPID, bundleIdentifier: "com.macidm.app")
        coordinator.prepareForWindowOpen(windowID: id2, frontmostApp: macIDMApp)
        XCTAssertEqual(coordinator.activeCount, 2)
        XCTAssertEqual(coordinator.previousFrontmostApp?.processIdentifier, externalPID)

        // Cancel the 1st window: the 2nd window is still alive, so no immediate restore
        let restored1 = coordinator.windowWillClose(windowID: id1)
        XCTAssertNil(restored1, "并存多确认窗时关闭非最后一个窗不得归还")
        XCTAssertEqual(coordinator.activeCount, 1)

        // Cancel the 2nd window: the last window closes, restore Chrome
        let restored2 = coordinator.windowWillClose(windowID: id2)
        XCTAssertNotNil(restored2)
        XCTAssertEqual(restored2?.processIdentifier, externalPID)
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testMultipleWindowsOneSubmittedOneCancelledDoesNotRestore() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let window1 = NSObject()
        let id1 = ObjectIdentifier(window1)
        let window2 = NSObject()
        let id2 = ObjectIdentifier(window2)

        coordinator.prepareForWindowOpen(windowID: id1, frontmostApp: chrome)
        coordinator.prepareForWindowOpen(windowID: id2, frontmostApp: chrome)

        // Window 1 submits successfully
        coordinator.markSubmitted(windowID: id1)
        let restored1 = coordinator.windowWillClose(windowID: id1)
        XCTAssertNil(restored1)

        // Window 2 cancels and closes: a window already submitted, so no mistaken restore
        let restored2 = coordinator.windowWillClose(windowID: id2)
        XCTAssertNil(restored2, "已有提交成功的窗口时关闭剩余窗口不得误归还")
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testPreviousApplicationIsCurrentAppDoesNotRestore() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let macIDMApp = MockRunningApp(processIdentifier: currentPID, bundleIdentifier: "com.macidm.app")
        let window = NSObject()
        let id = ObjectIdentifier(window)

        coordinator.prepareForWindowOpen(windowID: id, frontmostApp: macIDMApp)
        XCTAssertNil(coordinator.previousFrontmostApp, "先前应用是自身时不记录")

        let restored = coordinator.windowWillClose(windowID: id)
        XCTAssertNil(restored, "先前应用是自身时不执行归还")
    }

    func testPreviousApplicationTerminatedDoesNotRestore() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let window = NSObject()
        let id = ObjectIdentifier(window)

        coordinator.prepareForWindowOpen(windowID: id, frontmostApp: chrome)

        // Simulate the external app terminating while the confirmation window is open
        chrome.isTerminated = true

        let restored = coordinator.windowWillClose(windowID: id)
        XCTAssertNil(restored, "先前应用已终止时安全放弃归还")
    }

    func testSequentialWindowsLifecycle() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let window1 = NSObject()
        let id1 = ObjectIdentifier(window1)

        // Round 1: open -> cancel
        coordinator.prepareForWindowOpen(windowID: id1, frontmostApp: chrome)
        let restored1 = coordinator.windowWillClose(windowID: id1)
        XCTAssertEqual(restored1?.processIdentifier, externalPID)

        // Round 2: open a new window again -> submit
        let safariPID: pid_t = 200
        let safari = MockRunningApp(processIdentifier: safariPID, bundleIdentifier: "com.apple.Safari")
        let window2 = NSObject()
        let id2 = ObjectIdentifier(window2)

        coordinator.prepareForWindowOpen(windowID: id2, frontmostApp: safari)
        coordinator.markSubmitted(windowID: id2)
        let restored2 = coordinator.windowWillClose(windowID: id2)
        XCTAssertNil(restored2)
    }
}
