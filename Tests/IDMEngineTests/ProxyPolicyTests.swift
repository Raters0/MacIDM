import XCTest

@testable import IDMEngine

final class ProxyPolicyTests: XCTestCase {
    override func tearDown() {
        DownloadProxyPolicy.configure(nil)
        DownloadProxyPolicy.setForceDirect(false)
        super.tearDown()
    }

    private func makePolicy(
        kind: ProxyKind,
        username: String? = nil,
        password: String? = nil
    ) throws -> DownloadProxyPolicy.Value {
        DownloadProxyPolicy.Value(
            configuration: try ProxyConfiguration(
                kind: kind,
                host: "proxy.example.com",
                port: 8080,
                credentialReference: username.map { try? ProxyCredentialReference(keychainAccount: $0) } ?? nil
            ),
            username: username,
            password: password
        )
    }

    func testHTTPProxyDictionaryUsesDocumentedKeys() throws {
        DownloadProxyPolicy.configure(try makePolicy(kind: .http))
        let dictionary = try XCTUnwrap(DownloadProxyPolicy.connectionProxyDictionary)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPProxy] as? String, "proxy.example.com")
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPPort] as? Int, 8080)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPEnable] as? Bool, true)
    }

    func testSOCKS5ProxyDictionaryUsesSOCKSType() throws {
        DownloadProxyPolicy.configure(try makePolicy(kind: .socks5))
        let dictionary = try XCTUnwrap(DownloadProxyPolicy.connectionProxyDictionary)
        XCTAssertEqual(dictionary[kCFProxyTypeKey] as? String, kCFProxyTypeSOCKS as String)
        XCTAssertEqual(dictionary[kCFProxyHostNameKey] as? String, "proxy.example.com")
        XCTAssertEqual(dictionary[kCFProxyPortNumberKey] as? Int, 8080)
    }

    func testClearingPolicyRemovesDictionary() throws {
        DownloadProxyPolicy.configure(try makePolicy(kind: .https))
        XCTAssertNotNil(DownloadProxyPolicy.connectionProxyDictionary)
        DownloadProxyPolicy.configure(nil)
        XCTAssertNil(DownloadProxyPolicy.connectionProxyDictionary)
        XCTAssertNil(DownloadProxyPolicy.current)
    }

    func testForceDirectOverridesConfiguredProxy() throws {
        DownloadProxyPolicy.configure(try makePolicy(kind: .http))
        DownloadProxyPolicy.setForceDirect(true)
        // An empty dictionary makes CFNetwork bypass system proxy settings and
        // connect directly, semantically distinct from nil (inherit system proxy).
        let dictionary = try XCTUnwrap(DownloadProxyPolicy.connectionProxyDictionary)
        XCTAssertTrue(dictionary.isEmpty)
        DownloadProxyPolicy.setForceDirect(false)
        XCTAssertFalse(DownloadProxyPolicy.connectionProxyDictionary?.isEmpty ?? true)
    }

    func testNonProxyChallengeFallsBackToDefaultHandling() throws {
        DownloadProxyPolicy.configure(
            try makePolicy(kind: .http, username: "user", password: "secret")
        )
        let space = URLProtectionSpace(
            host: "origin.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        XCTAssertFalse(space.isProxy())
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: FailingAuthSender()
        )
        var disposition: URLSession.AuthChallengeDisposition?
        DownloadProxyPolicy.handle(challenge) { result, credential in
            disposition = result
            XCTAssertNil(credential)
        }
        XCTAssertEqual(disposition, .performDefaultHandling)
    }
}

/// URLAuthenticationChallenge requires a sender; the tests never invoke it.
private final class FailingAuthSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
