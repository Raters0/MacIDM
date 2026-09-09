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
}
