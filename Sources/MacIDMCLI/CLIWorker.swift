import Darwin
import Foundation
import IDMEngine

enum CLIWorker {
    /// Path-based media kind detection for CLI submissions. Mirrors the
    /// inspect-time heuristic; signed query material never affects routing.
    static func mediaKind(for url: URL) -> DownloadSourceKind {
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") { return .hls }
        if path.hasSuffix(".mpd") { return .dash }
        return .http
    }

    static func run(id: UUID, store: TaskStore) async throws {
        let signalSources = Self.installPauseOnSignal(store: store, id: id)
        defer {
            for source in signalSources { source.cancel() }
        }
        if let stored = try store.load(id), stored.errorCode == "NEEDS_REFETCH",
            store.runtimeURL(for: id) == nil
        {
            throw CLIError.usage("该任务的签名地址未持久化，请重新使用原始 URL 提交。")
        }
        guard let task = try store.claimWorker(id) else { throw CLIError.taskNotFound }
        guard let url = store.runtimeURL(for: id) ?? URL(string: task.url) else {
            throw IDMError.invalidURL
        }
        let sourceKind = mediaKind(for: url)
        // HLS/DASH need the FFmpeg toolchain: HLS publishes a raw segment
        // stream that must be remuxed, DASH merges separate audio/video
        // representations. Fail loudly before downloading anything.
        let ffmpegService: FFmpegService?
        if sourceKind == .http {
            ffmpegService = nil
        } else if let toolchain = FFmpegToolchain.fromEnvironment() {
            ffmpegService = FFmpegService(toolchain: toolchain)
        } else if let toolchain = await FFmpegToolchain.autodetect() {
            ffmpegService = FFmpegService(toolchain: toolchain)
        } else {
            throw CLIError.usage(
                "HLS/DASH 下载需要 FFmpeg 工具链：请安装 ffmpeg（brew install ffmpeg）或配置 MACIDM_FFMPEG_* 环境变量。"
            )
        }
        let finalDestination = URL(fileURLWithPath: task.destination)
        let hlsInput: URL? =
            sourceKind == .hls
            ? finalDestination.deletingLastPathComponent()
                .appendingPathComponent(".\(task.id.uuidString).macidm.hls-input.ts")
            : nil
        let request = DownloadRequest(
            url: url,
            destination: hlsInput ?? finalDestination,
            sourceKind: sourceKind,
            maximumParallelRequests: task.parallelRequests,
            expectedSHA256: sourceKind == .http ? task.expectedSHA256 : nil,
            taskID: task.id
        )
        let reporter = ProgressReporter(store: store, id: id)
        let controlReader = CachedControlReader(store: store, id: id)
        do {
            _ = try store.mutate(id) { $0.status = .running }
            let engine = DownloadEngine(
                hlsExecutor: HLSDownloadExecutor(merger: ffmpegService),
                dashExecutor: DASHDownloadExecutor(merger: ffmpegService)
            )
            let result = try await engine.download(
                request,
                control: { controlReader.read() },
                progress: { value in reporter.report(value) }
            )
            let published: DownloadResult
            if let hlsInput, let ffmpegService {
                // Mirror the App pipeline: remux the raw segment stream into
                // the final MP4 and only then remove the intermediate file.
                let remuxed = try await ffmpegService.remux(
                    FFmpegRemuxRequest(
                        inputURL: hlsInput,
                        outputURL: finalDestination,
                        outputKind: .mp4,
                        control: { controlReader.read() }
                    )
                )
                try? FileManager.default.removeItem(at: hlsInput)
                published = DownloadResult(
                    destination: remuxed.destination,
                    byteCount: remuxed.byteCount,
                    sha256: remuxed.sha256,
                    usedParallelRequests: result.usedParallelRequests,
                    resumed: result.resumed,
                    verification: "ffmpeg-ffprobe"
                )
            } else {
                published = result
            }
            _ = try store.mutate(id) {
                $0.status = .completed
                $0.desiredAction = .run
                $0.receivedBytes = published.byteCount
                $0.totalBytes = published.byteCount
                $0.sha256 = published.sha256
                $0.workerPID = nil
            }
        } catch let error as IDMError {
            _ = try? store.mutate(id) {
                switch error {
                case .paused:
                    $0.status = .paused
                case .cancelled:
                    $0.status = .cancelled
                case .filenameConflict:
                    $0.status = .filenameConflict
                case .storageError, .pathNotWritable:
                    $0.status = .storageError
                case .resourceChanged, .sidecarCorrupt:
                    $0.status = .needsRestart
                default:
                    $0.status = .failed
                }
                $0.errorCode = error.code
                $0.errorMessage = error.localizedDescription
                $0.workerPID = nil
            }
            throw error
        } catch {
            _ = try? store.mutate(id) {
                $0.status = .failed
                $0.errorCode = "NETWORK_ERROR"
                $0.errorMessage = error.localizedDescription
                $0.workerPID = nil
            }
            throw error
        }
    }

    /// Without this, Ctrl+C during `add --foreground` kills the process with
    /// `status=.running`/`workerPID` still recorded in the task file and no
    /// self-healing until the next resume/pause. The handler writes
    /// `desiredAction=.pause`, which the engine's control loop observes within
    /// ~200 ms and unwinds through the normal `.paused` completion path.
    /// A second signal exits immediately.
    private static func installPauseOnSignal(store: TaskStore, id: UUID) -> [DispatchSourceSignal] {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let countLock = NSLock()
        var forceExitCount = 0
        return [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(
                signal: sig,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler {
                _ = try? store.mutate(id) { $0.desiredAction = .pause }
                countLock.lock()
                forceExitCount += 1
                let count = forceExitCount
                countLock.unlock()
                if count >= 2 {
                    exit(130)
                }
            }
            source.resume()
            return source
        }
    }

    static func launch(id: UUID, arguments: CLIArguments) throws {
        // CommandLine.arguments[0] is $CWD-relative when invoked through PATH
        // (e.g. `macidm enqueue …`), so standardising it yields
        // $CWD/macidm — a non-existent path. _NSGetExecutablePath resolves the
        // real absolute path of the running binary regardless of how it was
        // invoked, which is what the detached worker must re-exec.
        let executablePath =
            currentExecutablePath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "_run", id.uuidString,
            "--state-dir", arguments.stateDirectory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return isWorkerProcessAlive(pid)
    }

    /// Returns `true` only when `pid` is still running AND its executable
    /// path resolves to the current binary. A bare `kill(pid, 0)` check
    /// cannot distinguish a recycled PID (the original worker exited and the
    /// OS reused the number for an unrelated process) from a genuinely live
    /// worker, which would permanently wedge a task in `alreadyRunning`.
    static func isWorkerProcessAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var peerBuffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &peerBuffer, UInt32(peerBuffer.count)) > 0 else {
            // Unable to resolve the path; fall back to the alive signal so we
            // don't false-positive on a transient sandbox restriction.
            return true
        }
        let peerPath = String(
            decoding: peerBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return currentExecutablePath().map { current in
            URL(fileURLWithPath: peerPath).standardizedFileURL.path
                == URL(fileURLWithPath: current).standardizedFileURL.path
        } ?? true
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let store: TaskStore
    private let id: UUID
    private var lastWrite = Date.distantPast
    private var lastBytes: Int64 = 0

    init(store: TaskStore, id: UUID) {
        self.store = store
        self.id = id
    }

    func report(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard
            Date().timeIntervalSince(lastWrite) >= 0.25
                || progress.receivedBytes - lastBytes >= 1_024 * 1_024
        else {
            return
        }
        lastWrite = Date()
        lastBytes = progress.receivedBytes
        _ = try? store.mutate(id) {
            $0.receivedBytes = progress.receivedBytes
            $0.totalBytes = progress.totalBytes
        }
    }
}

/// Caches `desiredAction` in memory and refreshes from disk at most once per
/// `refreshInterval`. The download engine invokes `control()` 1–2 times per
/// network chunk; without caching, every chunk paid the cost of flock + JSON
/// read + decode. With a 200 ms refresh ceiling, pause/cancel still land well
/// within the 250 ms responsiveness target.
private final class CachedControlReader: @unchecked Sendable {
    private let lock = NSLock()
    private let store: TaskStore
    private let id: UUID
    private let refreshInterval: TimeInterval
    private var cached: DesiredAction = .run
    private var lastRefresh = Date.distantPast

    init(store: TaskStore, id: UUID, refreshInterval: TimeInterval = 0.2) {
        self.store = store
        self.id = id
        self.refreshInterval = refreshInterval
    }

    func read() -> DownloadControl {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(lastRefresh) >= refreshInterval {
            lastRefresh = now
            cached = (try? store.load(id))?.desiredAction ?? .cancel
        }
        let action = cached
        lock.unlock()
        switch action {
        case .pause: return .pause
        case .cancel: return .cancel
        case .run: return .continue
        }
    }
}
