import AppKit
import SwiftUI

/// Cancelable countdown window shown when every download has settled and a
/// completion action (quit/sleep/shutdown) is about to run. Closing the
/// window or pressing the button cancels the action; the app itself stays
/// running either way.
final class CompletionActionCountdownWindowManager: NSObject, NSWindowDelegate,
    @unchecked Sendable
{
    static let shared = CompletionActionCountdownWindowManager()

    private var window: NSWindow?
    private weak var model: AppModel?

    @MainActor
    func present(action: SystemCompletionAction, model: AppModel? = nil) {
        // Re-present against the current model; the window content observes
        // the live countdown value.
        if let model { self.model = model }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = self.model else { return }
        let view = CompletionActionCountdownView(action: action)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = AppTheme.windowSurfaceNSColor
        window.contentView = NSHostingView(rootView: view.environmentObject(model))
        window.title = String(localized: "所有下载已完成")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    func close() {
        guard let window else { return }
        self.window = nil
        // Detach the delegate: this close is the *result* of a cancel, not a
        // user gesture, and must not re-enter the cancel path.
        window.delegate = nil
        window.close()
    }

    /// Closing the window directly is a cancel gesture.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            model?.cancelCompletionCountdown()
        }
    }
}

struct CompletionActionCountdownView: View {
    @EnvironmentObject private var model: AppModel
    let action: SystemCompletionAction

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(AppTheme.success)
            Text("所有下载已完成")
                .font(.headline)
            Text(
                "即将执行「\(action.title)」，剩余 \(model.completionCountdownSeconds ?? 0) 秒"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("取消") {
                model.cancelCompletionCountdown()
            }
            .buttonStyle(FlatHoverButtonStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
