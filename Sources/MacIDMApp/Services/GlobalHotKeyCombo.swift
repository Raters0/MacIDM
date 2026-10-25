import AppKit
import Carbon
import Foundation

/// A global shortcut as the user records it: one ANSI virtual key code plus the
/// modifier flags it was pressed with. One validated value type keeps the
/// settings recorder, the persisted preferences, and the Carbon registration
/// agreeing on what a shortcut is instead of passing loose integers around.
struct GlobalHotKeyCombo: Equatable, Hashable {
    /// macOS virtual key code (`kVK_*` from Carbon's `Events.h`).
    let keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    let carbonModifiers: UInt32

    /// The shipped default: ⌘⇧N.
    static let defaultValue = GlobalHotKeyCombo(
        keyCode: VirtualKey.ansiN,
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// A global shortcut steals the key from every application, so a bare key
    /// or a Shift-only combination is refused: those are ordinary typing.
    var isValid: Bool {
        let strongModifiers: UInt32 = UInt32(cmdKey | controlKey | optionKey)
        return carbonModifiers & strongModifiers != 0 && keyName != nil
    }

    var keyName: String? { VirtualKey.name(for: keyCode) }

    /// `⌘⇧N`. Command leads because that is how this project's documents and
    /// onboarding text write shortcuts, not Apple's menu order (`⇧⌘N`).
    var displayString: String {
        var prefix = ""
        if carbonModifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        if carbonModifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if carbonModifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if carbonModifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        return prefix + (keyName ?? "?")
    }

    /// Carbon and AppKit number the same modifiers with different constants, so
    /// a recorded `NSEvent` has to be translated before it can be registered.
    static func carbonModifiers(from eventFlags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if eventFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if eventFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if eventFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if eventFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// The recorder's entry point: an invalid combination (no strong modifier, or
    /// a key we cannot name) returns nil so the field keeps waiting.
    static func recorded(keyCode: UInt32, eventFlags: NSEvent.ModifierFlags) -> GlobalHotKeyCombo? {
        let combo = GlobalHotKeyCombo(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers(from: eventFlags)
        )
        return combo.isValid ? combo : nil
    }
}

/// Display names for the ANSI virtual key codes Apple defines in `Events.h`.
/// The codes are layout-based constants and carry no name, so a stored shortcut
/// can only be rendered after relaunch through this table.
enum VirtualKey {
    static let ansiN: UInt32 = 0x2D
    static let escape: UInt32 = 0x35

    static func name(for keyCode: UInt32) -> String? { names[keyCode] }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Escape",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Keypad Clear",
        0x4B: "Keypad /", 0x4C: "Keypad Enter", 0x4E: "Keypad -", 0x51: "Keypad =",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3",
        0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7",
        0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8", 0x65: "F9",
        0x67: "F11", 0x69: "F13", 0x6A: "F16", 0x6B: "F14", 0x6D: "F10",
        0x6F: "F12", 0x71: "F15", 0x76: "F4", 0x78: "F2", 0x7A: "F1",
        0x48: "Volume Up", 0x49: "Volume Down", 0x4A: "Mute",
        0x72: "Help", 0x73: "Home", 0x74: "Page Up", 0x75: "Forward Delete",
        0x77: "End", 0x79: "Page Down",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up",
    ]
}
