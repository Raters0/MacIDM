import Foundation
import MacIDMBridge

/// Credentials and the editable draft remain in memory until user confirmation.
struct PendingInteractiveTakeover {
    let request: MessageRequest
    let clientID: String
    let secret: Data
    let expiresAt: Date
}

extension AppModel {
    func validatedInteractiveTakeover(_ key: String) throws -> PendingInteractiveTakeover {
        guard let pending = pendingInteractiveTakeovers[key], pending.expiresAt > Date(),
            let browserID = pending.request.payload["browserDownloadId"]?.intValue,
            !abandonedTakeovers.contains(where: {
                $0.matches(
                    clientID: pending.clientID, idempotencyKey: pending.request.idempotencyKey,
                    browserDownloadID: browserID)
            }),
            !browserTakeovers.contains(where: {
                $0.authenticatedClientID == pending.clientID && $0.idempotencyKey == pending.request.idempotencyKey
            })
        else { throw BrowserTakeoverError.abandoned }
        return pending
    }

    func cancelInteractiveTakeoverDraft(_ key: String?) {
        guard let key, let pending = pendingInteractiveTakeovers.removeValue(forKey: key) else { return }
        // Closing a successfully submitted window must not cancel its ready task.
        guard
            !browserTakeovers.contains(where: {
                $0.authenticatedClientID == pending.clientID && $0.idempotencyKey == pending.request.idempotencyKey
            }), let browserID = pending.request.payload["browserDownloadId"]?.intValue
        else { return }
        rememberAbandonedTakeover(
            clientID: pending.clientID, idempotencyKey: pending.request.idempotencyKey, browserDownloadID: browserID
        )
        persistBrowserTakeoversOrPresentError()
    }

    func makeInteractiveTakeoverRecord(
        _ pending: PendingInteractiveTakeover, task: AppTask, startImmediately: Bool
    ) throws -> BrowserTakeoverRecord {
        guard let browserID = pending.request.payload["browserDownloadId"]?.intValue else {
            throw BrowserTakeoverError.abandoned
        }
        let destination = URL(fileURLWithPath: task.destinationPath)
        let reservation = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(task.id.uuidString).macidm.takeover")
        let token = TakeoverToken.make(
            secret: pending.secret, requestID: pending.request.requestId,
            browserDownloadID: browserID, taskID: task.id
        )
        try takeoverStore.reserve(path: reservation)
        return BrowserTakeoverRecord(
            authenticatedClientID: pending.clientID, idempotencyKey: pending.request.idempotencyKey,
            originalRequestID: pending.request.requestId, browserDownloadID: browserID, taskID: task.id,
            destinationPath: destination.path, reservationPath: reservation.path,
            tokenHash: TakeoverToken.hash(token), state: .appReady, updatedAt: Date(),
            startAfterTakeover: startImmediately
        )
    }
}
