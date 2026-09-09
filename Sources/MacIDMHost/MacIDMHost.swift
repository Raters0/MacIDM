import Foundation
import MacIDMBridge

private enum HostConfiguration {
    static let version = "1.0.0"
    static let expectedExtensionID = "obaipbnfoifafgcpekkfkapjifjgbjag"
    static let expectedOrigin = "chrome-extension://\(expectedExtensionID)/"
    static let clientInstanceID = "chrome:\(expectedExtensionID)"
}

@main
struct MacIDMHost {
    static func main() {
        // Chrome may close the native messaging pipes at any moment; writing
        // to a dead stdout would otherwise kill the Host with SIGPIPE instead
        // of surfacing the write error.
        signal(SIGPIPE, SIG_IGN)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--version"] {
                print("macidm-host \(HostConfiguration.version) protocol \(MacIDMProtocol.version)")
                return
            }
            try validateBrowserOrigin(arguments.first)
            try runNativeMessagingLoop()
        } catch {
            FileHandle.standardError.write(
                Data("macidm-host: \(safeDescription(error))\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func runNativeMessagingLoop() throws {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        let appConnection = AppConnection()
        while let data = try NativeMessagingFraming.readMessage(from: input) {
            let response = forward(data, appConnection: appConnection)
            try NativeMessagingFraming.writeMessage(try MessageCodec.encode(response), to: output)
        }
    }

    private static func forward(_ data: Data, appConnection: AppConnection) -> MessageResponse {
        do {
            let request = try MessageCodec.decodeRequest(data)
            return try appConnection.send(request)
        } catch BridgeError.protocolVersionMismatch {
            return .failure(
                requestId: MessageCodec.requestID(from: data),
                code: "PROTOCOL_VERSION_MISMATCH",
                retryable: false
            )
        } catch BridgeError.connectionFailed {
            return .failure(
                requestId: MessageCodec.requestID(from: data),
                code: "APP_START_TIMEOUT",
                retryable: true
            )
        } catch {
            return .failure(
                requestId: MessageCodec.requestID(from: data),
                code: error is DecodingError ? "INVALID_MESSAGE" : bridgeCode(for: error),
                retryable: false
            )
        }
    }

    private static func connectToApp() throws -> UDSBridgeClient {
        let secret = try BridgeSecretStore().load(createIfMissing: true)
        let client = UDSBridgeClient(
            secret: secret,
            clientInstanceID: HostConfiguration.clientInstanceID
        )
        do {
            try client.connect()
        } catch {
            try launchDebugApp()
            var connected = false
            for _ in 0..<50 {
                usleep(100_000)
                do {
                    try client.connect()
                    connected = true
                    break
                } catch {
                    continue
                }
            }
            guard connected else { throw BridgeError.connectionFailed }
        }
        return client
    }

    private static func validateBrowserOrigin(_ origin: String?) throws {
        guard origin == HostConfiguration.expectedOrigin else {
            throw BridgeError.unauthenticatedClient
        }
    }

    private static func launchDebugApp() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL: URL
        if executable.path.contains(".app/Contents/MacOS/") {
            appURL = executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
        } else {
            appURL = executable.deletingLastPathComponent().appendingPathComponent("MacIDM.app")
        }
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw BridgeError.connectionFailed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BridgeError.connectionFailed }
    }

    private static func bridgeCode(for error: Error) -> String {
        switch error {
        case BridgeError.keychainFailure: "UNAUTHENTICATED_CLIENT"
        case BridgeError.messageTooLarge: "MESSAGE_TOO_LARGE"
        case BridgeError.protocolVersionMismatch: "PROTOCOL_VERSION_MISMATCH"
        case BridgeError.connectionFailed, BridgeError.connectionClosed: "APP_START_TIMEOUT"
        default: "INVALID_MESSAGE"
        }
    }

    private static func safeDescription(_ error: Error) -> String {
        switch error {
        case BridgeError.unauthenticatedClient: "browser origin was rejected"
        case BridgeError.connectionFailed: "MacIDM App bridge is unavailable"
        default: bridgeCode(for: error)
        }
    }

    private final class AppConnection {
        private var client: UDSBridgeClient?

        func send(_ request: MessageRequest) throws -> MessageResponse {
            if client == nil {
                client = try MacIDMHost.connectToApp()
            }
            do {
                return try client!.send(request)
            } catch {
                client?.close()
                client = try MacIDMHost.connectToApp()
                return try client!.send(request)
            }
        }
    }
}
