import Darwin
import Dispatch
import Foundation

/// Final outcome of one external-tool session. Exactly one continuation
/// delivers it; every completion path (normal exit, cancel, timeout, launch
/// failure) funnels through the same finish gate.
struct ManagedToolOutcome: Sendable {
    /// Exit status of the direct child. `nil` when the child was killed or
    /// never spawned; callers use `cancelled`/`timedOut` for those paths.
    var exitStatus: Int32?
    var cancelled = false
    var timedOut = false
    var launchFailed = false
    var launchFailureDescription = ""
    /// The group could not be verified empty within the settle budget. Must
    /// surface as a diagnosable failure and block the next retry — it is
    /// never silently treated as success.
    var cleanupFailed = false
}

/// Thrown when the external tool cannot be spawned at all.
struct ManagedToolLaunchError: LocalizedError {
    let detail: String
    var errorDescription: String? { "tool launch failed: \(detail)" }
}

/// Shared lifecycle wrapper for external tools (yt-dlp) used by both the
/// inspector and the download runner:
///
/// - The child is spawned into its **own dedicated process group**
///   (`POSIX_SPAWN_SETPGROUP`, the child becomes the leader, pgid == pid)
///   before it can spawn anything itself. Cancellation/timeout signal the
///   whole group — group membership survives reparenting, so a root that
///   exits first on SIGTERM can no longer hide TERM-resistant descendants
///   re-attached to launchd, and descendants born during the grace period
///   are covered too.
/// - One explicit state machine (`idle → launching → running → settling /
///   terminating → finished`) guarded by a single lock. A cancel arriving
///   while `idle`/`launching` only records a flag; it never ends the
///   continuation while still allowing the spawn — closing the
///   cancel-before-launch race.
/// - The continuation is resumed exactly once, by whichever path observes
///   the completion conditions first: child reaped + reader EOF + **group
///   verified empty** (normal exit), termination settled + reader EOF, or
///   launch failure. Normal exit goes through the same "group empty" gate
///   as cancel/timeout: a root that exits 0 can still leave TERM-resistant
///   descendants in the group.
/// - Reader EOF is part of the gate, so descendants holding the stdout/
///   stderr or PTY slave keep the continuation open until they are gone.
final class ManagedToolSession: @unchecked Sendable {
    enum TerminationReason {
        case cancel
        case timeout
    }

    private enum State {
        case idle
        case launching
        case running
        /// Group-empty confirmation after a normal exit: the direct child is
        /// reaped and the reader is at EOF, but the process group must be
        /// explicitly verified empty (or the settle budget exhausted with
        /// `cleanupFailed`) before the continuation may finish.
        case settling
        case terminating
        case finished
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var continuation: CheckedContinuation<ManagedToolOutcome, Never>?
    private(set) var outcome = ManagedToolOutcome()
    private var cancelRequested = false
    private var timeoutRequested = false
    private var childReaped = false
    private var readerFinished = false
    private var terminationSettled = false
    /// Verdict of the settling phase: the group is confirmed empty (or the
    /// budget exhausted). Only once it is set does the `.settling` state
    /// satisfy the completion gate.
    private var settleResolved = false
    private var descriptorsClosed = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var pid: pid_t = 0
    private var groupID: pid_t = 0

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let stdoutFileDescriptor: Int32
    private let stderrFileDescriptor: Int32
    private let settleBudget: TimeInterval
    /// Grace is tunable after init so one session can serve both the normal
    /// stop path (longer grace) and the stall path (fast SIGKILL escalation).
    private var terminationGrace: TimeInterval
    /// Test seam: runs after `launching` is recorded but before the final
    /// cancel check and spawn, so cancel-before-launch races become
    /// deterministic instead of probabilistic.
    private let launchBarrier: (() -> Void)?
    /// Group liveness check; injectable so settle-budget exhaustion becomes
    /// testable without an unkillable process. Three-state: `.unknown`
    /// (process-table read failure) must never be treated as `.empty`
    /// of the process group.
    private let groupLivenessProbe: @Sendable (pid_t) -> ProcessTree.GroupState

    /// The session takes ownership of both descriptors and closes them after
    /// the spawn attempt (success or failure), so the caller's reader side
    /// reaches EOF exactly when the whole group is gone. `environment` is
    /// the child's **complete** environment when provided; `nil` inherits
    /// the App's environment.
    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdoutFileDescriptor: Int32,
        stderrFileDescriptor: Int32,
        terminationGrace: TimeInterval = 3.0,
        settleBudget: TimeInterval = 5.0,
        launchBarrier: (() -> Void)? = nil,
        groupLivenessProbe: (@Sendable (pid_t) -> ProcessTree.GroupState)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment ?? ProcessInfo.processInfo.environment
        self.stdoutFileDescriptor = stdoutFileDescriptor
        self.stderrFileDescriptor = stderrFileDescriptor
        self.terminationGrace = terminationGrace
        self.settleBudget = settleBudget
        self.launchBarrier = launchBarrier
        self.groupLivenessProbe = groupLivenessProbe ?? { ProcessTree.groupState($0) }
    }

    /// Direct child PID (`0` before a successful spawn).
    func childProcessID() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    /// Adjust the SIGTERM→SIGKILL grace before requesting termination.
    func setTerminationGrace(_ grace: TimeInterval) {
        lock.lock()
        terminationGrace = grace
        lock.unlock()
    }

    /// Stable process group ID (`0` before a successful spawn).
    func processGroupID() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return groupID
    }

    /// Spawns the tool and awaits the full lifecycle. Never throws; inspect
    /// the returned outcome. The continuation ends only after the child is
    /// reaped, the group is verified empty (or the settle budget is
    /// exhausted), and the reader side reported EOF.
    func run(timeout: TimeInterval) async -> ManagedToolOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ManagedToolOutcome, Never>) in
            lock.lock()
            guard state == .idle, self.continuation == nil else {
                lock.unlock()
                var reused = ManagedToolOutcome()
                reused.launchFailed = true
                reused.launchFailureDescription = "session already used"
                continuation.resume(returning: reused)
                return
            }
            state = .launching
            self.continuation = continuation
            lock.unlock()
            // The spawn pipeline runs on a dedicated thread: the injectable
            // launch barrier (deterministic race testing) may block safely and
            // never occupies a cooperative-pool thread (blocking pool threads
            // would deadlock tests).
            Thread.detachNewThread { [weak self] in
                self?.spawnPipeline(timeout: timeout)
            }
        }
    }

    /// Spawn pipeline after `launching`: barrier → final cancel check →
    /// establish the process group → record the running identity. The final
    /// cancel check and the spawn share one synchronous path: a cancel
    /// arriving before spawn skips it, one arriving during spawn enters
    /// termination right after spawn completes — the process is never left
    /// unmanaged (§4).
    private func spawnPipeline(timeout: TimeInterval) {
        // Deterministic race testing: cancellation may be injected while
        // the session is `launching` but has not spawned yet.
        launchBarrier?()

        lock.lock()
        if cancelRequested || timeoutRequested {
            outcome.cancelled = cancelRequested
            outcome.timedOut = !cancelRequested && timeoutRequested
            closeDescriptorsLocked()
            let decision = pendingResumeLocked()
            let snapshot = outcome
            lock.unlock()
            applyGateDecision(decision, snapshot: snapshot)
            return
        }
        lock.unlock()

        do {
            let spawned = try spawnInOwnGroup()
            lock.lock()
            pid = spawned
            groupID = spawned
            state = .running
            // Capture the concrete termination reasons once under the lock;
            // after unlocking, use only the immutable snapshot and never
            // re-read the shared mutable flags.
            let pendingCancel = cancelRequested
            let pendingTimeout = timeoutRequested
            lock.unlock()
            startExitWatcher()
            scheduleTimeout(timeout)
            if pendingCancel {
                requestCancel()
            } else if pendingTimeout {
                requestTimeout()
            }
        } catch {
            lock.lock()
            closeDescriptorsLocked()
            outcome.launchFailed = true
            outcome.launchFailureDescription = String(describing: error)
            let decision = pendingResumeLocked()
            let snapshot = outcome
            lock.unlock()
            applyGateDecision(decision, snapshot: snapshot)
        }
    }

    /// Requests termination of the whole process group. Safe in every state:
    /// before launch it only records the flag, after launch it starts the
    /// group termination.
    func requestCancel() {
        lock.lock()
        cancelRequested = true
        let started = beginTerminationLocked(reason: .cancel)
        lock.unlock()
        if started {
            Task { [weak self] in
                await self?.terminateGroup()
            }
        }
    }

    /// Timeout path: identical group termination, distinct outcome flag.
    func requestTimeout() {
        lock.lock()
        timeoutRequested = true
        let started = beginTerminationLocked(reason: .timeout)
        lock.unlock()
        if started {
            Task { [weak self] in
                await self?.terminateGroup()
            }
        }
    }

    /// The caller's output reader reached EOF: every write end of the pipes
    /// (or PTY slave) is closed, i.e. no group member still holds the
    /// channels. Part of the completion gate.
    func markReaderFinished() {
        lock.lock()
        readerFinished = true
        let decision = pendingResumeLocked()
        let snapshot = outcome
        lock.unlock()
        applyGateDecision(decision, snapshot: snapshot)
    }

    // MARK: - State machine internals

    /// Outcome of one completion-gate evaluation under the lock: either the
    /// continuation may resume (exactly once), or the normal-exit path must
    /// start the group-empty settlement before finishing (§3).
    private struct GateDecision {
        var continuation: CheckedContinuation<ManagedToolOutcome, Never>?
        var startSettle = false

        func resume(with snapshot: ManagedToolOutcome) {
            continuation?.resume(returning: snapshot)
        }
    }

    /// Unified post-unlock actions: when settlement is needed, start a
    /// separate Task (never do process-table queries or sleeps under the
    /// lock), then resume the continuation (if any).
    private func applyGateDecision(_ decision: GateDecision, snapshot: ManagedToolOutcome) {
        if decision.startSettle {
            Task { [weak self] in
                await self?.settleGroupAfterNormalExit()
            }
        }
        decision.resume(with: snapshot)
    }

    /// Lock must be held. Returns true when this call actually started the
    /// termination (state was `running`).
    private func beginTerminationLocked(reason: TerminationReason) -> Bool {
        guard state == .running else { return false }
        state = .terminating
        outcome.cancelled = reason == .cancel
        outcome.timedOut = reason == .timeout
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        return true
    }

    /// Lock must be held. Returns the gate decision: the continuation to
    /// resume exactly once, or the instruction to start the normal-exit
    /// group-empty settlement.
    private func pendingResumeLocked() -> GateDecision {
        guard let continuation else { return GateDecision() }
        var decision = GateDecision()
        if outcome.launchFailed {
            // complete below
        } else if state == .launching, cancelRequested || timeoutRequested {
            // Cancelled/timed out before an actual spawn: finish directly,
            // never wait for a process that does not exist.
            // complete below
        } else if state == .running, childReaped, readerFinished {
            // A normal exit must not finish directly (§3): after the root
            // exits 0 the group may still hold descendants that ignore
            // signals and closed their output channels. Enter the same
            // group-empty confirmation gate as cancel/timeout.
            state = .settling
            decision.startSettle = true
            return decision
        } else if state == .settling, settleResolved {
            // complete below
        } else if state == .terminating, terminationSettled, readerFinished {
            // complete below
        } else {
            return decision
        }
        state = .finished
        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        decision.continuation = continuation
        return decision
    }

    private func closeDescriptorsLocked() {
        guard !descriptorsClosed else { return }
        descriptorsClosed = true
        close(stdoutFileDescriptor)
        if stderrFileDescriptor != stdoutFileDescriptor {
            close(stderrFileDescriptor)
        }
    }

    private func scheduleTimeout(_ timeout: TimeInterval) {
        guard timeout.isFinite, timeout > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.requestTimeout()
        }
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Blocks a dedicated thread until the direct child is reaped, then
    /// records the exit status and evaluates the completion gate.
    private func startExitWatcher() {
        let watchedPID = pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            let reaped = waitpid(watchedPID, &status, 0)
            guard let self else { return }
            self.lock.lock()
            if reaped > 0 {
                if status & 0x7F == 0 {
                    self.outcome.exitStatus = (status >> 8) & 0xFF
                } else {
                    // Killed by a signal: no meaningful exit status; the
                    // cancellation/timeout flags carry the semantics.
                    self.outcome.exitStatus = nil
                }
            }
            self.childReaped = true
            let decision = self.pendingResumeLocked()
            let snapshot = self.outcome
            self.lock.unlock()
            self.applyGateDecision(decision, snapshot: snapshot)
        }
    }

    /// Group-empty confirmation for a normal exit (§3): the direct child is
    /// reaped and the reader is at EOF, but the group may still hold
    /// descendants that ignore signals and closed their output channels.
    /// Same controlled shutdown as cancel/timeout: whole-group SIGTERM →
    /// bounded grace → whole-group SIGKILL if needed → wait for the group to
    /// empty; if the budget cannot confirm emptiness, `cleanupFailed = true`
    /// and no retry may proceed.
    private func settleGroupAfterNormalExit() async {
        let group = processGroupID()
        if group > 0, groupLivenessProbe(group) != .empty {
            await signalGroupForTermination(group)
        }
        let deadline = Date().addingTimeInterval(settleBudget)
        let verifiedEmpty = await waitGroupVerifiedEmpty(group, deadline: deadline)
        finishSettlement(verifiedEmpty: verifiedEmpty)
    }

    /// The settling verdict returns to the single completion gate;
    /// synchronous, so lock operations are not in an async context.
    private func finishSettlement(verifiedEmpty: Bool) {
        lock.lock()
        settleResolved = true
        // Cancel/timeout arriving inside the settling window bypasses
        // beginTerminationLocked (the state is no longer running) and must
        // be reflected into the final result here, or a cancelled caller
        // would receive a "clean normal exit".
        if cancelRequested {
            outcome.cancelled = true
        } else if timeoutRequested {
            outcome.timedOut = true
        }
        outcome.cleanupFailed = !verifiedEmpty
        let decision = pendingResumeLocked()
        let snapshot = outcome
        lock.unlock()
        applyGateDecision(decision, snapshot: snapshot)
    }

    /// Whole-group SIGTERM → bounded grace → whole-group SIGKILL if still not
    /// empty. Process-group membership is unaffected by reparenting to
    /// launchd, so it covers TERM-resistant survivors after the root exits
    /// first and descendants spawned during the grace period. `.unknown`
    /// (process-table read failure) is treated as still alive — never
    /// released early (§5.1).
    private func signalGroupForTermination(_ group: pid_t) async {
        guard group > 0 else { return }
        kill(-group, SIGTERM)
        let graceDeadline = Date().addingTimeInterval(terminationGrace)
        while Date() < graceDeadline {
            if groupLivenessProbe(group) == .empty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if groupLivenessProbe(group) != .empty {
            kill(-group, SIGKILL)
        }
    }

    /// Polls until the group is confirmed empty or the deadline arrives;
    /// `.unknown` never counts as empty.
    private func waitGroupVerifiedEmpty(_ group: pid_t, deadline: Date) async -> Bool {
        guard group > 0 else { return true }
        while true {
            if groupLivenessProbe(group) == .empty { return true }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return groupLivenessProbe(group) == .empty
    }

    /// SIGTERM → grace → SIGKILL on the whole group, then verify the group
    /// is empty and the child is reaped within the settle budget.
    private func terminateGroup() async {
        let group = processGroupID()
        await signalGroupForTermination(group)
        let settleDeadline = Date().addingTimeInterval(settleBudget)
        var settled = group <= 0
        while !settled && Date() < settleDeadline {
            // Settled requires an empty group plus a reaped direct child;
            // `.unknown` does not count as empty (§5.1).
            if groupLivenessProbe(group) == .empty, childAlreadyReaped() {
                settled = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !settled {
            settled = group <= 0 || (groupLivenessProbe(group) == .empty && childAlreadyReaped())
        }
        finishTermination(settled: settled)
    }

    private func childAlreadyReaped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return childReaped
    }

    private func finishTermination(settled: Bool) {
        lock.lock()
        terminationSettled = true
        outcome.cleanupFailed = !settled
        let decision = pendingResumeLocked()
        let snapshot = outcome
        lock.unlock()
        applyGateDecision(decision, snapshot: snapshot)
    }

    // MARK: - Spawn

    private func spawnInOwnGroup() throws -> pid_t {
        defer {
            // The session's copies of the write ends must die here in every
            // case, otherwise the caller's reader would never reach EOF.
            lock.lock()
            closeDescriptorsLocked()
            lock.unlock()
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Establish the dedicated process group at spawn time — before the
        // child can spawn anything itself. The child becomes the leader of
        // a brand-new group (pgid == its PID); every descendant it later
        // spawns inherits the group. Every configuration step's return code
        // must be checked: after any failure the spawn must not continue,
        // and upper layers must not assume `pgid == pid` while the
        // process-group attribute is unconfirmed and signal `-pid`
        // before returning control to the caller.
        var status = posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawnattr_setflags rc=\(status)")
        }
        status = posix_spawnattr_setpgroup(&attributes, 0)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawnattr_setpgroup rc=\(status)")
        }
        // Signal dispositions are inherited from the parent — and the App,
        // the test runner or an IDE harness may ignore/block SIGTERM, which
        // would make the spawned tool (and its bash trap scripts) immune to
        // the group TERM. Reset every disposition to default and start with
        // an empty signal mask so termination semantics are deterministic.
        var defaultSet = sigset_t()
        sigfillset(&defaultSet)
        status = posix_spawnattr_setsigdefault(&attributes, &defaultSet)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawnattr_setsigdefault rc=\(status)")
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        status = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawnattr_setsigmask rc=\(status)")
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Every file-action step checks its return code the same way:
        // continuing the spawn after any failure would let upper layers
        // make wrong assumptions about FD bindings (§5.2).
        status = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn_file_actions_addopen rc=\(status)")
        }
        status = posix_spawn_file_actions_adddup2(&actions, stdoutFileDescriptor, STDOUT_FILENO)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn_file_actions_adddup2 stdout rc=\(status)")
        }
        status = posix_spawn_file_actions_adddup2(&actions, stderrFileDescriptor, STDERR_FILENO)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn_file_actions_adddup2 stderr rc=\(status)")
        }
        // Close the original descriptors after dup2 so EOF depends only on
        // the group's write ends. PTY/pipe fallbacks route both streams
        // through one descriptor — close it exactly once.
        status = posix_spawn_file_actions_addclose(&actions, stdoutFileDescriptor)
        guard status == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn_file_actions_addclose stdout rc=\(status)")
        }
        if stderrFileDescriptor != stdoutFileDescriptor {
            status = posix_spawn_file_actions_addclose(&actions, stderrFileDescriptor)
            guard status == 0 else {
                throw ManagedToolLaunchError(
                    detail: "posix_spawn_file_actions_addclose stderr rc=\(status)")
            }
        }

        let argvStrings = [executableURL.path] + arguments
        var argv = argvStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv.compactMap({ $0 }) {
                free(pointer)
            }
        }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in envp.compactMap({ $0 }) {
                free(pointer)
            }
        }

        var spawned: pid_t = 0
        let spawnStatus = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &spawned,
                    executableURL.path,
                    &actions,
                    &attributes,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }
        guard spawnStatus == 0 else {
            throw ManagedToolLaunchError(detail: "posix_spawn rc=\(spawnStatus) errno=\(errno)")
        }
        return spawned
    }
}
