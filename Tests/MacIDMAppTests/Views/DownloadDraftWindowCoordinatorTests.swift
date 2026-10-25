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

    func testConfirmationWindowFloatsWhileKeyOrInADialogPhase() {
        // 打开瞬间与用户正在填写时必须浮在浏览器之上：.accessory +
        // .nonactivatingPanel 下 .normal 层级不会被可靠前置（macOS 14+）。
        XCTAssertEqual(
            DownloadDraftWindowCoordinator.windowLevel(isKeyWindow: true, phase: .none),
            .floating
        )
        // 系统授权框抢占焦点时同样保持浮层：面板此时不是 key window，
        // 降层会让它在框关闭后沉到浏览器底下。
        XCTAssertEqual(
            DownloadDraftWindowCoordinator.windowLevel(isKeyWindow: false, phase: .dialogOpen),
            .floating
        )
        XCTAssertEqual(
            DownloadDraftWindowCoordinator.windowLevel(isKeyWindow: false, phase: .settling),
            .floating
        )
        // 用户切到其他应用后必须降回普通层级，否则别的应用永远盖不住确认窗。
        XCTAssertEqual(
            DownloadDraftWindowCoordinator.windowLevel(isKeyWindow: false, phase: .none),
            .normal
        )
    }

    /// The failing case this covers: a `.nonactivatingPanel` never activates
    /// MacIDM, so while the login-Keychain approval dialog is up the frontmost
    /// application still reports the browser. Only our own credential access can
    /// tell the dialog apart from a user-initiated app switch.
    func testCredentialAccessHoldsThePanelEvenThoughTheBrowserIsFrontmost() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())

        let phase = coordinator.recordResignKey(
            windowID: windowID, credentialAccessInFlight: true)

        XCTAssertEqual(phase, .dialogOpen)
        XCTAssertEqual(coordinator.phase(of: windowID), .dialogOpen)
    }

    func testUserSwitchToAnotherApplicationDoesNotHoldThePanel() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())

        let phase = coordinator.recordResignKey(
            windowID: windowID, credentialAccessInFlight: false)

        XCTAssertEqual(phase, .none)
        XCTAssertTrue(coordinator.beginSettlingAfterSystemDialog().isEmpty)
    }

    /// Measured on a live install: the panel was raised 4 ms before macOS handed
    /// focus back to the browser, and that hand-back demoted it again. A lost key
    /// status while waiting must keep the panel floating.
    func testFocusHandBackWhileSettlingKeepsThePanelFloating() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)
        XCTAssertEqual(coordinator.beginSettlingAfterSystemDialog(), [windowID])

        let phase = coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: false)

        XCTAssertEqual(phase, .settling, "the focus hand-back was read as a user app switch")
        XCTAssertEqual(
            DownloadDraftWindowCoordinator.windowLevel(isKeyWindow: false, phase: phase),
            .floating
        )
    }

    func testSettlingPanelIsRaisedOnceAndThenFollowsTheNormalPolicy() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)
        XCTAssertFalse(coordinator.isAnyWindowSettlingAfterSystemDialog)
        coordinator.beginSettlingAfterSystemDialog()
        XCTAssertTrue(coordinator.isAnyWindowSettlingAfterSystemDialog)

        XCTAssertEqual(coordinator.endSettlingAfterSystemDialog(), [windowID])

        XCTAssertEqual(coordinator.phase(of: windowID), .none)
        XCTAssertTrue(coordinator.endSettlingAfterSystemDialog().isEmpty)
        // After the raise, a later user switch demotes the panel as usual.
        XCTAssertEqual(
            coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: false),
            .none
        )
    }

    func testSecondDialogWhileSettlingExtendsTheSameWait() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)
        XCTAssertEqual(coordinator.beginSettlingAfterSystemDialog(), [windowID])

        // Another credential access raises a second dialog; the pending wait
        // still covers the panel, so nothing is dropped and nothing stacks up.
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)
        XCTAssertEqual(coordinator.beginSettlingAfterSystemDialog(), [])
        XCTAssertTrue(coordinator.isAnyWindowSettlingAfterSystemDialog)
    }

    func testBecomingKeyClearsTheDialogPhase() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let windowID = ObjectIdentifier(NSObject())
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)

        coordinator.recordBecomeKey(windowID: windowID)

        XCTAssertEqual(coordinator.phase(of: windowID), .none)
        XCTAssertTrue(coordinator.beginSettlingAfterSystemDialog().isEmpty)
    }

    /// A dialog that is already up when the panel opens leaves it non-key, so
    /// there is no resign-key event to classify. The phase has to be taken at
    /// open time.
    func testPanelOpenedDuringACredentialAccessIsHeldFromTheStart() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let windowID = ObjectIdentifier(NSObject())

        coordinator.prepareForWindowOpen(
            windowID: windowID, frontmostApp: chrome, credentialAccessInFlight: true)

        XCTAssertEqual(coordinator.phase(of: windowID), .dialogOpen)
        XCTAssertEqual(coordinator.beginSettlingAfterSystemDialog(), [windowID])
    }

    func testClosingAPanelClearsItsDialogPhase() {
        let coordinator = DownloadDraftWindowCoordinator(currentProcessPID: currentPID)
        let chrome = MockRunningApp(processIdentifier: externalPID, bundleIdentifier: "com.google.Chrome")
        let windowID = ObjectIdentifier(NSObject())
        coordinator.prepareForWindowOpen(windowID: windowID, frontmostApp: chrome)
        coordinator.recordResignKey(windowID: windowID, credentialAccessInFlight: true)
        coordinator.beginSettlingAfterSystemDialog()

        XCTAssertNotNil(coordinator.windowWillClose(windowID: windowID))

        XCTAssertEqual(coordinator.phase(of: windowID), .none)
        XCTAssertTrue(coordinator.endSettlingAfterSystemDialog().isEmpty)
    }
}
