import Foundation

/// Host normalization and the rules for what may hold a site session.
///
/// Capture, manual paste and lookup all resolve through here so a session key
/// cannot mean one thing when written and another when matched. The important
/// rule is that a session key must be a host the user actually visited, not a
/// delegated suffix: a session stored under `co.uk` would attach its cookie to
/// every `.co.uk` site the user later downloaded from.
enum SessionDomainPolicy {
    /// Second-level public suffixes that must never become a session key on
    /// their own. A maintained subset rather than the full Public Suffix List:
    /// the residual risk is a *manually pasted* suffix domain, which this
    /// covers for the common cases, while browser-captured keys are always real
    /// hosts. Adding the full list needs a data file and a updater, tracked as
    /// the site-session policy.
    private static let secondLevelPublicSuffixes: Set<String> = [
        "ac.cn", "ac.in", "ac.jp", "ac.nz", "co.ae", "co.at", "co.au", "co.il", "co.in",
        "co.jp", "co.kr", "co.nz", "co.ua", "co.uk", "co.za", "com.au", "com.br", "com.cn",
        "com.co",
        "com.de", "com.es", "com.fr", "com.hk", "com.id", "com.my", "com.mx",
        "com.ng", "com.tr", "com.tw", "com.ua", "com.sg", "edu.au", "edu.cn", "edu.hk",
        "edu.in", "edu.pl", "edu.sg", "gd.jp", "go.jp", "gov.au", "gov.br", "gov.cn",
        "gov.hk", "gov.in", "gov.pl", "gov.tr", "gov.uk", "gov.za", "me.uk", "mod.uk", "ne.jp",
        "nhs.uk",
        "net.au", "net.br", "net.cn", "net.in", "net.jp", "net.nz", "net.pl", "net.ru",
        "net.za", "or.jp", "org.au", "org.br", "org.cn", "org.hk", "org.il", "org.in",
        "org.nz", "org.pl", "org.ru", "org.uk", "org.za", "sch.uk", "web.za",
    ]

    /// Lowercases, drops a legal port, and validates the host shape.
    ///
    /// The `www.` label is deliberately preserved: `www.example.com` and
    /// `example.com` are two different hosts, and folding them let a cookie
    /// captured on one be replayed to the other. This normalization is also not
    /// a Cookie-semantics implementation — a stored raw `Cookie` header carries
    /// no Domain/Path/Secure/HostOnly attributes, and this type only decides
    /// what may name a session key.
    static func normalizedDomain(_ raw: String) -> String? {
        var host = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a legal port may follow the host. Anything else in that position
        // (a path, userinfo, an empty or out-of-range port) is refused here
        // rather than silently truncated at every caller.
        if let colon = host.firstIndex(of: ":") {
            guard isLegalPort(host[host.index(after: colon)...]) else { return nil }
            host = String(host[..<colon])
        }
        // Anything left that is not host material (a path, userinfo, a second
        // port separator) is refused here rather than at every caller.
        if host.contains("/") || host.contains("@") || host.contains(" ")
            || host.contains("?") || host.contains("#") || host.contains("%")
        {
            return nil
        }
        return host.isEmpty ? nil : host
    }

    private static func isLegalPort(_ raw: Substring) -> Bool {
        guard !raw.isEmpty, raw.count <= 5, raw.allSatisfy(\.isNumber),
            let port = Int(raw), (1...65535).contains(port)
        else { return false }
        return true
    }

    /// True when `domain` is safe to use as a session key.
    ///
    /// Rejects IP literals in any spelling (they have no subdomain relationship
    /// worth sharing), single-label hosts and bare TLDs, malformed labels, and
    /// a two-label domain that is really a delegated public suffix.
    static func isUsableSessionKey(_ domain: String) -> Bool {
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        guard !domain.contains("@"), !domain.contains("/"), !domain.contains(" ") else {
            return false
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ isValidLabel($0) }) else { return false }
        // A numeric final label means an IP literal in any spelling
        // (`127.0.0.1`, `0x7f.0.0.1`, `1.2.3.4`), which shares no subdomain
        // relationship worth reusing a login state for.
        let topLabel = labels[labels.count - 1]
        if topLabel.allSatisfy(\.isNumber) { return false }
        // A top-level label is at least two characters and starts with a letter,
        // which also rejects `example.c` and digit-leading pseudo-hosts.
        guard topLabel.count >= 2, let firstCharacter = topLabel.first, firstCharacter.isLetter
        else { return false }
        let trailing = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if labels.count == 2, secondLevelPublicSuffixes.contains(trailing) { return false }
        return true
    }

    /// Resolves a host to a session key, or nil when it must not hold one.
    static func sessionKey(forHost host: String?) -> String? {
        guard let host, let domain = normalizedDomain(host), isUsableSessionKey(domain) else {
            return nil
        }
        return domain
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
