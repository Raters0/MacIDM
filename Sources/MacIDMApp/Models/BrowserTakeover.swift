import CryptoKit
import Foundation

enum BrowserTakeoverState: String, Codable, Sendable {
    case appReady
    case appCancelled
    case browserCancelled
    case conflict
}

struct BrowserTakeoverRecord: Codable, Equatable, Sendable {
    let authenticatedClientID: String
    let idempotencyKey: String
    let originalRequestID: String
    let browserDownloadID: Int
    let taskID: UUID
    let destinationPath: String
    let reservationPath: String
    let tokenHash: String
    var state: BrowserTakeoverState
    var updatedAt: Date
    var startAfterTakeover: Bool? = nil
}

/// Prevents a late/replayed `download.create` from recreating a takeover that
/// Chrome already compensated after the native bridge timed out.  This is
/// deliberately a small identity-only record: signed URLs, cookies, and
/// destination paths never belong in the tombstone.
struct AbandonedBrowserTakeover: Codable, Equatable, Sendable {
    let authenticatedClientID: String
    let idempotencyKey: String
    let browserDownloadID: Int
    var expiresAt: Date

    func matches(clientID: String, idempotencyKey: String, browserDownloadID: Int) -> Bool {
        authenticatedClientID == clientID
            && self.idempotencyKey == idempotencyKey
            && self.browserDownloadID == browserDownloadID
    }
}

enum TakeoverToken {
    static func make(
        secret: Data,
        requestID: String,
        browserDownloadID: Int,
        taskID: UUID
    ) -> String {
        let value = "\(requestID):\(browserDownloadID):\(taskID.uuidString)"
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: SymmetricKey(data: secret)
        )
        return Data(code).base64EncodedString()
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
