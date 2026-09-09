import Foundation
import XCTest
import os

@testable import IDMEngine

/// Deterministic async test barrier providing strict coroutine interleaving control,
/// with zero reliance on Thread.sleep
final class AsyncBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if isOpened {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpened = true
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        for cont in ready {
            cont.resume()
        }
    }
}

final class MediaBufferBudgetTests: XCTestCase {

    // MARK: - Basic immediate reservation and release tests

    func testImmediateReservationWhenBudgetSufficient() async throws {
        let budget = MediaBufferBudget(capacity: 1024 * 1024)  // 1MB
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.availableBytes, 1024 * 1024)

        let reservation1 = try await budget.reserve(bytes: 256 * 1024)
        XCTAssertEqual(budget.reservedBytes, 256 * 1024)
        XCTAssertEqual(budget.availableBytes, 768 * 1024)
        XCTAssertEqual(budget.peakReservedBytes, 256 * 1024)

        let reservation2 = try await budget.reserve(bytes: 512 * 1024)
        XCTAssertEqual(budget.reservedBytes, 768 * 1024)

        reservation1.release()
        XCTAssertEqual(budget.reservedBytes, 512 * 1024)

        reservation2.release()
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.availableBytes, 1024 * 1024)
    }

    func testTryReserveReturnsNilWhenExceedingCapacity() {
        let budget = MediaBufferBudget(capacity: 64 * 1024)  // 64KB
        let res1 = budget.tryReserve(bytes: 40 * 1024)
        XCTAssertNotNil(res1)
        XCTAssertEqual(budget.reservedBytes, 40 * 1024)

        let res2 = budget.tryReserve(bytes: 30 * 1024)
        XCTAssertNil(res2)
        XCTAssertEqual(budget.reservedBytes, 40 * 1024)

        res1?.release()
        XCTAssertEqual(budget.reservedBytes, 0)

        let res3 = budget.tryReserve(bytes: 30 * 1024)
        XCTAssertNotNil(res3)
        XCTAssertEqual(budget.reservedBytes, 30 * 1024)
        res3?.release()
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    // MARK: - Deterministic boundary test: pre-enqueue cancellation race

    func testCancellationBeforeContinuationYieldsImmediateErrorWithoutGhostWaiter() async throws {
        let budget = MediaBufferBudget(capacity: 64 * 1024)
        let hold = try await budget.reserve(bytes: 64 * 1024)

        let task = Task {
            try await budget.reserve(bytes: 16 * 1024)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("已取消的任务必须抛出取消错误")
        } catch {
            guard case IDMError.cancelled = error else {
                XCTFail("预期 IDMError.cancelled，实际: \(error)")
                return
            }
        }

        XCTAssertEqual(budget.waitingCount, 0, "入队前取消绝不能在队列中留下僵尸节点")
        XCTAssertEqual(budget.reservedBytes, 64 * 1024)

        hold.release()
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    // MARK: - Deterministic P0-1 test: atomic rollback on cancellation during acquiringParent, waking the next waiter

    func testCancelDuringAcquiringParentRollsBackAllQuotasAndWakesNextWaiter() async throws {
        // 1. Parent budget 64KB, child budget 64KB (both >= 1024)
        let parentBudget = MediaBufferBudget(capacity: 64 * 1024)
        let childBudget = MediaBufferBudget(capacity: 64 * 1024, parent: parentBudget)

        // 2. Completely fill the parent budget (64KB)
        let parentHold = try await parentBudget.reserve(bytes: 64 * 1024)
        XCTAssertEqual(parentBudget.reservedBytes, 64 * 1024)
        XCTAssertEqual(parentBudget.availableBytes, 0)

        // 3. Install the deterministic synchronization barrier probe
        let barrier = AsyncBarrier()
        childBudget.testHook_onEnterAcquiringParent = {
            barrier.open()
        }

        // 4. Task 1 requests 32KB from the child budget (locally sufficient -> deduct local 32KB -> suspend on parent)
        let task1 = Task {
            try await childBudget.reserve(bytes: 32 * 1024, timeout: 5.0)
        }

        // 5. Wait deterministically until the acquiringParent state is reached, zero reliance on Thread.sleep
        await barrier.wait()

        // Verify the transient state: local reserved 32KB, available 32KB
        XCTAssertEqual(childBudget.reservedBytes, 32 * 1024)
        XCTAssertEqual(childBudget.availableBytes, 32 * 1024)

        // 6. Enqueue Task 2 requesting 64KB (only 32KB left locally, so Task 2 waits in the local queue)
        let task2 = Task {
            try await childBudget.reserve(bytes: 64 * 1024, timeout: 5.0)
        }

        let startWait = ContinuousClock.now
        while childBudget.waitingCount < 1 {
            if ContinuousClock.now - startWait > .seconds(2.0) {
                XCTFail("等待 Task 2 进入本地队列超时")
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(childBudget.waitingCount, 1)

        // 7. Precisely cancel Task 1 while it is in the acquiringParent state
        task1.cancel()

        do {
            _ = try await task1.value
            XCTFail("Task 1 必须抛出 cancelled")
        } catch {
            guard case IDMError.cancelled = error else {
                XCTFail("预期 IDMError.cancelled，实际收到: \(error)")
                return
            }
        }

        // 8. Key assertion: after Task 1 is cancelled, its 32KB local reservation must be
        // 100% atomically rolled back! The local quota returns to 64KB, and Task 2 immediately
        // leaves the queue, deducts 64KB locally, and applies to the parent!
        XCTAssertEqual(childBudget.waitingCount, 0, "Task 1 回滚后 Task 2 应出队进入 acquiringParent")
        XCTAssertEqual(childBudget.reservedBytes, 64 * 1024, "Task 2 成功占得本地 64KB")

        // 9. Release the parent hold; Task 2 completes successfully
        parentHold.release()
        let res2 = try await task2.value
        XCTAssertEqual(childBudget.reservedBytes, 64 * 1024)
        XCTAssertEqual(parentBudget.reservedBytes, 64 * 1024)

        res2.release()
        XCTAssertEqual(childBudget.reservedBytes, 0)
        XCTAssertEqual(parentBudget.reservedBytes, 0)
    }

    // MARK: - Deterministic P0-1 test: custom timeout is not amplified by hardcoding

    func testCustomTimeoutInheritedAcrossDrainAndNotAmplified() async throws {
        let parentBudget = MediaBufferBudget(capacity: 64 * 1024)
        let childBudget = MediaBufferBudget(capacity: 64 * 1024, parent: parentBudget)

        // Fill the parent completely
        let parentHold = try await parentBudget.reserve(bytes: 64 * 1024)

        let start = ContinuousClock.now
        do {
            // Set a short 50ms timeout
            _ = try await childBudget.reserve(bytes: 32 * 1024, timeout: 0.05)
            XCTFail("应当在 50ms 左右超时")
        } catch {
            guard case IDMError.timedOut = error else {
                XCTFail("预期 IDMError.timedOut，实际收到: \(error)")
                return
            }
        }
        let elapsed = ContinuousClock.now - start

        // Verify the elapsed time is reasonable (well under 500ms, definitely not amplified to 30s)
        XCTAssertLessThan(elapsed, .seconds(1.0), "50ms 超时绝不能被硬编码放大为 30s")
        XCTAssertEqual(childBudget.reservedBytes, 0, "超时后本地预留必须完全归零")

        parentHold.release()
        XCTAssertEqual(parentBudget.reservedBytes, 0)
    }

    // MARK: - Precise in-queue cancellation and FIFO fulfillment order

    func testInQueueCancellationRemovesTargetOnlyAndPreservesFIFODrain() async throws {
        let budget = MediaBufferBudget(capacity: 100 * 1024)
        let initialHold = try await budget.reserve(bytes: 100 * 1024)

        let task1Started = AsyncBarrier()
        let task2Started = AsyncBarrier()
        let task3Started = AsyncBarrier()

        let task1 = Task {
            task1Started.open()
            return try await budget.reserve(bytes: 30 * 1024)
        }
        let task2 = Task {
            task2Started.open()
            return try await budget.reserve(bytes: 40 * 1024)
        }
        let task3 = Task {
            task3Started.open()
            return try await budget.reserve(bytes: 30 * 1024)
        }

        await task1Started.wait()
        await task2Started.wait()
        await task3Started.wait()

        let startWait = ContinuousClock.now
        while budget.waitingCount < 3 {
            if ContinuousClock.now - startWait > .seconds(2.0) {
                XCTFail("等待 3 个 Waiter 排队超时")
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(budget.waitingCount, 3)

        // Precisely cancel the middle task2
        task2.cancel()

        do {
            _ = try await task2.value
            XCTFail("task2 必须抛出取消")
        } catch {
            guard case IDMError.cancelled = error else {
                XCTFail("预期 IDMError.cancelled，实际: \(error)")
                return
            }
        }

        XCTAssertEqual(budget.waitingCount, 2, "task2 取消后队列应恰好剩余 2 个 waiter")

        // Release the initial hold; task1 and task3 must be fulfilled in order
        initialHold.release()

        let res1 = try await task1.value
        let res3 = try await task3.value

        XCTAssertEqual(budget.reservedBytes, 60 * 1024)
        res1.release()
        res3.release()
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertEqual(budget.waitingCount, 0)
    }

    // MARK: - Cross-task starvation prevention and global fairness tests

    func testLocalWaitersDoNotHogGlobalCapacityAndPreventCrossTaskStarvation() async throws {
        let globalBudget = MediaBufferBudget(capacity: 64 * 1024)
        let taskBudgetA = MediaBufferBudget(capacity: 16 * 1024, parent: globalBudget)
        let taskBudgetB = MediaBufferBudget(capacity: 16 * 1024, parent: globalBudget)

        // 1. Task A fills its local 16KB
        let holdA = try await taskBudgetA.reserve(bytes: 16 * 1024)
        XCTAssertEqual(taskBudgetA.reservedBytes, 16 * 1024)
        XCTAssertEqual(globalBudget.reservedBytes, 16 * 1024)

        // 2. Task A spawns 2 queued segment waiters
        let taskA_Wait1 = Task { try await taskBudgetA.reserve(bytes: 8 * 1024) }
        let taskA_Wait2 = Task { try await taskBudgetA.reserve(bytes: 8 * 1024) }

        let startWait = ContinuousClock.now
        while taskBudgetA.waitingCount < 2 {
            if ContinuousClock.now - startWait > .seconds(2.0) {
                XCTFail("等待 Task A 排队超时")
                break
            }
            await Task.yield()
        }

        // Zero global quota consumed while queued
        XCTAssertEqual(globalBudget.reservedBytes, 16 * 1024, "排队中的子任务绝不能空占全局额度！")
        XCTAssertEqual(globalBudget.availableBytes, 48 * 1024)

        // 3. Task B requests a 16KB budget now -> succeeds immediately
        let holdB = try await taskBudgetB.reserve(bytes: 16 * 1024)
        XCTAssertEqual(taskBudgetB.reservedBytes, 16 * 1024)
        XCTAssertEqual(globalBudget.reservedBytes, 32 * 1024)

        holdB.release()
        XCTAssertEqual(taskBudgetB.reservedBytes, 0)
        XCTAssertEqual(globalBudget.reservedBytes, 16 * 1024)

        // 4. Task A releases its initial hold; queued segments are fulfilled in order
        holdA.release()
        let resA1 = try await taskA_Wait1.value
        let resA2 = try await taskA_Wait2.value

        XCTAssertEqual(taskBudgetA.reservedBytes, 16 * 1024)
        resA1.release()
        resA2.release()

        XCTAssertEqual(taskBudgetA.reservedBytes, 0)
        XCTAssertEqual(globalBudget.reservedBytes, 0)
    }
}
