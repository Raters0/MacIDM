import CryptoKit
import Foundation
import IDMEngine

/// Manages the yt-dlp tool lifecycle: detection, version query, update
/// checks against the official GitHub releases, and binary downloads.
///
/// Resolution order (first executable wins):
/// 1. `MACIDM_YTDLP_PATH` environment override,
/// 2. the managed copy in `~/Library/Application Support/MacIDM/yt-dlp`
///    (written by in-app updates),
/// 3. the binary bundled in the app's Resources (`yt-dlp`),
/// 4. standard system installs (Homebrew, /usr/bin, ~/.local/bin).
///
/// The bundled copy makes the app self-contained; the managed copy takes
/// precedence so in-app updates can outgrow the bundled version without
/// modifying the app bundle.
@MainActor
final class YTDlpManager: ObservableObject {

    // MARK: - Published state for UI binding

    /// Non-nil when the user should be shown an install/update dialog.
    @Published var alert: YTDlpAlert?

    /// True while a release lookup or download is running.
    @Published var isChecking = false

    /// Result of the most recent update check (for the Settings panel).
    @Published var checkResult: CheckResult?

    /// Human-readable status line for the Settings panel.
    @Published var statusText = String(localized: "检测中…")

    /// Live install/update download progress; nil while idle. Drives the
    /// progress sheet (a bare "processing" alert gave no byte-level feedback).
    @Published var installProgress: InstallProgress?

    /// Set when the user sends the progress sheet to the background; the
    /// download keeps running and completion is reported via `alert`.
    var isInstallProgressHidden = false

    struct InstallProgress: Equatable {
        enum Stage: Equatable {
            case fetchingRelease
            case downloading
            case installing
        }

        var stage: Stage
        var receivedBytes: Int64
        var totalBytes: Int64?
        var startedAt: Date

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(receivedBytes) / Double(totalBytes))
        }

        var averageSpeed: Double {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 0.5 else { return 0 }
            return Double(receivedBytes) / elapsed
        }
    }

    /// Version of the resolved binary, if any.
    @Published var resolvedVersion: String?

    /// Re-resolves the binary and refreshes `statusText`. Call on Settings
    /// display and after install/update.
    func refreshStatus() async {
        guard let binary = Self.locateBinary() else {
            resolvedVersion = nil
            statusText = String(localized: "未检测到（可在下方下载安装）")
            return
        }
        resolvedVersion = await Self.currentVersion()
        let version = resolvedVersion ?? String(localized: "未知版本")
        statusText = "\(version) · \(binary.location.displayTitle)"
    }

    // MARK: - Types

    enum YTDlpAlert: Identifiable {
        case installRequired
        case updateRecommended(currentVersion: String?, reason: UpdateReason)
        case installFailed(message: String)
        case updateFailed(message: String)
        case updateSucceeded(newVersion: String)

        var id: String {
            switch self {
            case .installRequired: "install_required"
            case .updateRecommended: "update_recommended"
            case .installFailed: "install_failed"
            case .updateFailed: "update_failed"
            case .updateSucceeded: "update_succeeded"
            }
        }
    }

    enum UpdateReason {
        /// yt-dlp exited non-zero with error text suggesting a YouTube
        /// protocol change (e.g. "Unable to extract", "Sign in to
        /// confirm", unsupported format).
        case youtubeProtocolChange(errorOutput: String)
        /// yt-dlp version is older than the latest known release.
        case versionOutdated(current: String, latest: String)
        /// Generic process failure that might be fixed by an update.
        case genericFailure
        /// Version check failed because GitHub is unreachable.
        /// The caller should show manual-install instructions.
        case networkFailed
        /// Version matches but the local binary's SHA-256 does not
        /// match GitHub's SHA2-256SUMS — the file may be corrupted.
        case integrityMismatch(localSHA256: String, expectedSHA256: String)
    }

    enum CheckResult: Equatable {
        case upToDate(latest: String)
        case updateAvailable(latest: String)
        case failed(message: String)
    }

    /// Where the resolved binary lives; drives UI copy and update strategy.
    enum BinaryLocation: Equatable {
        case environment
        case managed
        case bundled
        case system

        var displayTitle: String {
            switch self {
            case .environment: String(localized: "环境变量指定")
            case .managed: String(localized: "应用更新版")
            case .bundled: String(localized: "内置")
            case .system: String(localized: "系统安装")
            }
        }
    }

    struct ReleaseInfo: Sendable {
        let version: String
        /// Both URLs are pinned to `version`'s tag, so the binary and the
        /// checksum can never come from two different releases.
        let assetURL: URL
        let sha256SumsURL: URL
    }

    // MARK: - Locations

    /// Writable directory that in-app updates install into.
    nonisolated static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacIDM", isDirectory: true)
    }

    nonisolated static var managedBinaryURL: URL {
        managedDirectory.appendingPathComponent("yt-dlp")
    }

    /// The binary bundled inside the app's Resources, if present.
    nonisolated static var bundledBinaryURL: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return resourceURL.appendingPathComponent("yt-dlp")
    }

    /// Resolves the first executable yt-dlp following the documented
    /// resolution order. Returns nil when no binary is available.
    nonisolated static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL, location: BinaryLocation)? {
        if let configured = environment["MACIDM_YTDLP_PATH"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return (url, .environment)
            }
        }
        if FileManager.default.isExecutableFile(atPath: managedBinaryURL.path) {
            return (managedBinaryURL, .managed)
        }
        if let bundled = bundledBinaryURL,
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return (bundled, .bundled)
        }
        let systemCandidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/yt-dlp").path,
        ]
        for path in systemCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), .system)
            }
        }
        return nil
    }

    /// Returns the path to the yt-dlp executable if found, nil otherwise.
    nonisolated static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        locateBinary(environment: environment)?.url
    }

    /// Convenience: is yt-dlp installed and executable?
    nonisolated static var isAvailable: Bool {
        locateExecutable() != nil
    }

    /// Augments a process environment so yt-dlp can find a JavaScript
    /// runtime (Node.js / Deno) required to solve YouTube's n challenge.
    /// macOS apps launched from Finder inherit a minimal PATH that often
    /// omits Homebrew, local-bin, and similar directories; this helper
    /// prepends the common locations without clobbering user overrides.
    nonisolated static func augmentEnvironmentForJSRuntime(_ env: inout [String: String]) {
        let jsRuntimeDirs = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.deno/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = jsRuntimeDirs.joined(separator: ":")
        env["PATH"] = "\(extra):\(existing)"
    }

    // MARK: - Proxy integration

    /// Renders the app's configured proxy as a yt-dlp `--proxy` URL, e.g.
    /// `socks5://host:port` or `http://user:pass@host:port`. Returns nil
    /// when no proxy is configured, so callers can omit the argument.
    nonisolated static func currentProxyURLString() -> String? {
        guard let value = DownloadProxyPolicy.current else { return nil }
        let configuration = value.configuration
        let scheme = configuration.kind.rawValue
        if let username = value.username, !username.isEmpty, let password = value.password {
            let user = percentEncode(username)
            let pass = percentEncode(password)
            return "\(scheme)://\(user):\(pass)@\(configuration.host):\(configuration.port)"
        }
        return "\(scheme)://\(configuration.host):\(configuration.port)"
    }

    private nonisolated static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// URLSession routed through the app's configured proxy (or the
    /// shared session when none is configured). Used for GitHub release
    /// lookups so version/integrity checks work behind the same proxy as
    /// downloads themselves.
    nonisolated static func proxyAwareSession() -> URLSession {
        guard let dictionary = DownloadProxyPolicy.connectionProxyDictionary else {
            return .shared
        }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = dictionary
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }

    // MARK: - Version query

    /// Runs `yt-dlp --version` on the resolved binary and returns the
    /// version string (e.g. "2026.07.04"). The resolver may fall back to
    /// any install location, so this must NOT be used as proof that a
    /// specific install/update succeeded.
    nonisolated static func currentVersion() async -> String? {
        guard let url = locateExecutable() else { return nil }
        return await version(of: url)
    }

    /// Runs `--version` against one exact executable path. Unlike
    /// `currentVersion()` this never falls back to another binary
    /// location, so a non-nil result proves that this specific file
    /// exists, is executable, and runs.
    nonisolated static func version(of executableURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PYTHONHOME")
            env.removeValue(forKey: "PYTHONPATH")
            process.environment = env
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = output.split(separator: "\n").first
                continuation.resume(returning: firstLine.map(String.init))
            }
        }
    }

    /// Synchronous version query for use on the MainActor (e.g. status
    /// snapshots). Returns the cached value immediately and refreshes it in
    /// the background when stale, so callers never block on the yt-dlp
    /// process. Returns nil when yt-dlp is missing and no cached value
    /// exists yet.
    nonisolated static func currentVersionSync() -> String? {
        versionCache.current(resolve: resolveVersionInBackground)
    }

    private nonisolated static let versionCache = VersionCache()

    /// Resolves the version off the calling thread and stores it in the
    /// cache. Invoked at most once per cache TTL.
    private nonisolated static func resolveVersionInBackground() {
        DispatchQueue.global(qos: .utility).async {
            guard let url = locateExecutable() else {
                versionCache.store(nil)
                return
            }
            let process = Process()
            process.executableURL = url
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PYTHONHOME")
            env.removeValue(forKey: "PYTHONPATH")
            process.environment = env
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                versionCache.store(nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            versionCache.store(output.split(separator: "\n").first.map(String.init))
        }
    }

    /// Thread-safe TTL cache for the yt-dlp version string.
    private final class VersionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private var timestamp = Date.distantPast
        private var refreshScheduled = false
        private let ttl: TimeInterval = 120

        func current(resolve: @escaping () -> Void) -> String? {
            lock.lock()
            let stale = Date().timeIntervalSince(timestamp) >= ttl
            if stale && !refreshScheduled {
                refreshScheduled = true
                lock.unlock()
                resolve()
                lock.lock()
            }
            let result = value
            lock.unlock()
            return result
        }

        func store(_ newValue: String?) {
            lock.lock()
            value = newValue
            timestamp = Date()
            refreshScheduled = false
            lock.unlock()
        }
    }

    /// Numeric comparison for date-style versions such as "2026.07.04" or
    /// "2026.07.04.1". Non-numeric components compare as zero.
    nonisolated static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    // MARK: - Release lookup

    /// Queries the GitHub API for the newest yt-dlp release and the URL of
    /// its macOS standalone binary. Asset URLs are pinned to the tag the API
    /// just returned, never to the drifting `latest/download` form.
    nonisolated static func latestRelease() async -> ReleaseInfo? {
        let apiURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data
        do {
            // Route through the user-configured proxy when present so
            // GitHub lookups work in the same environments as downloads.
            (data, _) = try await proxyAwareSession().data(for: request)
        } catch {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        var assetURL = YTDlpReleaseIntegrity.pinnedAssetURL(
            tag: tag, name: YTDlpReleaseIntegrity.assetName)
        var sha256SumsURL = YTDlpReleaseIntegrity.pinnedAssetURL(
            tag: tag, name: YTDlpReleaseIntegrity.checksumAssetName)
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                    let download = asset["browser_download_url"] as? String
                else { continue }
                if name == YTDlpReleaseIntegrity.assetName,
                    let trusted = YTDlpReleaseIntegrity.trustedAssetURL(download, tag: tag)
                {
                    assetURL = trusted
                }
                if name == YTDlpReleaseIntegrity.checksumAssetName,
                    let trusted = YTDlpReleaseIntegrity.trustedAssetURL(download, tag: tag)
                {
                    sha256SumsURL = trusted
                }
            }
        }
        // A release whose binary or checksum cannot be pinned to its own tag
        // offers no verifiable evidence at all.
        guard let resolvedAssetURL = assetURL, let resolvedSumsURL = sha256SumsURL else {
            return nil
        }
        return ReleaseInfo(
            version: tag, assetURL: resolvedAssetURL, sha256SumsURL: resolvedSumsURL)
    }

    // MARK: - Update check

    /// Compares the resolved local version with the newest GitHub
    /// release. `auto` marks startup checks, which stay silent unless an
    /// update is available.
    func checkForUpdates(auto: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        AppLogger.shared.info(.youtube, "yt-dlp update check started (auto: \(auto))")

        guard let release = await Self.latestRelease() else {
            checkResult = .failed(message: String(localized: "无法访问 yt-dlp 更新源（api.github.com）"))
            if !auto {
                alert = .updateFailed(message: String(localized: "无法访问 GitHub 更新源，请稍后重试。"))
            }
            return
        }

        let current = await Self.currentVersion()
        if let current, !Self.isVersion(current, olderThan: release.version) {
            checkResult = .upToDate(latest: release.version)
            if !auto {
                alert = .updateSucceeded(newVersion: String(localized: "已是最新版本（\(current)）"))
            }
            return
        }

        checkResult = .updateAvailable(latest: release.version)
        alert = .updateRecommended(
            currentVersion: current,
            reason: .versionOutdated(current: current ?? String(localized: "未知"), latest: release.version)
        )
    }

    // MARK: - Install

    /// Runs an update check while temporarily bypassing the configured
    /// proxy — the diagnostic remedy offered when a proxy-aware check
    /// cannot reach GitHub, to find out whether the proxy itself is the
    /// failure point.
    func checkForUpdatesDirectConnection() async {
        DownloadProxyPolicy.setForceDirect(true)
        defer { DownloadProxyPolicy.setForceDirect(false) }
        await checkForUpdates()
    }

    /// Installs yt-dlp by downloading the official macOS binary into the
    /// managed Application Support directory.
    func install() async {
        AppLogger.shared.info(.youtube, "yt-dlp install requested")
        await downloadManagedBinary(reasonOnFailure: String(localized: "安装"))
    }

    // MARK: - Update

    /// Downloads the newest official macOS binary into the managed
    /// directory, which takes precedence over bundled and system copies.
    func update() async {
        AppLogger.shared.info(.youtube, "yt-dlp update requested")
        await downloadManagedBinary(reasonOnFailure: String(localized: "更新"))
    }

    /// Shared download path for install and update.
    private func downloadManagedBinary(reasonOnFailure reason: String) async {
        isInstallProgressHidden = false
        installProgress = InstallProgress(
            stage: .fetchingRelease, receivedBytes: 0, totalBytes: nil, startedAt: Date()
        )
        guard let release = await Self.latestRelease() else {
            installProgress = nil
            alert = .updateFailed(message: String(localized: "无法访问 yt-dlp 更新源，请检查网络后重试。"))
            return
        }
        installProgress?.stage = .downloading
        installProgress?.startedAt = Date()
        do {
            let tempURL = try await downloadReleaseAsset(release.assetURL)
            installProgress?.stage = .installing
            // Integrity evidence is mandatory. A slow or unreachable GitHub
            // costs the user one retry; skipping the check would instead let
            // an unverified binary be made executable and run.
            do {
                let expectedSHA256 = try await Self.fetchExpectedSHA256(
                    from: release.sha256SumsURL)
                await installManagedBinary(
                    at: tempURL,
                    targetURL: Self.managedBinaryURL,
                    expectedVersion: release.version,
                    expectedSHA256: expectedSHA256,
                    reasonOnFailure: reason
                )
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        } catch {
            AppLogger.shared.error(
                .youtube,
                "yt-dlp download failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? "SANITIZE_FAILED")"
            )
            installProgress = nil
            alert = .updateFailed(
                message: String(localized: "\(reason)失败：\(error.localizedDescription)")
            )
        }
    }

    /// Moves a freshly downloaded asset onto `targetURL` atomically and
    /// verifies the exact installed file. Split from the network path so
    /// unit tests can drive the replace/verify lifecycle against a
    /// temporary directory with a fake executable instead of GitHub.
    ///
    /// Guarantees:
    /// - A valid, strictly formatted SHA-256 is required. Without matching
    ///   integrity evidence the staged bytes are never made executable and
    ///   never run.
    /// - The previous target survives every failure path (bad download,
    ///   integrity mismatch, replace error) — it is only discarded by the
    ///   atomic replace itself, after the staged binary proved it runs.
    /// - `.updateSucceeded` requires the exact `targetURL` to be
    ///   executable and to report `expectedVersion`; a bundled/system
    ///   fallback can never masquerade as a successful managed install.
    func installManagedBinary(
        at downloadedURL: URL,
        targetURL: URL = YTDlpManager.managedBinaryURL,
        expectedVersion: String,
        expectedSHA256: String,
        reasonOnFailure reason: String
    ) async {
        do {
            guard YTDlpReleaseIntegrity.isValidSHA256Hex(expectedSHA256) else {
                throw YTDlpIntegrityError.checksumHashMalformed
            }
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic replacement: stage the fresh binary next to the target
            // and swap it in, so a failed move never deletes the currently
            // working copy (delete-then-move would leave no yt-dlp at all
            // if the move fails).
            let staged = targetURL.deletingLastPathComponent()
                .appendingPathComponent("yt-dlp.staging-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: downloadedURL, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            // Hash first: reading bytes needs no execute bit, so the staged
            // binary is only made runnable — and only ever run — after its
            // digest matches the release checksum.
            let digest = SHA256.hash(data: try Data(contentsOf: staged))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256.lowercased() else {
                throw YTDlpIntegrityError.binaryHashMismatch
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: staged.path
            )
            // Pre-install gate: prove the staged binary itself runs and
            // reports the downloaded version BEFORE touching the live
            // target, so a bad download never destroys the working copy.
            guard FileManager.default.isExecutableFile(atPath: staged.path),
                let stagedVersion = await Self.version(of: staged),
                stagedVersion == expectedVersion
            else {
                throw YTDlpInstallError.stagedVerificationFailed
            }
            if FileManager.default.fileExists(atPath: targetURL.path) {
                // replaceItemAt returns the URL of the item at the target
                // after the swap — NOT a backup of the old file. Treating
                // the return value as a backup and deleting it removed the
                // freshly installed binary (2026-08-25 incident: every
                // in-app update over an existing managed copy deleted the
                // new yt-dlp immediately after installing it).
                _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: targetURL)
            }
            // Post-install gate: success is proven on the exact managed
            // path. currentVersion() resolves with fallbacks (bundled /
            // system copies) and would mask a broken managed install.
            guard FileManager.default.isExecutableFile(atPath: targetURL.path),
                let installedVersion = await Self.version(of: targetURL),
                installedVersion == expectedVersion
            else {
                AppLogger.shared.error(
                    .youtube,
                    "yt-dlp installed binary failed verification: \(YouTubeOutputSanitizer.userSafePath(targetURL.path))"
                )
                installProgress = nil
                alert = .updateFailed(
                    message: String(localized: "下载完成但无法执行，请检查文件权限。"))
                return
            }
            AppLogger.shared.info(.youtube, "yt-dlp \(reason) complete: \(installedVersion)")
            checkResult = .upToDate(latest: installedVersion)
            installProgress = nil
            alert = .updateSucceeded(newVersion: installedVersion)
            await refreshStatus()
        } catch {
            AppLogger.shared.error(
                .youtube,
                "yt-dlp install failed: \(YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription) ?? "SANITIZE_FAILED")"
            )
            installProgress = nil
            alert = .updateFailed(
                message: String(localized: "\(reason)失败：\(error.localizedDescription)")
            )
        }
    }

    /// Downloads the release asset through a delegate-backed session so the
    /// UI can render received/total bytes while the binary transfers.
    private func downloadReleaseAsset(_ url: URL) async throws -> URL {
        let delegate = YTDlpBinaryDownloadDelegate { [weak self] received, total in
            Task { @MainActor in
                guard var progress = self?.installProgress else { return }
                progress.receivedBytes = received
                progress.totalBytes = total
                self?.installProgress = progress
            }
        }
        let session = URLSession(
            configuration: {
                let configuration = URLSessionConfiguration.default
                configuration.connectionProxyDictionary =
                    DownloadProxyPolicy.connectionProxyDictionary
                return configuration
            }(),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.start(task, continuation: continuation)
        }
    }

    // MARK: - Auto-check scheduling

    private static let autoCheckCooldown: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "ytdlpLastUpdateCheckTimestamp"

    /// Runs a silent update check at most once per day when the user has
    /// auto-check enabled. Call once during app startup.
    func autoCheckIfNeeded(settings: AppSettings) {
        guard settings.ytdlpAutoCheckUpdates else { return }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.autoCheckCooldown else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task { await checkForUpdates(auto: true) }
    }

    // MARK: - Error analysis

    /// Examines a YouTube download failure and decides whether an
    /// yt-dlp update might fix it. Returns the reason if an update is
    /// recommended, nil otherwise.
    ///
    /// Only returns a reason when there is *evidence* that an update
    /// would help (YouTube protocol-change signatures in the process
    /// output). Generic process failures are NOT treated as update
    /// candidates — the caller performs an async version comparison
    /// to decide whether the binary is actually outdated.
    nonisolated static func shouldRecommendUpdate(
        errorCode: String?,
        errorMessage: String?,
        processOutput: String?
    ) -> UpdateReason? {
        // toolUnavailable means yt-dlp is not installed at all — that's
        // an install, not an update. Precisely-classified failures (bot
        // check, site policy, network, toolchain) each have their own
        // remedy; recommending an update there only wastes the user's time.
        let updateNeverHelps: Set<String> = [
            "YTDLP_NOT_FOUND", "YTDLP_LAUNCH_FAILED", "YTDLP_BOT_CHECK", "YTDLP_N_CHALLENGE_FAILED",
            "YTDLP_GEO_BLOCKED", "YTDLP_AGE_RESTRICTED", "YTDLP_PRIVATE_VIDEO",
            "YTDLP_COPYRIGHT", "YTDLP_VIDEO_UNAVAILABLE", "YTDLP_LIVE_ENDED",
            "YTDLP_NETWORK_ERROR", "YTDLP_UNSUPPORTED_URL", "YTDLP_STALLED",
            "YTDLP_NO_MEDIA", "YTDLP_FFMPEG_UNAVAILABLE",
        ]
        if let errorCode, updateNeverHelps.contains(errorCode) {
            return nil
        }

        // Check for YouTube protocol change signatures in the process
        // output. yt-dlp typically emits these when YouTube changes
        // their player response format. Login/bot-check wording is
        // intentionally NOT listed — see the guard above.
        if let rawOutput = processOutput?.lowercased() {
            // yt-dlp sometimes prints typographic quotes ('); normalize
            // them so signature matching does not depend on the apostrophe
            // style used in the error text.
            let output = rawOutput.replacingOccurrences(of: "\u{2019}", with: "'")
            // Bot-check wording means YouTube flagged the request as a
            // login-state problem; an yt-dlp update will not help.
            let botSignatures = ["sign in to confirm", "confirm you're not a bot", "login required"]
            if botSignatures.contains(where: { output.contains($0) }) {
                return nil
            }

            let protocolChangeSignatures = [
                "unable to extract",
                "unable to download",
                "no video formats found",
                "signature extraction failed",
                "nsig extraction failed",
                "unsupported url",
                "http error 403",
            ]
            if protocolChangeSignatures.contains(where: { output.contains($0) }) {
                return .youtubeProtocolChange(errorOutput: processOutput ?? "")
            }
        }

        // Generic process failure without specific protocol-change
        // signatures — do NOT blindly recommend an update. The caller
        // performs an async version comparison to decide whether the
        // binary is actually outdated.
        return nil
    }

    /// Async guard: checks whether the installed yt-dlp is older than
    /// the latest GitHub release. Returns an `.versionOutdated` reason
    /// when an update is available, nil otherwise. Used by the error
    /// handler to avoid recommending updates when the binary is already
    /// current — a common source of user frustration.
    ///
    /// When GitHub is unreachable, returns `.networkFailed` so the
    /// caller can show manual-install instructions. When the version
    /// matches, verifies the binary's SHA-256 against GitHub's
    /// SHA2-256SUMS and returns `.integrityMismatch` on mismatch.
    nonisolated static func outdatedUpdateReason() async -> UpdateReason? {
        guard let release = await latestRelease() else {
            // GitHub unreachable — let the caller show manual instructions
            // instead of silently swallowing the error.
            return .networkFailed
        }
        let current = await currentVersion()
        guard let current else {
            // Cannot determine version — might be a broken binary;
            // an update could help.
            return .versionOutdated(current: String(localized: "未知"), latest: release.version)
        }
        if isVersion(current, olderThan: release.version) {
            return .versionOutdated(current: current, latest: release.version)
        }
        // Version matches — verify binary integrity via SHA-256. This is
        // read-only reporting: evidence that cannot be established means
        // "unverifiable" here, and must never be reinterpreted as consent to
        // install (the install path requires a throwing fetch instead).
        if let expected = try? await fetchExpectedSHA256(from: release.sha256SumsURL),
            let local = computeLocalSHA256(),
            local.lowercased() != expected.lowercased()
        {
            return .integrityMismatch(
                localSHA256: local, expectedSHA256: expected)
        }
        // Version matches and integrity is OK (or unverifiable).
        return nil
    }

    // MARK: - SHA-256 integrity

    /// Reads the verified SHA-256 for the release asset out of a
    /// `SHA2-256SUMS` document. Throws ``YTDlpIntegrityError`` for every
    /// condition that leaves the digest unestablished: an unreachable or
    /// non-successful fetch, a missing entry, a duplicated entry, or a
    /// malformed hash literal.
    nonisolated static func fetchExpectedSHA256(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await proxyAwareSession().data(for: request)
        } catch {
            throw YTDlpIntegrityError.checksumFetchFailed
        }
        // A 404 error page is not a checksum document; treating its body as
        // one would turn a missing asset into a bogus parse result.
        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            throw YTDlpIntegrityError.checksumFetchFailed
        }
        let text = String(decoding: data, as: UTF8.self)
        return try YTDlpReleaseIntegrity.parseExpectedSHA256(
            text, filename: YTDlpReleaseIntegrity.assetName
        ).get()
    }

    /// Computes the SHA-256 hash of the resolved yt-dlp binary.
    nonisolated static func computeLocalSHA256() -> String? {
        guard let url = locateExecutable() else { return nil }
        let data = try? Data(contentsOf: url)
        guard let data else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Failures detected while installing a freshly downloaded managed
/// binary. Thrown before the live target is touched, so the previous
/// working copy always survives them.
enum YTDlpInstallError: LocalizedError {
    case stagedVerificationFailed

    var errorDescription: String? {
        switch self {
        case .stagedVerificationFailed:
            return String(localized: "下载的 yt-dlp 无法执行或版本不符，已取消安装。")
        }
    }
}

/// Bridges URLSession download callbacks into the manager's progress state.
/// The temporary file delivered by `didFinishDownloadingTo` is moved out of
/// the session-owned location immediately — it is deleted the moment that
/// delegate method returns.
private final class YTDlpBinaryDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var resolved = false
    private let onProgress: @Sendable (Int64, Int64?) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(
            totalBytesWritten,
            totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-ytdlp-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            pending?.resume(returning: temp)
        } catch {
            pending?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
