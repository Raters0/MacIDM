import Darwin
import XCTest

@testable import MacIDMApp

/// Process-table utilities backing the yt-dlp process-group lifecycle
/// Termination behavior itself is covered by
/// `ManagedToolSessionTests`.
///
/// 每一棵树都由测试自己放进**专属进程组**（`POSIX_SPAWN_SETPGROUP`，
/// pgid == 根 pid），defer/tearDown 对明确的 pgid 执行整组 TERM → KILL → wait，
/// 并断言清理后组为空——完整 `swift test` 不得留下重挂到 PID 1 的后代（§6）。
final class ProcessTreeTests: XCTestCase {
    /// 尚未显式回收的根进程；tearDown 兜底整组清理。
    private var pendingRoots: [pid_t] = []

    override func tearDown() {
        for root in pendingRoots {
            killGroupAndReap(root)
        }
        pendingRoots.removeAll()
        super.tearDown()
    }

    /// 整组 SIGKILL 并回收根；随后等待组空。重复调用安全（组已空时 kill 失败无害，
    /// waitpid 对已回收的根返回 -1）。
    private func killGroupAndReap(_ pgid: pid_t) {
        kill(-pgid, SIGKILL)
        var status: Int32 = 0
        waitpid(pgid, &status, 0)
    }

    private func waitForGroupEmpty(_ pgid: pid_t, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProcessTree.groupState(pgid) == .empty { return }
            try Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("进程组 \(pgid) 在截止时刻前未清空")
    }

    /// Spawns `/bin/sh -c <script>` into its own dedicated process group
    /// (pgid == returned pid) so the test owns the whole tree.
    private func spawnInOwnGroup(_ script: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CocoaError(.featureUnsupported)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CocoaError(.featureUnsupported)
        }
        let argvStrings = ["/bin/sh", "-c", script]
        var argv = argvStrings.map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        var envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.compactMap { $0 }.forEach { free($0) } }
        var spawned: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &spawned, "/bin/sh", nil, &attributes,
                    argvBuffer.baseAddress, envpBuffer.baseAddress)
            }
        }
        guard status == 0 else {
            throw CocoaError(.featureUnsupported)
        }
        pendingRoots.append(spawned)
        return spawned
    }

    func testDescendantsIncludeGrandchildren() throws {
        let root = try spawnInOwnGroup("sleep 300 & sleep 60")
        defer {
            killGroupAndReap(root)
            pendingRoots.removeAll { $0 == root }
        }
        try Thread.sleep(forTimeInterval: 0.3)

        let descendants = ProcessTree.descendants(of: root)
        XCTAssertGreaterThanOrEqual(descendants.count, 2)
        XCTAssertTrue(ProcessTree.isRunning(root))

        // 清理后组必须为空，且整组清理覆盖了后台后代（§6）。
        killGroupAndReap(root)
        pendingRoots.removeAll { $0 == root }
        try waitForGroupEmpty(root)
        XCTAssertEqual(ProcessTree.groupState(root), .empty)
    }

    func testGroupHasLiveMembersTracksProcessGroup() throws {
        // §6 的真实正向断言：根与后代都活着时组必须为 live；整组清理后为 empty。
        // 进程组成员判定是进程组终止的基础：根先退出、后代被重新挂到
        // launchd 后，组成员身份仍然可查——动态追后代则会丢失它们（§3）。
        let root = try spawnInOwnGroup("sleep 300 & sleep 60")
        defer {
            killGroupAndReap(root)
            pendingRoots.removeAll { $0 == root }
        }
        try Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(ProcessTree.isRunning(root))
        XCTAssertTrue(
            ProcessTree.groupHasLiveMembers(root),
            "根和后代活着时进程组必须为 live")
        XCTAssertEqual(ProcessTree.groupState(root), .live)

        killGroupAndReap(root)
        pendingRoots.removeAll { $0 == root }
        try waitForGroupEmpty(root)
        XCTAssertFalse(
            ProcessTree.groupHasLiveMembers(root),
            "整组清理后进程组必须为 empty")
        XCTAssertFalse(ProcessTree.groupHasLiveMembers(99_999_999), "未知进程组必须为空")
        XCTAssertEqual(ProcessTree.groupState(99_999_999), .empty)
    }

    func testGroupMembershipSurvivesRootExitingFirst() throws {
        // 根先退出、sleep 后代重挂到 launchd：动态追后代会丢失它们，
        // 但进程组成员身份不受影响——组仍为 live，直到整组清理。
        let root = try spawnInOwnGroup("(sleep 300 &); exit 0")
        defer {
            killGroupAndReap(root)
            pendingRoots.removeAll { $0 == root }
        }
        var status: Int32 = 0
        waitpid(root, &status, 0)
        try Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(
            ProcessTree.groupState(root), .live,
            "根退出后组内残留后代必须仍被判为 live")

        killGroupAndReap(root)
        pendingRoots.removeAll { $0 == root }
        try waitForGroupEmpty(root)
        XCTAssertEqual(ProcessTree.groupState(root), .empty)
    }
}
