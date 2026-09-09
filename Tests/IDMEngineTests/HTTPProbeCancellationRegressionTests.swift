import Foundation
import XCTest

@testable import IDMEngine

final class HTTPProbeCancellationRegressionTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubHTTPProbeURLProtocol.reset()
    }

    private func makeHermeticSessionConfig() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPProbeURLProtocol.self]
        return configuration
    }

    func testCancelBeforeProbeStartThrowsCancellationErrorPromptly() async throws {
        let config = makeHermeticSessionConfig()
        let handler = HTTPHandler(
            probeRequestTimeout: 5,
            probeResourceTimeout: 5,
            sessionConfiguration: config
        )
        let request = DownloadRequest(
            url: URL(string: "https://stub.example.com/test.bin")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sourceKind: .http
        )

        let task = Task {
            try await handler.probe(request)
        }
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled probe must not return success")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? IDMError) == .cancelled,
                "Expected cancellation error but got \(error)"
            )
        }
        XCTAssertEqual(StubHTTPProbeURLProtocol.startedCount, 0, "No network request should be started")
    }

    func testCancelDuringHEADWaitCancelsNetworkTaskAndThrowsCancellation() async throws {
        let config = makeHermeticSessionConfig()
        let headStarted = expectation(description: "HEAD started")
        let headStopped = expectation(description: "HEAD stopLoading invoked")

        StubHTTPProbeURLProtocol.handler = { req in
            if req.httpMethod == "HEAD" {
                headStarted.fulfill()
                // Block until cancelled
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                throw URLError(.cancelled)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        StubHTTPProbeURLProtocol.onStopLoading = { req in
            if req.httpMethod == "HEAD" {
                headStopped.fulfill()
            }
        }

        let handler = HTTPHandler(
            probeRequestTimeout: 5,
            probeResourceTimeout: 5,
            sessionConfiguration: config
        )
        let request = DownloadRequest(
            url: URL(string: "https://stub.example.com/test.bin")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sourceKind: .http
        )

        let task = Task {
            try await handler.probe(request)
        }

        await fulfillment(of: [headStarted], timeout: 2.0)
        task.cancel()
        await fulfillment(of: [headStopped], timeout: 2.0)

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled probe must not return success")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? IDMError) == .cancelled,
                "Expected cancellation error but got \(error)"
            )
        }

        // Verify it never proceeded to Range GET
        XCTAssertFalse(StubHTTPProbeURLProtocol.requestedMethods.contains("GET"), "Must not proceed to Range GET")
    }

    func testCancelDuringRangeGETWaitCancelsNetworkTaskAndThrowsCancellation() async throws {
        let config = makeHermeticSessionConfig()
        let rangeStarted = expectation(description: "Range GET started")
        let rangeStopped = expectation(description: "Range GET stopLoading invoked")

        StubHTTPProbeURLProtocol.handler = { req in
            if req.httpMethod == "HEAD" {
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "1000", "Accept-Ranges": "bytes"]
                )!
                return (resp, Data())
            } else if req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Range") != nil {
                rangeStarted.fulfill()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                throw URLError(.cancelled)
            }
            throw URLError(.badURL)
        }
        StubHTTPProbeURLProtocol.onStopLoading = { req in
            if req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Range") != nil {
                rangeStopped.fulfill()
            }
        }

        let handler = HTTPHandler(
            probeRequestTimeout: 5,
            probeResourceTimeout: 5,
            sessionConfiguration: config
        )
        let request = DownloadRequest(
            url: URL(string: "https://stub.example.com/test.bin")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sourceKind: .http
        )

        let task = Task {
            try await handler.probe(request)
        }

        await fulfillment(of: [rangeStarted], timeout: 2.0)
        task.cancel()
        await fulfillment(of: [rangeStopped], timeout: 2.0)

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled probe must not return success")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? IDMError) == .cancelled,
                "Expected cancellation error but got \(error)"
            )
        }
    }

    func testCancelDuringFallbackGETWaitThrowsCancellation() async throws {
        let config = makeHermeticSessionConfig()
        let fallbackStarted = expectation(description: "Fallback GET started")
        let fallbackStopped = expectation(description: "Fallback GET stopLoading invoked")

        StubHTTPProbeURLProtocol.handler = { req in
            if req.httpMethod == "HEAD" {
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (resp, Data())
            } else if req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Range") != nil {
                // Return 403 to trigger fallback
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (resp, Data())
            } else if req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Range") == nil {
                fallbackStarted.fulfill()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                throw URLError(.cancelled)
            }
            throw URLError(.badURL)
        }
        StubHTTPProbeURLProtocol.onStopLoading = { req in
            if req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Range") == nil {
                fallbackStopped.fulfill()
            }
        }

        let handler = HTTPHandler(
            probeRequestTimeout: 5,
            probeResourceTimeout: 5,
            sessionConfiguration: config
        )
        let request = DownloadRequest(
            url: URL(string: "https://stub.example.com/test.bin")!,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sourceKind: .http
        )

        let task = Task {
            try await handler.probe(request)
        }

        await fulfillment(of: [fallbackStarted], timeout: 2.0)
        task.cancel()
        await fulfillment(of: [fallbackStopped], timeout: 2.0)

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled probe must not return success")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? IDMError) == .cancelled,
                "Expected cancellation error but got \(error)"
            )
        }
    }

    func testCancellationRacesCompletionContinuationResumesExactlyOnce() async throws {
        let config = makeHermeticSessionConfig()
        let handler = HTTPHandler(
            probeRequestTimeout: 5,
            probeResourceTimeout: 5,
            sessionConfiguration: config
        )

        StubHTTPProbeURLProtocol.handler = { req in
            // Random tiny sleep 0-2ms
            try? await Task.sleep(nanoseconds: UInt64.random(in: 100_000...2_000_000))
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "100",
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes",
                    "ETag": "\"test-etag\"",
                ]
            )!
            return (resp, Data(repeating: 0, count: 1))
        }

        for i in 0..<50 {
            let request = DownloadRequest(
                url: URL(string: "https://stub.example.com/race-\(i).bin")!,
                destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                sourceKind: .http
            )
            let task = Task {
                try await handler.probe(request)
            }
            // Cancel either immediately or after 1ms
            if Bool.random() {
                task.cancel()
            } else {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 500_000...2_000_000))
                    task.cancel()
                }
            }

            // Must complete without crash (exact-once continuation resume)
            _ = await task.result
        }
    }
}

private final class StubHTTPProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var onStopLoading: (@Sendable (URLRequest) -> Void)?
    nonisolated(unsafe) private static var _requestedMethods: [String] = []
    nonisolated(unsafe) private static var _startedCount = 0

    static var requestedMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedMethods
    }

    static var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startedCount
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        onStopLoading = nil
        _requestedMethods.removeAll()
        _startedCount = 0
    }

    private var activeTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host == "stub.example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        Self._startedCount += 1
        if let method = request.httpMethod {
            Self._requestedMethods.append(method)
        }
        let currentHandler = Self.handler
        Self.lock.unlock()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let req = request
        activeTask = Task {
            do {
                let (response, data) = try await currentHandler(req)
                guard !Task.isCancelled else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                    return
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    self.client?.urlProtocol(self, didLoad: data)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        activeTask?.cancel()
        activeTask = nil
        Self.lock.lock()
        let onStop = Self.onStopLoading
        Self.lock.unlock()
        onStop?(request)
    }
}
