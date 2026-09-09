import Foundation
import MacIDMBridge

enum BrowserBridgeStatus: Equatable {
    case stopped
    case listening
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .stopped: String(localized: "未启动")
        case .listening: String(localized: "等待 Chrome 连接")
        case .connected: String(localized: "已连接")
        case .failed: String(localized: "不可用")
        }
    }

    var isAvailable: Bool {
        switch self {
        case .listening, .connected: true
        default: false
        }
    }
}

final class AppBrowserBridge: @unchecked Sendable {
    private var server: UDSBridgeServer?
    private var watchdog: Timer?
    private weak var model: AppModel?

    @MainActor
    func start(model: AppModel) throws {
        guard server == nil else { return }
        self.model = model
        let secret = try BridgeSecretStore().load(createIfMissing: true)
        let bridge = UDSBridgeServer(
            secret: secret,
            expectedClientExecutablePaths: trustedHostPaths()
        ) { [weak model] request, clientID in
            guard let model else {
                return .failure(
                    requestId: request.requestId,
                    code: "APP_UNAVAILABLE",
                    retryable: true
                )
            }
            let box = SynchronousResultBox()
            Task { @MainActor in
                model.browserBridgeLastActivity = Date()
                box.fulfill(await model.handleBrowserBridgeRequest(request, clientID: clientID, secret: secret))
            }
            let isYouTube = request.payload["mediaKind"]?.stringValue == "youtube"
            let waitTimeout: TimeInterval =
                request.type == "media.inspect"
                ? (isYouTube ? 90 : 15) : 30
            return box.wait(requestID: request.requestId, timeout: waitTimeout)
        }
        bridge.onClientAuthenticated = { [weak model] _ in
            Task { @MainActor in
                model?.browserBridgeStatus = .connected
                model?.browserBridgeLastActivity = Date()
            }
        }
        bridge.onClientDisconnected = { [weak model] _ in
            Task { @MainActor in model?.browserBridgeStatus = .listening }
        }
        try bridge.start()
        server = bridge
        model.browserBridgeStatus = .listening
        startWatchdog()
    }

    /// A second instance (both Debug bundles share com.macidm.app) may have
    /// removed the socket file during its own startup before handing over;
    /// the surviving instance keeps accepting on a descriptor whose path is
    /// gone, so every new client fails to connect. Watch the file and rebind
    /// when it vanishes instead of waiting for the user to restart the App.
    @MainActor
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureSocketFileExists()
            }
        }
    }

    @MainActor
    private func ensureSocketFileExists() {
        guard server != nil else { return }
        guard !FileManager.default.fileExists(atPath: BridgePaths.defaultSocket.path) else { return }
        AppLogger.shared.warning(.system, "bridge socket file is missing; restarting bridge listener")
        server?.stop()
        server = nil
        guard let model else { return }
        do {
            try start(model: model)
        } catch {
            model.browserBridgeStatus = .failed(error.localizedDescription)
        }
    }

    private func trustedHostPaths() -> [String] {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let bundledHost = bundleURL.appendingPathComponent("Contents/MacOS/macidm-host")
        let debugHost = bundleURL.deletingLastPathComponent().appendingPathComponent("macidm-host")
        return [bundledHost.path, debugHost.path]
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        server?.stop()
        server = nil
    }
}

private final class SynchronousResultBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: MessageResponse?
    private var completed = false

    func fulfill(_ response: MessageResponse) {
        condition.lock()
        defer { condition.unlock() }
        // Ignore late fulfill if the waiter already timed out and moved on.
        guard !completed else { return }
        completed = true
        value = response
        condition.signal()
    }

    func wait(requestID: String, timeout: TimeInterval = 30) -> MessageResponse {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while value == nil {
            guard condition.wait(until: deadline) else {
                completed = true
                condition.unlock()
                return .failure(
                    requestId: requestID,
                    code: "APP_TIMEOUT",
                    retryable: true,
                    message: String(localized: "MacIDM 处理请求超时，请稍后重试。")
                )
            }
        }
        guard let response = value else {
            condition.unlock()
            return .failure(
                requestId: requestID,
                code: "APP_TIMEOUT",
                retryable: true
            )
        }
        completed = true
        condition.unlock()
        return response
    }
}
