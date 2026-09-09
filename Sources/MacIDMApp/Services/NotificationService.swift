import AppKit
import Foundation
import UserNotifications

/// Posts system notifications for finished/failed downloads and keeps the
/// Dock badge in sync with the active task count. All entry points are
/// no-ops outside a real .app bundle (unit tests, CLI runs).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter.current()` traps outside a real .app
    /// bundle (xctest runner, CLI), so it is resolved lazily and only after
    /// the bundle check passes.
    private lazy var center: UNUserNotificationCenter? = {
        guard isUsable else { return nil }
        return UNUserNotificationCenter.current()
    }()

    private var didRequestAuthorization = false
    private var lastBadgeValue: String?

    override init() {
        super.init()
        center?.delegate = self
    }

    func notifyTaskFinished(filename: String, succeeded: Bool, errorMessage: String?, playSound: Bool = true) {
        guard let center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title =
            succeeded ? String(localized: "下载完成") : String(localized: "下载失败")
        content.body =
            succeeded
            ? filename
            : "\(filename)：\(errorMessage ?? String(localized: "未知错误"))"
        if succeeded, playSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    func notifyFileMissing(filename: String) {
        guard let center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "文件已丢失")
        content.body = String(localized: "下载文件 \(filename) 已从下载目录中删除")
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    func notifyCompletionActionFailed(action: String, message: String) {
        guard let center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = action
        content.body = message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    func updateDockBadge(activeCount: Int) {
        guard isUsable else { return }
        let value = activeCount > 0 ? String(activeCount) : nil
        guard value != lastBadgeValue else { return }
        lastBadgeValue = value
        NSApp.dockTile.badgeLabel = value
    }

    private var isUsable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show banners even while the app is frontmost; download completion is
    // exactly the kind of event users wait on while watching the list.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
