import Foundation
import XCTest

@testable import IDMEngine

final class DownloadPlanTests: XCTestCase {
    func testProtocolRouterSelectsTheFirstHandlerThatSupportsARequest() throws {
        let router = DownloadProtocolRouter(handlers: [
            StubProtocolHandler(identifier: "unsupported", supportsResult: false),
            StubProtocolHandler(identifier: "fixture", supportsResult: true),
        ])
        let request = DownloadRequest(
            url: URL(string: "https://example.test/file")!,
            destination: URL(fileURLWithPath: "/tmp/file")
        )

        let selected = try router.handler(for: request)

        XCTAssertEqual(selected.identifier, "fixture")
        XCTAssertEqual(router.identifiers, ["unsupported", "fixture"])
    }

    func testFixedPlanCoversFileWithoutOverlapOrEmptyRanges() throws {
        let handler = HTTPHandler()
        for size in [Int64(1), 7, 8, 9, 1_024] {
            for parallel in [1, 2, 8, 32] {
                let info = ResourceInfo(
                    finalURL: URL(string: "https://example.test/file")!,
                    size: size,
                    supportsRange: true,
                    strongETag: "\"fixture\""
                )
                let plan = try handler.makePlan(info, parallelRequests: parallel)
                XCTAssertEqual(plan.units.count, min(Int(size), parallel))
                var cursor: Int64 = 0
                for unit in plan.units {
                    XCTAssertEqual(unit.range.start, cursor)
                    XCTAssertGreaterThan(unit.range.endExclusive, unit.range.start)
                    cursor = unit.range.endExclusive
                }
                XCTAssertEqual(cursor, size)
            }
        }
    }

    func testNonRangePlanAlwaysUsesOneStream() throws {
        let info = ResourceInfo(
            finalURL: URL(string: "https://example.test/file")!,
            size: 10_000,
            supportsRange: false
        )
        let plan = try HTTPHandler().makePlan(info, parallelRequests: 32)
        XCTAssertEqual(plan.units.count, 1)
        XCTAssertEqual(plan.units[0].range, ByteRange(start: 0, endExclusive: 10_000))
    }

    func testZeroBytePlanHasNoRequests() throws {
        let info = ResourceInfo(
            finalURL: URL(string: "https://example.test/empty")!,
            size: 0,
            supportsRange: true,
            strongETag: "\"empty\""
        )
        XCTAssertTrue(try HTTPHandler().makePlan(info, parallelRequests: 8).units.isEmpty)
    }
}

private struct StubProtocolHandler: DownloadProtocolHandler {
    let identifier: String
    let supportsResult: Bool

    func supports(_ request: DownloadRequest) -> Bool {
        supportsResult
    }

    func probe(_ request: DownloadRequest) async throws -> ResourceInfo {
        ResourceInfo(finalURL: request.url, size: 0, supportsRange: false)
    }

    func makePlan(_ info: ResourceInfo, parallelRequests: Int) throws -> DownloadPlan {
        DownloadPlan(units: [])
    }
}
