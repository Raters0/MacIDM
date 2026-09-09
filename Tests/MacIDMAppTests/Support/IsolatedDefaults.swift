import XCTest

/// 测试专用 UserDefaults 工厂：每次调用创建一个独立 suite，并在当前
/// 测试 teardown 时彻底清除。
///
/// `UserDefaults(suiteName:)` 的 plist 由 cfprefsd 惰性落盘到
/// `~/Library/Preferences`；只丢弃实例不清除域的话，每次测试运行都会
/// 泄漏一个 plist 文件（修复前累计了数千个）。统一从这里创建，保证
/// 域删除、同步与文件清理三步都执行。
extension XCTestCase {
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "MacIDMUnitTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults(suiteName:) never returns nil for a valid name")
        }
        // teardown 闭包只捕获可安全发送的 suite name，清理时在闭包内部
        // 重新创建实例，避免跨并发域传递非 Sendable 的 UserDefaults。
        addTeardownBlock {
            guard let cleanup = UserDefaults(suiteName: suiteName) else { return }
            cleanup.removePersistentDomain(forName: suiteName)
            cleanup.removeSuite(named: suiteName)
            // cfprefsd flushes lazily; a queued write-back can recreate an
            // empty plist after the domain removal. Synchronize first, then
            // delete any surviving file as a belt-and-suspenders pass.
            CFPreferencesAppSynchronize(suiteName as CFString)
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: plistURL)
        }
        return defaults
    }
}
