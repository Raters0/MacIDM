import XCTest

@testable import IDMEngine

final class DynamicRateLimiterTests: XCTestCase {
    /// A counting limiter used to observe whether acquire calls reach the
    /// current inner implementation after a reconfigure.
    private actor CountingLimiter: DownloadRateLimiting {
        private(set) var acquiredBytes: Int64 = 0

        func acquire(_ byteCount: Int64) async throws {
            acquiredBytes += byteCount
        }

        func reset() {
            acquiredBytes = 0
        }
    }

    func testNilInnerMeansUnlimited() async throws {
        let limiter = DynamicRateLimiter()
        // Must complete without sleeping or throwing.
        try await limiter.acquire(1_048_576)
    }

    func testReconfigureSwapsTheActiveLimiterForInFlightTasks() async throws {
        let first = CountingLimiter()
        let second = CountingLimiter()
        let limiter = DynamicRateLimiter(inner: first)

        try await limiter.acquire(100)
        var acquired = await first.acquiredBytes
        XCTAssertEqual(acquired, 100)

        // Simulates the app applying a changed speed-limit setting: the same
        // wrapper instance is reconfigured while tasks hold references to it.
        limiter.reconfigure(second)
        try await limiter.acquire(250)
        acquired = await first.acquiredBytes
        XCTAssertEqual(acquired, 100, "old limiter must not see new traffic")
        acquired = await second.acquiredBytes
        XCTAssertEqual(acquired, 250)

        // Reconfiguring back to unlimited stops rate limiting entirely.
        limiter.reconfigure(nil)
        try await limiter.acquire(500)
        acquired = await second.acquiredBytes
        XCTAssertEqual(acquired, 250)
    }
}
