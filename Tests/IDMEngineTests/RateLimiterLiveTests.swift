import XCTest

@testable import IDMEngine

final class RateLimiterLiveTests: XCTestCase {
    func testDynamicLimiterActuallyThrottles() async throws {
        let limiter = DynamicRateLimiter()
        limiter.reconfigure(try TokenBucketRateLimiter(rateBytesPerSecond: 1_048_576))
        let start = Date()
        // Simulate a 20MB download in 256KB slices (the engine's chunking).
        for _ in 0..<80 {
            try await limiter.acquire(262_144)
        }
        let elapsed = Date().timeIntervalSince(start)
        // 20MB at 1MB/s ≈ 20s (minus the initial 1MB burst).
        XCTAssertGreaterThan(elapsed, 15, "expected ~19s of throttling, got \(elapsed)s")
    }
}
