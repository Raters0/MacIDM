import Foundation
import XCTest

@testable import MacIDMApp

final class AppQueueTests: XCTestCase {
    /// Fixed calendar/date helper: 2026-08-10 is a Monday.
    private func date(dayOffset: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        // 2026-08-10 Monday ... 2026-08-16 Sunday
        components.day = 10 + dayOffset
        components.hour = minute / 60
        components.minute = minute % 60
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func schedule(
        days: Int = 127,
        start: Int = 0,
        stop: Int? = nil
    ) -> AppQueue {
        AppQueue(
            name: "夜间队列",
            scheduleEnabled: true,
            scheduleDays: days,
            scheduleStartMinutes: start,
            scheduleStopMinutes: stop
        )
    }

    func testDisabledScheduleIsAlwaysActive() {
        let queue = AppQueue(name: "普通队列")
        XCTAssertTrue(queue.scheduleSaysActive(at: Date()))
    }

    func testWindowInsideAndOutside() {
        let queue = schedule(start: 22 * 60, stop: 6 * 60)
        // Wednesday 23:30 → inside a window that crosses midnight.
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 2, minute: 23 * 60 + 30)))
        // Thursday 05:59 → still inside.
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 3, minute: 5 * 60 + 59)))
        // Thursday 06:00 → boundary is exclusive.
        XCTAssertFalse(queue.scheduleSaysActive(at: date(dayOffset: 3, minute: 6 * 60)))
        // Wednesday 12:00 → outside.
        XCTAssertFalse(queue.scheduleSaysActive(at: date(dayOffset: 2, minute: 12 * 60)))
    }

    func testSimpleWindowWithoutStopRunsUntilMidnight() {
        let queue = schedule(start: 8 * 60, stop: nil)
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 0, minute: 8 * 60)))
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 0, minute: 23 * 60 + 59)))
        XCTAssertFalse(queue.scheduleSaysActive(at: date(dayOffset: 0, minute: 7 * 60 + 59)))
    }

    func testDayBitmaskIsRespected() {
        // Only Monday (bit 0) and Sunday (bit 6).
        let queue = schedule(days: 0b1000001, start: 0, stop: nil)
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 0, minute: 12 * 60)))
        XCTAssertTrue(queue.scheduleSaysActive(at: date(dayOffset: 6, minute: 12 * 60)))
        XCTAssertFalse(queue.scheduleSaysActive(at: date(dayOffset: 2, minute: 12 * 60)))
    }

    func testConcurrencyIsClampedToSupportedRange() {
        let small = AppQueue(name: "a", concurrency: 0)
        let large = AppQueue(name: "b", concurrency: 999)
        XCTAssertEqual(small.concurrency, AppQueue.concurrencyRange.lowerBound)
        XCTAssertEqual(large.concurrency, AppQueue.concurrencyRange.upperBound)
    }

    func testNameIsTrimmedAndBounded() {
        let padded = "  " + String(repeating: "队", count: 100) + "  "
        let queue = AppQueue(name: padded)
        XCTAssertEqual(queue.name.count, AppQueue.maximumNameLength)
        XCTAssertFalse(queue.name.contains(" "))
        XCTAssertEqual(AppQueue(name: "   ").name, "")
    }

    func testStorePersistsQueuesAndTaskQueueBinding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)

        let queue = AppQueue(
            name: "夜间",
            concurrency: 3,
            orderMode: .fifo,
            stopOnEmpty: true,
            scheduleEnabled: true,
            scheduleDays: 0b0011111,
            scheduleStartMinutes: 22 * 60,
            scheduleStopMinutes: 6 * 60,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.saveQueues([queue])

        var task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.bin",
            destinationPath: directory.appendingPathComponent("file.bin").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.queueID = queue.id
        try store.save([task])

        let loadedQueue = try XCTUnwrap(store.loadQueues().first)
        XCTAssertEqual(loadedQueue, queue)

        let loadedTask = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loadedTask.queueID, queue.id)

        // Replacing the queue set atomically drops removed queues.
        try store.saveQueues([])
        XCTAssertTrue(try store.loadQueues().isEmpty)
    }

    func testLegacyTasksLoadWithoutQueueBinding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMQueueLegacyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/legacy.bin",
            destinationPath: directory.appendingPathComponent("legacy.bin").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .completed,
            receivedBytes: 10,
            totalBytes: 10,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        try store.save([task])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertNil(loaded.queueID)
        XCTAssertTrue(SidebarFilter.queue(nil).matches(loaded))
    }
}
