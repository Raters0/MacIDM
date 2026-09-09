import CommonCrypto
import CryptoKit
import Foundation
import XCTest
import os

@testable import IDMEngine

final class ProductionStreamingTests: XCTestCase {

    private static func aes128Encrypt(plainText: Data, key: Data, iv: Data) throws -> Data {
        let outputCapacity = plainText.count + kCCBlockSizeAES128
        var output = Data(repeating: 0, count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plainText.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress,
                            plainText.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "Encrypt", code: Int(status))
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    // MARK: - Structured async cooperative timeout guard helper
    //
    // Note: withThrowingTaskGroup waits for the cancelled action child task to exit
    // before leaving scope, so this is a Cooperative Timeout Guard: bounded exit
    // relies on URLSession request/resource timeouts, Task cancellation, and
    // MediaBufferBudget cancellation working together. The external test process
    // gate remains the final safety boundary against a permanently hung process.

    private struct AsyncTimeoutError: LocalizedError, CustomStringConvertible, Sendable {
        let seconds: TimeInterval
        var errorDescription: String? { "异步操作在 \(seconds) 秒内超时未完成 (Timed Out)" }
        var description: String { "AsyncTimeoutError(seconds: \(seconds))" }
    }

    @discardableResult
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ action: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await action()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AsyncTimeoutError(seconds: seconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw AsyncTimeoutError(seconds: seconds)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if error is AsyncTimeoutError {
                    XCTFail("测试在 \(seconds) 秒内超时未完成 (Timed Out)", file: file, line: line)
                }
                throw error
            }
        }
    }

    // MARK: - Local lightweight HTTP server (single-ownership lock-protected FD protocol)

    private final class MiniHTTPServer: @unchecked Sendable {
        private let serverSocket: Int32
        private let port: Int
        private let stateLock = OSAllocatedUnfairLock(initialState: ServerState())
        private let clientGroup = DispatchGroup()
        private var acceptThread: Thread?
        var onRequest: (@Sendable (String, Int32) -> Void)?

        private struct ServerState {
            var isRunning: Bool = true
            var isServerClosed: Bool = false
            var clientSockets: Set<Int32> = []
        }

        init() throws {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw NSError(domain: "Socket", code: 1) }

            var opt: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0

            let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                close(sock)
                throw NSError(domain: "Bind", code: 2)
            }

            guard listen(sock, 64) == 0 else {
                close(sock)
                throw NSError(domain: "Listen", code: 3)
            }

            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getsockname(sock, saPtr, &len)
                }
            }
            self.serverSocket = sock
            self.port = Int(UInt16(bigEndian: addr.sin_port))
        }

        static func writeAll(to fd: Int32, data: Data) -> Bool {
            return data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return true }
                var written = 0
                while written < buffer.count {
                    let res = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                    if res < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    if res == 0 { return false }
                    written += res
                }
                return true
            }
        }

        static func writeString(to fd: Int32, _ string: String) -> Bool {
            guard let data = string.data(using: .utf8) else { return false }
            return writeAll(to: fd, data: data)
        }

        func start() {
            acceptThread = Thread { [weak self] in
                guard let self else { return }
                while true {
                    let running = self.stateLock.withLock { $0.isRunning }
                    guard running else { break }

                    let client = accept(self.serverSocket, nil, nil)
                    guard client >= 0 else {
                        let stillRunning = self.stateLock.withLock { $0.isRunning }
                        if !stillRunning { break }
                        continue
                    }

                    // stop() intentionally shuts down sockets while a handler
                    // may still write. Observe EPIPE rather than killing XCTest.
                    var noSigPipe: Int32 = 1
                    guard
                        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                            == 0
                    else {
                        Darwin.close(client)
                        continue
                    }

                    let accepted = self.stateLock.withLock { s -> Bool in
                        guard s.isRunning else { return false }
                        s.clientSockets.insert(client)
                        self.clientGroup.enter()
                        return true
                    }

                    guard accepted else {
                        Darwin.close(client)
                        continue
                    }

                    let group = self.clientGroup
                    let onRequest = self.onRequest
                    DispatchQueue.global().async { [weak self] in
                        defer {
                            // 🔒 Single-ownership protocol:
                            // 1. Deregister from clientSockets under stateLock;
                            // 2. the handler is always the sole close owner and unconditionally
                            //    close(client) exactly once outside the lock;
                            // 3. the strongly captured group must have exactly one leave().
                            // stop() only shuts down registered clientSockets within the same
                            // stateLock (interrupting I/O without releasing the fd); it never
                            // closes clients, fully eliminating OS fd-reuse races.
                            self?.stateLock.withLock { _ = $0.clientSockets.remove(client) }
                            Darwin.close(client)
                            group.leave()
                        }
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        let bytesRead = read(client, &buffer, buffer.count)
                        if bytesRead > 0 {
                            let reqStr = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
                            onRequest?(reqStr, client)
                        }
                    }
                }
            }
            acceptThread?.start()
        }

        func stop() {
            stateLock.withLock { s in
                guard s.isRunning || !s.isServerClosed else { return }
                s.isRunning = false

                // 🔒 Shut down all currently registered active clients inside this same
                // stateLock critical section. shutdown interrupts blocked read/write
                // without releasing the fd number, so no OS fd reuse can occur; keeping
                // no stale snapshot outside the lock fully eliminates fd-reuse races.
                for client in s.clientSockets {
                    Darwin.shutdown(client, SHUT_RDWR)
                }

                // Idempotently close the server listening socket (done once inside the lock)
                if !s.isServerClosed {
                    s.isServerClosed = true
                    Darwin.shutdown(serverSocket, SHUT_RDWR)
                    Darwin.close(serverSocket)
                }
            }

            var waitCount = 0
            while acceptThread?.isExecuting == true && waitCount < 100 {
                usleep(1000)
                waitCount += 1
            }

            _ = clientGroup.wait(timeout: .now() + 2.0)
        }

        static func writeChunk(to fd: Int32, data: Data) -> Bool {
            let hexLength = String(data.count, radix: 16)
            guard writeString(to: fd, "\(hexLength)\r\n") else { return false }
            if !data.isEmpty {
                guard writeAll(to: fd, data: data) else { return false }
            }
            guard writeString(to: fd, "\r\n") else { return false }
            return true
        }

        static func writeChunkedEnd(to fd: Int32) -> Bool {
            return writeString(to: fd, "0\r\n\r\n")
        }

        var baseURL: URL {
            URL(string: "http://127.0.0.1:\(port)")!
        }
    }

    // MARK: - Production test 1: strict byte ordering across chunks under a real URLSession

    func testProductionURLSessionStreamToFilePreservesByteOrdering() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let expectedTotalChunks = 16
            let chunkSize = 16 * 1024  // 16KB per chunk
            var dataAccumulator = Data()

            for i in 0..<expectedTotalChunks {
                let chunkPattern = UInt8(i + 1)
                let chunk = Data(repeating: chunkPattern, count: chunkSize)
                dataAccumulator.append(chunk)
            }

            let expectedData = dataAccumulator
            let totalBytes = expectedData.count

            server.onRequest = { [expectedData] req, client in
                let headers =
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(totalBytes)\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)

                for i in 0..<expectedTotalChunks {
                    let start = i * chunkSize
                    let end = start + chunkSize
                    let sub = expectedData.subdata(in: start..<end)
                    _ = MiniHTTPServer.writeAll(to: client, data: sub)
                    usleep(2000)  // 2ms gap produces multiple independent delegate callbacks
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_order_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("ordered.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            let targetURL = server.baseURL.appendingPathComponent("test.ts")
            let result = try await client.streamToFile(
                HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                to: destination,
                budget: budget,
                control: { .continue }
            )

            XCTAssertEqual(result.statusCode, 200)
            XCTAssertEqual(result.byteCount, Int64(totalBytes))

            let fileData = try Data(contentsOf: destination)
            XCTAssertEqual(fileData.count, totalBytes)
            XCTAssertEqual(fileData, expectedData, "分块写入必须保持严格全序，绝不可发生乱序或字节错位")
            XCTAssertEqual(budget.reservedBytes, 0, "下载完成后预算必须严格归零")
        }
    }

    // MARK: - Production test 2: ordered streaming with unknown Content-Length / Connection: close

    func testProductionURLSessionUnknownLengthConnectionClosePreservesOrdering() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let chunks = 10
            let chunkSize = 8 * 1024
            var expectedData = Data()
            for i in 0..<chunks {
                expectedData.append(Data(repeating: UInt8(i + 10), count: chunkSize))
            }

            server.onRequest = { [expectedData] req, client in
                // No Content-Length; the body ends by closing the connection
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)

                for i in 0..<chunks {
                    let sub = expectedData.subdata(in: (i * chunkSize)..<((i + 1) * chunkSize))
                    _ = MiniHTTPServer.writeAll(to: client, data: sub)
                    usleep(1500)
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_unknown_len_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("chunked.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            let targetURL = server.baseURL.appendingPathComponent("chunked.ts")
            let result = try await client.streamToFile(
                HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                to: destination,
                budget: budget,
                control: { .continue }
            )

            XCTAssertEqual(result.statusCode, 200)
            XCTAssertEqual(result.byteCount, Int64(expectedData.count))
            let fileData = try Data(contentsOf: destination)
            XCTAssertEqual(fileData, expectedData)
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }

    // MARK: - Production test 2B: strict ordering over real RFC 9112 Transfer-Encoding: chunked

    func testProductionURLSessionRealRFCChunkedPreservesOrdering() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let chunkPayloads: [Data] = [
                Data("Header-Mini-Chunk".utf8),
                Data(repeating: 0xAA, count: 1024),
                Data(repeating: 0xBB, count: 32 * 1024),
                Data(repeating: 0xCC, count: 17 * 1024),
                Data("Tail-Mini-Chunk".utf8),
            ]
            var expectedData = Data()
            for chunk in chunkPayloads {
                expectedData.append(chunk)
            }

            server.onRequest = { req, client in
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nTransfer-Encoding: chunked\r\n\r\n"
                guard MiniHTTPServer.writeString(to: client, headers) else { return }

                for chunk in chunkPayloads {
                    guard MiniHTTPServer.writeChunk(to: client, data: chunk) else { return }
                    usleep(1500)
                }
                _ = MiniHTTPServer.writeChunkedEnd(to: client)
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_real_chunked_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("real_chunked.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            let targetURL = server.baseURL.appendingPathComponent("stream.ts")
            let result = try await client.streamToFile(
                HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                to: destination,
                budget: budget,
                control: { .continue }
            )

            XCTAssertEqual(result.statusCode, 200)
            XCTAssertEqual(result.byteCount, Int64(expectedData.count))
            let fileData = try Data(contentsOf: destination)
            XCTAssertEqual(fileData, expectedData, "真实 Chunked 传输解码后数据必须严格一致")
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }

    // MARK: - Production test 3: real Range 206 + Content-Range total validation and rejection

    func testProductionURLSessionRange206Validation() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let payload = Data(repeating: 0x42, count: 1024)

            server.onRequest = { req, client in
                if req.contains("valid_range.ts") {
                    let headers =
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp2t\r\nContent-Range: bytes 0-1023/4096\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers)
                    _ = MiniHTTPServer.writeAll(to: client, data: payload)
                } else if req.contains("bad_total.ts") {
                    let headers =
                        "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp2t\r\nContent-Range: bytes 0-1023/500\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers)
                    _ = MiniHTTPServer.writeAll(to: client, data: payload)
                } else if req.contains("bad_200_for_range.ts") {
                    let headers =
                        "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers)
                    _ = MiniHTTPServer.writeAll(to: client, data: payload)
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_range_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let byteRange = HLSByteRange(length: 1024, offset: 0)

            // 1. A valid 206 succeeds
            let validDst = tempDir.appendingPathComponent("valid.ts")
            let validURL = server.baseURL.appendingPathComponent("valid_range.ts")
            let res = try await client.streamToFile(
                HLSFetchRequest(url: validURL, byteRange: byteRange, contextOriginURL: validURL),
                to: validDst,
                budget: budget,
                control: { .continue }
            )
            XCTAssertEqual(res.statusCode, 206)
            XCTAssertEqual(res.byteCount, 1024)
            XCTAssertTrue(FileManager.default.fileExists(atPath: validDst.path))

            // 2. A wrong total is rejected and cleaned up
            let badTotalDst = tempDir.appendingPathComponent("bad_total.ts")
            let badTotalURL = server.baseURL.appendingPathComponent("bad_total.ts")
            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: badTotalURL, byteRange: byteRange, contextOriginURL: badTotalURL),
                    to: badTotalDst,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("应拒绝错误的 total")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: badTotalDst.path))
            }

            // 3. A 200 response to a Range request is rejected and cleaned up
            let bad200Dst = tempDir.appendingPathComponent("bad_200.ts")
            let bad200URL = server.baseURL.appendingPathComponent("bad_200_for_range.ts")
            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: bad200URL, byteRange: byteRange, contextOriginURL: bad200URL),
                    to: bad200Dst,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("Range 请求返回 200 必须被拒绝")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: bad200Dst.path))
            }
        }
    }

    // MARK: - Production test 4: terminate and clean up when unknown length exceeds the safety cap

    func testProductionURLSessionExceedingSafetyCapTerminatesAndCleansUp() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            server.onRequest = { req, client in
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)
                let chunk = Data(repeating: 0x99, count: 16 * 1024)
                for _ in 0..<4 {
                    _ = MiniHTTPServer.writeAll(to: client, data: chunk)
                    usleep(2000)
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_cap_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("overflow.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10, unitSafetyCap: 32 * 1024)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let targetURL = server.baseURL.appendingPathComponent("overflow.ts")

            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: destination,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("超限必须抛出 resourceTooLarge")
            } catch let IDMError.resourceTooLarge(limit) {
                XCTAssertEqual(limit, 32 * 1024)
            } catch {
                XCTFail("预期抛出 resourceTooLarge，实际为: \(error)")
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "超限后临时文件必须被清理")
            XCTAssertEqual(budget.reservedBytes, 0, "超限后预算必须归零")
        }
    }

    // MARK: - Production test 5: pre-setup invalid Range validation with zero resource leaks

    func testProductionURLSessionSetupInvalidByteRangeDoesNotLeak() async throws {
        try await withTimeout(seconds: 5) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_setup_invalid_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("invalid.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let targetURL = URL(string: "http://127.0.0.1:9999/test.ts")!

            let invalidRange = HLSByteRange(length: 0, offset: 0)
            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, byteRange: invalidRange, contextOriginURL: targetURL),
                    to: destination,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("非法 byteRange 必须在前置阶段被拒绝")
            } catch IDMError.invalidContentRange {
                // Expected
            } catch {
                XCTFail("预期抛出 invalidContentRange，实际为: \(error)")
            }

            let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            XCTAssertTrue(files.isEmpty, "前置拒绝绝不可残留任何临时文件")
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }

    // MARK: - Production test 6: stream with a full budget; external cancellation exits fast, resources at zero

    func testProductionURLSessionBudgetFullCancellation() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let testData = Data(repeating: 0x55, count: 64 * 1024)
            server.onRequest = { [testData] req, client in
                let headers =
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(testData.count)\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)
                _ = MiniHTTPServer.writeAll(to: client, data: testData)
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_budget_cancel_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("budget_cancel.ts")
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            let blocker = try await budget.reserve(bytes: 64 * 1024)
            defer { blocker.release() }

            let client = URLSessionHLSResourceClient(requestTimeout: 10, resourceTimeout: 10)
            let targetURL = server.baseURL.appendingPathComponent("block.ts")

            let task: Task<HLSStreamToFileResult, Error> = Task {
                try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: destination,
                    budget: budget,
                    control: { .continue }
                )
            }

            let waitDeadline = ContinuousClock.now + .seconds(2)
            while budget.waitingCount < 1 && ContinuousClock.now < waitDeadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertGreaterThanOrEqual(budget.waitingCount, 1, "流式写入必须真实进入预算排队等待")

            let startTime = ContinuousClock.now
            task.cancel()

            do {
                _ = try await task.value
                XCTFail("应当抛出取消错误")
            } catch IDMError.cancelled {
                // Expected exact cancellation
            } catch {
                XCTAssertTrue(
                    error is CancellationError || (error as NSError).code == NSURLErrorCancelled,
                    "错误必须为明确的取消语义，实际为: \(error)"
                )
            }

            let elapsed = ContinuousClock.now - startTime
            XCTAssertLessThan(elapsed, .seconds(1.0), "预算阻塞取消必须在 1 秒内迅速返回")

            blocker.release()
            XCTAssertEqual(budget.reservedBytes, 0, "释放 blocker 后预算必须为 0")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            XCTAssertTrue(files.isEmpty, "取消后临时文件必须被清理")
        }
    }

    // MARK: - Production test 7: 50 repeated stress rounds with no deadlock or hang

    func testProductionURLSessionRepeatedStressNoHangs() async throws {
        try await withTimeout(seconds: 30) {
            let server = try MiniHTTPServer()
            server.onRequest = { req, client in
                let headers =
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)
                let chunk = Data(repeating: 0x77, count: 16 * 1024)
                for _ in 0..<4 {
                    _ = MiniHTTPServer.writeAll(to: client, data: chunk)
                    usleep(300)
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_stress_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let client = URLSessionHLSResourceClient(requestTimeout: 5, resourceTimeout: 5)
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            for round in 0..<50 {
                try Task.checkCancellation()
                let dest = tempDir.appendingPathComponent("stress_\(round).ts")
                let targetURL = server.baseURL.appendingPathComponent("stress_\(round).ts")
                let result = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: dest,
                    budget: budget,
                    control: { .continue }
                )
                XCTAssertEqual(result.statusCode, 200)
                XCTAssertEqual(result.byteCount, 65536)
                try? FileManager.default.removeItem(at: dest)
            }

            XCTAssertEqual(budget.reservedBytes, 0, "50 轮压力测试后预算必须严格归零")
        }
    }

    // MARK: - Production test 8: AES-128 small-budget peak and release on decryption error

    func testHLSAES128SmallBudgetClampAndErrorRelease() async throws {
        try await withTimeout(seconds: 5) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_aes_budget_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let src = tempDir.appendingPathComponent("source.bin")
            let dst = tempDir.appendingPathComponent("decrypted.bin")

            let fakeCipher = Data(repeating: 0x88, count: 128 * 1024)
            try fakeCipher.write(to: src)

            let key = Data(repeating: 0x11, count: 16)
            let iv = Data(repeating: 0x22, count: 16)

            let smallBudget = MediaBufferBudget(capacity: 2048)

            do {
                _ = try await HLSAES128.decrypt(
                    sourceURL: src,
                    destinationURL: dst,
                    key: key,
                    iv: iv,
                    budget: smallBudget
                )
            } catch {
                // Decrypting fake data may throw decryptionFailed due to padding validation
            }

            XCTAssertEqual(smallBudget.reservedBytes, 0, "无论解密成功或失败，预算必须 100% 释放")
            XCTAssertLessThanOrEqual(smallBudget.peakReservedBytes, 2048, "峰值预留绝不能超出容量 2048 字节")
        }
    }

    // MARK: - Production test 9: AES-128 leaves no 0-byte destination when budget.reserve fails

    func testHLSAES128ReserveFailureCleansUpDestination() async throws {
        try await withTimeout(seconds: 5) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "aes_cleanup_\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let src = tempDir.appendingPathComponent("source.bin")
            let dest = tempDir.appendingPathComponent("dest.bin")
            let plain = Data(repeating: 0x55, count: 4096)
            let key = Data(repeating: 0x01, count: 16)
            let iv = Data(repeating: 0x02, count: 16)
            let cipher = try HLSAES128.decrypt(ciphertext: plain, key: key, iv: iv)
            try cipher.write(to: src)

            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let hold = try await budget.reserve(bytes: 64 * 1024)
            defer { hold.release() }

            let task = Task {
                try await HLSAES128.decrypt(
                    sourceURL: src,
                    destinationURL: dest,
                    key: key,
                    iv: iv,
                    budget: budget
                )
            }

            let deadline = ContinuousClock.now + .seconds(1.0)
            while budget.waitingCount < 1 && ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            task.cancel()

            do {
                _ = try await task.value
                XCTFail("应当抛出取消错误")
            } catch {
                // Expected cancellation captured
            }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dest.path),
                "reserve 失败或取消时，绝不能遗留 0 字节或半成品 destination 文件"
            )
        }
    }

    // MARK: - Production test 10: MediaBufferBudget overflow and over-capacity fast rejection

    func testMediaBufferBudgetOversizedAndOverflowRejection() async throws {
        try await withTimeout(seconds: 5) {
            let budget = MediaBufferBudget(capacity: 4096)

            // 1. bytes > capacity is rejected immediately
            do {
                _ = try await budget.reserve(bytes: 5000)
                XCTFail("超容量申请必须立即抛出 resourceTooLarge")
            } catch let err as IDMError {
                XCTAssertEqual(err, .resourceTooLarge(4096))
            }

            XCTAssertNil(budget.tryReserve(bytes: 5000))

            // 2. Int64 overflow is rejected immediately
            do {
                _ = try await budget.reserve(bytes: Int64.max)
                XCTFail("溢出申请必须立即抛出 resourceTooLarge")
            } catch let err as IDMError {
                XCTAssertEqual(err, .resourceTooLarge(4096))
            }

            XCTAssertNil(budget.tryReserve(bytes: Int64.max))
            XCTAssertEqual(budget.waitingCount, 0, "快速拒绝绝不能进入等待队列挂起")
        }
    }

    // MARK: - Production test 11: sentinel written right after failure must not be deleted

    func testFailedOperationDoesNotDeleteSentinelFileWrittenByCallerAfterwards() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            server.onRequest = { req, client in
                let headers =
                    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 12\r\nConnection: close\r\n\r\nServer Error"
                _ = MiniHTTPServer.writeString(to: client, headers)
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_sentinel_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destinationURL = tempDir.appendingPathComponent("target_output.bin")
            let client = URLSessionHLSResourceClient(requestTimeout: 5, resourceTimeout: 5)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let targetURL = server.baseURL.appendingPathComponent("failure.ts")

            // 1. Run a download that is guaranteed to fail
            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: destinationURL,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("必须抛出 HTTP 500 错误")
            } catch {
                // Expected error captured
            }

            // 2. The caller immediately writes a sentinel file at the same path after the failure
            let sentinelContent = "SENTINEL_TOKEN_\(UUID().uuidString)_PRESERVE_ME".data(using: .utf8)!
            try sentinelContent.write(to: destinationURL, options: .atomic)

            // 3. Wait long enough for all of the old operation's background cleanup to drain
            try await Task.sleep(nanoseconds: 50_000_000)

            // 4. Assert: the old operation's cleanup never deleted the sentinel, and it is intact
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: destinationURL.path),
                "旧操作清理逻辑绝不可误删重试写入的 Sentinel 文件"
            )
            let currentData = try Data(contentsOf: destinationURL)
            XCTAssertEqual(currentData, sentinelContent, "Sentinel 文件内容必须保持 100% 完整无损")
            XCTAssertEqual(budget.reservedBytes, 0, "预算在失败后必须严格归零")
        }
    }

    // MARK: - Production test 12: an existing file with the same name is not deleted on conflict

    func testPreExistingDestinationFileIsNotDeletedOnConflict() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            server.onRequest = { req, client in
                let headers =
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)
                _ = MiniHTTPServer.writeAll(to: client, data: Data(repeating: 0x33, count: 1024))
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_conflict_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destinationURL = tempDir.appendingPathComponent("preexisting.bin")
            let originalContent = "CRITICAL_ORIGINAL_DATA_DO_NOT_DELETE".data(using: .utf8)!
            try originalContent.write(to: destinationURL)

            let client = URLSessionHLSResourceClient(requestTimeout: 5, resourceTimeout: 5)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let targetURL = server.baseURL.appendingPathComponent("unit.ts")

            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: destinationURL,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("目标已存在时必须抛出冲突错误")
            } catch {
                // Expected conflict error captured
            }

            // Assert the original file is intact
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
            let remainingData = try Data(contentsOf: destinationURL)
            XCTAssertEqual(remainingData, originalContent, "冲突发生时绝不可删除或清空已存在的外部文件")
        }
    }

    // MARK: - Production test 13: ByteRange Int64 arithmetic overflow rejection

    func testByteRangeArithmeticOverflowRejection() async throws {
        try await withTimeout(seconds: 5) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_overflow_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destination = tempDir.appendingPathComponent("overflow.bin")
            let client = URLSessionHLSResourceClient(requestTimeout: 5, resourceTimeout: 5)
            let budget = MediaBufferBudget(capacity: 64 * 1024)
            let targetURL = URL(string: "http://127.0.0.1:9999/test.ts")!

            let overflowRange = HLSByteRange(length: Int64.max - 10, offset: 20)
            do {
                _ = try await client.streamToFile(
                    HLSFetchRequest(url: targetURL, byteRange: overflowRange, contextOriginURL: targetURL),
                    to: destination,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("溢出的 byteRange 必须被前置拒绝")
            } catch IDMError.invalidContentRange {
                // Expected
            } catch {
                XCTAssertTrue(error is IDMError)
            }

            let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            XCTAssertTrue(files.isEmpty, "溢出前置拒绝绝不可残留任何临时文件")
        }
    }

    // MARK: - Production test 14: MediaBufferBudget capacity shrink wakes over-limit waiters

    func testMediaBufferBudgetDynamicCapacityShrinkageRejectsImpossibleWaiters() async throws {
        try await withTimeout(seconds: 5) {
            let budget = MediaBufferBudget(capacity: 64 * 1024)

            // 1. Fill the full 64KB
            let hold = try await budget.reserve(bytes: 64 * 1024)
            XCTAssertEqual(budget.availableBytes, 0)

            // 2. Spawn a waiter requesting 48KB
            let task = Task {
                try await budget.reserve(bytes: 48 * 1024, timeout: 0)  // wait indefinitely
            }

            // Wait for it to enter the queue
            let waitDeadline = ContinuousClock.now + .seconds(1)
            while budget.waitingCount < 1 && ContinuousClock.now < waitDeadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertEqual(budget.waitingCount, 1)

            // 3. Dynamically shrink capacity to 32KB (the 48KB request can never be satisfied)
            budget.setCapacity(32 * 1024)

            // 4. Assert the task is woken with a rejection instead of waiting forever
            do {
                _ = try await task.value
                XCTFail("超限的 waiter 必须在容量收缩时立即被拒绝唤醒")
            } catch let IDMError.resourceTooLarge(limit) {
                XCTAssertEqual(limit, 32 * 1024)
            } catch {
                XCTFail("预期抛出 resourceTooLarge(32768)，实际为: \(error)")
            }

            XCTAssertEqual(budget.waitingCount, 0, "超限 waiter 必须已从队列中移除")
            hold.release()
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }

    // MARK: - Production test 15: encrypted batch retries a first-round unit failure to success without EEXIST conflicts

    func testEncryptedBatchRetryDoesNotConflictOnExistingDecryptedDestination() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            let key = Data(repeating: 0x07, count: 16)
            let iv = Data(repeating: 0x08, count: 16)

            let seg1Plain = Data("ENCRYPTED_SEGMENT_1_DATA_PAYLOAD_OK".utf8)
            let seg2Plain = Data("ENCRYPTED_SEGMENT_2_DATA_PAYLOAD_OK".utf8)

            let seg1Cipher = try Self.aes128Encrypt(plainText: seg1Plain, key: key, iv: iv)
            let seg2Cipher = try Self.aes128Encrypt(plainText: seg2Plain, key: key, iv: iv)

            let attempts = OSAllocatedUnfairLock(initialState: 0)

            server.onRequest = { req, client in
                if req.contains("master.m3u8") {
                    let manifest = """
                        #EXTM3U
                        #EXT-X-VERSION:3
                        #EXT-X-TARGETDURATION:10
                        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x08080808080808080808080808080808
                        #EXTINF:10.0,
                        seg1.ts
                        #EXTINF:10.0,
                        seg2.ts
                        #EXT-X-ENDLIST
                        """
                    let headers =
                        "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(manifest.utf8.count)\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers + manifest)
                } else if req.contains("key.bin") {
                    let headers =
                        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(key.count)\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers)
                    _ = MiniHTTPServer.writeAll(to: client, data: key)
                } else if req.contains("seg1.ts") {
                    // seg1 always succeeds
                    let headers =
                        "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(seg1Cipher.count)\r\nConnection: close\r\n\r\n"
                    _ = MiniHTTPServer.writeString(to: client, headers)
                    _ = MiniHTTPServer.writeAll(to: client, data: seg1Cipher)
                } else if req.contains("seg2.ts") {
                    let currentAttempt = attempts.withLock { s -> Int in
                        s += 1
                        return s
                    }
                    if currentAttempt == 1 {
                        // On the first seg2 request, sleep 0.5s to exceed the 0.2s requestTimeout,
                        // failing the TaskGroup and triggering HLSDownloadExecutor's internal
                        // reduced-concurrency batch retry
                        usleep(500_000)
                        let headers =
                            "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(seg2Cipher.count)\r\nConnection: close\r\n\r\n"
                        _ = MiniHTTPServer.writeString(to: client, headers)
                        _ = MiniHTTPServer.writeAll(to: client, data: seg2Cipher)
                    } else {
                        // On retry, seg2 succeeds immediately
                        let headers =
                            "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(seg2Cipher.count)\r\nConnection: close\r\n\r\n"
                        _ = MiniHTTPServer.writeString(to: client, headers)
                        _ = MiniHTTPServer.writeAll(to: client, data: seg2Cipher)
                    }
                }
            }
            server.start()
            defer { server.stop() }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_encrypted_retry_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let finalDestination = tempDir.appendingPathComponent("final_output.ts")
            let client = URLSessionHLSResourceClient(requestTimeout: 0.2, resourceTimeout: 0.2)
            let executor = HLSDownloadExecutor(client: client)

            let request = DownloadRequest(
                url: server.baseURL.appendingPathComponent("master.m3u8"),
                destination: finalDestination,
                maximumParallelRequests: 2,  // fetch 2 segments concurrently to build a partially completed batch
                taskID: UUID()
            )

            let result = try await executor.download(request)
            XCTAssertEqual(result.byteCount, Int64(seg1Plain.count + seg2Plain.count))

            let totalAttempts = attempts.withLock { $0 }
            XCTAssertGreaterThanOrEqual(totalAttempts, 2, "必须确实发生了至少 2 次 seg2 请求尝试以证明触发了批次重试")

            let finalData = try Data(contentsOf: finalDestination)
            var expected = Data()
            expected.append(seg1Plain)
            expected.append(seg2Plain)
            XCTAssertEqual(finalData, expected, "重试后合并的文件内容必须 100% 正确且无损坏")

            // Assert no leftover files in the temp directory besides finalDestination (including *.tmp, *.unit-*, *.cipher, *.sidecar)
            let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            XCTAssertEqual(
                remainingFiles,
                [finalDestination.lastPathComponent],
                "下载完成后 tempDir 下除了最终目标文件外不得残留任何临时文件/密文/孤儿文件，当前发现: \(remainingFiles)"
            )
        }
    }

    // MARK: - Production test 16: a fetch-only MockClient goes through the protocol's default streamToFile

    func testDefaultStreamToFileImplementationUsesFetchAndEnforcesBudget() async throws {
        try await withTimeout(seconds: 5) {
            // Define a MockClient that only implements fetch(_:), strictly testing the protocol extension's default streamToFile
            struct PureFetchMockClient: HLSResourceClient {
                let payload: Data
                func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
                    return HLSFetchResponse(data: payload, finalURL: request.url, statusCode: 200)
                }
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "test_proto_default_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let expectedPayload = Data(repeating: 0x4A, count: 32 * 1024)
            let mockClient = PureFetchMockClient(payload: expectedPayload)
            let budget = MediaBufferBudget(capacity: 16 * 1024)
            let targetURL = URL(string: "http://example.com/segment.ts")!

            // 1. Write normally through the default streamToFile
            let destinationURL = tempDir.appendingPathComponent("out.ts")
            let result = try await mockClient.streamToFile(
                HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                to: destinationURL,
                budget: budget,
                control: { .continue }
            )
            XCTAssertEqual(result.byteCount, Int64(expectedPayload.count))
            XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
            XCTAssertEqual(budget.reservedBytes, 0, "写入完成后预算必须为 0")

            // 2. With an existing destination, the default streamToFile must reject it and never delete the original
            do {
                _ = try await mockClient.streamToFile(
                    HLSFetchRequest(url: targetURL, contextOriginURL: targetURL),
                    to: destinationURL,
                    budget: budget,
                    control: { .continue }
                )
                XCTFail("目标已存在时必须抛出 filenameConflict")
            } catch let err as IDMError {
                guard case .filenameConflict(let path) = err else {
                    XCTFail("预期 filenameConflict，实际: \(err)")
                    return
                }
                XCTAssertEqual(path, destinationURL.path)
            }

            // Assert the existing file's content is intact
            XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
            XCTAssertEqual(budget.reservedBytes, 0)
        }
    }

    // MARK: - Production test 17: MiniHTTPServer repeated stop / concurrent shutdown (covers repeated concurrent stop paths)

    func testMiniHTTPServerRepeatStopAndConcurrentShutdown() async throws {
        try await withTimeout(seconds: 10) {
            let server = try MiniHTTPServer()
            server.onRequest = { req, client in
                let payload = Data(repeating: 0x99, count: 64 * 1024)
                let headers =
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                _ = MiniHTTPServer.writeString(to: client, headers)
                _ = MiniHTTPServer.writeAll(to: client, data: payload)
            }
            server.start()

            // 1. Start several concurrent client connections and call stop() concurrently
            // multiple times to cover repeated close paths (the race-free lock protocol
            // is guaranteed by code structure)
            await withTaskGroup(of: Void.self) { tg in
                for _ in 0..<8 {
                    tg.addTask {
                        if let url = URL(string: "\(server.baseURL.absoluteString)/test") {
                            let config = URLSessionConfiguration.ephemeral
                            config.timeoutIntervalForRequest = 2.0
                            let session = URLSession(configuration: config)
                            _ = try? await session.data(from: url)
                        }
                    }
                }

                // Call stop() concurrently after a tiny delay
                tg.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await withTaskGroup(of: Void.self) { stopGroup in
                        for _ in 0..<10 {
                            stopGroup.addTask {
                                server.stop()
                            }
                        }
                    }
                }
            }
        }
    }
}
