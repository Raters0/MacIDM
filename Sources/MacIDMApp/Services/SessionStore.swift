import Foundation

/// A persisted site session *without* its credential: the domain, the non-secret
/// request policy, and the timestamps that decide whether it may still be used.
/// The cookie value itself lives in a ``SessionSecretStore`` (the Keychain in
/// production), so this model is what `sessions.json` holds.
///
/// Sessions are per-site by design — there is no universal session that works
/// across all websites. A stored session is dropped once it exceeds
/// ``SessionStore/maximumSessionLifetime``, and a download that fails with an
/// authentication error marks its domain as possibly expired so the UI can ask
/// the user to refresh it.
struct StoredSession: Codable, Equatable, Sendable {
    let domain: String
    /// The URL scheme the cookie came from. Only `https` is accepted, so a
    /// session is only ever handed to https downloads of the same host; `nil`
    /// marks a legacy record whose scheme cannot be proven — it stays listed
    /// for the user to re-capture but is never reused automatically.
    let scheme: String?
    let userAgent: String?
    var updatedAt: Date
    /// Set when a download using this session failed with an authentication
    /// error — the UI shows an "expired" badge.
    var lastAuthFailureAt: Date?
}

/// Outcome of storing a session, so the manual-paste sheet can say why a
/// session was refused instead of failing silently.
enum SessionStoreOutcome: Equatable {
    case stored
    case emptyCookie
    case rejectedDomain
    /// A non-https URL: site sessions are captured and reused for https only.
    case rejectedScheme
    case secretStorageFailed(message: String)
}

/// The on-disk shape of `sessions.json`.
///
/// `cookieHeader` is present only while the Keychain does not hold that value —
/// i.e. a migration that failed or has not been retried yet. Everything else on
/// disk is credential-free metadata, and the field disappears as soon as the
/// secret is confirmed in the Keychain.
private struct PersistedSessionRecord: Codable {
    let domain: String
    /// `nil` on records written before scheme binding: their origin scheme
    /// cannot be proven, so they are kept but never reused automatically.
    let scheme: String?
    let cookieHeader: String?
    let userAgent: String?
    var updatedAt: Date
    var lastAuthFailureAt: Date?
}

/// Persists site sessions and drives the capture / reuse / expiry flows.
///
/// Cookies are credentials: only non-secret metadata is written to
/// `sessions.json`, the value goes to the Keychain, and no log records it. The
/// file's 0600 permissions limit who can read it, which is not the same as
/// storing a credential safely.
///
/// Scope is deliberately minimal: sessions bind to one https host exactly.
/// A raw `Cookie` header has no Domain/Path/Secure/HostOnly attributes, so this
/// is a safety boundary, not a Cookie-semantics implementation — cross-subdomain
/// and Path-aware reuse wait for structured cookies.
@MainActor
final class SessionStore: ObservableObject {

    /// How long a captured session may be reused before it is dropped. Sized for
    /// a login that survives a working week without asking the user to re-paste
    /// daily; a session that outlives this is treated as expired rather than
    /// kept because it still works.
    static let maximumSessionLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Sorted domain list for the Settings panel.
    @Published private(set) var sessions: [StoredSession] = []

    /// Domains whose cookie could not be moved into the Keychain at launch. The
    /// value is served from memory for this run and stays in `sessions.json`
    /// only while the Keychain does not hold it, so a later launch can retry the
    /// migration instead of losing the session. Reported, not discarded, so a
    /// locked Keychain cannot silently delete a working session.
    @Published private(set) var domainsNeedingReauthorization: [String] = []

    private let fileURL: URL
    private let secrets: SessionSecretStore
    private let fileManager = FileManager.default
    /// Cookies the Keychain does not hold: refused, unreadable, or not migrated
    /// yet. Served from memory this run and kept on disk so the next launch can
    /// retry rather than silently losing the session.
    private var pendingCookies: [String: String] = [:]
    private var rewriteFileAfterLoad = false

    init(directory: URL? = nil, secrets: SessionSecretStore = KeychainSessionSecretStore()) {
        // The default directory is test-isolated (AppSupportPaths): a test
        // constructing AppModel without injecting a session store must never
        // read or mutate the user's real sessions.
        self.fileURL =
            (directory ?? AppSupportPaths.supportDirectory())
            .appendingPathComponent("sessions.json")
        self.secrets = secrets
        loadFromDisk()
        if rewriteFileAfterLoad {
            saveToDisk()
        }
    }

    // MARK: - Public API

    /// Stores the session for a host the user pasted a cookie for. The paste
    /// sheet states that the session applies to https downloads of this host, so
    /// the paste itself is the user's https confirmation; automatic capture goes
    /// through ``store(url:cookie:userAgent:)``, which reads the scheme from the
    /// URL. The cookie value goes to the secret store first: a session is never
    /// recorded while its credential was not accepted.
    @discardableResult
    func store(domain rawDomain: String, cookie: String, userAgent: String?) -> SessionStoreOutcome {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyCookie }
        guard let domain = SessionDomainPolicy.sessionKey(forHost: rawDomain) else {
            return .rejectedDomain
        }
        return storeConfirmedHTTPS(domain: domain, cookie: trimmed, userAgent: userAgent)
    }

    /// Stores the session captured from a browser download. Only https sources
    /// are accepted: an https-captured cookie must never be handed back to the
    /// same host over http.
    @discardableResult
    func store(url: URL, cookie: String, userAgent: String?) -> SessionStoreOutcome {
        guard url.scheme?.lowercased() == "https" else { return .rejectedScheme }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyCookie }
        guard let domain = SessionDomainPolicy.sessionKey(forHost: url.host) else {
            return .rejectedDomain
        }
        return storeConfirmedHTTPS(domain: domain, cookie: trimmed, userAgent: userAgent)
    }

    /// Shared body of the two entry points, both of which have proven the https
    /// assertion (from the URL, or from the user's paste) before arriving here.
    private func storeConfirmedHTTPS(
        domain: String, cookie: String, userAgent: String?
    ) -> SessionStoreOutcome {
        do {
            try secrets.save(cookie, forDomain: domain)
        } catch {
            AppLogger.shared.error(
                .download, "site session cookie rejected by secret store: \(domain)")
            return .secretStorageFailed(message: error.localizedDescription)
        }
        pendingCookies.removeValue(forKey: domain)
        domainsNeedingReauthorization.removeAll { $0 == domain }
        replaceEntry(domain: domain, scheme: "https", userAgent: userAgent)
        AppLogger.shared.info(.download, "site session stored for domain: \(domain)")
        return .stored
    }

    /// Returns the stored session to use for `url`, if any. Expired entries are
    /// dropped here rather than returned.
    ///
    /// The boundary is deliberately narrow - https plus an exact host - and it
    /// is a safety boundary, not a Cookie-semantics implementation:
    /// - `http://` never receives a stored credential, even on the same host;
    /// - `www.example.com` and `example.com` are two different keys, and
    ///   neither serves a sibling subdomain;
    /// - records whose source scheme cannot be proven (legacy rows) stay listed
    ///   for re-capture but are never handed out.
    /// Replaying one login across subdomains or paths needs structured cookies
    /// with their real scope.
    func lookup(url: URL) -> StoredSession? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard let domain = SessionDomainPolicy.sessionKey(forHost: url.host) else { return nil }
        let matches = sessions.filter { $0.domain == domain && $0.scheme == "https" }
        let expired = matches.filter { isExpired($0) }.map(\.domain)
        if !expired.isEmpty { dropExpired(expired) }
        return matches.first { !isExpired($0) }
    }

    /// Resolves the cookie value for a session. Nil means the credential is
    /// gone (deleted, never migrated, or the Keychain refused it) and the
    /// download must continue without a stored session.
    func cookieHeader(for session: StoredSession) -> String? {
        if let pending = pendingCookies[session.domain] { return pending }
        return secrets.value(forDomain: session.domain)
    }

    /// Marks a domain's session as possibly expired after an
    /// authentication-class failure.
    func markAuthFailed(domain rawDomain: String) {
        guard let domain = SessionDomainPolicy.sessionKey(forHost: rawDomain),
            let index = sessions.firstIndex(where: { $0.domain == domain })
        else { return }
        sessions[index].lastAuthFailureAt = Date()
        saveToDisk()
        AppLogger.shared.info(.download, "site session marked expired: \(domain)")
    }

    func remove(domain rawDomain: String) {
        guard let domain = SessionDomainPolicy.sessionKey(forHost: rawDomain),
            sessions.contains(where: { $0.domain == domain })
        else { return }
        sessions.removeAll { $0.domain == domain }
        forgetSecret(domain: domain)
        saveToDisk()
        AppLogger.shared.info(.download, "site session removed: \(domain)")
    }

    func removeAll() {
        guard !sessions.isEmpty else { return }
        for session in sessions { forgetSecret(domain: session.domain) }
        sessions.removeAll()
        domainsNeedingReauthorization.removeAll()
        saveToDisk()
        AppLogger.shared.info(.download, "all site sessions removed")
    }

    // MARK: - Expiry

    private func isExpired(_ session: StoredSession, now: Date = Date()) -> Bool {
        now.timeIntervalSince(session.updatedAt) > Self.maximumSessionLifetime
    }

    private func dropExpired(_ domains: [String]) {
        guard !domains.isEmpty else { return }
        sessions.removeAll { domains.contains($0.domain) }
        for domain in domains { forgetSecret(domain: domain) }
        saveToDisk()
    }

    private func forgetSecret(domain: String) {
        pendingCookies.removeValue(forKey: domain)
        domainsNeedingReauthorization.removeAll { $0 == domain }
        secrets.removeValue(forDomain: domain)
    }

    private func replaceEntry(domain: String, scheme: String, userAgent: String?) {
        let entry = StoredSession(
            domain: domain,
            scheme: scheme,
            userAgent: userAgent,
            updatedAt: Date(),
            lastAuthFailureAt: nil
        )
        sessions.removeAll { $0.domain == domain }
        sessions.append(entry)
        sessions.sort { $0.domain < $1.domain }
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PersistedSessionRecord].self, from: data) else {
            return
        }
        let now = Date()
        var migrated: [StoredSession] = []
        for record in decoded {
            guard let domain = SessionDomainPolicy.sessionKey(forHost: record.domain) else {
                // A key that was never safe (a bare public suffix, an IP) must
                // not survive into the new model, credential included.
                if record.cookieHeader != nil { secrets.removeValue(forDomain: record.domain) }
                rewriteFileAfterLoad = true
                continue
            }
            let session = StoredSession(
                domain: domain,
                scheme: record.scheme == "https" ? "https" : nil,
                userAgent: record.userAgent,
                updatedAt: record.updatedAt,
                lastAuthFailureAt: record.lastAuthFailureAt
            )
            if now.timeIntervalSince(session.updatedAt) > Self.maximumSessionLifetime {
                forgetSecret(domain: domain)
                rewriteFileAfterLoad = true
                continue
            }
            if let legacyCookie = record.cookieHeader,
                !legacyCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                migrateLegacyCookie(legacyCookie, domain: domain)
            } else {
                pendingCookies.removeValue(forKey: domain)
            }
            migrated.append(session)
        }
        sessions = migrated.sorted { $0.domain < $1.domain }
    }

    /// Moves one pre-Keychain cookie into the secret store. The plaintext leaves
    /// `sessions.json` only after the value reads back; a failed migration keeps
    /// it exactly where it was and only reports it, so a locked Keychain cannot
    /// cost the user a session they would have to re-paste to get back.
    private func migrateLegacyCookie(_ cookie: String, domain: String) {
        do {
            try secrets.save(cookie, forDomain: domain)
        } catch {
            pendingCookies[domain] = cookie
            if !domainsNeedingReauthorization.contains(domain) {
                domainsNeedingReauthorization.append(domain)
            }
            AppLogger.shared.error(
                .download, "site session could not be migrated to the Keychain: \(domain)")
            return
        }
        guard secrets.value(forDomain: domain) == cookie else {
            pendingCookies[domain] = cookie
            if !domainsNeedingReauthorization.contains(domain) {
                domainsNeedingReauthorization.append(domain)
            }
            AppLogger.shared.error(
                .download, "site session migration did not read back: \(domain)")
            return
        }
        // Only now may the plaintext leave the file: everything above proved the
        // Keychain holds the value.
        rewriteFileAfterLoad = true
        AppLogger.shared.info(.download, "site session migrated to the Keychain: \(domain)")
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let records = sessions.map { session in
            PersistedSessionRecord(
                domain: session.domain,
                scheme: session.scheme,
                cookieHeader: pendingCookies[session.domain],
                userAgent: session.userAgent,
                updatedAt: session.updatedAt,
                lastAuthFailureAt: session.lastAuthFailureAt
            )
        }
        guard let data = try? encoder.encode(records) else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            _ = chmod(fileURL.path, mode_t(0o600))
        } catch {
            AppLogger.shared.error(
                .download,
                "failed to persist sessions: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? "SANITIZE_FAILED")"
            )
        }
    }
}
