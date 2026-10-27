import Foundation

// MARK: - Small metadata fetch operation (strict 2MB cap)

final class HLSDataFetchOperation: NSObject, URLSessionDataDelegate, SessionDataTaskRoutingDelegate,
    @unchecked Sendable
{
    private let request: HLSFetchRequest
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let scopedSession: TaskScopedSession?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HLSFetchResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var redirects = 0
    private var terminalError: Error?
    private var cancelled = false
    private var ownsSession = false

    init(
        request: HLSFetchRequest,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        scopedSession: TaskScopedSession? = nil
    ) {
        self.request = request
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.scopedSession = scopedSession
    }

    func run() async throws -> HLSFetchResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            if cancelled {
                lock.unlock()
                finish(.failure(terminalError ?? IDMError.cancelled))
                return
            }
            lock.unlock()
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "GET"
            request.requestContext?.apply(to: &urlRequest, boundTo: request.contextOriginURL)
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let byteRange = request.byteRange {
                guard byteRange.length > 0 else {
                    finish(.failure(IDMError.invalidContentRange))
                    return
                }
                urlRequest.setValue(
                    "bytes=\(byteRange.offset)-\(byteRange.offset + byteRange.length - 1)",
                    forHTTPHeaderField: "Range"
                )
            }
            let session: URLSession
            let ownsSession: Bool
            if let scoped = self.scopedSession {
                session = scoped.session
                ownsSession = false
            } else {
                let configuration = EngineSessionPolicy.makeConfiguration(
                    requestTimeout: requestTimeout,
                    resourceTimeout: resourceTimeout
                )
                session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                ownsSession = true
            }
            let task = session.dataTask(with: urlRequest)
            if let scoped = self.scopedSession {
                scoped.multiplexer.register(dataTask: task, delegate: self)
            }
            lock.lock()
            self.task = task
            self.ownsSession = ownsSession
            if cancelled {
                task.cancel()
            }
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if terminalError == nil { terminalError = IDMError.cancelled }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        DownloadProxyPolicy.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        guard redirects <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            terminalError = IDMError.invalidURL
            completionHandler(nil)
            task.cancel()
            return
        }
        var safe = request
        EngineSessionPolicy.sanitizeRedirectRequest(
            &safe,
            originalURL: response.url,
            targetURL: request.url,
            preserveReferer: true
        )
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(safe)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            terminalError = IDMError.invalidURL
            completionHandler(.cancel)
            return
        }
        self.response = response
        if response.expectedContentLength > 2 * 1024 * 1024 {
            terminalError = IDMError.resourceTooLarge(2 * 1024 * 1024)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let control = request.control {
            switch control() {
            case .continue: break
            case .pause:
                terminalError = IDMError.paused
                dataTask.cancel()
                return
            case .cancel:
                terminalError = IDMError.cancelled
                dataTask.cancel()
                return
            }
        }
        guard Int64(self.data.count) <= 2 * 1024 * 1024 - Int64(data.count) else {
            terminalError = IDMError.resourceTooLarge(2 * 1024 * 1024)
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let ownsSession = self.ownsSession
        let scoped = self.scopedSession
        let currentTask = self.task
        lock.unlock()
        if let currentTask, let scoped {
            scoped.multiplexer.unregister(taskIdentifier: currentTask.taskIdentifier)
        }
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
        if let terminalError {
            finish(.failure(terminalError))
            return
        }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish(.failure(error))
            return
        }
        guard let response else {
            finish(.failure(IDMError.invalidURL))
            return
        }
        guard normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) == "identity" else {
            finish(.failure(IDMError.resourceChanged))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(
                .failure(
                    response.statusCode == 401
                        ? IDMError.authenticationRequired : IDMError.httpStatus(response.statusCode)))
            return
        }
        let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
        if let byteRange = request.byteRange {
            guard response.statusCode == 206,
                contentRange?.start == byteRange.offset,
                contentRange?.endInclusive == byteRange.offset + byteRange.length - 1,
                data.count == byteRange.length
            else {
                finish(.failure(IDMError.invalidContentRange))
                return
            }
        } else {
            guard response.statusCode == 200 else {
                finish(.failure(IDMError.httpStatus(response.statusCode)))
                return
            }
        }
        finish(
            .success(
                HLSFetchResponse(
                    data: data,
                    finalURL: response.url ?? request.url,
                    statusCode: response.statusCode,
                    contentRange: contentRange
                )))
    }

    private func finish(_ result: Result<HLSFetchResponse, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
