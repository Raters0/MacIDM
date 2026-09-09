import CryptoKit
import Foundation

public struct FFmpegToolchain: Hashable, Sendable {
    public let ffmpegURL: URL
    public let ffprobeURL: URL
    public let ffmpegSHA256: String
    public let ffprobeSHA256: String
    public let ffmpegVersionPrefix: String
    public let ffprobeVersionPrefix: String

    public init(
        ffmpegURL: URL,
        ffprobeURL: URL,
        ffmpegSHA256: String,
        ffprobeSHA256: String,
        ffmpegVersionPrefix: String,
        ffprobeVersionPrefix: String
    ) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        self.ffmpegSHA256 = ffmpegSHA256.lowercased()
        self.ffprobeSHA256 = ffprobeSHA256.lowercased()
        self.ffmpegVersionPrefix = ffmpegVersionPrefix
        self.ffprobeVersionPrefix = ffprobeVersionPrefix
    }

    /// Builds a pinned toolchain from the local Debug environment.
    ///
    /// The App deliberately does not guess a Homebrew or system path. All six
    /// values must be supplied so a remux can be reproduced and audited.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FFmpegToolchain? {
        guard let ffmpegPath = environment["MACIDM_FFMPEG_PATH"],
            let ffprobePath = environment["MACIDM_FFPROBE_PATH"],
            let ffmpegSHA256 = environment["MACIDM_FFMPEG_SHA256"],
            let ffprobeSHA256 = environment["MACIDM_FFPROBE_SHA256"],
            let ffmpegVersion = environment["MACIDM_FFMPEG_VERSION"],
            let ffprobeVersion = environment["MACIDM_FFPROBE_VERSION"],
            !ffmpegPath.isEmpty, !ffprobePath.isEmpty,
            !ffmpegSHA256.isEmpty, !ffprobeSHA256.isEmpty,
            !ffmpegVersion.isEmpty, !ffprobeVersion.isEmpty
        else { return nil }

        return FFmpegToolchain(
            ffmpegURL: URL(fileURLWithPath: ffmpegPath),
            ffprobeURL: URL(fileURLWithPath: ffprobePath),
            ffmpegSHA256: ffmpegSHA256,
            ffprobeSHA256: ffprobeSHA256,
            ffmpegVersionPrefix: ffmpegVersion,
            ffprobeVersionPrefix: ffprobeVersion
        )
    }

    /// Auto-detects an ffmpeg/ffprobe pair on the user's PATH (or common
    /// Homebrew locations) and builds a self-consistent pinned toolchain by
    /// measuring the actual SHA-256 and capturing the real version prefix.
    ///
    /// This is the product path for end users, who cannot be expected to set
    /// six `MACIDM_*` environment variables. The resulting toolchain goes
    /// through the same `validateToolchain` checks as an environment-supplied
    /// one, so remux output remains reproducible and auditable; the only
    /// difference is the trust root (the local binary on disk instead of an
    /// env var). Returns nil when no usable pair is found.
    ///
    /// The version prefix is captured as the first line of `ffmpeg -version`
    /// so the existing `hasPrefix` validation still passes. SHA-256 is
    /// computed via `FileSupport.sha256`, the same routine used to validate
    /// pinned toolchains.
    public static func autodetect(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> FFmpegToolchain? {
        func locate(_ tool: String) async -> URL? {
            // Common Homebrew locations first (stable across Intel/Silicon),
            // then a PATH search via `which`.
            let candidates = [
                "/opt/homebrew/bin/\(tool)",
                "/usr/local/bin/\(tool)",
                "/usr/bin/\(tool)",
            ]
            for path in candidates {
                let url = URL(fileURLWithPath: path)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
            guard let which = try? await runWhich(tool) else { return nil }
            return URL(fileURLWithPath: which)
        }

        guard let ffmpegURL = await locate("ffmpeg"),
            let ffprobeURL = await locate("ffprobe")
        else { return nil }

        // Compute SHA-256 of both binaries. If either fails (e.g. the file
        // vanished between locate and read), give up rather than returning a
        // half-populated toolchain.
        guard let ffmpegSHA = try? FileSupport.sha256(url: ffmpegURL),
            let ffprobeSHA = try? FileSupport.sha256(url: ffprobeURL)
        else { return nil }

        // Capture the version first line as the prefix; validateToolchain
        // checks `version.hasPrefix(prefix)`, so the full first line is the
        // most specific prefix that still matches.
        let ffmpegVersion = (try? await captureVersion(of: ffmpegURL, tool: "ffmpeg")) ?? ""
        let ffprobeVersion = (try? await captureVersion(of: ffprobeURL, tool: "ffprobe")) ?? ""
        guard !ffmpegVersion.isEmpty, !ffprobeVersion.isEmpty else { return nil }

        return FFmpegToolchain(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            ffmpegSHA256: ffmpegSHA,
            ffprobeSHA256: ffprobeSHA,
            ffmpegVersionPrefix: ffmpegVersion,
            ffprobeVersionPrefix: ffprobeVersion
        )
    }

    /// Runs `which <tool>` to find a binary on PATH. Isolated so the
    /// autodetect path can be unit-tested without a real shell.
    private static func runWhich(_ tool: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FFmpegError.executableNotFound(tool) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path
    }

    /// Captures the first line of `<binary> -version` for use as the version
    /// prefix. Reuses the same Process plumbing the service uses elsewhere.
    private static func captureVersion(of url: URL, tool: String) async throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FFmpegError.versionMismatch(tool: tool) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output.firstLine
    }
}

public enum FFmpegOutputKind: String, Sendable {
    case mp4
    case m4a
}

public struct FFmpegRemuxRequest: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let outputKind: FFmpegOutputKind
    public let expectedDuration: TimeInterval?
    public let expectedSHA256: String?
    public let timeout: TimeInterval
    public let control: (@Sendable () -> DownloadControl)?

    public init(
        inputURL: URL,
        outputURL: URL,
        outputKind: FFmpegOutputKind = .mp4,
        expectedDuration: TimeInterval? = nil,
        expectedSHA256: String? = nil,
        timeout: TimeInterval = 5 * 60,
        control: (@Sendable () -> DownloadControl)? = nil
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.outputKind = outputKind
        self.expectedDuration = expectedDuration
        self.expectedSHA256 = expectedSHA256
        self.timeout = timeout
        self.control = control
    }
}

public struct FFmpegMergeRequest: Sendable {
    public let videoURL: URL?
    public let audioURL: URL?
    public let outputURL: URL
    public let outputKind: FFmpegOutputKind
    public let expectedDuration: TimeInterval?
    public let expectedSHA256: String?
    public let timeout: TimeInterval
    public let control: (@Sendable () -> DownloadControl)?

    public init(
        videoURL: URL?,
        audioURL: URL?,
        outputURL: URL,
        outputKind: FFmpegOutputKind = .mp4,
        expectedDuration: TimeInterval? = nil,
        expectedSHA256: String? = nil,
        timeout: TimeInterval = 5 * 60,
        control: (@Sendable () -> DownloadControl)? = nil
    ) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.outputURL = outputURL
        self.outputKind = outputKind
        self.expectedDuration = expectedDuration
        self.expectedSHA256 = expectedSHA256
        self.timeout = timeout
        self.control = control
    }
}

public struct FFmpegStreamInfo: Codable, Hashable, Sendable {
    public let index: Int?
    public let codecName: String?
    public let codecType: String?
    public let width: Int?
    public let height: Int?
    public let duration: Double?

    public init(
        index: Int?,
        codecName: String?,
        codecType: String?,
        width: Int?,
        height: Int?,
        duration: Double?
    ) {
        self.index = index
        self.codecName = codecName
        self.codecType = codecType
        self.width = width
        self.height = height
        self.duration = duration
    }
}

public struct FFmpegProbeResult: Codable, Hashable, Sendable {
    public let formatName: String?
    public let duration: Double?
    public let streams: [FFmpegStreamInfo]

    public init(formatName: String?, duration: Double?, streams: [FFmpegStreamInfo]) {
        self.formatName = formatName
        self.duration = duration
        self.streams = streams
    }

    public var hasVideo: Bool { streams.contains { $0.codecType == "video" } }
    public var hasAudio: Bool { streams.contains { $0.codecType == "audio" } }
}

public struct FFmpegToolchainValidation: Hashable, Sendable {
    public let ffmpegVersion: String
    public let ffprobeVersion: String
    public let ffmpegSHA256: String
    public let ffprobeSHA256: String
}

public struct FFmpegRemuxResult: Hashable, Sendable {
    public let destination: URL
    public let byteCount: Int64
    public let sha256: String?
    public let probe: FFmpegProbeResult

    public init(
        destination: URL,
        byteCount: Int64,
        sha256: String? = nil,
        probe: FFmpegProbeResult
    ) {
        self.destination = destination
        self.byteCount = byteCount
        self.sha256 = sha256
        self.probe = probe
    }
}

public protocol FFmpegRemuxing: Sendable {
    func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult
}

public protocol FFmpegMerging: Sendable {
    func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult
}

public enum FFmpegError: Error, Equatable, Sendable {
    case invalidToolchain(String)
    case executableNotFound(String)
    case hashMismatch(tool: String)
    case versionMismatch(tool: String)
    case inputMissing
    case invalidInputSet
    case outputAlreadyExists
    case invalidTimeout
    case launchFailed(tool: String)
    case processFailed(tool: String, status: Int32, stderrTail: String? = nil)
    case timedOut(tool: String)
    case cancelled
    case invalidProbeOutput
    case missingExpectedStream
    case durationMismatch(expected: Double, actual: Double)
    case invalidOutput
}

extension FFmpegError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidToolchain: return "FFmpeg 工具链配置无效"
        case .executableNotFound: return "FFmpeg 可执行文件不存在或不可执行"
        case .hashMismatch: return "FFmpeg 可执行文件 SHA-256 校验失败"
        case .versionMismatch: return "FFmpeg 可执行文件版本不符合配置"
        case .inputMissing: return "FFmpeg 输入文件不存在"
        case .invalidInputSet: return "FFmpeg 合并至少需要一个输入轨道"
        case .outputAlreadyExists: return "FFmpeg 输出文件已存在"
        case .invalidTimeout: return "FFmpeg 超时时间无效"
        case .launchFailed: return "无法启动 FFmpeg 进程"
        case .processFailed(let tool, let status, let stderrTail):
            guard let stderrTail, !stderrTail.isEmpty else {
                return "FFmpeg 进程失败，未发布输出文件"
            }
            return "FFmpeg 进程失败（\(tool) 退出码 \(status)）：\(stderrTail)"
        case .timedOut: return "FFmpeg 进程超时，未发布输出文件"
        case .cancelled: return "FFmpeg 进程已取消"
        case .invalidProbeOutput: return "ffprobe 输出无法解析"
        case .missingExpectedStream: return "FFmpeg 输出缺少预期媒体轨道"
        case .durationMismatch: return "FFmpeg 输出时长与输入不一致"
        case .invalidOutput: return "FFmpeg 输出无效或为空"
        }
    }
}

public extension FFmpegError {
    /// Stable error identifiers persisted by the App task model.
    var code: String {
        switch self {
        case .invalidToolchain: "FFMPEG_CONFIG_INVALID"
        case .executableNotFound: "FFMPEG_NOT_FOUND"
        case .hashMismatch: "FFMPEG_HASH_MISMATCH"
        case .versionMismatch: "FFMPEG_VERSION_MISMATCH"
        case .inputMissing: "FFMPEG_INPUT_MISSING"
        case .invalidInputSet: "FFMPEG_INPUT_SET_INVALID"
        case .outputAlreadyExists: "FFMPEG_OUTPUT_CONFLICT"
        case .invalidTimeout: "FFMPEG_TIMEOUT_INVALID"
        case .launchFailed: "FFMPEG_LAUNCH_FAILED"
        case .processFailed: "FFMPEG_PROCESS_FAILED"
        case .timedOut: "FFMPEG_TIMED_OUT"
        case .cancelled: "CANCELLED"
        case .invalidProbeOutput: "FFMPEG_PROBE_INVALID"
        case .missingExpectedStream: "FFMPEG_STREAM_MISSING"
        case .durationMismatch: "FFMPEG_DURATION_MISMATCH"
        case .invalidOutput: "FFMPEG_OUTPUT_INVALID"
        }
    }
}

public struct FFmpegService: FFmpegRemuxing, FFmpegMerging, Sendable {
    private let toolchain: FFmpegToolchain
    private let verifier: ArtifactVerifier

    public init(toolchain: FFmpegToolchain, verifier: ArtifactVerifier = ArtifactVerifier()) {
        self.toolchain = toolchain
        self.verifier = verifier
    }

    public func validateToolchain(timeout: TimeInterval = 15) async throws -> FFmpegToolchainValidation {
        guard timeout > 0, timeout.isFinite else { throw FFmpegError.invalidTimeout }
        guard !toolchain.ffmpegSHA256.isEmpty, !toolchain.ffprobeSHA256.isEmpty,
            !toolchain.ffmpegVersionPrefix.isEmpty, !toolchain.ffprobeVersionPrefix.isEmpty,
            toolchain.ffmpegSHA256.allSatisfy(\.isHexDigit),
            toolchain.ffprobeSHA256.allSatisfy(\.isHexDigit),
            toolchain.ffmpegSHA256.count == 64, toolchain.ffprobeSHA256.count == 64
        else { throw FFmpegError.invalidToolchain("pinned version and SHA-256 are required") }
        try validateExecutable(toolchain.ffmpegURL, tool: "ffmpeg")
        try validateExecutable(toolchain.ffprobeURL, tool: "ffprobe")

        let ffmpegHash = try digest(of: toolchain.ffmpegURL)
        guard ffmpegHash == toolchain.ffmpegSHA256 else {
            throw FFmpegError.hashMismatch(tool: "ffmpeg")
        }
        let ffprobeHash = try digest(of: toolchain.ffprobeURL)
        guard ffprobeHash == toolchain.ffprobeSHA256 else {
            throw FFmpegError.hashMismatch(tool: "ffprobe")
        }

        let ffmpegVersion = try await run(
            executableURL: toolchain.ffmpegURL,
            arguments: ["-version"],
            timeout: timeout,
            tool: "ffmpeg"
        ).stdout
        guard ffmpegVersion.firstLine.hasPrefix(toolchain.ffmpegVersionPrefix) else {
            throw FFmpegError.versionMismatch(tool: "ffmpeg")
        }

        let ffprobeVersion = try await run(
            executableURL: toolchain.ffprobeURL,
            arguments: ["-version"],
            timeout: timeout,
            tool: "ffprobe"
        ).stdout
        guard ffprobeVersion.firstLine.hasPrefix(toolchain.ffprobeVersionPrefix) else {
            throw FFmpegError.versionMismatch(tool: "ffprobe")
        }

        return FFmpegToolchainValidation(
            ffmpegVersion: ffmpegVersion.firstLine,
            ffprobeVersion: ffprobeVersion.firstLine,
            ffmpegSHA256: ffmpegHash,
            ffprobeSHA256: ffprobeHash
        )
    }

    public func probe(_ url: URL, timeout: TimeInterval = 30) async throws -> FFmpegProbeResult {
        _ = try await validateToolchain(timeout: timeout)
        return try await probeWithoutValidation(url, timeout: timeout, control: nil)
    }

    public func remux(_ request: FFmpegRemuxRequest) async throws -> FFmpegRemuxResult {
        guard request.timeout > 0, request.timeout.isFinite else {
            throw FFmpegError.invalidTimeout
        }
        _ = try await validateToolchain(timeout: min(request.timeout, 15))
        guard FileManager.default.fileExists(atPath: request.inputURL.path) else {
            throw FFmpegError.inputMissing
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path) else {
            throw FFmpegError.outputAlreadyExists
        }
        guard request.inputURL.standardizedFileURL != request.outputURL.standardizedFileURL else {
            throw FFmpegError.invalidOutput
        }
        let outputDirectory = request.outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = outputDirectory.appendingPathComponent(
            "." + request.outputURL.lastPathComponent + "." + UUID().uuidString
                + ".macidm.ffmpeg." + request.outputKind.rawValue
        )

        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-n", "-i", request.inputURL.path]
        switch request.outputKind {
        case .mp4:
            arguments += ["-map", "0", "-c", "copy", "-movflags", "+faststart", temporary.path]
        case .m4a:
            arguments += ["-map", "0:a:0?", "-vn", "-c:a", "copy", temporary.path]
        }

        do {
            let process = try await run(
                executableURL: toolchain.ffmpegURL,
                arguments: arguments,
                timeout: request.timeout,
                tool: "ffmpeg",
                control: request.control
            )
            guard process.exitStatus == 0 else {
                throw FFmpegError.processFailed(
                    tool: "ffmpeg",
                    status: process.exitStatus,
                    stderrTail: process.stderrTail
                )
            }
            guard FileManager.default.fileExists(atPath: temporary.path),
                let size = try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
                size.int64Value > 0
            else { throw FFmpegError.invalidOutput }

            let probe = try await probeWithoutValidation(
                temporary,
                timeout: request.timeout,
                control: request.control
            )
            try validateOutput(probe, kind: request.outputKind, expectedDuration: request.expectedDuration)
            let verifyResult = try verifier.verifyAndPublish(
                temporary: temporary,
                destination: request.outputURL,
                expectedSHA256: request.expectedSHA256,
                byteCount: size.int64Value,
                usedParallelRequests: 1,
                resumed: false,
                defaultVerification: "remux-verified",
                synchronizeParentDirectory: false
            )
            return FFmpegRemuxResult(
                destination: request.outputURL,
                byteCount: size.int64Value,
                sha256: verifyResult.sha256,
                probe: probe
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
        guard request.timeout > 0, request.timeout.isFinite else {
            throw FFmpegError.invalidTimeout
        }
        _ = try await validateToolchain(timeout: min(request.timeout, 15))
        let inputs = [request.videoURL, request.audioURL].compactMap { $0 }
        guard !inputs.isEmpty else { throw FFmpegError.invalidInputSet }
        guard inputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FFmpegError.inputMissing
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path) else {
            throw FFmpegError.outputAlreadyExists
        }
        let outputDirectory = request.outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = outputDirectory.appendingPathComponent(
            "." + request.outputURL.lastPathComponent + "." + UUID().uuidString
                + ".macidm.ffmpeg." + request.outputKind.rawValue
        )
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-n"]
        for input in inputs {
            arguments += ["-i", input.path]
        }
        switch request.outputKind {
        case .mp4:
            if request.videoURL != nil {
                arguments += ["-map", String(0) + ":v:0?"]
            }
            if request.audioURL != nil {
                let index = request.videoURL == nil ? 0 : 1
                arguments += ["-map", String(index) + ":a:0?"]
            }
            arguments += ["-c", "copy", "-movflags", "+faststart", temporary.path]
        case .m4a:
            let index = request.videoURL == nil ? 0 : 1
            arguments += ["-map", String(index) + ":a:0?", "-vn", "-c:a", "copy", temporary.path]
        }

        do {
            let process = try await run(
                executableURL: toolchain.ffmpegURL,
                arguments: arguments,
                timeout: request.timeout,
                tool: "ffmpeg",
                control: request.control
            )
            guard process.exitStatus == 0 else {
                throw FFmpegError.processFailed(
                    tool: "ffmpeg",
                    status: process.exitStatus,
                    stderrTail: process.stderrTail
                )
            }
            guard FileManager.default.fileExists(atPath: temporary.path),
                let size = try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
                size.int64Value > 0
            else { throw FFmpegError.invalidOutput }
            let probe = try await probeWithoutValidation(
                temporary,
                timeout: request.timeout,
                control: request.control
            )
            try validateOutput(probe, kind: request.outputKind, expectedDuration: request.expectedDuration)
            let verifyResult = try verifier.verifyAndPublish(
                temporary: temporary,
                destination: request.outputURL,
                expectedSHA256: request.expectedSHA256,
                byteCount: size.int64Value,
                usedParallelRequests: 1,
                resumed: false,
                defaultVerification: "merge-verified",
                synchronizeParentDirectory: false
            )
            return FFmpegRemuxResult(
                destination: request.outputURL,
                byteCount: size.int64Value,
                sha256: verifyResult.sha256,
                probe: probe
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func probeWithoutValidation(
        _ url: URL,
        timeout: TimeInterval,
        control: (@Sendable () -> DownloadControl)?
    ) async throws -> FFmpegProbeResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FFmpegError.inputMissing }
        let process = try await run(
            executableURL: toolchain.ffprobeURL,
            arguments: [
                "-hide_banner", "-v", "error", "-print_format", "json",
                "-show_format", "-show_streams", url.path,
            ],
            timeout: timeout,
            tool: "ffprobe",
            control: control
        )
        guard process.exitStatus == 0 else {
            throw FFmpegError.processFailed(
                tool: "ffprobe",
                status: process.exitStatus,
                stderrTail: process.stderrTail
            )
        }
        do {
            let data = Data(process.stdout.utf8)
            let payload = try JSONDecoder().decode(ProbePayload.self, from: data)
            return FFmpegProbeResult(
                formatName: payload.format?.formatName,
                duration: payload.format?.duration.flatMap(Double.init),
                streams: payload.streams.map {
                    FFmpegStreamInfo(
                        index: $0.index,
                        codecName: $0.codecName,
                        codecType: $0.codecType,
                        width: $0.width,
                        height: $0.height,
                        duration: $0.duration.flatMap(Double.init)
                    )
                }
            )
        } catch {
            throw FFmpegError.invalidProbeOutput
        }
    }

    private func validateOutput(
        _ probe: FFmpegProbeResult,
        kind: FFmpegOutputKind,
        expectedDuration: TimeInterval?
    ) throws {
        guard let formatName = probe.formatName,
            formatName.split(separator: ",").contains(where: { $0 == "mov" || $0 == "mp4" || $0 == "ipod" })
        else { throw FFmpegError.invalidOutput }
        switch kind {
        case .mp4:
            guard probe.hasVideo || probe.hasAudio else { throw FFmpegError.missingExpectedStream }
        case .m4a:
            guard probe.hasAudio else { throw FFmpegError.missingExpectedStream }
        }
        if let expectedDuration, expectedDuration > 0 {
            guard let actualDuration = probe.duration else {
                throw FFmpegError.invalidProbeOutput
            }
            if abs(actualDuration - expectedDuration) / expectedDuration > 0.01 {
                throw FFmpegError.durationMismatch(expected: expectedDuration, actual: actualDuration)
            }
        }
    }

    private func validateExecutable(_ url: URL, tool: String) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw FFmpegError.executableNotFound(tool)
        }
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        tool: String,
        control: (@Sendable () -> DownloadControl)? = nil
    ) async throws -> FFmpegProcessResult {
        guard timeout > 0, timeout.isFinite else { throw FFmpegError.invalidTimeout }
        let operation = FFmpegProcessOperation(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            tool: tool,
            control: control
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }
}

private struct ProbePayload: Decodable {
    struct Format: Decodable {
        let formatName: String?
        let duration: String?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case duration
        }
    }

    struct Stream: Decodable {
        let index: Int?
        let codecName: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let duration: String?

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case codecType = "codec_type"
            case width
            case height
            case duration
        }
    }

    let format: Format?
    let streams: [Stream]
}

private struct FFmpegProcessResult: Sendable {
    let exitStatus: Int32
    let stdout: String
    let stderrTail: String?
}

/// Keeps only the tail of ffmpeg/ffprobe stderr: error-level diagnostics
/// appear at the end, and full output may grow without bound.
private func ffmpegStderrTail(_ data: Data, maximumBytes: Int = 8 * 1024) -> String? {
    guard !data.isEmpty else { return nil }
    let clipped = data.count > maximumBytes ? data.suffix(maximumBytes) : data
    let text = String(data: Data(clipped), encoding: .utf8) ?? ""
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private final class FFmpegProcessOperation: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let tool: String
    private let control: (@Sendable () -> DownloadControl)?
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        tool: String,
        control: (@Sendable () -> DownloadControl)?
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.tool = tool
        self.control = control
    }

    func run() async throws -> FFmpegProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.execute(continuation: continuation)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    /// Escalate a SIGTERM to SIGKILL if the child is still running after a
    /// short grace period. Called after every termination path so a
    /// non-responsive ffmpeg/ffprobe is reaped deterministically.
    private func forceTerminateIfNeeded(_ process: Process) {
        guard process.isRunning else { return }
        let graceDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func execute(continuation: CheckedContinuation<FFmpegProcessResult, Error>) {
        let output = Pipe()
        let errorOutput = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput

        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: FFmpegError.cancelled)
            return
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            self.process = nil
            lock.unlock()
            continuation.resume(throwing: FFmpegError.launchFailed(tool: tool))
            return
        }

        // Both pipes must be drained while the child is running. Waiting for
        // the process first can deadlock when ffmpeg/ffprobe fills stderr or
        // stdout before it exits.
        output.fileHandleForWriting.closeFile()
        errorOutput.fileHandleForWriting.closeFile()
        let readers = DispatchGroup()
        let stdoutCapture = FFmpegPipeCapture()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            stdoutCapture.set(data)
            readers.leave()
        }
        readers.enter()
        let stderrCapture = FFmpegPipeCapture()
        DispatchQueue.global(qos: .utility).async {
            var collected = Data()
            while true {
                let chunk = errorOutput.fileHandleForReading.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                collected.append(chunk)
                if collected.count > 1 << 20 { collected.removeFirst(collected.count - (1 << 20)) }
            }
            stderrCapture.set(collected)
            readers.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var controlStop: DownloadControl?
        while process.isRunning {
            if let control {
                switch control() {
                case .continue: break
                case .pause:
                    controlStop = .pause
                    process.terminate()
                case .cancel:
                    controlStop = .cancel
                    process.terminate()
                }
                if controlStop != nil { break }
            }
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                process.terminate()
                break
            }
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // SIGTERM has already been issued inside the loop for cancel/timeout.
        // Give the child a few seconds to drain its pipes and exit, then
        // escalate to SIGKILL so a stuck ffmpeg/ffprobe cannot wedge the
        // download task or leak the pipe-reading dispatch group forever.
        forceTerminateIfNeeded(process)
        process.waitUntilExit()
        readers.wait()

        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        if wasCancelled {
            continuation.resume(throwing: IDMError.cancelled)
            return
        }
        if let controlStop {
            switch controlStop {
            case .continue: break
            case .pause:
                continuation.resume(throwing: IDMError.paused)
                return
            case .cancel:
                continuation.resume(throwing: IDMError.cancelled)
                return
            }
        }
        if timedOut {
            continuation.resume(throwing: FFmpegError.timedOut(tool: tool))
            return
        }
        continuation.resume(
            returning: FFmpegProcessResult(
                exitStatus: process.terminationStatus,
                stdout: String(data: stdoutCapture.value(), encoding: .utf8) ?? "",
                stderrTail: ffmpegStderrTail(stderrCapture.value())
            )
        )
    }
}

private final class FFmpegPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private extension String {
    var firstLine: String {
        components(separatedBy: .newlines).first ?? ""
    }
}
