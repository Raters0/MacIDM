import Darwin
import Foundation
import XCTest

@testable import IDMEngine

private final class MockDataTaskRoutingDelegate: SessionDataTaskRoutingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedData = Data()
    private var _responseReceived: URLResponse?
    private var _completionError: Error?
    private var _challengeReceived = false
    private var _isCompleted = false

    struct Snapshot: Sendable {
        let challengeReceived: Bool
        let responseReceived: URLResponse?
        let receivedData: Data
        let completionError: Error?
        let isCompleted: Bool
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            challengeReceived: _challengeReceived,
            responseReceived: _responseReceived,
            receivedData: _receivedData,
            completionError: _completionError,
            isCompleted: _isCompleted
        )
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCompleted
    }

    var receivedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return _receivedData
    }

    var completionError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _completionError
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        lock.lock()
        _challengeReceived = true
        lock.unlock()
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        _completionError = error
        _isCompleted = true
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        _responseReceived = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        _receivedData.append(data)
        lock.unlock()
    }
}

private final class ControlledTestHTTPServer: @unchecked Sendable {
    let port: Int
    private let serverSocket: Int32
    private let lock = NSLock()
    private var isRunningState = true
    private var isStopped = false
    private let queue = DispatchQueue(label: "controlled-test-server-queue", attributes: .concurrent)

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningState
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

        guard listen(sock, 32) == 0 else {
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

        startAcceptLoop()
    }

    private func startAcceptLoop() {
        queue.async { [weak self] in
            while let self = self, self.isRunning {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.accept(self.serverSocket, saPtr, &clientLen)
                    }
                }
                guard clientSock >= 0 else { break }

                self.queue.async {
                    self.handleClient(clientSock)
                }
            }
        }
    }

    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let readBytes = Darwin.read(clientFd, &buffer, buffer.count)
        guard readBytes > 0 else { return }

        let requestString = String(decoding: buffer[0..<readBytes], as: UTF8.self)
        if requestString.contains("/slow") {
            // Deterministic pause to allow in-flight cancellation
            usleep(300_000)
        }

        let responseBody = Data("HTTP-MULTIPLEX-PAYLOAD-OK".utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        var fullResponse = Data(header.utf8)
        fullResponse.append(responseBody)

        fullResponse.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let bytesWritten = Darwin.write(
                    clientFd,
                    base.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if bytesWritten <= 0 { break }
                totalWritten += bytesWritten
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        isStopped = true
        isRunningState = false
        close(serverSocket)
    }

    deinit {
        stop()
    }
}

final class SessionMultiplexerTests: XCTestCase {
    func testMultiplexedRoutingByTaskIdentifier() {
        let taskSession = TaskScopedSession()
        defer { taskSession.finishTasksAndInvalidate() }

        guard let url1 = URL(string: "https://example.com/seg1"),
            let url2 = URL(string: "https://example.com/seg2")
        else {
            XCTFail("Invalid URLs")
            return
        }

        let request1 = URLRequest(url: url1)
        let request2 = URLRequest(url: url2)

        let task1 = taskSession.session.dataTask(with: request1)
        let task2 = taskSession.session.dataTask(with: request2)

        let delegate1 = MockDataTaskRoutingDelegate()
        let delegate2 = MockDataTaskRoutingDelegate()

        taskSession.multiplexer.register(dataTask: task1, delegate: delegate1)
        taskSession.multiplexer.register(dataTask: task2, delegate: delegate2)

        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 2)

        // Route data chunks to task 1
        let dummyData1 = "Hello Task 1".data(using: .utf8)!
        taskSession.multiplexer.urlSession(taskSession.session, dataTask: task1, didReceive: dummyData1)

        // Route data chunks to task 2
        let dummyData2 = "Hello Task 2".data(using: .utf8)!
        taskSession.multiplexer.urlSession(taskSession.session, dataTask: task2, didReceive: dummyData2)

        XCTAssertEqual(delegate1.receivedData, dummyData1)
        XCTAssertEqual(delegate2.receivedData, dummyData2)

        // Complete task 1
        taskSession.multiplexer.urlSession(taskSession.session, task: task1, didCompleteWithError: nil)
        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 1)

        // Complete task 2
        taskSession.multiplexer.urlSession(taskSession.session, task: task2, didCompleteWithError: nil)
        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 0, "Routes should be zeroed after completion")
    }

    func testCancellationIsolationBetweenTasks() {
        let taskSession = TaskScopedSession()
        defer { taskSession.finishTasksAndInvalidate() }

        guard let url = URL(string: "https://example.com/test") else {
            XCTFail("Invalid URL")
            return
        }

        let request = URLRequest(url: url)
        let task1 = taskSession.session.dataTask(with: request)
        let task2 = taskSession.session.dataTask(with: request)

        let delegate1 = MockDataTaskRoutingDelegate()
        let delegate2 = MockDataTaskRoutingDelegate()

        taskSession.multiplexer.register(dataTask: task1, delegate: delegate1)
        taskSession.multiplexer.register(dataTask: task2, delegate: delegate2)

        // Cancel task 1 explicitly
        task1.cancel()
        taskSession.multiplexer.unregister(taskIdentifier: task1.taskIdentifier)

        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 1)
        XCTAssertEqual(task1.state, .canceling)
        XCTAssertNotEqual(task2.state, .canceling)

        taskSession.multiplexer.unregister(taskIdentifier: task2.taskIdentifier)
        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 0)
    }

    func testTaskScopedSessionEphemeralConfigurationIntegrity() {
        let taskSession = TaskScopedSession()
        defer { taskSession.finishTasksAndInvalidate() }

        let config = taskSession.session.configuration
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertEqual(config.timeoutIntervalForResource, 24 * 60 * 60)
    }

    func testHLSResourceClientReusesProvidedTaskScopedSession() async throws {
        let taskSession = TaskScopedSession()
        defer { taskSession.finishTasksAndInvalidate() }

        let client = URLSessionHLSResourceClient(scopedSession: taskSession)
        XCTAssertTrue(client.scopedSession === taskSession)
    }

    func testLocalHTTPMultiplexingConcurrencyCancellationAndRouteZeroing() async throws {
        let server = try ControlledTestHTTPServer()
        defer { server.stop() }

        let taskSession = TaskScopedSession()
        defer { taskSession.finishTasksAndInvalidate() }

        guard let slowURL = URL(string: "http://127.0.0.1:\(server.port)/slow"),
            let fastURL = URL(string: "http://127.0.0.1:\(server.port)/fast")
        else {
            XCTFail("Invalid server URLs")
            return
        }

        let taskCount = 5
        let delegates = (0..<taskCount).map { _ in MockDataTaskRoutingDelegate() }
        var tasks: [URLSessionDataTask] = []

        for i in 0..<taskCount {
            let targetURL = (i < 2) ? slowURL : fastURL
            var req = URLRequest(url: targetURL)
            req.timeoutInterval = 5
            let task = taskSession.session.dataTask(with: req)
            taskSession.multiplexer.register(dataTask: task, delegate: delegates[i])
            tasks.append(task)
        }

        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, taskCount)

        // Resume ALL tasks so they enter the real URLSession pipeline
        for task in tasks {
            task.resume()
        }

        // Cancel tasks 0 and 1 while running in flight
        tasks[0].cancel()
        tasks[1].cancel()

        // Wait for all 5 tasks to receive their natural URLSession completion callbacks within a 3s deadline
        let deadline = ContinuousClock.now + .seconds(3)
        var allDone = false
        while ContinuousClock.now < deadline {
            let delegatesCompleted = delegates.allSatisfy { $0.isCompleted }
            let routeZeroed = taskSession.multiplexer.activeRouteCount == 0
            if delegatesCompleted && routeZeroed {
                allDone = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(allDone, "All tasks must complete naturally via URLSession delegate within 3s deadline")

        // Assert cancelled tasks (0 and 1) received cancellation error
        let snap0 = delegates[0].snapshot
        let snap1 = delegates[1].snapshot
        XCTAssertTrue(snap0.isCompleted, "Task 0 must be marked completed")
        XCTAssertTrue(snap1.isCompleted, "Task 1 must be marked completed")
        XCTAssertNotNil(snap0.completionError, "Task 0 must receive cancellation error")
        XCTAssertNotNil(snap1.completionError, "Task 1 must receive cancellation error")
        let err0 = snap0.completionError as? NSError
        let err1 = snap1.completionError as? NSError
        XCTAssertEqual(err0?.domain, NSURLErrorDomain)
        XCTAssertEqual(err0?.code, NSURLErrorCancelled)
        XCTAssertEqual(err1?.domain, NSURLErrorDomain)
        XCTAssertEqual(err1?.code, NSURLErrorCancelled)

        // Assert sibling tasks (2, 3, 4) were completely unaffected and received correct payload
        let expectedPayload = Data("HTTP-MULTIPLEX-PAYLOAD-OK".utf8)
        for i in 2..<taskCount {
            let snap = delegates[i].snapshot
            XCTAssertTrue(snap.isCompleted, "Sibling task \(i) must be marked completed")
            XCTAssertNil(snap.completionError, "Sibling task \(i) must succeed without error")
            XCTAssertEqual(snap.receivedData, expectedPayload, "Sibling task \(i) payload must match")
        }

        // Assert activeRouteCount naturally reached zero without ANY manual unregister in test code
        XCTAssertEqual(taskSession.multiplexer.activeRouteCount, 0, "Route table must naturally reach zero")
    }
}
