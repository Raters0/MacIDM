import XCTest

@testable import MacIDMApp

/// Rules for what may hold a site session. A session key is a credential
/// scope: too wide and one pasted login is sent to unrelated sites.
final class SessionDomainPolicyTests: XCTestCase {

    // MARK: - Normalization

    func testNormalizationLowercasesAndDropsLegalPortButKeepsWWW() {
        // www.example.com and example.com are two different hosts; folding the
        // label let one host's credential be replayed to the other.
        XCTAssertEqual(SessionDomainPolicy.normalizedDomain("www.Example.COM:8443"), "www.example.com")
        XCTAssertEqual(SessionDomainPolicy.normalizedDomain("  CDN.Example.com  "), "cdn.example.com")
        XCTAssertEqual(SessionDomainPolicy.normalizedDomain("example.com/path"), nil)
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("   "))
    }

    func testOnlyALegalPortIsStripped() {
        XCTAssertEqual(SessionDomainPolicy.normalizedDomain("example.com:443"), "example.com")
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("example.com:"), "empty port")
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("example.com:abc"), "non-numeric port")
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("example.com:0"), "port zero")
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("example.com:99999"), "out of range")
        XCTAssertNil(SessionDomainPolicy.normalizedDomain("example.com:8443/path"), "path in port slot")
    }

    // MARK: - Accepted keys

    func testOrdinaryHostsAreUsableKeys() {
        for host in [
            "example.com", "cdn.example.com", "a.b.example.co.uk", "sub.example.com.cn",
            "example.org", "xn--80ak6aa92e.com",
        ] {
            XCTAssertTrue(
                SessionDomainPolicy.isUsableSessionKey(host), "\(host) should hold a session")
        }
    }

    // MARK: - Refused keys

    func testBareTLDsAndSingleLabelsAreRefused() {
        // `com` matched as a suffix would hand this cookie to every .com site.
        for host in ["com", "cn", "nas", "localhost", "tracker", "local"] {
            XCTAssertFalse(
                SessionDomainPolicy.isUsableSessionKey(host), "\(host) must be refused")
        }
    }

    func testDelegatedPublicSuffixesAreRefused() {
        let suffixes = [
            "co.uk", "com.cn", "com.au", "co.jp", "com.br", "org.in", "net.nz", "gov.za",
        ]
        for suffix in suffixes {
            XCTAssertFalse(
                SessionDomainPolicy.isUsableSessionKey(suffix), "\(suffix) must be refused")
        }
        // One label beyond the suffix is exactly a registrable domain.
        for domain in ["bbc.co.uk", "shop.example.com.cn", "bank.co.jp"] {
            XCTAssertTrue(SessionDomainPolicy.isUsableSessionKey(domain))
        }
    }

    func testIPLiteralsInEverySpellingAreRefused() {
        let hosts = [
            "127.0.0.1", "10.0.0.5", "192.168.1.10", "0.0.0.0", "1.2.3.4",
            "127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "::1", "fe80::1",
        ]
        for host in hosts {
            XCTAssertFalse(
                SessionDomainPolicy.isUsableSessionKey(host), "\(host) must be refused")
        }
    }

    func testMalformedHostsAreRefused() {
        for host in [
            "", ".", ".example.com", "example.com.", "exa mple.com", "example..com",
            "-example.com", "example-.com", "example.com:8080", "user@example.com",
            "example.com/path", "example.c",
            "\(String(repeating: "a", count: 64)).com",
        ] {
            XCTAssertFalse(
                SessionDomainPolicy.isUsableSessionKey(host), "\(host) must be refused")
        }
    }

    // MARK: - Session key resolution

    func testSessionKeyNormalizesThenValidates() {
        XCTAssertEqual(
            SessionDomainPolicy.sessionKey(forHost: "www.Example.com:443"), "www.example.com")
        XCTAssertEqual(SessionDomainPolicy.sessionKey(forHost: "cdn.example.com"), "cdn.example.com")
        // Refusing "www.com" was an artifact of www-folding: with the label
        // preserved it is simply a two-label host like any other.
        XCTAssertTrue(SessionDomainPolicy.sessionKey(forHost: "www.com") == "www.com")
        XCTAssertNil(SessionDomainPolicy.sessionKey(forHost: nil))
        XCTAssertNil(SessionDomainPolicy.sessionKey(forHost: ""))
    }

    func testURLHostsResolveThroughTheSameRules() throws {
        let bareSuffix = try XCTUnwrap(URL(string: "https://co.uk/popular"))
        XCTAssertNil(SessionDomainPolicy.sessionKey(forHost: bareSuffix.host))
        let realPage = try XCTUnwrap(URL(string: "https://www.bbc.co.uk/news"))
        XCTAssertEqual(
            SessionDomainPolicy.sessionKey(forHost: realPage.host), "www.bbc.co.uk")
    }
}
