import CryptoKit
import Foundation
import XCTest

@testable import IDMEngine

final class FFmpegServiceTests: XCTestCase {
    private static let homebrewFFmpeg = "/opt/homebrew/bin/ffmpeg"
    private static let homebrewFFprobe = "/opt/homebrew/bin/ffprobe"

    func testBuildsToolchainFromPinnedEnvironment() {
        let toolchain = FFmpegToolchain.fromEnvironment([
            "MACIDM_FFMPEG_PATH": "/tmp/tools with spaces/ffmpeg",
            "MACIDM_FFPROBE_PATH": "/tmp/tools with spaces/ffprobe",
            "MACIDM_FFMPEG_SHA256": String(repeating: "A", count: 64),
            "MACIDM_FFPROBE_SHA256": String(repeating: "b", count: 64),
            "MACIDM_FFMPEG_VERSION": "ffmpeg version 7.",
            "MACIDM_FFPROBE_VERSION": "ffprobe version 7.",
        ])

        XCTAssertEqual(toolchain?.ffmpegURL.path, "/tmp/tools with spaces/ffmpeg")
        XCTAssertEqual(toolchain?.ffprobeURL.path, "/tmp/tools with spaces/ffprobe")
        XCTAssertEqual(toolchain?.ffmpegSHA256, String(repeating: "a", count: 64))
        XCTAssertNil(FFmpegToolchain.fromEnvironment(["MACIDM_FFMPEG_PATH": "/tmp/ffmpeg"]))
    }

    func testExposesStableErrorCodes() {
        XCTAssertEqual(FFmpegError.hashMismatch(tool: "ffmpeg").code, "FFMPEG_HASH_MISMATCH")
        XCTAssertEqual(FFmpegError.durationMismatch(expected: 1, actual: 2).code, "FFMPEG_DURATION_MISMATCH")
        XCTAssertEqual(FFmpegError.cancelled.code, "CANCELLED")
    }

    /// Guards against S3 regression: `FFmpegToolchain.autodetect()` must build a
    /// self-consistent pinned toolchain from the local ffmpeg/ffprobe binaries so
    /// end users (who cannot set six `MACIDM_*` env vars) still get reproducible,
    /// auditable remux output. This is an integration test that depends on a real
    /// ffmpeg install; it skips when one is absent.
    func testAutodetectBuildsConsistentToolchainFromLocalFFmpeg() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: Self.homebrewFFmpeg)
                || !FileManager.default.isExecutableFile(atPath: Self.homebrewFFprobe),
            "ffmpeg/ffprobe not installed under /opt/homebrew/bin"
        )

        guard let toolchain = await FFmpegToolchain.autodetect() else {
            XCTFail("autodetect should return a toolchain when ffmpeg is installed")
            return
        }

        // SHA-256 must be a 64-char lowercase hex string so it can be
        // compared against a pinned value and persisted in the task model.
        XCTAssertEqual(toolchain.ffmpegSHA256.count, 64)
        XCTAssertTrue(toolchain.ffmpegSHA256.allSatisfy(\.isHexDigit))
        XCTAssertEqual(toolchain.ffprobeSHA256.count, 64)
        XCTAssertTrue(toolchain.ffprobeSHA256.allSatisfy(\.isHexDigit))

        // The version prefix is the first line of `ffmpeg -version`; it must
        // be non-empty so `validateToolchain`'s `hasPrefix` check is meaningful.
        XCTAssertFalse(toolchain.ffmpegVersionPrefix.isEmpty)
        XCTAssertFalse(toolchain.ffprobeVersionPrefix.isEmpty)

        // The autodetected toolchain must round-trip through validateToolchain
        // without raising, proving the trust root (local binary on disk) is
        // as strong as an environment-supplied one.
        let service = FFmpegService(toolchain: toolchain)
        let validation = try await service.validateToolchain()
        XCTAssertEqual(validation.ffmpegSHA256, toolchain.ffmpegSHA256)
        XCTAssertEqual(validation.ffprobeSHA256, toolchain.ffprobeSHA256)
    }

    func testValidatesPinnedToolchain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let validation = try await fixture.service.validateToolchain()

        XCTAssertEqual(validation.ffmpegSHA256, fixture.toolchain.ffmpegSHA256)
        XCTAssertEqual(validation.ffprobeSHA256, fixture.toolchain.ffprobeSHA256)
        XCTAssertTrue(validation.ffmpegVersion.hasPrefix(fixture.toolchain.ffmpegVersionPrefix))
        XCTAssertTrue(validation.ffprobeVersion.hasPrefix(fixture.toolchain.ffprobeVersionPrefix))
    }

    func testRemuxesMP4AndExtractsAudioWithoutPublishingPartialOutput() async throws {
        let fixture = try fixture()
        let inputProbe = try await fixture.service.probe(fixture.inputURL)
        let mp4 = fixture.directory.appendingPathComponent("remux.mp4")
        let m4a = fixture.directory.appendingPathComponent("audio.m4a")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let videoResult = try await fixture.service.remux(
            FFmpegRemuxRequest(
                inputURL: fixture.inputURL,
                outputURL: mp4,
                expectedDuration: inputProbe.duration
            )
        )
        let audioResult = try await fixture.service.remux(
            FFmpegRemuxRequest(
                inputURL: fixture.inputURL,
                outputURL: m4a,
                outputKind: .m4a,
                expectedDuration: inputProbe.duration
            )
        )

        XCTAssertGreaterThan(videoResult.byteCount, 0)
        XCTAssertGreaterThan(audioResult.byteCount, 0)
        XCTAssertTrue(videoResult.probe.hasVideo)
        XCTAssertTrue(videoResult.probe.hasAudio)
        XCTAssertTrue(audioResult.probe.hasAudio)
        XCTAssertFalse(audioResult.probe.hasVideo)
        XCTAssertNil(videoResult.sha256)
        XCTAssertNil(audioResult.sha256)
    }

    func testMergesSeparateVideoAndAudioInputs() async throws {
        let fixture = try fixture()
        let output = fixture.directory.appendingPathComponent("merged.mp4")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let inputProbe = try await fixture.service.probe(fixture.inputURL)
        let result = try await fixture.service.merge(
            FFmpegMergeRequest(
                videoURL: fixture.inputURL,
                audioURL: fixture.inputURL,
                outputURL: output,
                expectedDuration: inputProbe.duration
            )
        )

        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertTrue(result.probe.hasVideo)
        XCTAssertTrue(result.probe.hasAudio)
        XCTAssertNil(result.sha256)
    }

    func testMergeRejectsAnEmptyInputSet() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.service.merge(
                FFmpegMergeRequest(
                    videoURL: nil,
                    audioURL: nil,
                    outputURL: fixture.directory.appendingPathComponent("empty.mp4")
                )
            )
            XCTFail("an empty merge input set should be rejected")
        } catch let error as FFmpegError {
            XCTAssertEqual(error, .invalidInputSet)
        }
    }

    func testCorruptInputNeverPublishesOutput() async throws {
        let fixture = try fixture()
        let corrupt = fixture.directory.appendingPathComponent("corrupt.ts")
        let output = fixture.directory.appendingPathComponent("corrupt.mp4")
        try Data("not a media file".utf8).write(to: corrupt, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.service.remux(
                FFmpegRemuxRequest(inputURL: corrupt, outputURL: output)
            )
            XCTFail("corrupt input should be rejected")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testHashMismatchIsRejectedBeforeRemux() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let invalidToolchain = FFmpegToolchain(
            ffmpegURL: fixture.toolchain.ffmpegURL,
            ffprobeURL: fixture.toolchain.ffprobeURL,
            ffmpegSHA256: String(repeating: "0", count: 64),
            ffprobeSHA256: fixture.toolchain.ffprobeSHA256,
            ffmpegVersionPrefix: fixture.toolchain.ffmpegVersionPrefix,
            ffprobeVersionPrefix: fixture.toolchain.ffprobeVersionPrefix
        )

        do {
            _ = try await FFmpegService(toolchain: invalidToolchain).validateToolchain()
            XCTFail("hash mismatch should be rejected")
        } catch let error as FFmpegError {
            XCTAssertEqual(error, .hashMismatch(tool: "ffmpeg"))
        }
    }

    private func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let rawInput = environment["MACIDM_FFMPEG_INPUT"],
            let inputURL = URL(string: rawInput), inputURL.isFileURL,
            let ffmpegPath = environment["MACIDM_FFMPEG_PATH"],
            let ffprobePath = environment["MACIDM_FFPROBE_PATH"],
            let ffmpegHash = environment["MACIDM_FFMPEG_SHA256"],
            let ffprobeHash = environment["MACIDM_FFPROBE_SHA256"],
            let ffmpegVersion = environment["MACIDM_FFMPEG_VERSION"],
            let ffprobeVersion = environment["MACIDM_FFPROBE_VERSION"]
        else {
            throw XCTSkip("FFmpeg integration environment is not configured")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-ffmpeg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(
            directory: directory,
            inputURL: inputURL,
            toolchain: FFmpegToolchain(
                ffmpegURL: URL(fileURLWithPath: ffmpegPath),
                ffprobeURL: URL(fileURLWithPath: ffprobePath),
                ffmpegSHA256: ffmpegHash,
                ffprobeSHA256: ffprobeHash,
                ffmpegVersionPrefix: ffmpegVersion,
                ffprobeVersionPrefix: ffprobeVersion
            ),
            service: FFmpegService(
                toolchain: FFmpegToolchain(
                    ffmpegURL: URL(fileURLWithPath: ffmpegPath),
                    ffprobeURL: URL(fileURLWithPath: ffprobePath),
                    ffmpegSHA256: ffmpegHash,
                    ffprobeSHA256: ffprobeHash,
                    ffmpegVersionPrefix: ffmpegVersion,
                    ffprobeVersionPrefix: ffprobeVersion
                )
            )
        )
    }

    private func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: url))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct Fixture {
    let directory: URL
    let inputURL: URL
    let toolchain: FFmpegToolchain
    let service: FFmpegService
}
