import Carbon
import XCTest

@testable import MacIDMApp

/// Regression tests for R2-1/R6: the Agent API assigns raw numbers to
/// settings, so the in-memory value must be clamped too — a persist-only
/// clamp left 0 in `maximumParallelRequests`, failing every new download
/// until relaunch, and negative speed limits silently disabled the limiter.
final class AppSettingsClampTests: XCTestCase {
    @MainActor
    private func makeSettings() throws -> (AppSettings, UserDefaults) {
        let suiteName = "test.appsettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults)
    }

    @MainActor
    func testAssigningZeroToMaximumParallelRequestsClampsToOneInMemory() throws {
        let (settings, _) = try makeSettings()
        settings.maximumParallelRequests = 0
        XCTAssertEqual(settings.maximumParallelRequests, 1)
        settings.maximumParallelRequests = 999
        XCTAssertEqual(settings.maximumParallelRequests, 64)
    }

    @MainActor
    func testAssigningZeroToSimultaneousDownloadsClampsToOneInMemory() throws {
        let (settings, _) = try makeSettings()
        settings.simultaneousDownloads = 0
        XCTAssertEqual(settings.simultaneousDownloads, 1)
        settings.simultaneousDownloads = 99
        XCTAssertEqual(settings.simultaneousDownloads, 10)
    }

    @MainActor
    func testAssigningNegativeSpeedLimitClampsToZeroInMemory() throws {
        let (settings, _) = try makeSettings()
        settings.speedLimitKBps = -5
        XCTAssertEqual(settings.speedLimitKBps, 0)
    }

    @MainActor
    func testClampedValuesArePersisted() throws {
        let (settings, defaults) = try makeSettings()
        settings.maximumParallelRequests = 0
        settings.simultaneousDownloads = 99
        settings.speedLimitKBps = -5
        XCTAssertEqual(defaults.integer(forKey: "maximumParallelRequests"), 1)
        XCTAssertEqual(defaults.integer(forKey: "simultaneousDownloads"), 10)
        XCTAssertEqual(defaults.integer(forKey: "speedLimitKBps"), 0)
    }

    @MainActor
    func testGlobalHotKeyStartsEnabledWithTheDocumentedCombination() throws {
        let (settings, _) = try makeSettings()
        XCTAssertTrue(settings.globalHotKeyEnabled)
        XCTAssertEqual(settings.globalHotKeyCombo, .defaultValue)
    }

    @MainActor
    func testRecordedGlobalHotKeySurvivesAReload() throws {
        let (settings, defaults) = try makeSettings()
        let recorded = GlobalHotKeyCombo(keyCode: 0x08, carbonModifiers: UInt32(controlKey))
        settings.globalHotKeyCombo = recorded
        XCTAssertEqual(defaults.object(forKey: "globalHotKeyCode") as? Int, 8)
        XCTAssertEqual(AppSettings(defaults: defaults).globalHotKeyCombo, recorded)
        settings.globalHotKeyEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).globalHotKeyEnabled)

        // 清除即「未设置」：存 -1，读回来是 nil，而不是复活成默认组合键。
        settings.globalHotKeyCombo = nil
        XCTAssertEqual(defaults.object(forKey: "globalHotKeyCode") as? Int, -1)
        XCTAssertNil(AppSettings(defaults: defaults).globalHotKeyCombo)
    }

    @MainActor
    func testStoredCombinationIsNotConfusedWithNeverRecorded() throws {
        // keyCode 0 是真实的 A 键；用 integer(forKey:) 的 0 判缺省会丢掉 ⌘A。
        let (settings, defaults) = try makeSettings()
        settings.globalHotKeyCombo = GlobalHotKeyCombo(keyCode: 0, carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(AppSettings(defaults: defaults).globalHotKeyCombo?.displayString, "⌘A")

        // 读不懂的存值按「未设置」处理，而不是偷偷恢复一个全局键。
        let (tainted, taintedDefaults) = try makeSettings()
        tainted.globalHotKeyCombo = .defaultValue
        taintedDefaults.set(0, forKey: "globalHotKeyModifiers")
        XCTAssertNil(AppSettings(defaults: taintedDefaults).globalHotKeyCombo)
    }
}
