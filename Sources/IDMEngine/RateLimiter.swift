import Foundation

public enum RateLimitConfigurationError: Error, Equatable, Sendable {
    case invalidRate
    case invalidBurst
}

extension RateLimitConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRate: "限速必须大于 0 字节/秒。"
        case .invalidBurst: "令牌桶容量必须大于 0。"
        }
    }
}

public struct RateLimitClock: Sendable {
    public let nowNanoseconds: @Sendable () -> UInt64
    public let sleep: @Sendable (UInt64) async throws -> Void

    public init(
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }

    public static let system = RateLimitClock(
        nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        sleep: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

public protocol DownloadRateLimiting: Sendable {
    func acquire(_ byteCount: Int64) async throws
}

/// An actor-isolated token bucket. The bucket starts full for a bounded burst,
/// then reservations are made against the same clock so concurrent tasks cannot
/// bypass a shared rate. No URLs, credentials, or task payloads are retained.
public actor TokenBucketRateLimiter: DownloadRateLimiting {
    public let rateBytesPerSecond: Int64
    public let burstBytes: Int64

    private let clock: RateLimitClock
    private var capacity: Double
    private var tokens: Double
    private var lastRefillNanoseconds: UInt64
    private var reservedUntilNanoseconds: UInt64

    public init(
        rateBytesPerSecond: Int64,
        burstBytes: Int64? = nil,
        clock: RateLimitClock = .system
    ) throws {
        guard rateBytesPerSecond > 0 else {
            throw RateLimitConfigurationError.invalidRate
        }
        let resolvedBurst = burstBytes ?? rateBytesPerSecond
        guard resolvedBurst > 0 else {
            throw RateLimitConfigurationError.invalidBurst
        }
        self.rateBytesPerSecond = rateBytesPerSecond
        self.burstBytes = resolvedBurst
        self.clock = clock
        capacity = Double(resolvedBurst)
        tokens = Double(resolvedBurst)
        let now = clock.nowNanoseconds()
        lastRefillNanoseconds = now
        reservedUntilNanoseconds = now
    }

    public func acquire(_ byteCount: Int64) async throws {
        guard byteCount >= 0 else { throw RateLimitConfigurationError.invalidRate }
        guard byteCount > 0 else { return }

        let requested = Double(byteCount)
        let now = clock.nowNanoseconds()
        let elapsed = now >= lastRefillNanoseconds ? now - lastRefillNanoseconds : 0
        if elapsed > 0 {
            let refill = Double(elapsed) * Double(rateBytesPerSecond) / 1_000_000_000
            tokens = min(capacity, tokens + refill)
            lastRefillNanoseconds = now
        }

        if tokens >= requested, now >= reservedUntilNanoseconds {
            tokens -= requested
            return
        }

        // A single read may be larger than the configured burst. Consume the
        // available burst and reserve the remaining service time; never grow
        // the bucket capacity to fit one unusually large network chunk.
        let availableTokens = now >= reservedUntilNanoseconds ? tokens : 0
        let missing = max(0, requested - availableTokens)
        let waitNanoseconds = UInt64(max(1, ceil(missing * 1_000_000_000 / Double(rateBytesPerSecond))))
        let start = max(now, reservedUntilNanoseconds)
        let wake =
            start.addingReportingOverflow(waitNanoseconds).overflow
            ? UInt64.max
            : start + waitNanoseconds
        reservedUntilNanoseconds = wake
        tokens = 0
        // The reservation includes all tokens up to `wake`. Prevent a
        // re-entrant acquire during the sleep from refilling those tokens.
        lastRefillNanoseconds = wake
        try await clock.sleep(max(1, wake > now ? wake - now : 1))
    }
}

public struct CombinedRateLimiter: DownloadRateLimiting, Sendable {
    private let global: (any DownloadRateLimiting)?
    private let task: (any DownloadRateLimiting)?

    public init(
        global: (any DownloadRateLimiting)? = nil,
        task: (any DownloadRateLimiting)? = nil
    ) {
        self.global = global
        self.task = task
    }

    public func acquire(_ byteCount: Int64) async throws {
        try await global?.acquire(byteCount)
        try await task?.acquire(byteCount)
    }
}

/// A limiter whose inner implementation can be swapped while downloads are
/// running. Tasks capture this wrapper once at start; when the user changes
/// the global speed limit the app reconfigures the same wrapper instance, so
/// the new limit applies to in-flight transfers immediately instead of only to
/// tasks started afterwards. `nil` inner means unlimited.
public final class DynamicRateLimiter: DownloadRateLimiting, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: (any DownloadRateLimiting)?

    public init(inner: (any DownloadRateLimiting)? = nil) {
        self.inner = inner
    }

    public func reconfigure(_ limiter: (any DownloadRateLimiting)?) {
        lock.lock()
        inner = limiter
        lock.unlock()
    }

    /// Synchronous snapshot so `acquire` never holds the lock across an
    /// await point (NSLock is not async-safe).
    private var currentLimiter: (any DownloadRateLimiting)? {
        lock.lock()
        defer { lock.unlock() }
        return inner
    }

    public func acquire(_ byteCount: Int64) async throws {
        let current = currentLimiter
        try await current?.acquire(byteCount)
    }
}
