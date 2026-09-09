import CryptoKit
import Foundation
import Security

public struct BridgeSecretStore: Sendable {
    private static let localSecretFileName = "bridge-token-v5"

    public init() {}

    public func load(createIfMissing: Bool) throws -> Data {
        // The unsigned Debug App and its bundled Native Messaging Host do not
        // necessarily resolve the data-protection keychain under the same
        // code identity. If a valid local Debug token already exists, prefer
        // it so both processes use one deterministic bridge identity instead
        // of one process silently creating an inaccessible keychain item.
        if prefersLocalDebugStore,
            let localSecret = try? loadLocalSecret(createIfMissing: false)
        {
            return localSecret
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: MacIDMProtocol.keychainService,
            kSecAttrAccount: MacIDMProtocol.keychainAccount,
            // The Debug bundle is ad-hoc signed and changes its code identity
            // on every rebuild. The data-protection keychain avoids binding
            // this local bridge token to that changing ACL.
            kSecUseDataProtectionKeychain: true,
            // A bridge startup must never block on an unexpected keychain UI.
            // If an item cannot be read silently, surface the failure instead
            // of asking for the login-keychain password on every launch.
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return data
        }
        if Self.shouldUseLocalDebugStore(status) {
            return try loadLocalSecret(createIfMissing: createIfMissing)
        }
        guard status == errSecItemNotFound, createIfMissing else {
            throw BridgeError.keychainFailure(status)
        }

        var secret = Data(count: 32)
        let randomStatus = secret.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw BridgeError.keychainFailure(randomStatus)
        }
        let insert: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: MacIDMProtocol.keychainService,
            kSecAttrAccount: MacIDMProtocol.keychainAccount,
            kSecValueData: secret,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus == errSecDuplicateItem {
            return try load(createIfMissing: false)
        }
        if Self.shouldUseLocalDebugStore(insertStatus) {
            return try loadLocalSecret(createIfMissing: true)
        }
        guard insertStatus == errSecSuccess else {
            throw BridgeError.keychainFailure(insertStatus)
        }
        return secret
    }

    private var prefersLocalDebugStore: Bool {
        let executablePath = CommandLine.arguments.first ?? ""
        if executablePath.contains("/.build/") {
            return true
        }

        let infoURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return Bundle.main.object(forInfoDictionaryKey: "MacIDMLocalDevelopmentBuild") as? Bool
                == true
        }
        return info["MacIDMLocalDevelopmentBuild"] as? Bool == true
    }

    private static func shouldUseLocalDebugStore(_ status: OSStatus) -> Bool {
        // The local ad-hoc Debug bundle has no keychain access-group
        // entitlement, so the data-protection keychain returns -34018 instead
        // of presenting a one-time approval dialog. Authentication UI is also
        // intentionally skipped above; a bridge startup must not block on a
        // password prompt.
        status == errSecMissingEntitlement || status == errSecInteractionNotAllowed
    }

    private func loadLocalSecret(createIfMissing: Bool) throws -> Data {
        let fileManager = FileManager.default
        let directory = BridgePaths.defaultDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let fileURL = directory.appendingPathComponent(Self.localSecretFileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
            else {
                throw BridgeError.keychainFailure(errSecAuthFailed)
            }
            let secret = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard secret.count == 32 else {
                throw BridgeError.keychainFailure(errSecDecode)
            }
            return secret
        }

        guard createIfMissing else {
            throw BridgeError.keychainFailure(errSecItemNotFound)
        }

        var secret = Data(count: 32)
        let randomStatus = secret.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw BridgeError.keychainFailure(randomStatus)
        }

        // createFile gives the token its restrictive mode at creation time.
        // If the App and Native Host race on first launch, read the winner's
        // token instead of generating two different bridge identities.
        if fileManager.createFile(
            atPath: fileURL.path,
            contents: secret,
            attributes: [.posixPermissions: 0o600]
        ) {
            return secret
        }
        return try loadLocalSecret(createIfMissing: false)
    }
}

enum BridgeAuthentication {
    static func randomNonce() throws -> Data {
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw BridgeError.keychainFailure(status) }
        return nonce
    }

    static func proof(
        role: String,
        secret: Data,
        clientNonce: Data,
        serverNonce: Data,
        clientID: String
    ) -> Data {
        var material = Data(role.utf8)
        material.append(0)
        material.append(clientNonce)
        material.append(serverNonce)
        material.append(Data(clientID.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret)))
    }

    static func sessionKey(
        secret: Data,
        clientNonce: Data,
        serverNonce: Data,
        clientID: String
    ) -> Data {
        proof(
            role: "session",
            secret: secret,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientID: clientID
        )
    }

    static func frameTag(sequence: UInt64, body: Data, sessionKey: Data) -> Data {
        var bigEndianSequence = sequence.bigEndian
        var material = withUnsafeBytes(of: &bigEndianSequence) { Data($0) }
        material.append(body)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: material,
                using: SymmetricKey(data: sessionKey)
            ))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
