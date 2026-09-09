import AppKit
import Carbon
import Foundation

/// Registers a system-wide ⌘⇧N hotkey via Carbon's RegisterEventHotKey,
/// which (unlike NSEvent global monitors) works without Accessibility or
/// Input Monitoring permission. Triggering it opens the new-download sheet,
/// prefilled from the clipboard when it holds a link.
@MainActor
final class GlobalHotKeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var retainedPointer: UnsafeMutableRawPointer?
    private let onTrigger: @MainActor () -> Void

    /// kVK_ANSI_N
    private static let keyCodeN: UInt32 = 45
    private static let signature: OSType = 0x4D49_444D  // "MIDM"

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        guard hotKeyRef == nil else { return }
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
        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            Self.keyCodeN,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let pointer = retainedPointer {
            Unmanaged<GlobalHotKeyService>.fromOpaque(pointer).release()
            retainedPointer = nil
        }
    }

    fileprivate func handleHotKey() {
        onTrigger()
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
