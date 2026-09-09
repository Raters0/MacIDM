import AppKit
import Foundation

extension AppModel {
    /// Evaluates whether the armed completion action should fire. Called
    /// every time a task settles. Guards:
    /// - an action is armed in settings;
    /// - at least one task actually ran this session (a launch with an
    ///   empty/finished list must not instantly sleep the Mac);
    /// - nothing is still active or waiting (paused tasks do not block —
    ///   they are the user's explicit hold);
    /// - no countdown is already running.
    func checkCompletionActionAfterSettle() {
        let action = settings.completionAction
        guard action != .none, completionCountdownSeconds == nil,
            hasStartedTasksThisSession
        else { return }
        let hasPendingWork = tasks.contains {
            !$0.isCLIManaged && !$0.isArchived
                && !$0.status.isTerminal
                && $0.status != .paused
        }
        guard !hasPendingWork, executions.tasks.isEmpty else { return }
        startCompletionCountdown(action)
    }

    private func startCompletionCountdown(_ action: SystemCompletionAction) {
        AppLogger.shared.info(
            .system, "completion action armed: \(action.rawValue)")
        completionCountdownSeconds = action.countdownSeconds
        CompletionActionCountdownWindowManager.shared.present(action: action, model: self)
        completionCountdownTask?.cancel()
        completionCountdownTask = Task { @MainActor [weak self] in
            while let self, let remaining = self.completionCountdownSeconds,
                remaining > 0, !Task.isCancelled
            {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let current = self.completionCountdownSeconds
                else { return }
                self.completionCountdownSeconds = current - 1
            }
            guard !Task.isCancelled, let self, self.completionCountdownSeconds == 0
            else { return }
            self.executeCompletionAction()
        }
    }

    /// User-facing cancel; also used when new work arrives during the
    /// countdown (a fresh download implicitly rescinds the action).
    func cancelCompletionCountdown() {
        completionCountdownTask?.cancel()
        completionCountdownTask = nil
        completionCountdownSeconds = nil
        CompletionActionCountdownWindowManager.shared.close()
    }

    /// If the user adds or resumes work while the countdown is open, the
    /// completion action no longer reflects reality — rescind it silently.
    func rescindCompletionCountdownIfBusy() {
        guard completionCountdownSeconds != nil else { return }
        let hasPendingWork = tasks.contains {
            !$0.isCLIManaged && !$0.isArchived
                && !$0.status.isTerminal
                && $0.status != .paused
        }
        if hasPendingWork || !executions.tasks.isEmpty {
            AppLogger.shared.info(.system, "completion countdown rescinded: new work arrived")
            cancelCompletionCountdown()
        }
    }

    private func executeCompletionAction() {
        let action = settings.completionAction
        completionCountdownTask?.cancel()
        completionCountdownTask = nil
        completionCountdownSeconds = nil
        CompletionActionCountdownWindowManager.shared.close()
        // Disarm so the action never fires twice from one arming.
        settings.completionAction = .none

        switch action {
        case .none:
            return
        case .quitApp:
            AppLogger.shared.info(.system, "completion action: quitting app")
            NSApp.terminate(nil)
        case .sleep:
            runSystemEventScript(
                "tell application \"System Events\" to sleep",
                failureTitle: String(localized: "睡眠失败")
            )
        case .shutDown:
            runSystemEventScript(
                "tell application \"System Events\" to shut down",
                failureTitle: String(localized: "关机失败")
            )
        }
    }

    /// Sleep/shutdown go through System Events and therefore require the
    /// user-granted Automation permission. On failure the app stays fully
    /// running and the user gets both a window alert and a notification —
    /// the system capability is best-effort by design and never presented
    /// as a guaranteed outcome.
    private func runSystemEventScript(_ source: String, failureTitle: String) {
        AppLogger.shared.info(.system, "completion action: \(source)")
        Task.detached(priority: .userInitiated) { [weak self] in
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            let failed = script?.executeAndReturnError(&errorInfo) == nil
            let message = errorInfo?[NSAppleScript.errorMessage] as? String
            await MainActor.run { [weak self] in
                guard let self else { return }
                if failed {
                    let detail =
                        message
                        ?? String(localized: "未获得系统自动化权限或系统拒绝了请求。")
                    AppLogger.shared.error(
                        .system,
                        "completion action failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(detail) ?? "SANITIZE_FAILED")"
                    )
                    self.presentedError = PresentedError(
                        title: failureTitle,
                        message:
                            String(
                                localized:
                                    "\(detail)\n\n请前往「系统设置 → 隐私与安全性 → 自动化」允许 MacIDM 控制 System Events，然后重试。"
                            )
                    )
                    self.notifier.notifyCompletionActionFailed(
                        action: failureTitle, message: detail)
                }
            }
        }
    }
}
