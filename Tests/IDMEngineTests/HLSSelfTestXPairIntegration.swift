import Foundation
import XCTest

@testable import IDMEngine

/// 临时自测（MACIDM_X_SELFTEST=1 才运行）：用真实 X 推文 HLS master 走
/// DownloadEngine → HLS pair 合并 → ffprobe 验证产出含音视频双流。
final class HLSSelfTestXPairIntegration: XCTestCase {
    private let masterURLString =
        "https://video.twimg.com/amplify_video/2099453445837299712/pl/ILEhdo8JQNMg-7Ns.m3u8?tag=29&v=cfc&variant_version=1"

    func testRealXMasterMergesAudio() async throws {
        guard ProcessInfo.processInfo.environment["MACIDM_X_SELFTEST"] == "1" else {
            throw XCTSkip("需要 MACIDM_X_SELFTEST=1")
        }
        guard let toolchain = await FFmpegToolchain.autodetect() else {
            throw XCTSkip("FFmpeg 工具链不可用")
        }
        let ffmpeg = FFmpegService(toolchain: toolchain)
        let engine = DownloadEngine(hlsExecutor: HLSDownloadExecutor(merger: ffmpeg))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-x-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("merged.mp4")

        let result = try await engine.download(
            DownloadRequest(
                url: URL(string: masterURLString)!,
                destination: destination,
                sourceKind: .hls,
                maximumParallelRequests: 4,
                taskID: UUID()
            )
        )
        print("SELFTEST result: verification=\(result.verification) bytes=\(result.byteCount)")

        // ffprobe 验证双流
        let probe = Process()
        probe.executableURL = toolchain.ffprobeURL
        probe.arguments = [
            "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0",
            destination.path,
        ]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        print("SELFTEST ffprobe: \(output)")
        XCTAssertTrue(output.contains("video"), "缺视频流: \(output)")
        XCTAssertTrue(output.contains("audio"), "缺音频流（合并未生效）: \(output)")
    }
}
