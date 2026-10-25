import AppKit
import Carbon
import SwiftUI

/// Click-to-record field for the global shortcut. Recording uses a local key
/// monitor instead of first-responder `keyDown` handling: the monitor sees
/// ⌘-modified keys before the app menu converts them into key equivalents, and
/// returning nil swallows them so nothing else fires while recording.
struct GlobalHotKeyRecorder: View {
    @Binding var combo: GlobalHotKeyCombo?
    /// Tells the app to suspend its live registration while capturing keys, and
    /// to restore it afterwards.
    var onRecordingChanged: (Bool) -> Void = { _ in }

    @StateObject private var session = GlobalHotKeyRecordingSession()

    var body: some View {
        Button {
            if session.isRecording {
                session.stop()
            } else {
                session.start(
                    onCapture: { captured in combo = captured },
                    onStateChanged: onRecordingChanged
                )
            }
        } label: {
            Text(labelText)
                .font(.body)
                .foregroundStyle(labelColor)
                .frame(minWidth: 104)
                .padding(.vertical, 3)
        }
        .buttonStyle(FlatHoverButtonStyle())
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .strokeBorder(
                    session.isRecording ? AppTheme.selectionOutline : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityLabel("全局快捷键")
        .accessibilityValue(combo?.displayString ?? String(localized: "未设置"))
        .onDisappear { session.stop() }
    }

    private var labelColor: Color {
        if session.isRecording { return AppTheme.accent }
        return combo == nil ? .secondary : .primary
    }

    private var labelText: String {
        if session.isRecording {
            return session.hint ?? String(localized: "按下组合键…")
        }
        return combo?.displayString ?? String(localized: "未设置")
    }
}

/// Recording state for `GlobalHotKeyRecorder`. A class because the event
/// monitor outlives the view pass that installs it, and because the field can
/// leave the window entirely while still recording.
@MainActor
final class GlobalHotKeyRecordingSession: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var hint: String?

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onCapture: ((GlobalHotKeyCombo) -> Void)?
    private var onStateChanged: ((Bool) -> Void)?

    func start(
        onCapture: @escaping (GlobalHotKeyCombo) -> Void,
        onStateChanged: @escaping (Bool) -> Void
    ) {
        guard !isRecording else { return }
        self.onCapture = onCapture
        self.onStateChanged = onStateChanged
        isRecording = true
        hint = nil
        onStateChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            // Swallow every key while recording, including the ones the window
            // would otherwise type into a field or send to a menu.
            return nil
        }
        // A local monitor only sees keys while this app is active, so tabbing
        // away ends the recording instead of leaving it up (and the user's
        // shortcut suspended) with no way to notice.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        isRecording = false
        hint = nil
        onCapture = nil
        onStateChanged?(false)
        onStateChanged = nil
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else { return }
        let carbonModifiers = GlobalHotKeyCombo.carbonModifiers(from: event.modifierFlags)
        let strongModifiers: UInt32 = UInt32(cmdKey | controlKey | optionKey)
        if carbonModifiers & strongModifiers == 0, UInt32(event.keyCode) == VirtualKey.escape {
            stop()
            return
        }
        guard
            let captured = GlobalHotKeyCombo.recorded(
                keyCode: UInt32(event.keyCode),
                eventFlags: event.modifierFlags
            )
        else {
            hint = String(localized: "需要 ⌘、⌥ 或 ⌃ 修饰键")
            return
        }
        onCapture?(captured)
        stop()
    }
}
