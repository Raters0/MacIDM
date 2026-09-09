import Darwin
import XCTest

@testable import MacIDMApp

/// Process-group lifecycle tests for the shared yt-dlp wrapper
/// (docs/AI交接.md §3): the dedicated group must cover TERM-resistant
/// survivors, grace-period newcomers and output-channel holders, and settle
/// budget exhaustion must surface as a diagnosable failure.
final class ManagedToolSessionTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func makeScript(_ body: String) throws -> URL {
        let directory = try makeDirectory()
        let executable = directory.appendingPathComponent("fake-tool")
        try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// Session + pipe + reader thread. The reader records the EOF moment so
    /// tests can prove the continuation waited for the output channel.
    private func makeSession(
        executable: URL,
        terminationGrace: TimeInterval = 1.0,
        settleBudget: TimeInterval = 5.0,
        launchBarrier: (() -> Void)? = nil,
        groupLivenessProbe: (@Sendable (pid_t) -> ProcessTree.GroupState)? = nil
    ) throws -> (ManagedToolSession, @Sendable () -> Bool, @Sendable () -> Date?) {
        // pipe() failure must not be hidden (§5.3): infrastructure errors must not
        // masquerade as business failures.
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            throw ManagedToolLaunchError(detail: "test pipe() failed errno=\(errno)")
        }
        final class ReaderState: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var eofAt: Date?
        }
        let state = ReaderState()
        let master = pipeFDs[0]
        let session = ManagedToolSession(
            executableURL: executable,
            arguments: [],
            stdoutFileDescriptor: pipeFDs[1],
            stderrFileDescriptor: pipeFDs[1],
            terminationGrace: terminationGrace,
            settleBudget: settleBudget,
            launchBarrier: launchBarrier,
            groupLivenessProbe: groupLivenessProbe
        )
        // Same as production callers: read-end EOF must feed the session's completion
        // gate, or the continuation never ends.
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(master, &buffer, buffer.count) > 0 {}
            close(master)
            state.lock.lock()
            state.finished = true
            state.eofAt = Date()
            state.lock.unlock()
            session.markReaderFinished()
        }
        return (
            session,
            {
                state.lock.lock()
                defer { state.lock.unlock() }
                return state.finished
            },
            {
                state.lock.lock()
                defer { state.lock.unlock() }
                return state.eofAt
            }
        )
    }

    func testTermResistantDescendantIsForceKilledWhenRootExitsFirst() async throws {
        // §3 confirmed defect: after the root exits on TERM, TERM-ignoring descendants
        // are re-parented to launchd — dynamically chasing descendants would misjudge
        // the tree as gone. The process group must SIGKILL them.
        let executable = try makeScript(
            """
            (trap '' TERM; sleep 300) &
            trap 'exit 0' TERM
            wait
            """
        )
        let (session, _, _) = try makeSession(executable: executable, terminationGrace: 1.0)
        let runTask = Task { await session.run(timeout: 60) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let group = session.processGroupID()
        XCTAssertGreaterThan(group, 0)
        XCTAssertTrue(ProcessTree.groupHasLiveMembers(group))

        session.requestCancel()
        let outcome = await runTask.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertFalse(
            ProcessTree.groupHasLiveMembers(group),
            "忽略 TERM 的后代必须被整组 SIGKILL，不得残留")
    }

    func testDescendantSpawnedDuringGraceIsCleanedUp() async throws {
        // New descendants the root spawns during the grace period inherit the process
        // group: they must be cleaned up too.
        let executable = try makeScript(
            """
            trap 'sleep 300 & wait' TERM
            sleep 60 &
            wait
            """
        )
        let (session, _, _) = try makeSession(executable: executable, terminationGrace: 1.0)
        let runTask = Task { await session.run(timeout: 60) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let group = session.processGroupID()

        session.requestCancel()
        let outcome = await runTask.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertFalse(
            ProcessTree.groupHasLiveMembers(group),
            "宽限期内新派生的后代也属于进程组，必须被清理")
    }

    func testContinuationWaitsForOutputEOFHeldByDescendant() async throws {
        // A descendant holds the stdout write end and ignores TERM: only killing it
        // brings the read end to EOF, and the continuation must wait for EOF
        // (§3 "PTY holder" scenario).
        let executable = try makeScript(
            """
            (trap '' TERM; sleep 300) &
            trap 'exit 0' TERM
            wait
            """
        )
        let (session, readerFinished, _) = try makeSession(
            executable: executable, terminationGrace: 1.0)
        let runTask = Task { await session.run(timeout: 60) }
        try await Task.sleep(nanoseconds: 500_000_000)

        session.requestCancel()
        let outcome = await runTask.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertTrue(
            readerFinished(),
            "continuation 结束前输出通道必须已到 EOF（后代持有的写端已关闭）")
    }

    func testSettleBudgetExhaustionReportsCleanupFailure() async throws {
        // Settle-budget exhaustion must return a diagnosable failure, never silently
        // succeed (§3). An always-live probe simulates the cannot-confirm-empty case.
        let executable = try makeScript("sleep 300")
        let (session, _, _) = try makeSession(
            executable: executable,
            terminationGrace: 0.2,
            settleBudget: 0.5,
            groupLivenessProbe: { _ in .live }
        )
        let runTask = Task { await session.run(timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)

        session.requestCancel()
        let outcome = await runTask.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertTrue(outcome.cleanupFailed, "settle 预算耗尽必须显式报告清理失败")
    }

    func testCancelBeforeLaunchSpawnsNothingAcrossRepeatedRounds() async throws {
        // Cancellation lands between "registered as launching" and "actually spawned":
        // no process may remain, and the continuation ends exactly once. Repeated
        // rounds rely on no probabilities (§4 isomorphism).
        for _ in 0..<5 {
            let directory = try makeDirectory()
            let marker = directory.appendingPathComponent("started")
            let executable = try makeScript("echo 1 > \"\(marker.path)\"; sleep 300")
            let semaphore = DispatchSemaphore(value: 0)
            let (session, _, _) = try makeSession(
                executable: executable,
                launchBarrier: { semaphore.wait() }
            )
            let runTask = Task { await session.run(timeout: 60) }
            try await Task.sleep(nanoseconds: 200_000_000)
            session.requestCancel()
            semaphore.signal()
            let outcome = await runTask.value

            XCTAssertTrue(outcome.cancelled, "launching 期间的取消必须结束为 cancelled")
            XCTAssertNil(outcome.exitStatus, "未真正 spawn 不得有退出码")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                "取消先到时不得真正启动子进程")
        }
    }

    func testNormalExitReportsStatusAfterReaderEOF() async throws {
        let executable = try makeScript("echo hello; exit 7")
        let (session, readerFinished, _) = try makeSession(executable: executable)

        let outcome = await session.run(timeout: 30)

        XCTAssertEqual(outcome.exitStatus, 7)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertTrue(readerFinished())
    }

    func testNormalExitVerifiesGroupEmptyBeforeResuming() async throws {
        // §3 P0 deterministic test: the root `exit 0`s while descendants ignore HUP/TERM
        // and close stdout/stderr themselves — the direct child is reaped and the read
        // end is at EOF, yet descendants remain in the process group. Before run()
        // returns, the group must be emptied (controlled teardown SIGKILLs the group).
        let executable = try makeScript(
            """
            (trap '' HUP TERM; exec 1>&- 2>&-; sleep 300) &
            exit 0
            """
        )
        let (session, readerFinished, _) = try makeSession(
            executable: executable, terminationGrace: 0.5)
        let groupHolder = session

        let outcome = await session.run(timeout: 30)
        let group = groupHolder.processGroupID()

        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertTrue(readerFinished())
        XCTAssertGreaterThan(group, 0)
        XCTAssertEqual(
            ProcessTree.groupState(group), .empty,
            "正常退出返回前进程组必须已确认为空，忽略信号的后代不得残留")
    }

    func testNormalExitSettleBudgetExhaustionReportsCleanupFailure() async throws {
        // §3: when group-emptiness cannot be confirmed, return cleanupFailed instead of
        // silently succeeding. An always-live probe simulates the cannot-confirm case;
        // real descendants are still SIGKILLed with the whole group, with no leaks.
        let executable = try makeScript(
            """
            (trap '' TERM; exec 1>&- 2>&-; sleep 300) &
            exit 0
            """
        )
        let (session, _, _) = try makeSession(
            executable: executable,
            terminationGrace: 0.2,
            settleBudget: 0.5,
            groupLivenessProbe: { _ in .live }
        )

        let outcome = await session.run(timeout: 30)

        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertTrue(outcome.cleanupFailed, "正常退出同样受组空确认门约束")
    }

    func testUnknownGroupStateIsNeverTreatedAsEmpty() async throws {
        // §5.1: process-table read failure (unknown) and "confirmed no members" (empty)
        // must not be conflated; unknown is treated as not-empty, and budget exhaustion
        // reports a cleanup failure.
        let executable = try makeScript(
            """
            (trap '' TERM; exec 1>&- 2>&-; sleep 300) &
            exit 0
            """
        )
        let (session, _, _) = try makeSession(
            executable: executable,
            terminationGrace: 0.2,
            settleBudget: 0.5,
            groupLivenessProbe: { _ in .unknown }
        )

        let outcome = await session.run(timeout: 30)

        XCTAssertTrue(outcome.cleanupFailed, "进程表 unknown 不得当成组已空")
    }

    func testFileActionFailureLaunchesNothingAndEndsAsLaunchFailed() async throws {
        // §5.2 fault injection: an invalid descriptor makes adddup2 fail — no child
        // process may exist; return a diagnosable launchFailed. The session closes its
        // held descriptors after the spawn attempt (exactly once).
        let directory = try makeDirectory()
        let marker = directory.appendingPathComponent("started")
        let executable = try makeScript("echo 1 > \"\(marker.path)\"; sleep 300")
        let session = ManagedToolSession(
            executableURL: executable,
            arguments: [],
            stdoutFileDescriptor: -1,
            stderrFileDescriptor: -1
        )

        let outcome = await session.run(timeout: 30)

        XCTAssertTrue(outcome.launchFailed)
        XCTAssertEqual(session.childProcessID(), 0, "配置失败时不得真正 spawn")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "配置失败时不得执行子进程")
    }

    func testCancelDuringSettleIsReflectedInOutcome() async throws {
        // A cancellation arriving inside the settling window must not be dropped: the
        // final outcome must reflect cancelled, or a cancelled caller would see a
        // "clean normal exit" and parse the output as usual.
        let executable = try makeScript(
            """
            (trap '' TERM; exec 1>&- 2>&-; sleep 300) &
            exit 0
            """
        )
        let (session, _, _) = try makeSession(executable: executable, terminationGrace: 2.0)
        let runTask = Task { await session.run(timeout: 30) }
        // After read-end EOF, settle enters whole-group grace polling (TERM-ignoring
        // descendants stretch the window out to grace).
        try await Task.sleep(nanoseconds: 300_000_000)
        session.requestCancel()

        let outcome = await runTask.value

        XCTAssertTrue(outcome.cancelled, "settling 窗口内的取消必须反映到最终结果")
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertEqual(
            ProcessTree.groupState(session.processGroupID()), .empty,
            "返回前进程组必须已确认为空")
    }

    func testTimeoutTerminatesGroupAndFlagsOutcome() async throws {
        let executable = try makeScript("sleep 300")
        let (session, _, _) = try makeSession(executable: executable, terminationGrace: 0.5)
        let groupHolder = session

        let outcome = await session.run(timeout: 0.5)

        XCTAssertTrue(outcome.timedOut)
        XCTAssertFalse(outcome.cleanupFailed)
        XCTAssertFalse(ProcessTree.groupHasLiveMembers(groupHolder.processGroupID()))
    }
}
