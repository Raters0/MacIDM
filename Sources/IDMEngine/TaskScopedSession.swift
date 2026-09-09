import Foundation

/// Defines callbacks for tasks routed through `SessionTaskMultiplexer`.
protocol SessionTaskRoutingDelegate: AnyObject, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    )

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    )

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    )
}

/// Specialized routing for DataTasks (direct segments, HLS playlists/keys).
protocol SessionDataTaskRoutingDelegate: SessionTaskRoutingDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    )

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    )
}

/// Specialized routing for DownloadTasks (HLS stream-to-file operations).
protocol SessionDownloadTaskRoutingDelegate: SessionTaskRoutingDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    )

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    )
}

/// Multiplexes a single task-scoped URLSession across multiple concurrent DataTasks and DownloadTasks,
/// routing delegate callbacks strictly by taskIdentifier.
final class SessionTaskMultiplexer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var dataRoutes: [Int: any SessionDataTaskRoutingDelegate] = [:]
    private var downloadRoutes: [Int: any SessionDownloadTaskRoutingDelegate] = [:]

    var activeRouteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dataRoutes.count + downloadRoutes.count
    }

    func register(dataTask: URLSessionDataTask, delegate: any SessionDataTaskRoutingDelegate) {
        lock.lock()
        defer { lock.unlock() }
        dataRoutes[dataTask.taskIdentifier] = delegate
    }

    func register(downloadTask: URLSessionDownloadTask, delegate: any SessionDownloadTaskRoutingDelegate) {
        lock.lock()
        defer { lock.unlock() }
        downloadRoutes[downloadTask.taskIdentifier] = delegate
    }

    func unregister(taskIdentifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        dataRoutes.removeValue(forKey: taskIdentifier)
        downloadRoutes.removeValue(forKey: taskIdentifier)
    }

    // MARK: - Task Delegate Callbacks

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.isProxy() {
            DownloadProxyPolicy.handle(challenge, completionHandler: completionHandler)
            return
        }
        lock.lock()
        let delegate: (any SessionTaskRoutingDelegate)? =
            dataRoutes[task.taskIdentifier] ?? downloadRoutes[task.taskIdentifier]
        lock.unlock()
        if let delegate {
            delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let delegate: (any SessionTaskRoutingDelegate)? =
            dataRoutes[task.taskIdentifier] ?? downloadRoutes[task.taskIdentifier]
        lock.unlock()
        if let delegate {
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                completionHandler: completionHandler)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let delegate: (any SessionTaskRoutingDelegate)? =
            dataRoutes.removeValue(forKey: task.taskIdentifier)
            ?? downloadRoutes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        delegate?.urlSession(session, task: task, didCompleteWithError: error)
    }

    // MARK: - DataTask Callbacks

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let delegate = dataRoutes[dataTask.taskIdentifier]
        lock.unlock()
        if let delegate {
            delegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let delegate = dataRoutes[dataTask.taskIdentifier]
        lock.unlock()
        delegate?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    // MARK: - DownloadTask Callbacks

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let delegate = downloadRoutes[downloadTask.taskIdentifier]
        lock.unlock()
        delegate?.urlSession(
            session,
            downloadTask: downloadTask,
            didWriteData: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let delegate = downloadRoutes[downloadTask.taskIdentifier]
        lock.unlock()
        delegate?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }
}

/// Encapsulates a single task-scoped URLSession with multiplexed task routing.
final class TaskScopedSession: @unchecked Sendable {
    let session: URLSession
    let multiplexer: SessionTaskMultiplexer
    private let lock = NSLock()
    private var isInvalidated = false

    init(
        requestTimeout: TimeInterval = EngineSessionPolicy.defaultRequestTimeout,
        resourceTimeout: TimeInterval = EngineSessionPolicy.defaultResourceTimeout,
        proxyDictionary: [AnyHashable: Any]? = DownloadProxyPolicy.connectionProxyDictionary
    ) {
        let multiplexer = SessionTaskMultiplexer()
        let configuration = EngineSessionPolicy.makeConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            proxyDictionary: proxyDictionary
        )

        self.multiplexer = multiplexer
        self.session = URLSession(configuration: configuration, delegate: multiplexer, delegateQueue: nil)
    }

    func invalidateAndCancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return }
        isInvalidated = true
        session.invalidateAndCancel()
    }

    func finishTasksAndInvalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return }
        isInvalidated = true
        session.finishTasksAndInvalidate()
    }
}
