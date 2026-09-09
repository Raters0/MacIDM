import Foundation
import IDMEngine

extension AppModel {
    /// Resolves the user's proxy settings — including the Keychain-backed
    /// password — and publishes them to the engine's global proxy policy.
    /// Idempotent: reconfigures only when the effective proxy signature
    /// changes, because a proxy change also invalidates every learned
    /// per-host connection policy (CDN behavior is proxy-dependent).
    func rebuildProxyPolicy() {
        let signature: String?
        if settings.proxyEnabled, settings.proxyConfiguration != nil {
            signature =
                "\(settings.proxyKind.rawValue)|\(settings.proxyHost)|\(settings.proxyPort)|\(settings.proxyUsername)"
        } else {
            signature = nil
        }
        guard signature != lastProxySignature else { return }
        let hadProxy = lastProxySignature != nil
        lastProxySignature = signature

        guard settings.proxyEnabled, let configuration = settings.proxyConfiguration else {
            DownloadProxyPolicy.configure(nil)
            if hadProxy { resetConnectionLearnerAfterProxyChange() }
            return
        }
        let username = settings.proxyUsername.isEmpty ? nil : settings.proxyUsername
        let password = username.flatMap { keychainCredentialStore.loadPassword(username: $0) }
        if configuration.credentialReference != nil && password == nil {
            AppLogger.shared.warning(
                .system,
                "proxy credential configured but Keychain item is missing; connecting without authentication"
            )
        }
        DownloadProxyPolicy.configure(
            DownloadProxyPolicy.Value(
                configuration: configuration,
                username: username,
                password: password
            )
        )
        AppLogger.shared.info(
            .system,
            "proxy configured: \(configuration.kind.rawValue) \(configuration.host):\(configuration.port)"
        )
        resetConnectionLearnerAfterProxyChange()
    }

    private func resetConnectionLearnerAfterProxyChange() {
        Task { await connectionPolicyLearner.resetAll() }
    }
}
