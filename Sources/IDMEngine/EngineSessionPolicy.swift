import Foundation

/// Unified engine network-session policy and configuration builder (see the public technical specification).
///
/// Eliminates the duplicated ephemeral / cache / cookie / proxy / timeout boilerplate found in
/// TaskScopedSession, Transfer fallback, HLS fallback, HTTPHandler, and the external discovery
/// modules, while guaranteeing that every session follows the strict invariants: no system
/// cache, no automatic cookies, global proxy injection, and the configured timeouts.
public enum EngineSessionPolicy {
    /// Default request timeout (30 seconds)
    public static let defaultRequestTimeout: TimeInterval = 30.0
    /// Default resource timeout (24 hours)
    public static let defaultResourceTimeout: TimeInterval = 24.0 * 60.0 * 60.0

    /// Creates an ephemeral URLSessionConfiguration that satisfies MacIDM's security and
    /// performance invariants.
    ///
    /// - Parameters:
    ///   - requestTimeout: Timeout for a single request (seconds, default 30s)
    ///   - resourceTimeout: Timeout for the whole resource lifecycle (seconds, default 24h)
    ///   - proxyDictionary: Proxy configuration dictionary (defaults to
    ///     DownloadProxyPolicy.connectionProxyDictionary)
    /// - Returns: A configured, independent URLSessionConfiguration instance
    public static func makeConfiguration(
        requestTimeout: TimeInterval = defaultRequestTimeout,
        resourceTimeout: TimeInterval = defaultResourceTimeout,
        proxyDictionary: [AnyHashable: Any]? = DownloadProxyPolicy.connectionProxyDictionary
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.connectionProxyDictionary = proxyDictionary
        return configuration
    }

    /// Strips sensitive authentication headers (Authorization / Cookie) on cross-origin
    /// redirects and checks for HTTPS downgrades.
    ///
    /// - Parameters:
    ///   - request: The new request about to follow the redirect
    ///   - originalURL: The URL the redirect originated from
    ///   - targetURL: The redirect target URL
    ///   - preserveReferer: Whether to keep Referer across origins (still forcibly stripped
    ///     on an HTTPS downgrade)
    public static func sanitizeRedirectRequest(
        _ request: inout URLRequest,
        originalURL: URL?,
        targetURL: URL?,
        preserveReferer: Bool = true
    ) {
        let isCrossOrigin = originalURL?.httpOrigin != targetURL?.httpOrigin
        let isHTTPSDowngrade =
            originalURL?.scheme?.lowercased() == "https"
            && targetURL?.scheme?.lowercased() == "http"

        if isCrossOrigin {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            if !preserveReferer {
                request.setValue(nil, forHTTPHeaderField: "Referer")
            }
        }

        if isHTTPSDowngrade {
            request.setValue(nil, forHTTPHeaderField: "Referer")
        }
    }
}
