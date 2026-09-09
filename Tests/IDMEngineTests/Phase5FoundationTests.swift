import Foundation
import XCTest

@testable import IDMEngine

final class Phase5FoundationTests: XCTestCase {
    func testTokenBucketUsesInjectedClockAndSharesReservations() async throws {
        let clock = TestRateClock()
        let limiter = try TokenBucketRateLimiter(
            rateBytesPerSecond: 1_000,
            burstBytes: 1_000,
            clock: clock.rateLimitClock
        )

        try await limiter.acquire(1_000)
        XCTAssertEqual(clock.read(), 0)
        try await limiter.acquire(1_000)
        XCTAssertGreaterThanOrEqual(clock.read(), 1_000_000_000)
        try await limiter.acquire(500)
        XCTAssertGreaterThanOrEqual(clock.read(), 1_000_000_000)
    }

    func testCombinedLimiterAppliesGlobalAndTaskBuckets() async throws {
        let clock = TestRateClock()
        let global = try TokenBucketRateLimiter(
            rateBytesPerSecond: 1_000,
            burstBytes: 1_000,
            clock: clock.rateLimitClock
        )
        let task = try TokenBucketRateLimiter(
            rateBytesPerSecond: 2_000,
            burstBytes: 2_000,
            clock: clock.rateLimitClock
        )
        let combined = CombinedRateLimiter(global: global, task: task)

        try await combined.acquire(1_000)
        try await combined.acquire(1_000)
        XCTAssertGreaterThanOrEqual(clock.read(), 1_000_000_000)
    }

    func testTokenBucketDoesNotExpandBurstForLargeChunks() async throws {
        let clock = TestRateClock()
        let limiter = try TokenBucketRateLimiter(
            rateBytesPerSecond: 1_000,
            burstBytes: 1_000,
            clock: clock.rateLimitClock
        )

        try await limiter.acquire(1_500)
        XCTAssertEqual(clock.read(), 500_000_000)
        try await limiter.acquire(1_000)
        XCTAssertEqual(clock.read(), 1_500_000_000)
    }

    func testProxyConfigurationStoresOnlyKeychainReference() throws {
        let credential = try ProxyCredentialReference(keychainAccount: "proxy-account")
        let configuration = try ProxyConfiguration(
            kind: .https,
            host: "proxy.example.test",
            port: 8443,
            credentialReference: credential
        )
        let encoded = try JSONEncoder().encode(configuration)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("proxy-account"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertThrowsError(
            try ProxyConfiguration(kind: .http, host: "https://proxy.example.test/path", port: 80)
        )
        XCTAssertThrowsError(
            try ProxyConfiguration(kind: .http, host: "proxy.example.test", port: 65_536)
        )
    }
}

private final class TestRateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    var rateLimitClock: RateLimitClock {
        RateLimitClock(
            nowNanoseconds: { [weak self] in self?.read() ?? 0 },
            sleep: { [weak self] duration in self?.advance(duration) }
        )
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }

    func advance(_ duration: UInt64) {
        lock.lock()
        nanoseconds += duration
        lock.unlock()
    }
}
