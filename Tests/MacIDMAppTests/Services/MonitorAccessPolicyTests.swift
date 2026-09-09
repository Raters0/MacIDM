import XCTest

@testable import MacIDMApp

final class MonitorAccessPolicyTests: XCTestCase {

    // MARK: - Which reads stay open

    func testOnlyHealthIsReadableWithoutAToken() {
        XCTAssertTrue(MonitorAccessPolicy.isPublicReadEndpoint(method: "GET", path: "/health"))
        for path in ["/status", "/tasks", "/logs", "/settings", "/"] {
            XCTAssertFalse(
                MonitorAccessPolicy.isPublicReadEndpoint(method: "GET", path: path),
                "\(path) must require the token")
        }
    }

    func testHealthIsNotPublicForNonGetMethods() {
        XCTAssertFalse(MonitorAccessPolicy.isPublicReadEndpoint(method: "POST", path: "/health"))
        XCTAssertFalse(MonitorAccessPolicy.isPublicReadEndpoint(method: "DELETE", path: "/health"))
    }

    func testTokenRequirementIsCaseInsensitiveOnMethod() {
        XCTAssertTrue(MonitorAccessPolicy.isPublicReadEndpoint(method: "get", path: "/health"))
    }

    // MARK: - Host validation (DNS rebinding)

    func testLoopbackHostHeadersAreAccepted() {
        let allowed = [
            "127.0.0.1", "127.0.0.1:7831", "localhost", "localhost:7831",
            "LOCALHOST:7831", "[::1]", "[::1]:7831",
        ]
        for host in allowed {
            XCTAssertTrue(
                MonitorAccessPolicy.hostIsAllowed(host), "\(host) is a loopback Host")
        }
    }

    func testRemoteAndMissingHostHeadersAreRefused() {
        // A page that rebinds its own name to 127.0.0.1 still sends that name.
        let refused = [
            "attacker.example", "attacker.example:7831", "rebind.test", "127.0.0.1.attacker",
            "localhost.attacker.example", "app.example.com",
        ]
        for host in refused {
            XCTAssertFalse(
                MonitorAccessPolicy.hostIsAllowed(host), "\(host) must be refused")
        }
        XCTAssertFalse(MonitorAccessPolicy.hostIsAllowed(nil))
        XCTAssertFalse(MonitorAccessPolicy.hostIsAllowed(""))
    }

    func testHostPortSuffixIsOnlyStrippedWhenItIsNumeric() {
        XCTAssertEqual(MonitorAccessPolicy.stripPort("127.0.0.1:7831"), "127.0.0.1")
        XCTAssertEqual(MonitorAccessPolicy.stripPort("127.0.0.1:notaport"), "127.0.0.1:notaport")
        XCTAssertEqual(MonitorAccessPolicy.stripPort("localhost"), "localhost")
        XCTAssertEqual(MonitorAccessPolicy.stripPort("[::1]:7831"), "[::1]")
        XCTAssertEqual(MonitorAccessPolicy.stripPort("[::1]"), "[::1]")
        XCTAssertEqual(MonitorAccessPolicy.stripPort("[unclosed"), "[unclosed")
    }

    // MARK: - Origin validation

    func testOriginHeaderMayBeAbsentButNotRemote() {
        XCTAssertTrue(MonitorAccessPolicy.originIsAllowed(nil))
        XCTAssertTrue(MonitorAccessPolicy.originIsAllowed(""))
        XCTAssertTrue(MonitorAccessPolicy.originIsAllowed("https://localhost"))
        XCTAssertTrue(MonitorAccessPolicy.originIsAllowed("http://127.0.0.1:7831"))
        XCTAssertFalse(MonitorAccessPolicy.originIsAllowed("https://evil.example"))
        // Firefox reports an opaque origin as the literal "null"; it is not a
        // loopback document, so it must not be treated as one.
        XCTAssertFalse(MonitorAccessPolicy.originIsAllowed("null"))
        XCTAssertFalse(MonitorAccessPolicy.originIsAllowed("not a url"))
    }
}

final class MonitorRateLimiterTests: XCTestCase {

    func testRequestsWithinTheWindowAreAccepted() {
        var limiter = MonitorRateLimiter(maximumRequests: 3, window: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<3 {
            XCTAssertTrue(
                limiter.shouldAccept(
                    source: "127.0.0.1",
                    now: start.addingTimeInterval(
                        Double(offset))))
        }
        XCTAssertFalse(limiter.shouldAccept(source: "127.0.0.1", now: start.addingTimeInterval(3)))
    }

    func testBudgetReturnsOnceTheWindowRollsOn() {
        var limiter = MonitorRateLimiter(maximumRequests: 2, window: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertTrue(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertFalse(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertTrue(
            limiter.shouldAccept(source: "127.0.0.1", now: start.addingTimeInterval(11)))
    }

    func testOneFloodingSourceCannotExhaustAnother() {
        var limiter = MonitorRateLimiter(maximumRequests: 2, window: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertTrue(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertFalse(limiter.shouldAccept(source: "127.0.0.1", now: start))
        XCTAssertTrue(limiter.shouldAccept(source: "::1", now: start))
    }

    func testOlderSourcesArePrunedWithoutLosingCurrentBudget() {
        var limiter = MonitorRateLimiter(maximumRequests: 2, window: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        // Fill past the prune threshold with stale sources, then check a fresh
        // source still gets its full budget.
        for index in 0..<40 {
            limiter.shouldAccept(source: "stale-\(index)", now: start)
        }
        XCTAssertTrue(
            limiter.shouldAccept(source: "127.0.0.1", now: start.addingTimeInterval(60)))
    }
}
