import Foundation

/// Default-directory policy for App support files: isolates test processes
/// into a temporary directory.
///
/// The `swift test` host and the real App share the same default paths.
/// Before this fix, any test construction that did not explicitly inject a
/// directory (`AppLogger.shared`, `YouTubeDiagnosticEventLog.shared`,
/// `SessionStore()`) read and wrote production files directly: `macidm.log`
/// was polluted with fixture output, `sessions.json` was wiped by tests
/// running the "clear all sites" action, and the private diagnostic log was
/// filled with test events. Test hosts (the xctest process, where
/// `XCTestConfigurationFilePath` is set) are always redirected to a
/// temporary directory; the production directory is used only by the real
/// App process.
enum AppSupportPaths {
    /// Detects the test host process. Both the `swift test` and Xcode XCTest
    /// runners set `XCTestConfigurationFilePath`; the XCTest class-existence
    /// check is a fallback covering custom runners that do not set it.
    static var isTestProcess: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    /// Default directory for support files. Test processes get a fixed
    /// temporary directory (predictable for tests and reclaimed under the
    /// system's /tmp policy); production processes get
    /// `~/Library/Application Support/MacIDM`.
    static func supportDirectory() -> URL {
        let base: URL
        if isTestProcess {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacIDMTestSupport", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MacIDM", isDirectory: true)
        }
        return base
    }
}
