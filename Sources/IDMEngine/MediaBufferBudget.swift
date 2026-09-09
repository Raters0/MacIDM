import Foundation
import os

// MARK: - Media buffer reservation handle

/// A handle for a media memory budget reservation.
///
/// Holding this handle means the specified number of bytes has been taken from the associated
/// ``MediaBufferBudget``. Supports parent-child composite reservations; bytes are returned
/// automatically in a cascade on `deinit` or an explicit ``release()`` call.
public final class MediaBufferReservation: @unchecked Sendable {
    private let budget: MediaBufferBudget
    public let bytes: Int64
    private let parentReservation: MediaBufferReservation?
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var isReleased = false

    init(budget: MediaBufferBudget, bytes: Int64, parentReservation: MediaBufferReservation? = nil) {
        self.budget = budget
        self.bytes = bytes
        self.parentReservation = parentReservation
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        release()
        lock.deallocate()
    }

    /// Explicitly returns the reserved bytes to the budget pool (thread-safe and idempotent).
    public func release() {
        os_unfair_lock_lock(lock)
        guard !isReleased else {
            os_unfair_lock_unlock(lock)
            return
        }
        isReleased = true
        os_unfair_lock_unlock(lock)

        budget.releaseInternal(bytes: bytes)
        parentReservation?.release()
    }
}

// MARK: - Media buffer budget manager

/// A thread-safe, race-free media buffer budget manager that supports local-first two-phase
/// hierarchical allocation and deterministic atomic cancellation.
public final class MediaBufferBudget: @unchecked Sendable {

    // MARK: - Internal state machine and deferred actions

    final class WaiterNode: @unchecked Sendable {
        let id: UUID
        let bytes: Int64
        let deadline: ContinuousClock.Instant?
        var state: WaiterState
        var continuation: CheckedContinuation<MediaBufferReservation, Error>?

        init(
            id: UUID = UUID(),
            bytes: Int64,
            deadline: ContinuousClock.Instant?,
            continuation: CheckedContinuation<MediaBufferReservation, Error>? = nil
        ) {
            self.id = id
            self.bytes = bytes
            self.deadline = deadline
            self.state = .pending
            self.continuation = continuation
        }

        func extractContinuation() -> CheckedContinuation<MediaBufferReservation, Error>? {
            let cont = continuation
            continuation = nil
            return cont
        }
    }

    enum WaiterState {
        case pending
        case waitingLocal(timeoutTask: Task<Void, Never>?)
        case acquiringParent(parentTask: Task<MediaBufferReservation, Error>, localReserved: Int64)
        case fulfilled
        case cancelled
        case timedOut
    }

    private enum DeferredAction {
        case resumeSuccess(CheckedContinuation<MediaBufferReservation, Error>, MediaBufferReservation)
        case resumeFailure(CheckedContinuation<MediaBufferReservation, Error>, Error)
        case cancelTask(Task<Void, Never>)
        case cancelParentTask(Task<MediaBufferReservation, Error>)
        case releaseReservation(MediaBufferReservation)
        case triggerTestHook(@Sendable () -> Void)
    }

    private struct State {
        var capacity: Int64
        var reservedBytes: Int64 = 0
        var peakReservedBytes: Int64 = 0
        var totalWaitCount: Int = 0
        var totalTimeoutCount: Int = 0
        var activeReservationsCount: Int = 0
        var waiters: [WaiterNode] = []
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var state: State
    public let parent: MediaBufferBudget?

    /// Internal test probe: fired when a Waiter enters the acquiringParent state
    /// (unit tests only, executed outside the lock).
    var testHook_onEnterAcquiringParent: (@Sendable () -> Void)?

    // MARK: - Initialization

    public init(capacity: Int64, parent: MediaBufferBudget? = nil) {
        self.parent = parent
        self.state = State(capacity: max(1024, capacity))
    }

    // MARK: - Public read-only state monitoring

    public var capacity: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return state.capacity
    }

    public var reservedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return state.reservedBytes
    }

    public var peakReservedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return state.peakReservedBytes
    }

    public var availableBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(0, state.capacity - state.reservedBytes)
    }

    public var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.waiters.count
    }

    public var totalWaitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.totalWaitCount
    }

    public var totalTimeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.totalTimeoutCount
    }

    // MARK: - Dynamic capacity adjustment

    public func setCapacity(_ newCapacity: Int64) {
        var actions: [DeferredAction] = []
        lock.lock()
        let clampedCapacity = max(1024, newCapacity)
        state.capacity = clampedCapacity

        let parentCap = parent?.capacity ?? Int64.max
        let effectiveLimit = min(clampedCapacity, parentCap)

        // When capacity shrinks, immediately reject and drop unsatisfiable waiters
        // from the queue to prevent indefinite waits
        var remainingWaiters: [WaiterNode] = []
        for waiter in state.waiters {
            if waiter.bytes > effectiveLimit {
                if case .waitingLocal(let timeoutTask) = waiter.state, let t = timeoutTask {
                    actions.append(.cancelTask(t))
                }
                waiter.state = .timedOut
                if let cont = waiter.extractContinuation() {
                    actions.append(.resumeFailure(cont, IDMError.resourceTooLarge(effectiveLimit)))
                }
            } else {
                remainingWaiters.append(waiter)
            }
        }
        state.waiters = remainingWaiters

        drainWaitersLocked(into: &actions)
        lock.unlock()
        executeActions(actions)
    }

    // MARK: - Non-blocking reservation

    /// Attempts a non-blocking reservation of the given number of bytes.
    /// Two-phase: atomically take from the local budget first, then try the parent;
    /// if the parent fails, roll back the local reservation atomically.
    public func tryReserve(bytes: Int64) -> MediaBufferReservation? {
        guard bytes > 0 else {
            return MediaBufferReservation(budget: self, bytes: 0)
        }

        // 1. Try reserving locally
        lock.lock()
        let (newReserved, overflow) = state.reservedBytes.addingReportingOverflow(bytes)
        guard !overflow, newReserved <= state.capacity, state.waiters.isEmpty else {
            lock.unlock()
            return nil
        }
        state.reservedBytes = newReserved
        state.peakReservedBytes = max(state.peakReservedBytes, state.reservedBytes)
        state.activeReservationsCount += 1
        lock.unlock()

        // 2. If a parent exists, try to acquire the parent quota
        var parentRes: MediaBufferReservation? = nil
        if let parent {
            if let p = parent.tryReserve(bytes: bytes) {
                parentRes = p
            } else {
                // Parent exhausted; roll back the local quota
                releaseInternal(bytes: bytes)
                return nil
            }
        }

        return MediaBufferReservation(budget: self, bytes: bytes, parentReservation: parentRes)
    }

    // MARK: - Async blocking reservation (core state machine)

    /// Reserves the given number of bytes.
    /// - Parameters:
    ///   - bytes: The number of bytes requested.
    ///   - timeout: Timeout in seconds. If <= 0 there is no timeout (wait indefinitely
    ///     until fulfilled or cancelled).
    public func reserve(bytes: Int64, timeout: TimeInterval = 30.0) async throws -> MediaBufferReservation {
        guard bytes > 0 else {
            return MediaBufferReservation(budget: self, bytes: 0)
        }
        if Task.isCancelled {
            throw IDMError.cancelled
        }

        let cap = capacity
        let parentCap = parent?.capacity ?? Int64.max
        let effectiveLimit = min(cap, parentCap)
        guard bytes <= effectiveLimit else {
            throw IDMError.resourceTooLarge(effectiveLimit)
        }

        // 1. Try the fast path
        if let fastRes = tryReserve(bytes: bytes) {
            return fastRes
        }

        let clock = ContinuousClock()
        let deadline: ContinuousClock.Instant?
        if timeout > 0 && timeout.isFinite {
            // Overflow-safe conversion
            let safeSeconds = min(timeout, 315360000.0)  // 10 years max
            deadline = clock.now + .seconds(safeSeconds)
        } else {
            deadline = nil
        }

        let node = WaiterNode(bytes: bytes, deadline: deadline)

        // 2. Enter the suspension state machine
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var actions: [DeferredAction] = []
                self.lock.lock()
                node.continuation = continuation

                if let dl = deadline, clock.now >= dl {
                    node.state = .timedOut
                    self.state.totalTimeoutCount += 1
                    if let cont = node.extractContinuation() {
                        actions.append(.resumeFailure(cont, IDMError.timedOut))
                    }
                    self.lock.unlock()
                    self.executeActions(actions)
                    return
                }

                switch node.state {
                case .cancelled:
                    // Race handling: onCancel fired before the continuation was entered
                    if let cont = node.extractContinuation() {
                        actions.append(.resumeFailure(cont, IDMError.cancelled))
                    }
                    self.lock.unlock()
                    self.executeActions(actions)
                    return

                case .pending:
                    // Check whether the local quota can be acquired directly
                    if self.state.reservedBytes + bytes <= self.state.capacity && self.state.waiters.isEmpty {
                        self.state.reservedBytes += bytes
                        self.state.peakReservedBytes = max(self.state.peakReservedBytes, self.state.reservedBytes)
                        self.state.activeReservationsCount += 1

                        if let parent = self.parent {
                            // Start the parent two-phase acquisition
                            self.startParentAcquireLocked(node: node, parent: parent, clock: clock, into: &actions)
                            self.lock.unlock()
                        } else {
                            node.state = .fulfilled
                            if let cont = node.extractContinuation() {
                                let res = MediaBufferReservation(budget: self, bytes: bytes)
                                actions.append(.resumeSuccess(cont, res))
                            }
                            self.lock.unlock()
                        }
                        self.executeActions(actions)
                        return
                    }

                    // Enqueue and wait for the local drain
                    self.state.totalWaitCount += 1
                    let waiterID = node.id
                    var timeoutTask: Task<Void, Never>? = nil
                    if let dl = deadline {
                        timeoutTask = Task { [weak self] in
                            do {
                                try await Task.sleep(until: dl, clock: clock)
                                self?.handleTimeout(waiterID: waiterID)
                            } catch {
                                // Ignore task cancellation
                            }
                        }
                    }

                    node.state = .waitingLocal(timeoutTask: timeoutTask)
                    self.state.waiters.append(node)
                    self.lock.unlock()

                default:
                    self.lock.unlock()
                }
            }
        } onCancel: {
            self.handleCancellation(node: node)
        }
    }

    // MARK: - Cross-level two-phase parent acquisition

    private func startParentAcquireLocked(
        node: WaiterNode,
        parent: MediaBufferBudget,
        clock: ContinuousClock,
        into actions: inout [DeferredAction]
    ) {
        let requestedBytes = node.bytes
        let deadline = node.deadline

        // Compute the remaining time (a nil deadline yields timeout 0, i.e. no timeout)
        let remainingSeconds: TimeInterval
        if let deadline {
            let remainingDuration = deadline - clock.now
            if remainingDuration > .zero {
                let (sec, attosec) = remainingDuration.components
                remainingSeconds = Double(sec) + Double(attosec) / 1_000_000_000_000_000_000.0
            } else {
                remainingSeconds = 0.001
            }
        } else {
            remainingSeconds = 0
        }

        // Create the managed parent acquisition Task
        let parentTask = Task<MediaBufferReservation, Error> {
            try await parent.reserve(bytes: requestedBytes, timeout: remainingSeconds)
        }

        node.state = .acquiringParent(parentTask: parentTask, localReserved: requestedBytes)

        // Register the test probe action (executed outside the lock)
        if let hook = testHook_onEnterAcquiringParent {
            actions.append(.triggerTestHook(hook))
        }

        // Observe the parent acquisition result asynchronously
        Task { [weak self, weak node] in
            let result = await parentTask.result
            guard let self = self, let node = node else {
                if case .success(let parentRes) = result {
                    parentRes.release()
                }
                return
            }
            self.handleParentAcquireCompletion(node: node, result: result)
        }
    }

    private func handleParentAcquireCompletion(
        node: WaiterNode,
        result: Result<MediaBufferReservation, Error>
    ) {
        var actions: [DeferredAction] = []
        lock.lock()

        guard case .acquiringParent = node.state else {
            // Already cancelled or timed out before the parent returned
            if case .success(let parentRes) = result {
                actions.append(.releaseReservation(parentRes))
            }
            drainWaitersLocked(into: &actions)
            lock.unlock()
            executeActions(actions)
            return
        }

        switch result {
        case .success(let parentRes):
            node.state = .fulfilled
            if let cont = node.extractContinuation() {
                let compositeLease = MediaBufferReservation(
                    budget: self,
                    bytes: node.bytes,
                    parentReservation: parentRes
                )
                actions.append(.resumeSuccess(cont, compositeLease))
            }

        case .failure(let error):
            // Parent acquisition failed/timed out/cancelled: roll back the locally
            // reserved quota and record the terminal state
            state.reservedBytes = max(0, state.reservedBytes - node.bytes)
            state.activeReservationsCount = max(0, state.activeReservationsCount - 1)
            node.state = (error is CancellationError || (error as? IDMError) == .cancelled) ? .cancelled : .timedOut
            if case .timedOut = node.state {
                state.totalTimeoutCount += 1
            }
            if let cont = node.extractContinuation() {
                actions.append(.resumeFailure(cont, error))
            }
        }

        drainWaitersLocked(into: &actions)
        lock.unlock()
        executeActions(actions)
    }

    // MARK: - Atomic cancellation and timeout transitions

    private func handleCancellation(node: WaiterNode) {
        var actions: [DeferredAction] = []
        lock.lock()

        switch node.state {
        case .pending:
            node.state = .cancelled
            if let cont = node.extractContinuation() {
                actions.append(.resumeFailure(cont, IDMError.cancelled))
            }

        case .waitingLocal(let timeoutTask):
            node.state = .cancelled
            if let t = timeoutTask {
                actions.append(.cancelTask(t))
            }
            if let idx = state.waiters.firstIndex(where: { $0.id == node.id }) {
                state.waiters.remove(at: idx)
            }
            if let cont = node.extractContinuation() {
                actions.append(.resumeFailure(cont, IDMError.cancelled))
            }

        case .acquiringParent(let parentTask, let localReserved):
            // Core rollback: atomically cancel the parent Task + return the locally
            // reserved quota + switch to a terminal state
            node.state = .cancelled
            actions.append(.cancelParentTask(parentTask))
            state.reservedBytes = max(0, state.reservedBytes - localReserved)
            state.activeReservationsCount = max(0, state.activeReservationsCount - 1)
            if let cont = node.extractContinuation() {
                actions.append(.resumeFailure(cont, IDMError.cancelled))
            }

        case .fulfilled, .cancelled, .timedOut:
            // Already in a terminal state; ignore
            break
        }

        drainWaitersLocked(into: &actions)
        lock.unlock()
        executeActions(actions)
    }

    private func handleTimeout(waiterID: UUID) {
        var actions: [DeferredAction] = []
        lock.lock()

        if let idx = state.waiters.firstIndex(where: { $0.id == waiterID }) {
            let node = state.waiters.remove(at: idx)
            if case .waitingLocal(let timeoutTask) = node.state {
                if let t = timeoutTask {
                    actions.append(.cancelTask(t))
                }
                node.state = .timedOut
                state.totalTimeoutCount += 1
                if let cont = node.extractContinuation() {
                    actions.append(.resumeFailure(cont, IDMError.timedOut))
                }
            }
        }

        drainWaitersLocked(into: &actions)
        lock.unlock()
        executeActions(actions)
    }

    // MARK: - Release and drain scheduling

    func releaseInternal(bytes: Int64) {
        guard bytes > 0 else { return }
        var actions: [DeferredAction] = []
        lock.lock()
        state.reservedBytes = max(0, state.reservedBytes - bytes)
        state.activeReservationsCount = max(0, state.activeReservationsCount - 1)
        drainWaitersLocked(into: &actions)
        lock.unlock()
        executeActions(actions)
    }

    private func drainWaitersLocked(into actions: inout [DeferredAction]) {
        let clock = ContinuousClock()
        let now = clock.now

        let parentCap = parent?.capacity ?? Int64.max
        let effectiveLimit = min(state.capacity, parentCap)

        while !state.waiters.isEmpty {
            let next = state.waiters[0]

            // 1. Drop timed-out nodes
            if let dl = next.deadline, now >= dl {
                state.waiters.removeFirst()
                if case .waitingLocal(let timeoutTask) = next.state, let t = timeoutTask {
                    actions.append(.cancelTask(t))
                }
                next.state = .timedOut
                state.totalTimeoutCount += 1
                if let cont = next.extractContinuation() {
                    actions.append(.resumeFailure(cont, IDMError.timedOut))
                }
                continue
            }

            // 2. Drop unsatisfiable over-limit nodes (e.g. after parent capacity shrank)
            if next.bytes > effectiveLimit {
                state.waiters.removeFirst()
                if case .waitingLocal(let timeoutTask) = next.state, let t = timeoutTask {
                    actions.append(.cancelTask(t))
                }
                next.state = .timedOut
                if let cont = next.extractContinuation() {
                    actions.append(.resumeFailure(cont, IDMError.resourceTooLarge(effectiveLimit)))
                }
                continue
            }

            // 3. Check whether the local quota fits (with addition overflow check)
            let (newReserved, overflow) = state.reservedBytes.addingReportingOverflow(next.bytes)
            if !overflow, newReserved <= state.capacity {
                state.waiters.removeFirst()
                state.reservedBytes = newReserved
                state.peakReservedBytes = max(state.peakReservedBytes, state.reservedBytes)
                state.activeReservationsCount += 1

                if case .waitingLocal(let timeoutTask) = next.state, let t = timeoutTask {
                    actions.append(.cancelTask(t))
                }

                if let parent = self.parent {
                    // Acquire from the parent, forwarding the remaining deadline
                    startParentAcquireLocked(node: next, parent: parent, clock: clock, into: &actions)
                } else {
                    next.state = .fulfilled
                    if let cont = next.extractContinuation() {
                        let res = MediaBufferReservation(budget: self, bytes: next.bytes)
                        actions.append(.resumeSuccess(cont, res))
                    }
                }
            } else {
                break
            }
        }
    }

    private func executeActions(_ actions: [DeferredAction]) {
        for action in actions {
            switch action {
            case .resumeSuccess(let continuation, let reservation):
                continuation.resume(returning: reservation)
            case .resumeFailure(let continuation, let error):
                continuation.resume(throwing: error)
            case .cancelTask(let task):
                task.cancel()
            case .cancelParentTask(let task):
                task.cancel()
            case .releaseReservation(let res):
                res.release()
            case .triggerTestHook(let hook):
                hook()
            }
        }
    }

    // MARK: - Test helpers

    public func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        state.peakReservedBytes = state.reservedBytes
        state.totalWaitCount = 0
        state.totalTimeoutCount = 0
    }
}

// MARK: - Global budget singleton

public enum GlobalMediaBufferBudget {
    private static let globalBudget = MediaBufferBudget(
        capacity: DownloadResourceLimits.maximumBufferedResourceBytes
    )

    public static var shared: MediaBufferBudget {
        globalBudget
    }

    public static func configure(capacity: Int64) {
        globalBudget.setCapacity(capacity)
    }
}
