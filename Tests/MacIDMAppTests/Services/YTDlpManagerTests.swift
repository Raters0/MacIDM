import CryptoKit
import XCTest

@testable import MacIDMApp

@MainActor
final class YTDlpManagerTests: XCTestCase {

    // MARK: - Version comparison

    func testDateStyleVersionsCompareNumerically() {
        XCTAssertTrue(YTDlpManager.isVersion("2026.07.04", olderThan: "2026.07.05"))
        XCTAssertTrue(YTDlpManager.isVersion("2025.12.23", olderThan: "2026.01.01"))
        XCTAssertFalse(YTDlpManager.isVersion("2026.07.04", olderThan: "2026.07.04"))
        XCTAssertFalse(YTDlpManager.isVersion("2026.08.01", olderThan: "2026.07.31"))
    }

    func testFourthComponentBreaksTies() {
        XCTAssertTrue(YTDlpManager.isVersion("2026.07.04", olderThan: "2026.07.04.1"))
        XCTAssertFalse(YTDlpManager.isVersion("2026.07.04.1", olderThan: "2026.07.04"))
        XCTAssertFalse(YTDlpManager.isVersion("2026.07.04.2", olderThan: "2026.07.04.1"))
    }

    func testNonNumericComponentsDoNotCrashComparison() {
        // Non-numeric components compare as zero, so a garbage version
        // string simply reads as "older" without crashing.
        XCTAssertTrue(YTDlpManager.isVersion("nightly", olderThan: "2026.07.04"))
        XCTAssertFalse(YTDlpManager.isVersion("2026.07.04", olderThan: "nightly"))
    }

    // MARK: - Binary resolution

    func testEnvironmentOverrideWinsOverOtherLocations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-ytdlp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeBinary = directory.appendingPathComponent("yt-dlp-fake")
        guard FileManager.default.createFile(atPath: fakeBinary.path, contents: Data()) else {
            XCTFail("could not create fake binary")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let resolved = YTDlpManager.locateBinary(
            environment: ["MACIDM_YTDLP_PATH": fakeBinary.path]
        )
        XCTAssertEqual(resolved?.url, fakeBinary)
        XCTAssertEqual(resolved?.location, .environment)
    }

    func testMissingEnvironmentOverrideFallsThrough() {
        // A bogus env path must not resolve to the environment location;
        // the result (if any) must come from a later candidate.
        let resolved = YTDlpManager.locateBinary(
            environment: ["MACIDM_YTDLP_PATH": "/nonexistent/yt-dlp"]
        )
        XCTAssertNotEqual(resolved?.location, .environment)
    }

    // MARK: - Managed install lifecycle

    /// Writes a fake yt-dlp executable script reporting `version` for
    /// `--version`, so install-lifecycle tests never touch GitHub.
    private func makeFakeYTDlpAsset(version: String) -> Data {
        Data(
            ("#!/bin/sh\n"
                + "if [ \"$1\" = \"--version\" ]; then printf '%s\\n' '\(version)'; exit 0; fi\n"
                + "exit 0\n").utf8)
    }

    /// Digest of an asset's exact bytes, as the release checksum would report.
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "macidm-ytdlp-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAsset(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func stagingLeftovers(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("yt-dlp.staging-") } ?? []
    }

    func testFirstManagedInstallCreatesExecutableBinary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        let asset = makeFakeYTDlpAsset(version: "2026.07.04")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: sha256Hex(asset),
            reasonOnFailure: "安装"
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2026.07.04")
        guard case .updateSucceeded(let newVersion) = manager.alert else {
            XCTFail("expected updateSucceeded, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertEqual(newVersion, "2026.07.04")
        XCTAssertNil(manager.installProgress)
        XCTAssertTrue(stagingLeftovers(in: directory).isEmpty)
    }

    func testManagedUpdateOverExistingBinaryKeepsTargetInstalled() async throws {
        // Regression (2026-08-25 incident): the update flow treated
        // replaceItemAt's return URL as a "backup" and deleted it — but the
        // return value IS the freshly replaced binary, so every in-app
        // update over an existing managed copy removed the new yt-dlp.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        let asset = makeFakeYTDlpAsset(version: "2026.07.04")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: sha256Hex(asset),
            reasonOnFailure: "更新"
        )

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: target.path),
            "the freshly installed binary was deleted after the replace")
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2026.07.04")
        guard case .updateSucceeded(let newVersion) = manager.alert else {
            XCTFail("expected updateSucceeded, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertEqual(newVersion, "2026.07.04")
        XCTAssertTrue(stagingLeftovers(in: directory).isEmpty)
    }

    func testRepeatedManagedUpdatesKeepBinaryInstalled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)

        let manager = YTDlpManager()
        for version in ["2026.07.04", "2026.08.09"] {
            let downloaded = directory.appendingPathComponent("asset-\(version)")
            let asset = makeFakeYTDlpAsset(version: version)
            try writeAsset(asset, to: downloaded)
            await manager.installManagedBinary(
                at: downloaded,
                targetURL: target,
                expectedVersion: version,
                expectedSHA256: sha256Hex(asset),
                reasonOnFailure: "更新"
            )
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
            let installed = await YTDlpManager.version(of: target)
            XCTAssertEqual(installed, version)
            guard case .updateSucceeded = manager.alert else {
                XCTFail("update to \(version) did not succeed: \(String(describing: manager.alert))")
                return
            }
        }
    }

    func testUnrunnableDownloadedBinaryFailsInstallAndKeepsExistingCopy() async throws {
        // A downloaded binary that runs but reports no version must fail
        // verification against the exact target — even when a bundled or
        // system yt-dlp exists on this machine. The old code verified via
        // currentVersion(), whose fallback resolver found those copies and
        // masked the broken install as success.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        let asset = Data("#!/bin/sh\nexit 0\n".utf8)
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: sha256Hex(asset),
            reasonOnFailure: "更新"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertNil(manager.installProgress)
        // The pre-existing binary survives untouched.
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2025.01.01")
    }

    func testVersionMismatchDownloadedBinaryFailsInstallAndKeepsExistingCopy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        // Runs fine, but reports a different version than the release that
        // was downloaded — the staged gate must reject it.
        let asset = makeFakeYTDlpAsset(version: "2020.01.01")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: sha256Hex(asset),
            reasonOnFailure: "更新"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2025.01.01")
    }

    func testIntegrityMismatchFailsInstallAndKeepsExistingCopy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        try writeAsset(makeFakeYTDlpAsset(version: "2026.07.04"), to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: String(repeating: "0", count: 64),
            reasonOnFailure: "更新"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2025.01.01")
    }

    func testFailedInstallLeavesExistingBinaryUsable() async throws {
        // A missing download asset fails in the staging move, before the
        // live target is ever touched; the failure must surface as
        // updateFailed while the existing binary stays usable. (Note:
        // replaceItemAt never throws for a directory target on current
        // macOS — verified experimentally — so the staging move is the
        // deterministic injection point for the failure path.)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let missingAsset = directory.appendingPathComponent("asset-that-never-arrived")

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: missingAsset,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: String(repeating: "a", count: 64),
            reasonOnFailure: "更新"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertNil(manager.installProgress)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2025.01.01")
    }

    func testVersionOfExactPathDoesNotFallBackToOtherLocations() async {
        // version(of:) must query the exact URL only; a nil/empty result
        // may never be satisfied by a bundled or system copy.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-missing-ytdlp-\(UUID().uuidString)")
        let version = await YTDlpManager.version(of: missing)
        XCTAssertNil(version)
    }

    func testBotCheckFailureDoesNotRecommendUpdate() {
        // Regression: "Sign in to confirm you're not a bot" is a login-state
        // problem; recommending a yt-dlp update misleads the user.
        let reason = YTDlpManager.shouldRecommendUpdate(
            errorCode: "YTDLP_PROCESS_FAILED",
            errorMessage: nil,
            processOutput: "ERROR: [youtube] DrbB6Nk5yo8: Sign in to confirm you\u{2019}re not a bot."
        )
        XCTAssertNil(reason)

        let botCode = YTDlpManager.shouldRecommendUpdate(
            errorCode: "YTDLP_BOT_CHECK",
            errorMessage: nil,
            processOutput: "anything at all"
        )
        XCTAssertNil(botCode)

        // A launch failure means the binary exists but cannot start —
        // downloading another copy of the same release will not fix a
        // corrupt file recommendation loop.
        let launchFailed = YTDlpManager.shouldRecommendUpdate(
            errorCode: "YTDLP_LAUNCH_FAILED",
            errorMessage: nil,
            processOutput: nil
        )
        XCTAssertNil(launchFailed)

        // Genuine protocol-change signatures still recommend an update.
        let protocolChange = YTDlpManager.shouldRecommendUpdate(
            errorCode: "YTDLP_PROCESS_FAILED",
            errorMessage: nil,
            processOutput: "ERROR: Unable to extract js player"
        )
        XCTAssertNotNil(protocolChange)
    }

    // MARK: - Fail-closed integrity gate

    /// An asset that reports a version successfully but records an execution
    /// marker when run. Used to prove the staged binary is never executed on a
    /// path where integrity evidence did not pass.
    private func makeMarkerAsset(version: String, marker: URL) -> Data {
        Data(
            ("#!/bin/sh\n"
                + "touch '\(marker.path)'\n"
                + "if [ \"$1\" = \"--version\" ]; then printf '%s\\n' '\(version)'; exit 0; fi\n"
                + "exit 0\n").utf8)
    }

    func testBinaryIsNotExecutedAndExistingCopySurvivesWhenDigestDoesNotMatch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        try writeAsset(makeFakeYTDlpAsset(version: "2025.01.01"), to: target)
        try makeExecutable(target)
        let marker = directory.appendingPathComponent("was-executed")
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        try writeAsset(makeMarkerAsset(version: "2026.07.04", marker: marker), to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: String(repeating: "0", count: 64),
            reasonOnFailure: "更新"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the unverified binary was executed during install")
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2025.01.01")
        XCTAssertTrue(stagingLeftovers(in: directory).isEmpty)
    }

    func testFirstInstallLeavesNoTargetWhenDigestDoesNotMatch() async throws {
        // Nothing existed before, so a failed integrity gate must create no
        // managed binary at all rather than an unverified one.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        let asset = makeFakeYTDlpAsset(version: "2026.07.04")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: String(repeating: "f", count: 64),
            reasonOnFailure: "安装"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(stagingLeftovers(in: directory).isEmpty)
    }

    func testInstallAbortsBeforeStagingWhenExpectedDigestIsMalformed() async throws {
        // A digest that is not 64 hex digits is not evidence, so the gate must
        // reject it before the asset is even moved into place.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        let asset = makeFakeYTDlpAsset(version: "2026.07.04")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: "zzzz",
            reasonOnFailure: "安装"
        )

        guard case .updateFailed = manager.alert else {
            XCTFail("expected updateFailed, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloaded.path),
            "a malformed digest must abort before the downloaded asset is consumed")
        XCTAssertTrue(stagingLeftovers(in: directory).isEmpty)
    }

    func testStagedBinaryRunsOnlyAfterItsDigestMatches() async throws {
        // Same marker asset as the mismatch case, this time with the checksum
        // the release would actually publish: execution and replacement are
        // then allowed.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("yt-dlp")
        let marker = directory.appendingPathComponent("was-executed")
        let asset = makeMarkerAsset(version: "2026.07.04", marker: marker)
        let downloaded = directory.appendingPathComponent("downloaded-asset")
        try writeAsset(asset, to: downloaded)

        let manager = YTDlpManager()
        await manager.installManagedBinary(
            at: downloaded,
            targetURL: target,
            expectedVersion: "2026.07.04",
            expectedSHA256: sha256Hex(asset),
            reasonOnFailure: "安装"
        )

        guard case .updateSucceeded = manager.alert else {
            XCTFail("expected updateSucceeded, got \(String(describing: manager.alert))")
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the version gate never ran, so the integrity gate may not have either")
        let version = await YTDlpManager.version(of: target)
        XCTAssertEqual(version, "2026.07.04")
    }
}
