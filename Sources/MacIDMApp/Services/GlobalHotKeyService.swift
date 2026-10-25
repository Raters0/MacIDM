import AppKit
import Carbon
import Foundation

/// Owns the process's single global shortcut registration. Behind a protocol so
/// the App's settings wiring can be tested without Carbon, and so the recorder
/// can suspend the live key without knowing how it is registered.
@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    /// The combination this process currently owns, or nil when the shortcut is
    /// not registered.
    var registeredCombo: GlobalHotKeyCombo? { get }

    /// Register `combo`, or unregister everything when nil. Returns false when
    /// the system refuses the combination — another application owns it, or it
    /// is reserved. On refusal the previously registered combination, if any, is
    /// restored so a failed re-record never silently kills a working shortcut.
    @discardableResult func apply(combo: GlobalHotKeyCombo?) -> Bool
}

/// Registers a system-wide shortcut via Carbon's RegisterEventHotKey, which
/// (unlike NSEvent global monitors) works without Accessibility or Input
/// Monitoring permission. Triggering it opens the new-download window,
/// prefilled from the clipboard when it holds a link.
@MainActor
final class GlobalHotKeyService: GlobalHotKeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var retainedPointer: UnsafeMutableRawPointer?
    private let onTrigger: @MainActor () -> Void

    private static let signature: OSType = 0x4D49_444D  // "MIDM"

    private(set) var registeredCombo: GlobalHotKeyCombo?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    @discardableResult
    func apply(combo: GlobalHotKeyCombo?) -> Bool {
        guard let combo else {
            unregister()
            return true
        }
        guard combo.isValid else { return false }
        if combo == registeredCombo { return true }
        let previous = registeredCombo
        unregisterHotKey()
        if registerHotKey(combo) {
            registeredCombo = combo
            return true
        }
        AppLogger.shared.warning(.system, "global hot key \(combo.displayString) refused")
        if let previous, registerHotKey(previous) {
            registeredCombo = previous
        } else {
            removeHandler()
            registeredCombo = nil
        }
        return false
    }

    func unregister() {
        unregisterHotKey()
        removeHandler()
        registeredCombo = nil
    }

    fileprivate func handleHotKey() {
        onTrigger()
    }

    private func registerHotKey(_ combo: GlobalHotKeyCombo) -> Bool {
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// The Carbon event handler outlives individual hot keys: switching
    /// combinations reuses it instead of tearing the retain cycle down and
    /// rebuilding it.
    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passRetained(self).toOpaque()
        retainedPointer = pointer
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            &eventType,
            pointer,
            &handlerRef
        )
        guard status == noErr else {
            releaseRetainedPointer()
            return false
        }
        return true
    }

    private func removeHandler() {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        releaseRetainedPointer()
    }

    private func releaseRetainedPointer() {
        if let pointer = retainedPointer {
            Unmanaged<GlobalHotKeyService>.fromOpaque(pointer).release()
            retainedPointer = nil
        }
    }
}

private let hotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        service.handleHotKey()
    }
    return noErr
}
