import XCTest

@testable import MacIDMApp

/// 测试进程必须与生产支持文件隔离（AppSupportPaths）：`swift test`
/// 曾把 fixture 日志写进用户 `macidm.log`、把诊断事件写进
/// `macidm-private.log`、并对生产 `sessions.json` 执行站点清除。
@MainActor
final class AppSupportPathsTests: XCTestCase {
    private let productionSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacIDM", isDirectory: true)

    func testTestProcessDetectionIsPositiveUnderXCTest() {
        // 本测试自身就运行在 xctest 宿主里。
        XCTAssertTrue(AppSupportPaths.isTestProcess)
    }

    func testSupportDirectoryIsIsolatedFromProductionInTestProcess() {
        let directory = AppSupportPaths.supportDirectory()
        XCTAssertNotEqual(
            directory.standardizedFileURL.path,
            productionSupport.standardizedFileURL.path
        )
        XCTAssertTrue(
            directory.path.contains("MacIDMTestSupport"),
            "test-process support directory must live under the isolated temporary root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSharedLoggerUsesIsolatedPathInTestProcess() {
        XCTAssertNotEqual(
            AppLogger.shared.logFileURL.standardizedFileURL.path,
            productionSupport.appendingPathComponent("macidm.log").standardizedFileURL.path
        )
    }

    func testPrivateDiagnosticLogUsesIsolatedPathInTestProcess() {
        XCTAssertNotEqual(
            YouTubeDiagnosticEventLog.defaultPrivateLogURL().standardizedFileURL.path,
            productionSupport.appendingPathComponent("macidm-private.log").standardizedFileURL
                .path
        )
    }

    func testSessionStoreDefaultIsIsolatedInTestProcess() throws {
        // 行为断言：默认构造的 store 写入后，生产 sessions.json 不得
        // 出现该 marker（文件不存在亦视为通过）。Cookie 原值已改存
        // 钥匙串，而钥匙串是整账户共享命名空间、不受临时目录隔离，
        // 因此还需确认测试自己写入的凭据在清理后不残留。
        let marker = "macidm-isolation-\(UUID().uuidString)"
        let domain = "macidm-isolation-\(UUID().uuidString.prefix(8)).example"
        let store = SessionStore()
        defer { store.removeAll() }
        guard case .stored = store.store(domain: domain, cookie: marker, userAgent: nil) else {
            // Keychain unavailable here: nothing was persisted anywhere, which
            // is the safe outcome for an isolation check.
            return
        }
        let productionSessions = productionSupport.appendingPathComponent("sessions.json")
        let productionContent = try? String(
            contentsOf: productionSessions, encoding: .utf8)
        XCTAssertNil(
            productionContent?.range(of: marker),
            "test writes must never land in the production sessions.json")
        XCTAssertNil(
            productionContent?.range(of: domain),
            "test session metadata must never land in the production sessions.json")

        store.remove(domain: domain)
        XCTAssertNil(
            KeychainSessionSecretStore().value(forDomain: domain),
            "a test credential outlived the test that created it")
    }
}
