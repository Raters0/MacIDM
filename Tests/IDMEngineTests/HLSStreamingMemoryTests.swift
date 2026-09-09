import Foundation
import XCTest
import os

@testable import IDMEngine

final class HLSStreamingMemoryTests: XCTestCase {
    private struct MockHLSClient: HLSResourceClient, Sendable {
        let responses: [String: Data]
        let delays: [String: UInt64]

        init(responses: [String: Data], delays: [String: UInt64] = [:]) {
            self.responses = responses
            self.delays = delays
        }

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            let key = request.url.absoluteString
            if let delay = delays[key] {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let data = responses[key] else {
                throw IDMError.httpStatus(404)
            }
            return HLSFetchResponse(data: data, finalURL: request.url, statusCode: 200)
        }
    }

    func testSmallBudgetInjectionBoundsInFlightMemoryAndCompletes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://example.com/stream/master.m3u8")!
        let seg0URL = URL(string: "https://example.com/stream/seg0.ts")!
        let seg1URL = URL(string: "https://example.com/stream/seg1.ts")!
        let seg2URL = URL(string: "https://example.com/stream/seg2.ts")!

        let playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            seg0.ts
            #EXTINF:4.0,
            seg1.ts
            #EXTINF:4.0,
            seg2.ts
            #EXT-X-ENDLIST
            """

        let chunk0 = Data(repeating: 0x11, count: 64 * 1024)
        let chunk1 = Data(repeating: 0x22, count: 64 * 1024)
        let chunk2 = Data(repeating: 0x33, count: 64 * 1024)

        let mockClient = MockHLSClient(responses: [
            masterURL.absoluteString: Data(playlist.utf8),
            seg0URL.absoluteString: chunk0,
            seg1URL.absoluteString: chunk1,
            seg2URL.absoluteString: chunk2,
        ])

        let smallBudget = MediaBufferBudget(capacity: 64 * 1024)  // 64KB tight budget
        let executor = HLSDownloadExecutor(client: mockClient, budget: smallBudget)

        let destination = tempDir.appendingPathComponent("output.ts")
        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 4,
            taskID: UUID()
        )

        let result = try await executor.download(request)
        XCTAssertEqual(result.byteCount, Int64(chunk0.count + chunk1.count + chunk2.count))
        XCTAssertEqual(smallBudget.reservedBytes, 0, "下载完成后预算占用必须精准归零")

        let diskData = try Data(contentsOf: destination)
        XCTAssertEqual(diskData, chunk0 + chunk1 + chunk2, "输出文件必须严格按分片顺序拼接")
    }

    func testOutOfOrderUnitArrivalSequencing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://example.com/stream/master.m3u8")!
        let seg0URL = URL(string: "https://example.com/stream/seg0.ts")!
        let seg1URL = URL(string: "https://example.com/stream/seg1.ts")!
        let seg2URL = URL(string: "https://example.com/stream/seg2.ts")!

        let playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            seg0.ts
            #EXTINF:4.0,
            seg1.ts
            #EXTINF:4.0,
            seg2.ts
            #EXT-X-ENDLIST
            """

        let chunk0 = Data(repeating: 0xAA, count: 32 * 1024)
        let chunk1 = Data(repeating: 0xBB, count: 32 * 1024)
        let chunk2 = Data(repeating: 0xCC, count: 32 * 1024)

        let mockClient = MockHLSClient(
            responses: [
                masterURL.absoluteString: Data(playlist.utf8),
                seg0URL.absoluteString: chunk0,
                seg1URL.absoluteString: chunk1,
                seg2URL.absoluteString: chunk2,
            ],
            delays: [
                seg0URL.absoluteString: 30_000_000,  // 30ms delay for segment 0
                seg1URL.absoluteString: 2_000_000,
                seg2URL.absoluteString: 1_000_000,
            ]
        )

        let budget = MediaBufferBudget(capacity: 256 * 1024)
        let executor = HLSDownloadExecutor(client: mockClient, budget: budget)

        let destination = tempDir.appendingPathComponent("sequenced.ts")
        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 4,
            taskID: UUID()
        )

        let result = try await executor.download(request)
        XCTAssertEqual(result.byteCount, Int64(chunk0.count + chunk1.count + chunk2.count))
        XCTAssertEqual(budget.reservedBytes, 0)

        let diskData = try Data(contentsOf: destination)
        XCTAssertEqual(diskData, chunk0 + chunk1 + chunk2, "即使乱序返回，写入必须严格按序号重组")

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let unitFiles = remainingFiles.filter { $0.contains(".unit-") }
        XCTAssertTrue(unitFiles.isEmpty, "完成发布后不得残留任何 unit 临时文件")
    }

    /// P1-5: verify that with 16-way concurrency the out-of-order window and scheduling batch cap stay at 8 and complete correctly
    func testOutOfOrderWindowCapWithConcurrency16() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://example.com/stream/concurrency16.m3u8")!
        var responses: [String: Data] = [:]
        var delays: [String: UInt64] = [:]
        var playlistLines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:4",
        ]
        var expectedCombinedData = Data()

        for i in 0..<16 {
            playlistLines.append("#EXTINF:4.0,")
            playlistLines.append("seg\(i).ts")
            let segData = Data(repeating: UInt8(i + 1), count: 16 * 1024)
            expectedCombinedData.append(segData)
            let segURL = "https://example.com/stream/seg\(i).ts"
            responses[segURL] = segData
            if i == 0 {
                // Make seg0 arrive late so later segments reach the window first
                delays[segURL] = 30_000_000
            }
        }
        playlistLines.append("#EXT-X-ENDLIST")
        responses[masterURL.absoluteString] = Data(playlistLines.joined(separator: "\n").utf8)

        let mockClient = MockHLSClient(responses: responses, delays: delays)
        let budget = MediaBufferBudget(capacity: 512 * 1024)
        let executor = HLSDownloadExecutor(client: mockClient, budget: budget)

        let destination = tempDir.appendingPathComponent("output16.ts")
        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 16,
            taskID: UUID()
        )

        let result = try await executor.download(request)
        XCTAssertEqual(result.byteCount, Int64(expectedCombinedData.count))
        XCTAssertEqual(budget.reservedBytes, 0)
        XCTAssertLessThanOrEqual(executor.maxObservedUncommittedRefs, 8, "乱序未提交引用峰值绝不可超过 8")

        let diskData = try Data(contentsOf: destination)
        XCTAssertEqual(diskData, expectedCombinedData, "16 并发乱序下最终数据必须完全一致")

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let unitFiles = remainingFiles.filter { $0.contains(".unit-") }
        XCTAssertTrue(unitFiles.isEmpty, "所有 unit 临时文件必须在完成时清空")
    }

    func testNoOrphanFilesOnCancel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://example.com/stream/master.m3u8")!
        var responses: [String: Data] = [:]
        var playlistLines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:4",
        ]
        for i in 0..<10 {
            playlistLines.append("#EXTINF:4.0,")
            playlistLines.append("seg\(i).ts")
            responses["https://example.com/stream/seg\(i).ts"] = Data(repeating: UInt8(i), count: 10 * 1024)
        }
        playlistLines.append("#EXT-X-ENDLIST")
        responses[masterURL.absoluteString] = Data(playlistLines.joined(separator: "\n").utf8)

        let mockClient = MockHLSClient(responses: responses)
        let budget = MediaBufferBudget(capacity: 128 * 1024)
        let executor = HLSDownloadExecutor(client: mockClient, budget: budget)

        let destination = tempDir.appendingPathComponent("cancelled.ts")
        let taskID = UUID()
        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 2,
            taskID: taskID
        )

        struct CancelState: Sendable {
            var control: DownloadControl = .continue
            var count = 0
        }
        let cancelState = OSAllocatedUnfairLock(initialState: CancelState())

        do {
            _ = try await executor.download(
                request,
                control: {
                    cancelState.withLock { $0.control }
                },
                progress: { _ in
                    cancelState.withLock { s in
                        s.count += 1
                        if s.count >= 2 {
                            s.control = .cancel
                        }
                    }
                }
            )
            XCTFail("应抛出 cancelled 错误")
        } catch {
            guard case IDMError.cancelled = error else {
                XCTFail("预期 IDMError.cancelled，实际: \(error)")
                return
            }
        }

        XCTAssertEqual(budget.reservedBytes, 0, "取消后预算必须归零")

        // Verify no orphan files in the destination directory
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let orphans = remainingFiles.filter { $0.contains(taskID.uuidString) }
        XCTAssertTrue(orphans.isEmpty, "取消后不得残留主临时文件、sidecar 或 unit 临时文件: \(orphans)")
    }
}
