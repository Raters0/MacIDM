import CryptoKit
import Darwin
import Foundation

private struct AuthenticationHello: Codable {
    let kind: String
    let protocolVersion: Int
    let clientNonce: Data
    let clientInstanceId: String
    let clientPublicKey: Data
}

private struct AuthenticationChallenge: Codable {
    let kind: String
    let serverNonce: Data
    let serverPublicKey: Data
    let encryptedSecret: Data
    let proof: Data
}

private struct AuthenticationResponse: Codable {
    let kind: String
    let proof: Data
}

private struct AuthenticationResult: Codable {
    let kind: String
    let accepted: Bool
}

private struct SecureFrame: Codable {
    let sequence: UInt64
    let body: Data
    let authenticationTag: Data
}

public enum BridgePaths {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacIDM", isDirectory: true)
    }

    public static var defaultSocket: URL {
        defaultDirectory.appendingPathComponent("host.sock")
    }
}

public final class UDSBridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (MessageRequest, String) -> MessageResponse

    private let socketURL: URL
    private let secret: Data
    private let expectedClientExecutablePaths: Set<String>
    private let handler: Handler
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var running = false

    public var onClientAuthenticated: (@Sendable (String) -> Void)?
    public var onClientDisconnected: (@Sendable (String) -> Void)?

    public init(
        socketURL: URL = BridgePaths.defaultSocket,
        secret: Data,
        expectedClientExecutablePaths: [String] = [],
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.secret = secret
        self.expectedClientExecutablePaths = Set(
            expectedClientExecutablePaths.compactMap(canonicalPath)
        )
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }

        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(directory)
        try removeStaleSocketIfSafe()

        let serverDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverDescriptor >= 0 else { throw posixError("socket") }
        do {
            try withSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.bind(serverDescriptor, address, length) == 0 else {
                    throw posixError("bind")
                }
            }
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else { throw posixError("chmod") }
            guard Darwin.listen(serverDescriptor, 8) == 0 else { throw posixError("listen") }
        } catch {
            Darwin.close(serverDescriptor)
            throw error
        }
        descriptor = serverDescriptor
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        stateLock.lock()
        let oldDescriptor = descriptor
        descriptor = -1
        running = false
        stateLock.unlock()
        if oldDescriptor >= 0 {
            Darwin.shutdown(oldDescriptor, SHUT_RDWR)
            Darwin.close(oldDescriptor)
        }
        if socketURL.path.hasSuffix("/MacIDM/host.sock") {
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let currentDescriptor = descriptor
            let isRunning = running
            stateLock.unlock()
            guard isRunning, currentDescriptor >= 0 else { return }
            let client = Darwin.accept(currentDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // Any other accept failure means the listen socket is no
                // longer usable. Stop cleanly so future clients get an
                // immediate connectionFailed instead of hanging until their
                // send timeout while nothing accepts.
                stop()
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { Darwin.close(client) }
                try? self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) throws {
        try validatePeer(client)
        try SocketIO.configureTimeouts(client)
        let helloData = try SocketIO.readFrame(client)
        let hello = try JSONDecoder().decode(AuthenticationHello.self, from: helloData)
        guard hello.kind == "auth.hello",
            hello.protocolVersion == MacIDMProtocol.version,
            !hello.clientInstanceId.isEmpty,
            hello.clientInstanceId.utf8.count <= 256,
            hello.clientNonce.count == 32,
            hello.clientPublicKey.count == 32
        else {
            throw BridgeError.unauthenticatedClient
        }

        let serverNonce = try BridgeAuthentication.randomNonce()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let wrappingKey = try UDSKeyAgreement.key(
            privateKey: serverKey,
            peerPublicKey: hello.clientPublicKey,
            clientID: hello.clientInstanceId
        )
        let encryptedSecret = try ChaChaPoly.seal(secret, using: wrappingKey).combined
        let serverProof = BridgeAuthentication.proof(
            role: "server",
            secret: secret,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce,
            clientID: hello.clientInstanceId
        )
        try SocketIO.writeFrame(
            try encodeTransport(
                AuthenticationChallenge(
                    kind: "auth.challenge",
                    serverNonce: serverNonce,
                    serverPublicKey: serverKey.publicKey.rawRepresentation,
                    encryptedSecret: encryptedSecret,
                    proof: serverProof
                )),
            descriptor: client
        )
        let response = try JSONDecoder().decode(
            AuthenticationResponse.self,
            from: SocketIO.readFrame(client)
        )
        let expectedClientProof = BridgeAuthentication.proof(
            role: "client",
            secret: secret,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce,
            clientID: hello.clientInstanceId
        )
        guard response.kind == "auth.response",
            BridgeAuthentication.constantTimeEqual(response.proof, expectedClientProof)
        else {
            try? SocketIO.writeFrame(
                try encodeTransport(AuthenticationResult(kind: "auth.result", accepted: false)),
                descriptor: client
            )
            throw BridgeError.unauthenticatedClient
        }
        try SocketIO.writeFrame(
            try encodeTransport(AuthenticationResult(kind: "auth.result", accepted: true)),
            descriptor: client
        )
        onClientAuthenticated?(hello.clientInstanceId)
        defer { onClientDisconnected?(hello.clientInstanceId) }

        let sessionKey = BridgeAuthentication.sessionKey(
            secret: secret,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce,
            clientID: hello.clientInstanceId
        )
        var inboundSequence: UInt64 = 0
        var outboundSequence: UInt64 = 0
        while true {
            let encodedFrame: Data
            do {
                encodedFrame = try SocketIO.readFrame(client)
            } catch BridgeError.connectionClosed {
                return
            }
            let frame = try JSONDecoder().decode(SecureFrame.self, from: encodedFrame)
            guard frame.sequence == inboundSequence + 1,
                BridgeAuthentication.constantTimeEqual(
                    frame.authenticationTag,
                    BridgeAuthentication.frameTag(
                        sequence: frame.sequence,
                        body: frame.body,
                        sessionKey: sessionKey
                    )
                )
            else {
                throw BridgeError.unauthenticatedClient
            }
            inboundSequence = frame.sequence

            let response: MessageResponse
            do {
                let request = try MessageCodec.decodeRequest(frame.body)
                response = handler(request, hello.clientInstanceId)
            } catch BridgeError.protocolVersionMismatch {
                response = .failure(
                    requestId: MessageCodec.requestID(from: frame.body),
                    code: "PROTOCOL_VERSION_MISMATCH",
                    retryable: false
                )
            } catch {
                response = .failure(
                    requestId: MessageCodec.requestID(from: frame.body),
                    code: "INVALID_MESSAGE",
                    retryable: false
                )
            }
            let body = try MessageCodec.encode(response)
            outboundSequence += 1
            let replyFrame = SecureFrame(
                sequence: outboundSequence,
                body: body,
                authenticationTag: BridgeAuthentication.frameTag(
                    sequence: outboundSequence,
                    body: body,
                    sessionKey: sessionKey
                )
            )
            try SocketIO.writeFrame(try encodeTransport(replyFrame), descriptor: client)
        }
    }

    private func validateOwnedDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
            (info.st_mode & S_IFMT) == S_IFDIR,
            (info.st_mode & 0o077) == 0
        else {
            throw BridgeError.ioFailure("bridge directory ownership or permissions are unsafe")
        }
    }

    private func validatePeer(_ client: Int32) throws {
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard getpeereid(client, &peerUserID, &peerGroupID) == 0, peerUserID == getuid() else {
            throw BridgeError.unauthenticatedClient
        }
        guard !expectedClientExecutablePaths.isEmpty else { return }

        var peerPID: pid_t = 0
        var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0,
            peerPID > 0
        else {
            throw BridgeError.unauthenticatedClient
        }
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(peerPID, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            throw BridgeError.unauthenticatedClient
        }
        let peerPath = String(
            decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard let canonicalPeerPath = canonicalPath(peerPath),
            expectedClientExecutablePaths.contains(canonicalPeerPath)
        else {
            throw BridgeError.unauthenticatedClient
        }
    }

    private func removeStaleSocketIfSafe() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw posixError("lstat")
        }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw BridgeError.ioFailure("refusing to replace an unsafe socket path")
        }
        // A socket file with a live listener must never be deleted: the
        // second instance (e.g. a transient .build/debug bundle launched
        // over a running Debug app — both share com.macidm.app) would
        // otherwise orphan the first instance's accept descriptor while the
        // filesystem path is gone, making the bridge unreachable for every
        // new client until that instance restarts. Probe the path first and
        // only remove it when no listener answers (ECONNREFUSED), which is
        // the crash-leftover case this cleanup exists for.
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { if probe >= 0 { Darwin.close(probe) } }
        if probe >= 0 {
            var liveListener = false
            try withSocketAddress(path: socketURL.path) { address, length in
                liveListener = Darwin.connect(probe, address, length) == 0
            }
            if liveListener {
                throw BridgeError.ioFailure("bridge socket is already in use by a live listener")
            }
        }
        try FileManager.default.removeItem(at: socketURL)
    }
}

public final class UDSBridgeClient: @unchecked Sendable {
    private let socketURL: URL
    private let expectedSecret: Data?
    private let clientInstanceID: String
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var sessionKey = Data()
    private var outboundSequence: UInt64 = 0
    private var inboundSequence: UInt64 = 0

    public init(
        socketURL: URL = BridgePaths.defaultSocket,
        secret: Data? = nil,
        clientInstanceID: String
    ) {
        self.socketURL = socketURL
        expectedSecret = secret
        self.clientInstanceID = clientInstanceID
    }

    deinit {
        close()
    }

    public func connect() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        closeUnlocked()
        let newDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard newDescriptor >= 0 else { throw posixError("socket") }
        do {
            try SocketIO.configureTimeouts(newDescriptor)
            try withSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.connect(newDescriptor, address, length) == 0 else {
                    throw BridgeError.connectionFailed
                }
            }
            descriptor = newDescriptor
            try authenticate()
        } catch {
            closeUnlocked()
            throw error
        }
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        closeUnlocked()
    }

    private func closeUnlocked() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        sessionKey.removeAll()
        outboundSequence = 0
        inboundSequence = 0
    }

    public func send(_ request: MessageRequest) throws -> MessageResponse {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0, !sessionKey.isEmpty else { throw BridgeError.connectionFailed }
        let body = try MessageCodec.encode(request)
        outboundSequence += 1
        let frame = SecureFrame(
            sequence: outboundSequence,
            body: body,
            authenticationTag: BridgeAuthentication.frameTag(
                sequence: outboundSequence,
                body: body,
                sessionKey: sessionKey
            )
        )
        try SocketIO.writeFrame(try encodeTransport(frame), descriptor: descriptor)
        let responseFrame = try JSONDecoder().decode(
            SecureFrame.self,
            from: SocketIO.readFrame(descriptor)
        )
        guard responseFrame.sequence == inboundSequence + 1,
            BridgeAuthentication.constantTimeEqual(
                responseFrame.authenticationTag,
                BridgeAuthentication.frameTag(
                    sequence: responseFrame.sequence,
                    body: responseFrame.body,
                    sessionKey: sessionKey
                )
            )
        else {
            throw BridgeError.unauthenticatedClient
        }
        inboundSequence = responseFrame.sequence
        return try JSONDecoder().decode(MessageResponse.self, from: responseFrame.body)
    }

    private func authenticate() throws {
        let clientNonce = try BridgeAuthentication.randomNonce()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = AuthenticationHello(
            kind: "auth.hello",
            protocolVersion: MacIDMProtocol.version,
            clientNonce: clientNonce,
            clientInstanceId: clientInstanceID,
            clientPublicKey: clientKey.publicKey.rawRepresentation
        )
        try SocketIO.writeFrame(try encodeTransport(hello), descriptor: descriptor)
        let challenge = try JSONDecoder().decode(
            AuthenticationChallenge.self,
            from: SocketIO.readFrame(descriptor)
        )
        guard challenge.serverPublicKey.count == 32 else {
            throw BridgeError.unauthenticatedClient
        }
        let wrappingKey = try UDSKeyAgreement.key(
            privateKey: clientKey,
            peerPublicKey: challenge.serverPublicKey,
            clientID: clientInstanceID
        )
        let sealedSecret = try ChaChaPoly.SealedBox(combined: challenge.encryptedSecret)
        let receivedSecret = try ChaChaPoly.open(sealedSecret, using: wrappingKey)
        let secret = expectedSecret ?? receivedSecret
        if let expectedSecret,
            !BridgeAuthentication.constantTimeEqual(expectedSecret, receivedSecret)
        {
            throw BridgeError.unauthenticatedClient
        }
        let expectedServerProof = BridgeAuthentication.proof(
            role: "server",
            secret: secret,
            clientNonce: clientNonce,
            serverNonce: challenge.serverNonce,
            clientID: clientInstanceID
        )
        guard challenge.kind == "auth.challenge",
            challenge.serverNonce.count == 32,
            BridgeAuthentication.constantTimeEqual(challenge.proof, expectedServerProof)
        else {
            throw BridgeError.unauthenticatedClient
        }
        let clientProof = BridgeAuthentication.proof(
            role: "client",
            secret: secret,
            clientNonce: clientNonce,
            serverNonce: challenge.serverNonce,
            clientID: clientInstanceID
        )
        try SocketIO.writeFrame(
            try encodeTransport(AuthenticationResponse(kind: "auth.response", proof: clientProof)),
            descriptor: descriptor
        )
        let result = try JSONDecoder().decode(
            AuthenticationResult.self,
            from: SocketIO.readFrame(descriptor)
        )
        guard result.kind == "auth.result", result.accepted else {
            throw BridgeError.unauthenticatedClient
        }
        sessionKey = BridgeAuthentication.sessionKey(
            secret: secret,
            clientNonce: clientNonce,
            serverNonce: challenge.serverNonce,
            clientID: clientInstanceID
        )
    }

}

private enum UDSKeyAgreement {
    static func key(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        clientID: String
    ) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("MacIDM UDS key agreement v1".utf8),
            sharedInfo: Data(clientID.utf8),
            outputByteCount: 32
        )
    }
}

private enum SocketIO {
    static func configureTimeouts(_ descriptor: Int32, seconds: Int = 75) throws {
        // A peer may close the socket immediately after rejecting our
        // credentials. Suppress SIGPIPE so the bridge reports a recoverable
        // connection error instead of terminating the App/Host process.
        var noSigPipe: Int32 = 1
        let noSigPipeResult = withUnsafePointer(to: &noSigPipe) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard noSigPipeResult == 0 else { throw posixError("setsockopt(SO_NOSIGPIPE)") }
        // Read timeout must be ≥2.5× the heartbeat interval so a momentarily
        // silent peer (e.g. during a large disk write) is not mistaken for a
        // dead connection. Heartbeat is 30s; 75s gives ample headroom.
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        let receiveResult = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, timeoutSize)
        }
        guard receiveResult == 0 else { throw posixError("setsockopt(SO_RCVTIMEO)") }
        let sendResult = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, timeoutSize)
        }
        guard sendResult == 0 else { throw posixError("setsockopt(SO_SNDTIMEO)") }
    }

    static func readFrame(_ descriptor: Int32) throws -> Data {
        let header = try readExactly(4, descriptor: descriptor)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length <= MacIDMProtocol.maximumUDSFrameSize else {
            throw BridgeError.messageTooLarge
        }
        return try readExactly(Int(length), descriptor: descriptor)
    }

    static func writeFrame(_ data: Data, descriptor: Int32) throws {
        guard data.count <= MacIDMProtocol.maximumUDSFrameSize else {
            throw BridgeError.messageTooLarge
        }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { try writeAll(Data($0), descriptor: descriptor) }
        try writeAll(data, descriptor: descriptor)
    }

    private static func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if amount == 0 { throw BridgeError.connectionClosed }
            if amount < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            offset += amount
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw posixError("write")
            }
            offset += amount
        }
    }
}

private func withSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw BridgeError.ioFailure("socket path is too long")
    }
    withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
        for (index, byte) in bytes.enumerated() {
            pointer.advanced(by: index).pointee = CChar(bitPattern: byte)
        }
        pointer.advanced(by: bytes.count).pointee = 0
    }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func posixError(_ operation: String) -> BridgeError {
    BridgeError.ioFailure("\(operation) failed with errno \(errno)")
}

private func canonicalPath(_ path: String) -> String? {
    path.withCString { pointer in
        guard let resolved = realpath(pointer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func encodeTransport<T: Encodable>(_ value: T) throws -> Data {
    let data = try MessageCodec.encoder().encode(value)
    guard data.count <= MacIDMProtocol.maximumUDSFrameSize else {
        throw BridgeError.messageTooLarge
    }
    return data
}
