import Foundation
import XCTest
import os

@testable import IDMEngine

final class LargeSegmentStreamingTests: XCTestCase {

    /// Mock HLS resource client that streams slow chunked feeds (actually runs streamToFile
    /// writing through SafeFileDescriptor)
    private struct SlowChunkStreamClient: HLSResourceClient, Sendable {
        let masterPlaylist: String
        let segmentBytes: Int
        let chunkSize: Int
        let chunkDelayNanoseconds: UInt64
        let onChunkDelivered: (@Sendable (Int, Int) -> Void)?

        init(
            masterPlaylist: String,
            segmentBytes: Int,
            chunkSize: Int = 64 * 1024,
            chunkDelayNanoseconds: UInt64 = 0,
            onChunkDelivered: (@Sendable (Int, Int) -> Void)? = nil
        ) {
            self.masterPlaylist = masterPlaylist
            self.segmentBytes = segmentBytes
            self.chunkSize = chunkSize
            self.chunkDelayNanoseconds = chunkDelayNanoseconds
            self.onChunkDelivered = onChunkDelivered
        }

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            if request.url.pathExtension == "m3u8" {
                return HLSFetchResponse(data: Data(masterPlaylist.utf8), finalURL: request.url, statusCode: 200)
            }
            throw IDMError.invalidURL
        }

        func streamToFile(
            _ request: HLSFetchRequest,
            to destinationURL: URL,
            budget: MediaBufferBudget,
            control: @escaping @Sendable () -> DownloadControl,
            progress: (@Sendable (Int64) -> Void)?
        ) async throws -> HLSStreamToFileResult {
            let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
            var delivered = 0

            do {
                while delivered < segmentBytes {
                    try Task.checkCancellation()
                    switch control() {
                    case .continue: break
                    case .pause:
                        throw IDMError.paused
                    case .cancel:
                        throw IDMError.cancelled
                    }

                    let toDeliver = min(chunkSize, segmentBytes - delivered)
                    guard Int64(delivered + toDeliver) <= DownloadResourceLimits.maximumMediaUnitBytes else {
                        throw IDMError.resourceTooLarge(DownloadResourceLimits.maximumMediaUnitBytes)
                    }
                    let chunk = Data(repeating: UInt8(delivered % 255), count: toDeliver)

                    // Actually reserve this chunk's budget (e.g. 64KB) and release it safely afterwards
                    let reservation = try await budget.reserve(bytes: Int64(chunk.count))
                    do {
                        try sink.writeAll(chunk)
                        reservation.release()
                    } catch {
                        reservation.release()
                        throw error
                    }

                    delivered += toDeliver
                    progress?(Int64(toDeliver))
                    onChunkDelivered?(delivered, segmentBytes)

                    if chunkDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                    }
                }

                try sink.synchronize()
                try sink.closeFile()

                return HLSStreamToFileResult(
                    finalURL: request.url,
                    statusCode: 200,
                    byteCount: Int64(delivered),
                    contentRange: nil
                )
            } catch {
                try? sink.closeFile()
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    /// Mock client that wrongly answers Range requests with a 200 response
    private struct BadRangeClient: HLSResourceClient, Sendable {
        let playlist: String
        let fullData: Data

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            if request.url.pathExtension == "m3u8" {
                return HLSFetchResponse(data: Data(playlist.utf8), finalURL: request.url, statusCode: 200)
            }
            throw IDMError.invalidURL
        }

        func streamToFile(
            _ request: HLSFetchRequest,
            to destinationURL: URL,
            budget: MediaBufferBudget,
            control: @escaping @Sendable () -> DownloadControl,
            progress: (@Sendable (Int64) -> Void)?
        ) async throws -> HLSStreamToFileResult {
            let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
            do {
                let res = try await budget.reserve(bytes: Int64(fullData.count))
                try sink.writeAll(fullData)
                res.release()
                try sink.synchronize()
                try sink.closeFile()

                // Wrong behavior: returns status 200 for a Byte-Range request
                return HLSStreamToFileResult(
                    finalURL: request.url,
                    statusCode: 200,
                    byteCount: Int64(fullData.count),
                    contentRange: nil
                )
            } catch {
                try? sink.closeFile()
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    // MARK: - 5MB slow-chunk streaming tests

    /// Verify a 5MB oversized segment streams to completion under a tiny 64KB budget,
    /// with the budget exactly back to zero
    func testOversizedSegmentSingleStream() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://mock.media/stream/master.m3u8")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            seg0.ts
            #EXT-X-ENDLIST
            """

        let totalSegmentBytes = 5 * 1024 * 1024  // 5MB
        let client = SlowChunkStreamClient(
            masterPlaylist: playlist,
            segmentBytes: totalSegmentBytes,
            chunkSize: 64 * 1024
        )

        // Inject a tiny 64KB budget
        let budget = MediaBufferBudget(capacity: 64 * 1024)
        let executor = HLSDownloadExecutor(client: client, budget: budget)
        let destination = tempDir.appendingPathComponent("output.ts")

        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            taskID: UUID()
        )

        let result = try await executor.download(request)
        XCTAssertEqual(result.byteCount, Int64(totalSegmentBytes), "5MB 分片必须完整下载并落盘")
        XCTAssertEqual(budget.reservedBytes, 0, "下载完成后预算必须严格归 0")
        XCTAssertEqual(budget.peakReservedBytes, 64 * 1024, "峰值预算预留必须稳定在 64KB")
    }

    /// Verify a 5MB oversized segment immediately releases the budget and cleans up all
    /// orphan files when cancelled mid-download
    func testOversizedSegmentMidStreamCancel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_cancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://mock.media/stream/master.m3u8")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            seg0.ts
            #EXT-X-ENDLIST
            """

        let controlState = OSAllocatedUnfairLock(initialState: DownloadControl.continue)

        let totalSegmentBytes = 5 * 1024 * 1024  // 5MB
        let client = SlowChunkStreamClient(
            masterPlaylist: playlist,
            segmentBytes: totalSegmentBytes,
            chunkSize: 64 * 1024,
            chunkDelayNanoseconds: 1_000_000,  // 1ms delay
            onChunkDelivered: { delivered, _ in
                // Trigger cancellation once 512KB has been delivered
                if delivered >= 512 * 1024 {
                    controlState.withLock { $0 = .cancel }
                }
            }
        )

        let budget = MediaBufferBudget(capacity: 64 * 1024)
        let executor = HLSDownloadExecutor(client: client, budget: budget)
        let destination = tempDir.appendingPathComponent("output_cancel.ts")

        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            taskID: UUID()
        )

        let start = ContinuousClock.now
        do {
            _ = try await executor.download(
                request,
                control: { controlState.withLock { $0 } }
            )
            XCTFail("应当抛出 IDMError.cancelled")
        } catch {
            guard case IDMError.cancelled = error else {
                XCTFail("预期 IDMError.cancelled，实际: \(error)")
                return
            }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(2.0), "取消应在 2s 内快速返回")

        XCTAssertEqual(budget.reservedBytes, 0, "取消后预算必须立即精准归零")

        // Verify no orphan files remain in the destination temp directory
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        XCTAssertTrue(remainingFiles.isEmpty, "取消后不应遗留任何临时文件，实际存在: \(remainingFiles)")
    }

    // MARK: - P0-3: protocol-level strict Range revalidation tests

    func testByteRangeRequestRejects200ResponseFromMaliciousClient() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_range_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://mock.media/stream/byterange.m3u8")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            #EXT-X-BYTERANGE:100@0
            main.ts
            #EXT-X-ENDLIST
            """

        let client = BadRangeClient(
            playlist: playlist,
            fullData: Data(repeating: 0xAA, count: 500)
        )

        let budget = MediaBufferBudget(capacity: 64 * 1024)
        let executor = HLSDownloadExecutor(client: client, budget: budget)
        let destination = tempDir.appendingPathComponent("output_range.ts")

        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            taskID: UUID()
        )

        do {
            _ = try await executor.download(request)
            XCTFail("对于 Byte-Range 切片返回 200 必须抛出 invalidContentRange")
        } catch {
            guard case IDMError.invalidContentRange = error else {
                XCTFail("预期 IDMError.invalidContentRange，实际收到: \(error)")
                return
            }
        }

        XCTAssertEqual(budget.reservedBytes, 0, "异常后预算必须归零")
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let remainingUnitFiles = remainingFiles.filter { $0.contains(".unit-") || $0.hasSuffix(".tmp") }
        XCTAssertTrue(remainingUnitFiles.isEmpty, "校验失败后必须清理所有 Unit 临时文件，实际存在: \(remainingUnitFiles)")
    }

    // MARK: - Single unit over-limit protection and cleanup tests

    func testRejectsUnitExceedingSafetyCapAndCleansUp() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_cap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let masterURL = URL(string: "https://mock.media/stream/huge.m3u8")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            huge.ts
            #EXT-X-ENDLIST
            """

        // Mock an oversized segment exceeding DownloadResourceLimits.maximumMediaUnitBytes
        let client = SlowChunkStreamClient(
            masterPlaylist: playlist,
            segmentBytes: Int(DownloadResourceLimits.maximumMediaUnitBytes + 1024),
            chunkSize: 64 * 1024
        )

        let budget = MediaBufferBudget(capacity: 64 * 1024)
        let executor = HLSDownloadExecutor(client: client, budget: budget)
        let destination = tempDir.appendingPathComponent("output_huge.ts")

        let request = DownloadRequest(
            url: masterURL,
            destination: destination,
            sourceKind: .hls,
            taskID: UUID()
        )

        do {
            _ = try await executor.download(request)
            XCTFail("超出单 Unit 安全上限必须抛出 resourceTooLarge")
        } catch {
            guard case IDMError.resourceTooLarge = error else {
                XCTFail("预期 IDMError.resourceTooLarge，实际收到: \(error)")
                return
            }
        }

        XCTAssertEqual(budget.reservedBytes, 0, "超限拒绝后预算必须归零")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let tempFiles = files.filter { $0.contains(".tmp") || $0.contains(".unit-") }
        XCTAssertTrue(tempFiles.isEmpty, "超限拒绝后临时文件必须完全清理: \(tempFiles)")
    }
}
