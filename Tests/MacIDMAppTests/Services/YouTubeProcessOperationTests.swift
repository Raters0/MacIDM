import Darwin
import IDMEngine
import XCTest

@testable import MacIDMApp

/// 下载 runner 进程操作的 FD、取消竞态与通道回退收口（technical-spec §3.4）。
final class YouTubeProcessOperationTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRunnerFDTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func makeMarkerScript() throws -> (executable: URL, marker: URL) {
        let directory = try makeDirectory()
        let marker = directory.appendingPathComponent("started")
        let executable = directory.appendingPathComponent("fake-tool")
        try Data(
            ("#!/bin/bash\necho 1 > \"\(marker.path)\"\nsleep 300\n").utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, marker)
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    func testPipeFallbackCancelRaceClosesAllDescriptors() async throws {
        // §8.1：openpty 失败进入 pipe 路径，会话已创建但从未 run 时被取消——
        // 输出写端与回退读端都必须被关闭，不得泄漏，也不得有外部进程。
        let (executable, marker) = try makeMarkerScript()
        let barrier = DispatchSemaphore(value: 0)
        let operation = YouTubeProcessOperation(
            executableURL: executable,
            arguments: [],
            control: { .continue },
            progress: { _ in },
            stallTimeout: 300,
            openPTY: { _, _ in -1 },
            fallbackPipe: { pipe($0) },
            startBarrier: { barrier.wait() }
        )
        let before = openDescriptorCount()
        let task = Task { try await operation.run() }
        // 让 start() 通过首次取消检查并停在屏障上，然后取消。
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        barrier.signal()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as IDMError {
            guard case .cancelled = error else {
                return XCTFail("expected IDMError.cancelled, got \(error)")
            }
        }
        // 收尾（含描述符关闭）在屏障放行后同步完成；等待其结束再清点。
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "取消先到时不得真正启动子进程")
        XCTAssertEqual(
            openDescriptorCount(), before, "pipe 回退路径的写端与读端都必须被关闭")
    }

    func testBothChannelFailuresEndAsLaunchFailure() async throws {
        // §5.3：PTY 与 pipe 都失败时不得继续，必须稳定报错且零泄漏。
        let (executable, marker) = try makeMarkerScript()
        let operation = YouTubeProcessOperation(
            executableURL: executable,
            arguments: [],
            control: { .continue },
            progress: { _ in },
            stallTimeout: 300,
            openPTY: { _, _ in -1 },
            fallbackPipe: { _ in
                errno = EMFILE
                return -1
            }
        )
        let before = openDescriptorCount()
        do {
            _ = try await operation.run()
            XCTFail("expected channel-creation failure")
        } catch let error as YouTubeDownloadError {
            XCTAssertEqual(error, .toolLaunchFailed)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "无可用输出通道时不得启动子进程")
        XCTAssertEqual(openDescriptorCount(), before, "零 FD 泄漏")
    }

    func testRepeatedImmediateCancelsDoNotLeakDescriptors() async throws {
        // §8.3：重复立即取消（覆盖启动前/后两个竞态分支），FD 不得持续增长。
        let (executable, _) = try makeMarkerScript()
        let baseline = openDescriptorCount()
        for _ in 0..<5 {
            let operation = YouTubeProcessOperation(
                executableURL: executable,
                arguments: [],
                control: { .continue },
                progress: { _ in },
                stallTimeout: 300,
                openPTY: { _, _ in -1 },
                fallbackPipe: { pipe($0) }
            )
            let task = Task { try await operation.run() }
            task.cancel()
            _ = try? await task.value
            // 等待收尾线程关闭描述符与会话完成组清理。
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        let after = openDescriptorCount()
        XCTAssertLessThanOrEqual(
            after, baseline + 1, "反复立即取消不得造成 FD 持续增长")
    }
}
