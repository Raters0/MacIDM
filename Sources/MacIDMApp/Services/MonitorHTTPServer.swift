import Foundation
import Network

/// Lightweight HTTP server that exposes the app's state and a small
/// control surface on `127.0.0.1:7831` so external tools (including AI
/// agents) can monitor and drive downloads without screenshots or UI
/// automation.
///
/// Read endpoints: `/health` answers without a token and reports nothing but
/// liveness and version. `/status`, `/tasks`, `/logs` and `/settings` name
/// files, errors and recent log lines, so they require the same per-launch
/// token as the control surface; local clients read it from the 0600
/// `agent-token` file, which keeps scripted monitoring free of manual
/// credential handling. Any other origin or a non-loopback `Host` is refused.
///
/// Control endpoints (dispatched to the app via ``configure(handler:)``):
/// `POST /downloads`, `POST /tasks/{id}/pause|resume|cancel`,
/// `DELETE /tasks/{id}`, `POST /settings`.
///
/// The server uses `NWListener` from the Network framework — no external
/// dependencies. It binds to localhost only. Every failure is swallowed:
/// the monitor must never crash the download pipeline.
final class MonitorHTTPServer: @unchecked Sendable {
    static let shared = MonitorHTTPServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private let port: UInt16 = 7831
    private var cachedState: MonitorState?
    private var handler: (@Sendable (AgentCommand) async -> AgentResponse)?
    private var token: String?

    /// Bounded resource guards. The monitor is a convenience surface: a client
    /// that stalls, floods or never closes its socket must not be able to hold
    /// app resources open.
    static let maximumConcurrentConnections = 16
    static let requestDeadline: TimeInterval = 15
    private var activeConnections = 0
    private var pendingDeadlines: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var rateLimiter = MonitorRateLimiter(maximumRequests: 40, window: 10)

    struct MonitorState: Codable {
        var timestamp: String
        var appVersion: String
        var bridgeStatus: String
        var ytdlpInstalled: Bool
        var ytdlpVersion: String?
        var ffmpegAvailable: Bool
        var tasks: [StatusExporter.TaskSnapshot]
        var recentLogs: [String]
    }

    /// Commands an external agent may submit over the control endpoints.
    enum AgentCommand: Sendable {
        case addDownload(
            url: String,
            filename: String?,
            directory: String?,
            start: Bool?,
            parallel: Int?
        )
        case pauseTask(id: String)
        case resumeTask(id: String)
        case cancelTask(id: String)
        case removeTask(id: String, deleteFile: Bool)
        case getSettings
        case updateSettings(body: Data)
    }

    /// Uniform JSON envelope returned by the control endpoints.
    struct AgentResponse: Codable, Sendable {
        var ok: Bool
        var message: String?
        var taskID: String?
        var destination: String?
        var task: StatusExporter.TaskSnapshot?
        var settings: SettingsSnapshot?
    }

    /// Settings snapshot shared by `GET /settings` and the status file.
    struct SettingsSnapshot: Codable, Sendable {
        var downloadDirectory: String
        var maximumParallelRequests: Int
        var simultaneousDownloads: Int
        var speedLimitKBps: Int
        var autoStartDownloads: Bool
        var organizeByCategory: Bool
        var archiveOnDelete: Bool
        var notificationSoundsEnabled: Bool
        var clipboardAutoDetect: Bool
        var ytdlpAutoCheckUpdates: Bool
        var colorScheme: String
    }

    /// The one unauthenticated response, kept to "is it alive". Browser-bridge
    /// state belongs to `/status`, where it costs a token to read.
    private struct HealthResponse: Codable {
        var ok: Bool
        var version: String
    }

    private struct TasksResponse: Codable {
        var tasks: [StatusExporter.TaskSnapshot]
    }

    private struct LogsResponse: Codable {
        var logs: [String]
    }

    private struct ErrorResponse: Codable {
        var error: String
    }

    private init() {}

    @MainActor
    func start(stateProvider: @escaping () -> MonitorState?) {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let initial = stateProvider() {
            update(initial)
        }

        guard let portValue = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Bind explicitly to the IPv4 loopback. A default NWListener binds
        // IPv6-only on macOS, which makes plain `http://127.0.0.1:7831`
        // requests from agents fail with connection refused.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: portValue
        )

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    AppLogger.shared.error(
                        .bridge,
                        "monitor server listener failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(String(describing: error)) ?? "SANITIZE_FAILED")"
                    )
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: DispatchQueue.global(qos: .utility))
            lock.lock()
            self.listener = listener
            lock.unlock()
        } catch {
            // Best-effort: if the port is in use or binding fails,
            // continue without the monitor server.
            AppLogger.shared.error(
                .bridge,
                "monitor server could not start: \(YouTubeOutputSanitizer.sanitizedErrorSummary(String(describing: error)) ?? "SANITIZE_FAILED")"
            )
        }
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        lock.unlock()
    }

    func update(_ state: MonitorState) {
        lock.lock()
        cachedState = state
        lock.unlock()
    }

    /// Installs the app-side command dispatcher for the control endpoints.
    @MainActor
    func configure(handler: @escaping @Sendable (AgentCommand) async -> AgentResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// Installs the bearer token required by all protected endpoints.
    /// `/health` stays open without a token so casual liveness checks keep working;
    /// all other read and control endpoints require this token to prevent unauthenticated
    /// local process enumeration and cross-origin abuse.
    @MainActor
    func configure(token newValue: String) {
        lock.lock()
        token = newValue
        lock.unlock()
    }

    // MARK: - Connection handling

    private static let maximumRequestBytes = 1_048_576

    private func handleConnection(_ connection: NWConnection) {
        guard reserveSlot(for: connection) else {
            // Over the concurrency cap: refuse immediately rather than queue a
            // client that would only hold the socket open longer.
            connection.cancel()
            return
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        receiveFullRequest(connection: connection, accumulated: Data())
    }

    /// Takes one bounded slot and arms a single deadline covering the whole
    /// exchange — reading the request and producing the response — so neither a
    /// slow-loris reader nor a stalled control command can hold a connection.
    private func reserveSlot(for connection: NWConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        if activeConnections >= Self.maximumConcurrentConnections {
            lock.unlock()
            AppLogger.shared.warning(
                .bridge, "monitor connection limit reached; rejecting a new connection")
            return false
        }
        activeConnections += 1
        let deadline = DispatchWorkItem { [weak self, connection] in
            self?.handleExpiredConnection(connection)
        }
        pendingDeadlines[identifier] = deadline
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.requestDeadline, execute: deadline)
        return true
    }

    /// Peer label for the rate limiter. Everything here is loopback, so the
    /// value only has to distinguish one local client from another.
    private static func source(of connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else {
            return "\(connection.endpoint)"
        }
        return "\(host)"
    }

    private func handleExpiredConnection(_ connection: NWConnection) {
        releaseSlot(for: connection)
        connection.cancel()
    }

    /// Gives the slot back and disarms the deadline. Idempotent, so the send
    /// path and the expired-connection path can both call it safely. The armed
    /// work item is cancelled outside the lock: a deadline that already fired
    /// (or is about to) only re-enters the same idempotent path, and no callback
    /// runs while this lock is held.
    private func releaseSlot(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        guard let deadline = pendingDeadlines.removeValue(forKey: identifier) else {
            lock.unlock()
            return
        }
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
        deadline.cancel()
    }

    /// Accumulates bytes until the headers and any declared body are
    /// complete (or the connection closes / the request grows too large).
    private func receiveFullRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            guard buffer.count <= Self.maximumRequestBytes else {
                let tooLarge = self.jsonError(status: 413, message: "request too large")
                self.send(connection: connection, response: tooLarge)
                return
            }
            if let request = ParsedRequest(data: buffer), request.bodyComplete {
                self.dispatch(connection: connection, request: request)
                return
            }
            if isComplete || error != nil {
                if let request = ParsedRequest(data: buffer) {
                    self.dispatch(connection: connection, request: request)
                } else {
                    self.send(
                        connection: connection,
                        response: self.jsonError(status: 400, message: "bad request")
                    )
                }
                return
            }
            self.receiveFullRequest(connection: connection, accumulated: buffer)
        }
    }

    private func dispatch(connection: NWConnection, request: ParsedRequest) {
        guard MonitorAccessPolicy.hostIsAllowed(request.headers["host"]),
            MonitorAccessPolicy.originIsAllowed(request.headers["origin"])
        else {
            send(
                connection: connection,
                response: jsonError(status: 400, message: "unexpected host or origin"))
            return
        }
        let source = Self.source(of: connection)
        lock.lock()
        let withinBudget = rateLimiter.shouldAccept(source: source)
        lock.unlock()
        if !withinBudget {
            send(
                connection: connection,
                response: jsonError(status: 429, message: "too many requests"))
            return
        }
        // `/health` is the whole unauthenticated surface: a liveness flag and
        // the version. Everything that names files, errors or log lines needs
        // the token, including the read endpoints that used to be open.
        if MonitorAccessPolicy.isPublicReadEndpoint(
            method: request.method, path: request.path)
        {
            send(connection: connection, response: routeGet(request))
            return
        }
        lock.lock()
        let expectedToken = token
        lock.unlock()
        // Fail closed. An unset token used to fall through and serve every read
        // endpoint unauthenticated, which is exactly what a caller racing the
        // startup configuration would see. The token is configured before the
        // listener starts, so this only fires if that ordering regresses or
        // token provisioning failed.
        guard let expectedToken, !expectedToken.isEmpty else {
            send(
                connection: connection,
                response: jsonError(status: 503, message: "monitor token unavailable"))
            return
        }
        if !constantTimeEquals(request.headers["x-macidm-token"], expectedToken) {
            send(
                connection: connection,
                response: jsonError(status: 401, message: "missing or invalid X-MacIDM-Token")
            )
            return
        }
        if request.method == "GET" && request.path != "/settings" {
            // Read endpoints answer from the cached snapshot, but only once the
            // token is accepted. `/settings` needs app state, so it goes
            // through the command handler like the control endpoints.
            send(connection: connection, response: routeGet(request))
            return
        }
        guard let command = parseCommand(request) else {
            send(connection: connection, response: jsonError(status: 404, message: "not found"))
            return
        }
        lock.lock()
        let currentHandler = handler
        lock.unlock()
        guard let currentHandler else {
            send(
                connection: connection,
                response: jsonError(status: 503, message: "app command handler unavailable")
            )
            return
        }
        Task { [weak self] in
            let response = await currentHandler(command)
            self?.send(connection: connection, response: self?.jsonResponse(status: 200, encodable: response) ?? Data())
        }
    }

    private func constantTimeEquals(_ supplied: String?, _ expected: String) -> Bool {
        guard let supplied, supplied.utf8.count == expected.utf8.count else { return false }
        var difference = 0
        for (lhs, rhs) in zip(supplied.utf8, expected.utf8) {
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }

    private func parseCommand(_ request: ParsedRequest) -> AgentCommand? {
        let segments = request.path.split(separator: "/").map(String.init)
        switch (request.method, segments.first ?? "") {
        case ("POST", "downloads"):
            let payload = JSONObject(data: request.body)
            guard let url = payload.string("url"), !url.isEmpty else { return nil }
            return .addDownload(
                url: url,
                filename: payload.string("filename"),
                directory: payload.string("directory"),
                start: payload.bool("start"),
                parallel: payload.int("parallel")
            )
        case ("POST", "tasks"):
            guard segments.count == 3, let action = segments.last else { return nil }
            switch action {
            case "pause": return .pauseTask(id: segments[1])
            case "resume": return .resumeTask(id: segments[1])
            case "cancel": return .cancelTask(id: segments[1])
            default: return nil
            }
        case ("DELETE", "tasks"):
            guard segments.count == 2 else { return nil }
            let deleteFile = request.query["deleteFile"] == "true"
            return .removeTask(id: segments[1], deleteFile: deleteFile)
        case ("GET", "settings"):
            return .getSettings
        case ("POST", "settings"):
            return .updateSettings(body: request.body)
        default:
            return nil
        }
    }

    private func routeGet(_ request: ParsedRequest) -> Data {
        let state = currentState()
        switch request.path {
        case "/status":
            return jsonResponse(status: 200, encodable: state)
        case "/tasks":
            return jsonResponse(
                status: 200,
                encodable: TasksResponse(tasks: state?.tasks ?? [])
            )
        case "/logs":
            return jsonResponse(
                status: 200,
                encodable: LogsResponse(logs: state?.recentLogs ?? [])
            )
        case "/health":
            return jsonResponse(
                status: 200,
                encodable: HealthResponse(
                    ok: true,
                    version: state?.appVersion ?? "unknown"
                )
            )
        default:
            return jsonError(status: 404, message: "not found")
        }
    }

    private func currentState() -> MonitorState? {
        lock.lock()
        defer { lock.unlock() }
        return cachedState
    }

    // MARK: - Request parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        let bodyComplete: Bool

        init?(data: Data) {
            // Header section ends at the first CRLFCRLF.
            guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
            let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let firstLine = lines.first else { return nil }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            method = String(parts[0])
            let target = String(parts[1])
            let targetParts = target.split(separator: "?", maxSplits: 1)
            path = String(targetParts[0])
            var queryItems: [String: String] = [:]
            if targetParts.count > 1 {
                for pair in targetParts[1].split(separator: "&") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1)
                    guard let key = keyValue.first else { continue }
                    queryItems[String(key)] =
                        keyValue.count > 1 ? String(keyValue[1]) : ""
                }
            }
            query = queryItems

            var contentLength = 0
            var headerFields: [String: String] = [:]
            for line in lines.dropFirst() {
                let lowered = line.lowercased()
                if lowered.hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count)
                        .trimmingCharacters(in: .whitespaces)
                    contentLength = Int(value) ?? 0
                }
                if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].lowercased()
                        .trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    headerFields[name] = value
                }
            }
            headers = headerFields
            let bodyData = data.subdata(in: headerRange.upperBound..<data.endIndex)
            body = bodyData
            bodyComplete = bodyData.count >= contentLength
        }
    }

    /// Minimal JSON object reader used for request payloads.
    private struct JSONObject {
        let dictionary: [String: Any]

        init(data: Data) {
            dictionary =
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        func string(_ key: String) -> String? {
            dictionary[key] as? String
        }

        func bool(_ key: String) -> Bool? {
            dictionary[key] as? Bool
        }

        func int(_ key: String) -> Int? {
            if let number = dictionary[key] as? NSNumber {
                return number.intValue
            }
            return nil
        }
    }

    // MARK: - HTTP response building

    private func send(connection: NWConnection, response: Data) {
        // The slot and its deadline stay armed until the bytes are actually
        // written: releasing earlier would let a client that reads the response
        // slowly keep a live socket outside the concurrency cap.
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                self.releaseSlot(for: connection)
                connection.cancel()
            })
    }

    private func jsonResponse<T: Encodable>(status: Int, encodable: T?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(encodable) else {
            return jsonError(status: 500, message: "internal error")
        }
        return httpResponse(status: status, bodyData: body)
    }

    private func jsonError(status: Int, message: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(ErrorResponse(error: message))) ?? Data()
        return httpResponse(status: status, bodyData: body)
    }

    private func httpResponse(status: Int, bodyData: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default: statusText = "OK"
        }

        let header =
            "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var result = Data(header.utf8)
        result.append(bodyData)
        return result
    }
}
