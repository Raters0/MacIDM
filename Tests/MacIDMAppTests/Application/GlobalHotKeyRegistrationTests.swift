import Carbon
import XCTest

@testable import MacIDMApp

/// 设置里的开关、录制框和系统注册之间的关系都收敛在 AppModel。这些用例用假
/// registrar 锁定这层接线，不触碰 Carbon。
@MainActor
final class GlobalHotKeyRegistrationTests: XCTestCase {
    private final class FakeRegistrar: GlobalHotKeyRegistering {
        private(set) var registeredCombo: GlobalHotKeyCombo?
        /// 模拟被系统或其他应用占用的键码：拒绝时保留上一个可用组合键，
        /// 与 `GlobalHotKeyService` 的语义一致。
        var refusedKeyCodes: Set<UInt32> = []

        @discardableResult
        func apply(combo: GlobalHotKeyCombo?) -> Bool {
            guard let combo else {
                registeredCombo = nil
                return true
            }
            guard !refusedKeyCodes.contains(combo.keyCode) else { return false }
            registeredCombo = combo
            return true
        }
    }

    private func makeModel() -> (AppModel, AppSettings) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHotKeyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        return (AppModel(storeDirectory: directory, settings: settings), settings)
    }

    func testInstallingTheRegistrarRegistersTheEnabledDefaultShortcut() {
        let (model, _) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        XCTAssertEqual(registrar.registeredCombo, .defaultValue)
        XCTAssertNil(model.globalHotKeyError)
    }

    func testModelWithoutARegistrarNeverRegistersAnything() {
        // 普通单测构造模型时不该碰到 Carbon：没有安装 registrar 时改设置是无操作。
        let (model, settings) = makeModel()
        settings.globalHotKeyEnabled = false
        settings.globalHotKeyCombo = GlobalHotKeyCombo(
            keyCode: VirtualKey.ansiN,
            carbonModifiers: UInt32(controlKey)
        )
        XCTAssertNil(model.globalHotKeyRegistrar)
        XCTAssertNil(model.globalHotKeyError)
    }

    func testDisablingTheSwitchUnregistersAndReEnablingRegistersAgain() {
        let (model, settings) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        settings.globalHotKeyEnabled = false
        XCTAssertNil(registrar.registeredCombo)
        settings.globalHotKeyEnabled = true
        XCTAssertEqual(registrar.registeredCombo, .defaultValue)
    }

    func testRecordingANewCombinationReplacesTheRegistration() {
        let (model, settings) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        let recorded = GlobalHotKeyCombo(
            keyCode: VirtualKey.ansiN,
            carbonModifiers: UInt32(controlKey | optionKey)
        )
        settings.globalHotKeyCombo = recorded
        XCTAssertEqual(registrar.registeredCombo, recorded)
    }

    func testClearingTheRecorderUnregistersTheShortcut() {
        // 清空录制框就是「这个操作不要全局快捷键」，不是退回默认组合键。
        let (model, settings) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        settings.globalHotKeyCombo = nil
        XCTAssertNil(registrar.registeredCombo)
        XCTAssertNil(model.globalHotKeyError)
    }

    func testRecordingClearsTheLiveKeySoTheCombinationReachesTheApp() {
        // Carbon 把组合键交给先注册的进程，因此录制时必须让线上注册让位；
        // 否则用户按下正在使用的快捷键，设置框什么都收不到。
        let (model, _) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        model.isGlobalHotKeyRecording = true
        XCTAssertNil(registrar.registeredCombo)
        model.isGlobalHotKeyRecording = false
        XCTAssertEqual(registrar.registeredCombo, .defaultValue)
    }

    func testOccupiedCombinationKeepsTheLiveKeyAndNamesBoth() {
        let (model, settings) = makeModel()
        let registrar = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(registrar)
        registrar.refusedKeyCodes = [0x08]
        let refused = GlobalHotKeyCombo(keyCode: 0x08, carbonModifiers: UInt32(cmdKey | shiftKey))
        settings.globalHotKeyCombo = refused
        // 用户要的那个键没抢到，上一个仍然有效：保留线上键，并把两个键都写进
        // 提示，同时把用户录入的组合留着，方便他换一个再试。
        XCTAssertEqual(registrar.registeredCombo, .defaultValue)
        XCTAssertEqual(settings.globalHotKeyCombo, refused)
        // 文案本体随测试进程语言解析，这里只锁定「两个键都被点名」这一事实。
        XCTAssertTrue(model.globalHotKeyError?.contains("⌘⇧C") == true)
        XCTAssertTrue(model.globalHotKeyError?.contains("⌘⇧N") == true)

        // 换一个没被占用的组合键后，错误必须自己消失。
        let free = GlobalHotKeyCombo(keyCode: 0x0E, carbonModifiers: UInt32(cmdKey))
        settings.globalHotKeyCombo = free
        XCTAssertEqual(registrar.registeredCombo, free)
        XCTAssertNil(model.globalHotKeyError)
    }

    func testReinstallingTheRegistrarReleasesThePreviousOne() {
        // 主窗口被 SwiftUI 重建时会再跑一次启动任务；两个 registrar 同时持有
        // 同一个组合键的话，第二个注册必然被拒并被当成占用报错。
        let (model, _) = makeModel()
        let first = FakeRegistrar()
        let second = FakeRegistrar()
        model.installGlobalHotKeyRegistrar(first)
        model.installGlobalHotKeyRegistrar(second)
        XCTAssertNil(first.registeredCombo)
        XCTAssertEqual(second.registeredCombo, .defaultValue)
        XCTAssertTrue(model.globalHotKeyRegistrar === second)
    }
}
