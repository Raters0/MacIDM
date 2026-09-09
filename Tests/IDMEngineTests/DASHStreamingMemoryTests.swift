import XCTest

@testable import IDMEngine

final class DASHStreamingMemoryTests: XCTestCase {
    private struct MockDASHClient: HLSResourceClient, Sendable {
        let responses: [String: Data]

        func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
            let key = request.url.absoluteString
            guard let data = responses[key] else {
                throw IDMError.httpStatus(404)
            }
            if let range = request.byteRange {
                let start = Int(range.offset)
                let end = start + Int(range.length)
                guard end <= data.count else {
                    throw IDMError.invalidContentRange
                }
                let slice = data.subdata(in: start..<end)
                return HLSFetchResponse(
                    data: slice,
                    finalURL: request.url,
                    statusCode: 206,
                    contentRange: ParsedContentRange(
                        start: range.offset, endInclusive: range.offset + Int64(range.length) - 1,
                        total: Int64(data.count))
                )
            }
            return HLSFetchResponse(data: data, finalURL: request.url, statusCode: 200)
        }
    }

    private final class MockMerger: FFmpegMerging, Sendable {
        func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
            var total: Int64 = 0
            if let video = request.videoURL, FileManager.default.fileExists(atPath: video.path) {
                let attr = try FileManager.default.attributesOfItem(atPath: video.path)
                total += (attr[.size] as? NSNumber)?.int64Value ?? 0
            }
            if let audio = request.audioURL, FileManager.default.fileExists(atPath: audio.path) {
                let attr = try FileManager.default.attributesOfItem(atPath: audio.path)
                total += (attr[.size] as? NSNumber)?.int64Value ?? 0
            }
            let data = Data(repeating: 0x99, count: max(1024, Int(min(total, 1024 * 1024))))
            try data.write(to: request.outputURL)
            return FFmpegRemuxResult(
                destination: request.outputURL,
                byteCount: total,
                sha256: "mock_merged_sha256",
                probe: FFmpegProbeResult(
                    formatName: "mov,mp4,m4a",
                    duration: request.expectedDuration ?? 10.0,
                    streams: [
                        FFmpegStreamInfo(
                            index: 0, codecName: "h264", codecType: "video", width: 1920, height: 1080, duration: 10.0),
                        FFmpegStreamInfo(
                            index: 1, codecName: "aac", codecType: "audio", width: nil, height: nil, duration: 10.0),
                    ]
                )
            )
        }
    }

    func testDASHStreamingWithSmallBudgetAndCompleteCleanup() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mpdURL = URL(string: "https://example.com/dash/manifest.mpd")!
        let mpd = """
            <?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT10S" minBufferTime="PT1.5S" type="static">
              <Period id="0">
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v1" bandwidth="2000000" width="1920" height="1080">
                    <SegmentList timescale="1000" duration="5000">
                      <Initialization sourceURL="init-v.mp4"/>
                      <SegmentURL media="v-seg1.m4s"/>
                      <SegmentURL media="v-seg2.m4s"/>
                    </SegmentList>
                  </Representation>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <Representation id="a1" bandwidth="128000">
                    <SegmentList timescale="1000" duration="5000">
                      <Initialization sourceURL="init-a.mp4"/>
                      <SegmentURL media="a-seg1.m4s"/>
                      <SegmentURL media="a-seg2.m4s"/>
                    </SegmentList>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """

        let mockClient = MockDASHClient(responses: [
            mpdURL.absoluteString: Data(mpd.utf8),
            "https://example.com/dash/init-v.mp4": Data(repeating: 0x01, count: 4096),
            "https://example.com/dash/v-seg1.m4s": Data(repeating: 0x02, count: 64 * 1024),
            "https://example.com/dash/v-seg2.m4s": Data(repeating: 0x03, count: 64 * 1024),
            "https://example.com/dash/init-a.mp4": Data(repeating: 0x04, count: 2048),
            "https://example.com/dash/a-seg1.m4s": Data(repeating: 0x05, count: 16 * 1024),
            "https://example.com/dash/a-seg2.m4s": Data(repeating: 0x06, count: 16 * 1024),
        ])

        let budget = MediaBufferBudget(capacity: 32 * 1024)  // 32KB tight budget
        let executor = DASHDownloadExecutor(
            client: mockClient,
            parser: DASHParser(),
            merger: MockMerger(),
            budget: budget
        )

        let destination = tempDir.appendingPathComponent("dash_output.mp4")
        let taskID = UUID()
        let request = DASHDownloadRequest(
            url: mpdURL,
            destination: destination,
            outputKind: .mp4,
            maximumParallelRequests: 4,
            taskID: taskID
        )

        let result = try await executor.download(request)
        let expectedTotal: Int64 = 4096 + (64 * 1024 * 2) + 2048 + (16 * 1024 * 2)
        XCTAssertEqual(result.byteCount, expectedTotal)
        XCTAssertEqual(budget.reservedBytes, 0, "DASH 下载完成后预算必须归零")

        // Verify no unit temp files or temp directories remain
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let orphans = remainingFiles.filter { $0.contains(taskID.uuidString) }
        XCTAssertTrue(orphans.isEmpty, "完成发布后不得残留任何 DASH 临时目录或 unit 文件: \(orphans)")
    }
}
