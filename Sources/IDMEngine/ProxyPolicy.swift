import Foundation
import os

/// Global download proxy policy applied to every engine URLSession.
///
/// The App resolves the user's proxy settings (including Keychain-backed
/// credentials) and publishes them here once at startup and on every
/// settings change; engine session factories read the snapshot when they
/// build their ephemeral configurations. Storage is lock-guarded so reads
/// from concurrent download loops are safe.
///
/// Supported matrix (deliberately narrow, matching the Phase 5-3 scope):
/// HTTP/HTTPS proxies with Basic authentication, and SOCKS5 on a
/// best-effort basis (URLSession applies SOCKS dictionaries, but macOS
/// offers no authenticated-SOCKS challenge hook). Digest, NTLM and
/// Kerberos are explicitly unsupported.
public enum DownloadProxyPolicy {
    public struct Value: Equatable, Sendable {
        public let configuration: ProxyConfiguration
        public let username: String?
        public let password: String?

        public init(configuration: ProxyConfiguration, username: String?, password: String?) {
            self.configuration = configuration
            self.username = username
            self.password = password
        }
    }

    private static let state = OSAllocatedUnfairLock<Value?>(initialState: nil)
    private static let directOnly = OSAllocatedUnfairLock<Bool>(initialState: false)

    public static func configure(_ value: Value?) {
        state.withLock { $0 = value }
    }

    /// Force every engine session to bypass OS-level proxy settings.
    /// Intended for diagnostics and network gates where a flaky system
    /// proxy would otherwise poison results; an empty
    /// `connectionProxyDictionary` makes CFNetwork connect directly.
    public static func setForceDirect(_ enabled: Bool) {
        directOnly.withLock { $0 = enabled }
    }

    public static var current: Value? {
        state.withLock { $0 }
    }

    /// `connectionProxyDictionary` for new URLSession configurations, or nil
    /// when no proxy is configured.
    public static var connectionProxyDictionary: [AnyHashable: Any]? {
        if directOnly.withLock({ $0 }) { return [:] }
        guard let configuration = current?.configuration else { return nil }
        switch configuration.kind {
        case .http, .https:
            // The documented HTTP keys also route CONNECT traffic for
            // https:// requests through the same proxy.
            return [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: configuration.host,
                kCFNetworkProxiesHTTPPort: configuration.port,
            ]
        case .socks5:
            return [
                kCFProxyTypeKey: kCFProxyTypeSOCKS,
                kCFProxyHostNameKey: configuration.host,
                kCFProxyPortNumberKey: configuration.port,
            ]
        }
    }

    private static var proxyCredential: URLCredential? {
        guard let value = current,
            let username = value.username, !username.isEmpty,
            let password = value.password
        else { return nil }
        return URLCredential(user: username, password: password, persistence: .none)
    }

    /// Shared delegate hook answering proxy Basic-auth challenges. Rejects
    /// after the first failure so a wrong password surfaces an error
    /// instead of looping forever.
    public static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isProxyBasic =
            space.isProxy()
            && space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
        guard isProxyBasic, challenge.previousFailureCount == 0,
            let credential = proxyCredential
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }
}
