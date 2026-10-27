import Foundation
import os

// MARK: - True streaming media segment operation (URLSessionDownloadTask + unique transit
// file + MediaBufferBudget-bounded chunk copy)

final class HLSStreamToFileOperation: NSObject, URLSessionDownloadDelegate, SessionDownloadTaskRoutingDelegate,
    @unchecked Sendable
{
    private struct OperationState {
        var continuation: CheckedContinuation<HLSStreamToFileResult, Error>?
        var downloadTask: URLSessionDownloadTask?
        var session: URLSession?
        var ownsSession: Bool = false
        var response: HTTPURLResponse?
        var transitURL: URL?
        var redirects: Int = 0
        var terminalError: Error?
        var isCancelled: Bool = false
        var completionTask: Task<Void, Never>?
        var networkError: Error?
        var didFinish: Bool = false
    }

    private let request: HLSFetchRequest
    private let destinationURL: URL
    private let budget: MediaBufferBudget
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let unitSafetyCap: Int64
    private let control: @Sendable () -> DownloadControl
    private let scopedSession: TaskScopedSession?
    private let progress: (@Sendable (Int64) -> Void)?

    private let stateLock = OSAllocatedUnfairLock(initialState: OperationState())

    init(
        request: HLSFetchRequest,
        destinationURL: URL,
        budget: MediaBufferBudget,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 24 * 60 * 60,
        unitSafetyCap: Int64 = DownloadResourceLimits.maximumMediaUnitBytes,
        control: @escaping @Sendable () -> DownloadControl,
        scopedSession: TaskScopedSession? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.budget = budget
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.unitSafetyCap = unitSafetyCap
        self.control = control
        self.scopedSession = scopedSession
        self.progress = progress
    }

    func run() async throws -> HLSStreamToFileResult {
        // 1. Pre-validate the request before creating any file or Session
        //    (with Int64 addition overflow checks)
        if let byteRange = request.byteRange {
            guard byteRange.offset >= 0, byteRange.length > 0 else {
                throw IDMError.invalidContentRange
            }
            let (endPlusOne, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
            guard !overflow, endPlusOne > 0 else {
                throw IDMError.invalidContentRange
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let isAlreadyCancelled = stateLock.withLock { s -> Bool in
                    s.continuation = continuation
                    return s.isCancelled
                }
                if isAlreadyCancelled {
                    let err = stateLock.withLock { $0.terminalError ?? IDMError.cancelled }
                    finish(.failure(err))
                    return
                }

                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = "GET"
                request.requestContext?.apply(to: &urlRequest, boundTo: request.contextOriginURL)
                urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

                if let byteRange = request.byteRange {
                    let endInclusive = byteRange.offset + byteRange.length - 1
                    urlRequest.setValue(
                        "bytes=\(byteRange.offset)-\(endInclusive)",
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
                let task = session.downloadTask(with: urlRequest)
                if let scoped = self.scopedSession {
                    scoped.multiplexer.register(downloadTask: task, delegate: self)
                }

                let shouldCancel = stateLock.withLock { s -> Bool in
                    s.session = session
                    s.ownsSession = ownsSession
                    s.downloadTask = task
                    return s.isCancelled
                }

                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let (task, compTask) = stateLock.withLock { s -> (URLSessionDownloadTask?, Task<Void, Never>?) in
            s.isCancelled = true
            if s.terminalError == nil { s.terminalError = IDMError.cancelled }
            return (s.downloadTask, s.completionTask)
        }
        task?.cancel()
        compTask?.cancel()
    }

    // MARK: - Common response metadata validation

    static func validateResponseMetadata(
        response: HTTPURLResponse,
        byteRange: HLSByteRange?
    ) throws {
        guard normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) == "identity" else {
            throw IDMError.resourceChanged
        }

        guard (200...299).contains(response.statusCode) else {
            let err =
                (response.statusCode == 401)
                ? IDMError.authenticationRequired
                : IDMError.httpStatus(response.statusCode)
            throw err
        }

        let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
        if let byteRange {
            let (endPlusOne, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
            guard !overflow, endPlusOne > 0 else {
                throw IDMError.invalidContentRange
            }
            let expectedEndInclusive = endPlusOne - 1
            guard response.statusCode == 206,
                let contentRange,
                contentRange.start == byteRange.offset,
                contentRange.endInclusive == expectedEndInclusive,
                contentRange.total >= endPlusOne
            else {
                throw IDMError.invalidContentRange
            }
        } else {
            // Without a Range request it must be exactly 200 OK (206 is not acceptable)
            guard response.statusCode == 200 else {
                throw IDMError.httpStatus(response.statusCode)
            }
        }
    }

    // MARK: - URLSession Delegate

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
        let count = stateLock.withLock { s -> Int in
            s.redirects += 1
            return s.redirects
        }

        guard count <= 10,
            let scheme = request.url?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            setTerminalError(IDMError.invalidURL)
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
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            stateLock.withLock { $0.response = httpResponse }
            // On the first progress callback, quickly pre-validate response metadata
            do {
                try Self.validateResponseMetadata(response: httpResponse, byteRange: request.byteRange)
            } catch {
                setTerminalError(error)
                downloadTask.cancel()
                return
            }
        }

        switch control() {
        case .continue:
            break
        case .pause:
            setTerminalError(IDMError.paused)
            downloadTask.cancel()
            return
        case .cancel:
            setTerminalError(IDMError.cancelled)
            downloadTask.cancel()
            return
        }

        if totalBytesWritten > unitSafetyCap || totalBytesExpectedToWrite > unitSafetyCap {
            setTerminalError(IDMError.resourceTooLarge(unitSafetyCap))
            downloadTask.cancel()
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            stateLock.withLock { $0.response = httpResponse }
        }

        // Critical: keep the transit file in a dedicated path on the same filesystem as
        // `location`, ensuring a fast same-volume atomic rename
        let transitDir = location.deletingLastPathComponent()
        let transit = transitDir.appendingPathComponent("macidm_transit.\(UUID().uuidString).tmp")

        do {
            if FileManager.default.fileExists(atPath: transit.path) {
                try? FileManager.default.removeItem(at: transit)
            }
            try FileManager.default.moveItem(at: location, to: transit)
            stateLock.withLock { $0.transitURL = transit }
        } catch {
            setTerminalError(IDMError.storageError(error.localizedDescription))
        }

        // Never declare success here; wait for didCompleteWithError to run terminal handling
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Critical: atomically record the network terminal state, then create and
        // register the completionTask
        let (isCancelled, compTask) = stateLock.withLock { s -> (Bool, Task<Void, Never>) in
            s.networkError = error
            if let httpResponse = task.response as? HTTPURLResponse {
                s.response = httpResponse
            }
            let comp = Task { [weak self] in
                guard let self else { return }
                await self.processDownloadCompletion()
            }
            s.completionTask = comp
            return (s.isCancelled, comp)
        }

        if isCancelled {
            compTask.cancel()
        }
    }

    // MARK: - Terminal-state handling and MediaBufferBudget-bounded chunk copy

    private func processDownloadCompletion() async {
        let snap = stateLock.withLock {
            s -> (
                err: Error?,
                transit: URL?,
                resp: HTTPURLResponse?,
                cancelled: Bool,
                sess: URLSession?,
                task: URLSessionDownloadTask?,
                ownsSession: Bool
            ) in
            guard !s.didFinish else { return (nil, nil, nil, false, nil, nil, false) }
            s.didFinish = true
            let finalErr = s.terminalError ?? s.networkError
            return (finalErr, s.transitURL, s.response, s.isCancelled, s.session, s.downloadTask, s.ownsSession)
        }

        guard let session = snap.sess else { return }

        var destinationCreatedBySelf = false
        var createdSink: SafeFileDescriptor? = nil
        let transitURL = snap.transit
        var completionResult: Result<HLSStreamToFileResult, Error>

        do {
            if let err = snap.err {
                throw err
            }
            if snap.cancelled || Task.isCancelled {
                throw IDMError.cancelled
            }
            guard let transitURL, FileManager.default.fileExists(atPath: transitURL.path) else {
                throw IDMError.invalidURL
            }
            guard let response = snap.resp else {
                throw IDMError.invalidURL
            }

            // Strictly re-validate metadata at the terminal state
            try Self.validateResponseMetadata(response: response, byteRange: request.byteRange)

            let transitSize = try FileSupport.fileSize(transitURL)
            guard transitSize <= unitSafetyCap else {
                throw IDMError.resourceTooLarge(unitSafetyCap)
            }

            if let byteRange = request.byteRange {
                guard transitSize == byteRange.length else {
                    throw IDMError.invalidContentRange
                }
            }

            // Create the destination file exclusively; if a same-named file already exists,
            // throw an error and never delete the existing file
            let sink = try SafeFileDescriptor(creatingExclusiveAt: destinationURL)
            createdSink = sink
            destinationCreatedBySelf = true

            let readHandle = try FileHandle(forReadingFrom: transitURL)
            defer { try? readHandle.close() }

            let chunkSize = min(64 * 1024, max(1024, Int(budget.capacity)))
            var copiedBytes: Int64 = 0

            while copiedBytes < transitSize {
                try Task.checkCancellation()
                switch control() {
                case .continue: break
                case .pause: throw IDMError.paused
                case .cancel: throw IDMError.cancelled
                }

                let toRead = Int(min(Int64(chunkSize), transitSize - copiedBytes))

                // Critical: acquire budget before reading each chunk from disk and writing it
                let reservation = try await budget.reserve(bytes: Int64(toRead))
                do {
                    guard let chunk = try readHandle.read(upToCount: toRead), !chunk.isEmpty else {
                        reservation.release()
                        break
                    }
                    try sink.writeAll(chunk)
                    reservation.release()
                    copiedBytes += Int64(chunk.count)
                    progress?(Int64(chunk.count))
                } catch {
                    reservation.release()
                    throw error
                }
            }

            guard copiedBytes == transitSize else {
                throw IDMError.storageError("复制字节数不完整 (预期 \(transitSize)，实际 \(copiedBytes))")
            }

            try sink.synchronize()
            try sink.closeFile()
            createdSink = nil  // closed successfully

            let contentRange = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range"))
            completionResult = .success(
                HLSStreamToFileResult(
                    finalURL: response.url ?? request.url,
                    statusCode: response.statusCode,
                    byteCount: copiedBytes,
                    contentRange: contentRange
                ))
        } catch {
            let finalError: Error
            if Task.isCancelled || (error as? IDMError) == .cancelled || error is CancellationError {
                finalError = IDMError.cancelled
            } else {
                finalError = error
            }
            completionResult = .failure(finalError)
        }

        // Complete file cleanup and terminate the session before waking the continuation with finish.
        if let task = snap.task, let scoped = self.scopedSession {
            scoped.multiplexer.unregister(taskIdentifier: task.taskIdentifier)
        }
        if snap.ownsSession {
            switch completionResult {
            case .success:
                session.finishTasksAndInvalidate()
            case .failure:
                session.invalidateAndCancel()
            }
        }
        switch completionResult {
        case .success:
            if let transitURL {
                try? FileManager.default.removeItem(at: transitURL)
            }
        case .failure:
            if let createdSink {
                try? createdSink.closeFile()
            }
            if destinationCreatedBySelf {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            if let transitURL {
                try? FileManager.default.removeItem(at: transitURL)
            }
        }

        stateLock.withLock { s in
            s.session = nil
            s.downloadTask = nil
            s.transitURL = nil
            s.completionTask = nil
        }

        // Destination/transit cleanup and session termination have been issued;
        // wake the continuation without waiting for the asynchronous invalidation callback.
        finish(completionResult)
    }

    private func finish(_ result: Result<HLSStreamToFileResult, Error>) {
        let cont = stateLock.withLock { s -> CheckedContinuation<HLSStreamToFileResult, Error>? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.resume(with: result)
    }

    private func setTerminalError(_ error: Error) {
        stateLock.withLock { s in
            if s.terminalError == nil {
                s.terminalError = error
            }
        }
    }
}
