import Darwin
import XCTest

@testable import MacIDMApp

/// `read(2)` 结果分类与输出通道建立的故障语义（docs/AI交接.md §5.3/§8.2）：
/// EINTR 必须重试，读错误不得冒充 EOF，pipe 失败必须显式报错且零泄漏。
final class ChannelReaderTests: XCTestCase {
    func testEINTRIsRetriedAndDataStaysIntact() {
        // 注入两次 EINTR 后继续输出：重试在读取原语内完成，调用方只看到数据。
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 1)
        defer { buffer.deallocate() }
        var step = 0
        let outcome = ChannelReader.read(fileDescriptor: 3, buffer: buffer, count: 16) { _, buf, _ in
            step += 1
            if step <= 2 {
                errno = EINTR
                return -1
            }
            buf.storeBytes(of: UInt8(42), toByteOffset: 0, as: UInt8.self)
            buf.storeBytes(of: UInt8(7), toByteOffset: 1, as: UInt8.self)
            return 2
        }
        XCTAssertEqual(outcome, .bytes(2))
        XCTAssertEqual(step, 3, "EINTR 必须原地重试而不是返回给读取循环")
        XCTAssertEqual(buffer.load(fromByteOffset: 0, as: UInt8.self), 42)
        XCTAssertEqual(buffer.load(fromByteOffset: 1, as: UInt8.self), 7)
    }

    func testReadErrorIsChannelFailureNotEOF() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 1)
        defer { buffer.deallocate() }
        let outcome = ChannelReader.read(fileDescriptor: 3, buffer: buffer, count: 16) { _, _, _ in
            errno = EIO
            return -1
        }
        XCTAssertEqual(outcome, .channelFailure(EIO), "非 EINTR 读错误必须可诊断，不得冒充 EOF")
    }

    func testZeroLengthReadIsEOF() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 1)
        defer { buffer.deallocate() }
        let outcome = ChannelReader.read(fileDescriptor: 3, buffer: buffer, count: 16) { _, _, _ in
            0
        }
        XCTAssertEqual(outcome, .endOfFile)
    }

    func testRealPipeDrainsToEOF() throws {
        // 真实管道上的端到端：写端关闭后读到 EOF，数据完整。
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw CocoaError(.featureUnsupported) }
        let payload = Data("macidm-eintr-check".utf8)
        payload.withUnsafeBytes { raw in
            _ = write(fds[1], raw.baseAddress, raw.count)
        }
        close(fds[1])

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64)
        readLoop: while true {
            let outcome = buffer.withUnsafeMutableBytes { raw in
                ChannelReader.read(fileDescriptor: fds[0], buffer: raw.baseAddress!, count: raw.count)
            }
            switch outcome {
            case .bytes(let count):
                received.append(contentsOf: buffer[0..<count])
            case .endOfFile:
                break readLoop
            case .channelFailure:
                XCTFail("真实管道读取不应失败")
                break readLoop
            }
        }
        close(fds[0])
        XCTAssertEqual(received, payload)
    }
}

/// `YouTubeInspectProcess.makeOutputPipes` 的故障路径（§5.3）。
final class InspectPipeCreationTests: XCTestCase {
    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    func testFirstPipeFailureThrowsWithZeroLeak() throws {
        let before = openDescriptorCount()
        XCTAssertThrowsError(
            try YouTubeInspectProcess.makeOutputPipes(
                pipeCall: { _ in
                    errno = EMFILE
                    return -1
                })
        )
        XCTAssertEqual(openDescriptorCount(), before, "第一条管道失败时不得泄漏 FD")
    }

    func testSecondPipeFailureClosesFirstPipeExactlyOnce() throws {
        // 第二条 pipe 失败时必须关闭第一条已成功创建的两个 FD，零泄漏（§5.3）。
        let before = openDescriptorCount()
        var calls = 0
        XCTAssertThrowsError(
            try YouTubeInspectProcess.makeOutputPipes(
                pipeCall: { fds in
                    calls += 1
                    if calls == 1 { return pipe(fds) }
                    errno = EMFILE
                    return -1
                })
        )
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(
            openDescriptorCount(), before, "第一条管道的两个 FD 必须被收回，零泄漏")
    }

    func testSuccessReturnsDistinctDescriptors() throws {
        let before = openDescriptorCount()
        let pipes = try YouTubeInspectProcess.makeOutputPipes()
        defer {
            for fd in [pipes.stdout[0], pipes.stdout[1], pipes.stderr[0], pipes.stderr[1]] {
                close(fd)
            }
        }
        let all = [pipes.stdout[0], pipes.stdout[1], pipes.stderr[0], pipes.stderr[1]]
        XCTAssertEqual(Set(all).count, 4, "四个描述符必须互不相同（否则 `[0,0]` 初始值曾被误用）")
        XCTAssertFalse(all.contains(0), "不得占用标准输入")
        XCTAssertEqual(openDescriptorCount(), before + 4)
    }
}
