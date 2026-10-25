import AppKit
import Carbon
import XCTest

@testable import MacIDMApp

/// 全局快捷键的语义契约：什么算一个可用的组合键、存回来的整数怎样变成标签，
/// 以及录制时 AppKit 的修饰键怎样翻成 Carbon 标志。
final class GlobalHotKeyComboTests: XCTestCase {
    func testDefaultCombinationRendersAsTheDocumentedShortcut() {
        XCTAssertEqual(GlobalHotKeyCombo.defaultValue.displayString, "⌘⇧N")
        XCTAssertTrue(GlobalHotKeyCombo.defaultValue.isValid)
    }

    func testDisplayOrderPutsCommandFirstThenShiftOptionControl() {
        XCTAssertEqual(
            GlobalHotKeyCombo(
                keyCode: VirtualKey.ansiN,
                carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
            ).displayString,
            "⌘⇧⌥⌃N"
        )
    }

    func testCombinationsWithoutAStrongModifierAreRefused() {
        // 全局快捷键会从所有应用手里抢走按键，裸键和只带 ⇧ 的组合必须拒绝。
        XCTAssertFalse(
            GlobalHotKeyCombo(keyCode: VirtualKey.ansiN, carbonModifiers: 0).isValid
        )
        XCTAssertFalse(
            GlobalHotKeyCombo(
                keyCode: VirtualKey.ansiN,
                carbonModifiers: UInt32(shiftKey)
            ).isValid
        )
        XCTAssertTrue(
            GlobalHotKeyCombo(
                keyCode: VirtualKey.ansiN,
                carbonModifiers: UInt32(controlKey)
            ).isValid
        )
    }

    func testKeyCodesWithoutANameAreRefused() {
        // 显示不出来的键不能录制，否则设置页会呈现一个读不懂的快捷键。
        XCTAssertFalse(
            GlobalHotKeyCombo(keyCode: 0x3FFF, carbonModifiers: UInt32(cmdKey)).isValid
        )
        XCTAssertNil(VirtualKey.name(for: 0x3FFF))
    }

    func testRecordingTranslatesAppKitFlagsIntoCarbonFlags() {
        XCTAssertEqual(
            GlobalHotKeyCombo.carbonModifiers(from: [.command, .shift]),
            UInt32(cmdKey | shiftKey)
        )
        XCTAssertEqual(
            GlobalHotKeyCombo.recorded(keyCode: VirtualKey.ansiN, eventFlags: [.command, .option])?
                .displayString,
            "⌘⌥N"
        )
        XCTAssertNil(GlobalHotKeyCombo.recorded(keyCode: VirtualKey.ansiN, eventFlags: [.shift]))
    }

    func testNamedKeysCoverTheKeysUsersActuallyRecord() {
        XCTAssertEqual(VirtualKey.name(for: 0x31), "Space")
        XCTAssertEqual(VirtualKey.name(for: 0x24), "Return")
        XCTAssertEqual(VirtualKey.name(for: 0x7B), "Left")
        XCTAssertEqual(VirtualKey.name(for: 0x7A), "F1")
        XCTAssertEqual(
            GlobalHotKeyCombo(keyCode: 0x31, carbonModifiers: UInt32(controlKey)).displayString,
            "⌃Space"
        )
    }
}
