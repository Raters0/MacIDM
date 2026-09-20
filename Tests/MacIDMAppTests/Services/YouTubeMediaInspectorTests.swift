import IDMEngine
import XCTest

@testable import MacIDMApp

final class YouTubeMediaInspectorTests: XCTestCase {
    /// 构造一个假的 yt-dlp 可执行文件：向 stderr 输出指定文本并以
    /// status 退出。用于驱动 classifyProcessFailure 的错误归类
    /// （technical-spec §3.4）。
    private func makeFailingExecutable(
        stderr: String,
        status: Int32 = 1,
        diagnosticLog: YouTubeDiagnosticEventLog? = nil
    ) throws -> (
        YouTubeMediaInspector, URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorClassifyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script = "#!/bin/sh\ncat >&2 <<'EOF'\n\(stderr)\nEOF\nexit \(status)\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return (
            YouTubeMediaInspector(
                executableURL: executable, diagnosticLog: diagnosticLog ?? .shared),
            directory
        )
    }

    func testLiveURLsAreRecognizedAsYouTubePages() {
        // /live/<id> 与 /watch、/shorts 同为单视频页：已结束直播的回放
        // 允许进入检查链路；无效路径仍然拒绝（technical-spec §3.4）。
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/live/liv3id99")!))
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=abc123")!))
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/shorts/sh0rt1d")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(URL(string: "https://www.youtube.com/")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/live/")!))
        // §4.5：缺少或空着 `v` 参数的 /watch 不是视频页，浅层与深层判定一致。
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/shorts/")!))
        // 携带其他参数的 /watch 仍要求 `v`。
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?list=PL123&v=abc123")!))
        // §4.3：与扩展 youTubeVideoIDFromURL 同一组样例，判定必须完全一致。
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=abc_-12345")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=a")!),
            "过短 ID 必须拒绝")
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=ab!d")!),
            "非法字符 ID 必须拒绝")
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/watch?v=abcd!efgh")!),
            "含非法字符的长 ID 也必须拒绝")
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/live/abc")!),
            "过短 ID 必须拒绝")
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://www.youtube.com/live/liv3id99/extra")!),
            "多余路径不参与判定，第一段合法即有效")
        XCTAssertTrue(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://youtu.be/sh0rt1d")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(URL(string: "https://youtu.be/")!))
        XCTAssertFalse(
            YouTubeMediaInspector.isYouTubePage(
                URL(string: "https://youtu.be/abc")!),
            "过短 ID 必须拒绝")
    }

    func testInspectClassifiesAuthenticationRequirement() async throws {
        // "sign in to confirm / not a bot" 归类为 authenticationRequired，
        // 而不是泛化的 invalidPlaylist。
        let (inspector, directory) = try makeFailingExecutable(
            stderr: "ERROR: [youtube] abc123: Sign in to confirm you're not a bot."
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected authenticationRequired")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .authenticationRequired)
        }
    }

    func testInspectClassifiesStaleTool() async throws {
        let (inspector, directory) = try makeFailingExecutable(
            stderr: "WARNING: nsig extraction failed: Some formats may be missing"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected toolUpdateSuggested")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .toolUpdateSuggested)
        }
    }

    func testInspectClassifiesNetworkFailure() async throws {
        let (inspector, directory) = try makeFailingExecutable(
            stderr: "ERROR: unable to download video data: [Errno] Connection refused"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected networkOrProxyFailure")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .networkOrProxyFailure)
        }
    }

    func testInspectClassifiesUnusableCookieFile() async throws {
        // yt-dlp 拒绝临时 cookie file（invalid Netscape format）时归类为
        // cookieContextUnavailable，而不是泛化的 invalidPlaylist
        // （technical-spec §3.4）。
        let (inspector, directory) = try makeFailingExecutable(
            stderr: """
                http/cookiejar.py:2079: UserWarning: http.cookiejar bug!
                ERROR: invalid Netscape format cookies file '/tmp/cookies-fixture.txt': \
                'www.youtube.com\tTRUE\t/\tTRUE\t0\tVISITOR_INFO1_LIVE\tfake'
                """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected cookieContextUnavailable")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .cookieContextUnavailable)
        }
    }

    func testInspectWithoutVideoFormatsThrowsNoFormats() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorNoFormatsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        // 只有音轨（vcodec=none）的 JSON 是合法输出但没有视频变体。
        let json = """
            {"live_status": "not_live", "duration": 60, "formats": [
              {"format_id": "140", "ext": "m4a", "vcodec": "none",
               "acodec": "mp4a.40.2", "tbr": 129, "filesize": 900000}
            ]}
            """
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected noFormats")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .noFormats)
        }
    }

    /// 假 yt-dlp：把收到的 Cookie 相关参数记录到 marker 文件，再输出一个
    /// 合法 JSON（单条 720p 视频轨）让 inspect 成功返回。
    private func makeCookieObservingExecutable(directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let marker = directory.appendingPathComponent("cookie-args")
        let json = """
            {"live_status": "not_live", "duration": 60, "formats": [
              {"format_id": "22", "ext": "mp4", "width": 1280, "height": 720,
               "vcodec": "avc1.64001F", "acodec": "mp4a.40.2", "tbr": 1500,
               "filesize": 10000000}
            ]}
            """
        let script = """
            #!/bin/sh
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "--cookies" ]; then
                if [ -f "$arg" ]; then
                  echo "cookieFileExists=$arg" >> "\(marker.path)"
                  sed -n '2p' "$arg" >> "\(marker.path)"
                else
                  echo "cookieFileMissing=$arg" >> "\(marker.path)"
                fi
              fi
              if [ "$prev" = "--cookies-from-browser" ]; then
                echo "browserFallback=$arg" >> "\(marker.path)"
              fi
              prev="$arg"
            done
            cat <<'EOF'
            \(json)
            EOF
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func testExplicitCookieContextUsesTemporaryCookieFileAndCleansUp() async throws {
        // 显式 Cookie 存在时：yt-dlp 收到 --cookies <临时文件>，文件在
        // 进程运行期间存在，inspect 结束后被删除。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorCookieTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = try makeCookieObservingExecutable(directory: directory)
        let requestContext = DownloadRequestContext(
            cookie: "session=fixture",
            referer: nil,
            userAgent: nil
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        _ = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: requestContext,
            mediaKind: .http
        )

        let marker = directory.appendingPathComponent("cookie-args")
        let recorded = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(recorded.contains("cookieFileExists="), "expected an explicit cookie file")
        XCTAssertFalse(recorded.contains("browserFallback="), "must not fall back with a supplied cookie")

        // Netscape 格式断言 domain_specified=TRUE 的域名必须以「.」开头，
        // 否则 yt-dlp 拒绝整个 Cookie 文件（2026-08-26 真实环境复现的
        // App 回退失败根因）。页面主机 www.youtube.com → .www.youtube.com。
        // Cookie 行内 name 与 value 以 TAB 分隔，不是「=」。
        let cookieRow =
            recorded
            .split(separator: "\n")
            .first { $0.contains("\tsession\tfixture") }
            .map(String.init)
            ?? ""
        XCTAssertTrue(
            cookieRow.hasPrefix(".www.youtube.com\tTRUE\t/\tTRUE\t"),
            "cookie row must use a leading-dot domain, got: \(cookieRow)"
        )

        // 临时 cookie file 必须已清理：检查 yt-dlp 的 Cookie 临时目录没有残留。
        let cookieDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-youtube-inspect", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cookieDir.path)) ?? []
        XCTAssertTrue(
            leftovers.filter { $0.hasPrefix("cookies-") }.isEmpty,
            "temporary cookie files must be cleaned up, found: \(leftovers)"
        )
    }

    func testWithoutCookieContextRunsAnonymouslyWithoutBrowserCookies() async throws {
        // 无 Cookie：匿名运行。规格已移除 --cookies-from-browser 回退
        // （§6 Swift-4）：读 Chrome 的 Cookies DB 需要 macOS Full Disk
        // Access 且每次 ad-hoc 重建都失效，因此无授权 Cookie 时不得传任何
        // Cookie 参数，让 yt-dlp 匿名提取（公开视频仍可用）。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorNoCookieTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = try makeCookieObservingExecutable(directory: directory)

        let inspector = YouTubeMediaInspector(executableURL: executable)
        _ = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: nil,
            mediaKind: .http
        )

        // 匿名：假 yt-dlp 只在收到 --cookies / --cookies-from-browser 时写
        // marker；两者都不应出现，故 marker 不存在。
        let marker = directory.appendingPathComponent("cookie-args")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "anonymous inspect must not pass any cookie argument (no Chrome DB read)"
        )
    }

    func testInspectCancellationTerminatesChildProcessPromptly() async throws {
        // Regression: AppModel.withTimeout(15) only works if the inspect
        // process reacts to Swift cancellation. Previously the continuation
        // ignored cancelAll() and the dialog hung until the inner 60s
        // process timeout expired.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorCancelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("terminated")
        let pidFile = directory.appendingPathComponent("child.pid")
        let executable = directory.appendingPathComponent("slow-fake-yt-dlp")
        // 注意：`sleep 60` 若作为脚本最后一条命令会被 shell 尾调用 exec 优化替换，
        // trap 随之丢失；后台 + wait 结构保证 trap 始终存活。另须用 bash：
        // macOS 自带 /bin/sh 在 wait 期间收到 TERM 不会及时执行 trap（实测）。
        // 标记用 bash 内建重定向而非 touch：touch 需 fork 外部进程，高负载下
        // 慢，可能在 SIGKILL 升级前没来得及落盘（误报残留）。
        let script =
            [
                "#!/bin/bash",
                "echo $$ > \"\(pidFile.path)\"",
                "trap 'echo 1 > \"\(marker.path)\"; exit 1' TERM",
                "sleep 60 &",
                "wait",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        let task = Task {
            try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
        }
        // Wait until the child actually starts (it writes its PID first):
        // a fixed sleep races a slow launch under heavy parallel test load.
        var childStarted = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) {
                childStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(childStarted, "fake yt-dlp child never started")
        let cancelStart = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the inspection to throw after cancellation")
        } catch {
            // The await must settle almost immediately — well below any
            // process timeout — proving cancellation propagates.
            XCTAssertLessThan(
                Date().timeIntervalSince(cancelStart), 5,
                "cancellation took too long to settle the inspect call")
        }

        // The child must actually receive SIGTERM, not merely be abandoned.
        var sawMarker = false
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: marker.path) {
                sawMarker = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawMarker, "expected the child process to be terminated on cancel")

        // 直接子进程必须确实退出（非僵尸）：即使标记竞态也不得留下活进程。
        let childPID = try XCTUnwrap(
            pid_t(
                (try String(contentsOf: pidFile, encoding: .utf8))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        var deadline = 60
        while deadline > 0 && ProcessTree.isRunning(childPID) {
            deadline -= 1
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(ProcessTree.isRunning(childPID), "child process must be reaped on cancel")
    }

    func testInspectCancellationAlsoTerminatesLongLivedDescendant() async throws {
        // technical-spec §3.4：yt-dlp 会再派生长寿命后代（JS 运行时）；取消必须结束
        // 整棵进程树，只杀直接子进程会把后代留守成孤儿进程。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorDescendantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        let executable = directory.appendingPathComponent("slow-fake-yt-dlp")
        let script =
            [
                "#!/bin/bash",
                "sleep 300 &",
                "echo $! > \"\(descendantPIDFile.path)\"",
                "sleep 60 &",
                "wait",
            ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        let task = Task {
            try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
        }
        // 等子进程启动并写出后代 PID。
        var descendantPID: pid_t = 0
        for _ in 0..<40 {
            if let raw = try? String(contentsOf: descendantPIDFile, encoding: .utf8),
                let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                descendantPID = pid
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(descendantPID, 0, "helper must report the descendant PID")
        XCTAssertTrue(ProcessTree.isRunning(descendantPID))

        let cancelStart = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the inspection to throw after cancellation")
        } catch {
            // continuation 只能在进程树退出后结束：结束得快，且结束时后代已死。
            XCTAssertLessThan(
                Date().timeIntervalSince(cancelStart), 8,
                "cancellation took too long to settle the inspect call")
        }
        XCTAssertFalse(
            ProcessTree.isRunning(descendantPID),
            "the long-lived descendant must be terminated together with the child"
        )
    }

    func testInspectFillsTopLevelDurationOntoEveryVariant() async throws {
        // yt-dlp 顶层 duration 对所有画质相同；逐 format 的 duration 常缺失，
        // 确认窗口与插件 tooltip 需要每个变体都带上时长。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorDurationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let json = """
            {"live_status": "not_live", "duration": 301.5, "formats": [
              {"format_id": "22", "ext": "mp4", "width": 1280, "height": 720,
               "vcodec": "avc1.64001F", "acodec": "mp4a.40.2", "tbr": 1500},
              {"format_id": "137", "ext": "mp4", "width": 1920, "height": 1080,
               "vcodec": "avc1.640028", "acodec": "none", "tbr": 4300}
            ]}
            """
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        let inspection = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: nil,
            mediaKind: .http
        )

        XCTAssertEqual(inspection.variants.count, 2)
        for variant in inspection.variants {
            XCTAssertEqual(variant.duration, 301.5)
        }
    }

    func testVariantEstimatesMirrorTheMergedFormatSelector() async throws {
        // 预估必须对齐下载端的 bv*[ext=mp4][height<=h]+ba[ext=m4a] 口径：
        // 视频轨 filesize + 最优 m4a 音轨 filesize，而不是单轨 filesize。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorEstimateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let json = """
            {"live_status": "not_live", "duration": 600, "formats": [
              {"format_id": "22", "ext": "mp4", "width": 1280, "height": 720,
               "vcodec": "avc1.64001F", "acodec": "mp4a.40.2", "tbr": 1500,
               "filesize": 15000000},
              {"format_id": "137", "ext": "mp4", "width": 1920, "height": 1080,
               "vcodec": "avc1.640028", "acodec": "none", "tbr": 4300,
               "filesize": 60000000},
              {"format_id": "248", "ext": "webm", "width": 1920, "height": 1080,
               "vcodec": "vp9", "acodec": "none", "tbr": 3000,
               "filesize": 40000000},
              {"format_id": "136", "ext": "mp4", "width": 1280, "height": 720,
               "vcodec": "avc1.4d401f", "acodec": "none", "tbr": 2000,
               "filesize": 25000000},
              {"format_id": "140", "ext": "m4a", "vcodec": "none",
               "acodec": "mp4a.40.2", "tbr": 129, "filesize": 1800000},
              {"format_id": "251", "ext": "webm", "vcodec": "none",
               "acodec": "opus", "tbr": 160, "filesize": 2100000}
            ]}
            """
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        let inspection = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: nil,
            mediaKind: .http
        )

        // 变体按（高度、码率）降序：1080 mp4(137)、1080 webm(248)、
        // 720 progressive(22)、720 mp4(136)。
        XCTAssertEqual(inspection.variants.count, 4)
        let estimates = inspection.variants.map(\.estimatedSize)
        // 预估镜像用户实际选中的 itag（technical-spec §3.4）：变体 URL 带
        // itag 时按「该轨自身大小 + 无音轨则叠加最优 m4a」计算。
        // 1080 mp4(137)：60M + m4a 140 的 1.8M。
        XCTAssertEqual(estimates[0], 60_000_000 + 1_800_000)
        // 1080 webm(248)：40M + 1.8M —— 与 137 不同，预估真实反映编码选择。
        XCTAssertEqual(estimates[1], 40_000_000 + 1_800_000)
        // 720 两行按码率降序：136（tbr 2000）在前，22（tbr 1500）在后。
        // 136 无音轨：25M + 1.8M；22 自带音轨：仅自身 15M。
        XCTAssertEqual(inspection.variants[2].height, 720)
        XCTAssertEqual(estimates[2], 25_000_000 + 1_800_000)
        XCTAssertEqual(estimates[3], 15_000_000)
    }

    func testVariantEstimateFallsBackToDurationTimesBitrate() async throws {
        // filesize 缺失时退回 duration × 码率；progressive 选中时不再叠加音轨。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorFallbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let json = """
            {"live_status": "not_live", "duration": 100, "formats": [
              {"format_id": "18", "ext": "mp4", "width": 640, "height": 360,
               "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "tbr": 500}
            ]}
            """
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let inspector = YouTubeMediaInspector(executableURL: executable)
        let inspection = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: nil,
            mediaKind: .http
        )

        XCTAssertEqual(inspection.variants.count, 1)
        // 100s × 500 kbps / 8 = 6.25 MB；progressive 不再叠加音轨。
        XCTAssertEqual(inspection.variants.first?.estimatedSize, 6_250_000)
    }

    // MARK: - Live status（technical-spec §3.4）

    /// 构造输出固定 `-J` JSON 的假 yt-dlp。
    private func makeJSONExecutable(json: String, directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-yt-dlp-\(UUID().uuidString)")
        let script = "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInspectorLiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let vodFormats = """
        "formats": [
          {"format_id": "22", "ext": "mp4", "width": 1280, "height": 720,
           "vcodec": "avc1.64001F", "acodec": "mp4a.40.2", "tbr": 1500,
           "filesize": 10000000}
        ]
        """

    func testInspectBlocksCurrentlyLiveStream() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = "{\"is_live\": true, \"live_status\": \"is_live\", \(vodFormats)}"
        let inspector = YouTubeMediaInspector(
            executableURL: try makeJSONExecutable(json: json, directory: directory))
        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/live/liv3id99")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected unsupportedLiveStream")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .unsupportedLiveStream)
        }
    }

    func testInspectBlocksUpcomingLiveStream() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = "{\"live_status\": \"is_upcoming\", \(vodFormats)}"
        let inspector = YouTubeMediaInspector(
            executableURL: try makeJSONExecutable(json: json, directory: directory))
        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected unsupportedLiveStream")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .unsupportedLiveStream)
        }
    }

    func testInspectAllowsEndedLiveReplay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = "{\"was_live\": true, \"live_status\": \"was_live\", \(vodFormats)}"
        let inspector = YouTubeMediaInspector(
            executableURL: try makeJSONExecutable(json: json, directory: directory))
        let inspection = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/live/liv3id99")!,
            requestContext: nil,
            mediaKind: .http
        )
        XCTAssertEqual(inspection.variants.count, 1)
    }

    func testInspectAllowsNormalVOD() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = "{\"live_status\": \"not_live\", \(vodFormats)}"
        let inspector = YouTubeMediaInspector(
            executableURL: try makeJSONExecutable(json: json, directory: directory))
        let inspection = try await inspector.inspect(
            url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
            requestContext: nil,
            mediaKind: .http
        )
        XCTAssertEqual(inspection.variants.count, 1)
    }

    func testInspectFailsClosedWhenLegacyOutputLacksLiveFields() async throws {
        // 第二轮 §P1-2：直播字段缺失不得再按 VOD 放行；检查层抛出可重试的
        // liveStatusUnknown（映射 MEDIA_LIVE_STATUS_UNKNOWN）。
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = "{\(vodFormats)}"
        let inspector = YouTubeMediaInspector(
            executableURL: try makeJSONExecutable(json: json, directory: directory))
        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=fixture")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected liveStatusUnknown")
        } catch let error as MediaInspectionError {
            XCTAssertEqual(error, .liveStatusUnknown)
            XCTAssertEqual(error.diagnosticCode, "MEDIA_LIVE_STATUS_UNKNOWN")
        }
    }

    /// 检查层与执行层共用的表驱动直播状态样例（第二轮 §P1-2）：结论必须与
    /// YouTubeDownloadRunnerTests 中同一组样例完全一致。
    func testLiveClassifierSharedFixtures() throws {
        for fixture in YouTubeLivePhaseFixtures.cases {
            let phase = try XCTUnwrap(
                YouTubeLivePhaseFixtures.phase(forJSON: fixture.json),
                "\(fixture.name): JSON should decode")
            XCTAssertEqual(phase, fixture.expected, "\(fixture.name)")
        }
        XCTAssertFalse(YouTubeLiveClassifier.isAllowed(.unknown))
        XCTAssertFalse(YouTubeLiveClassifier.isAllowed(.currentlyLive))
        XCTAssertTrue(YouTubeLiveClassifier.isAllowed(.vod))
        XCTAssertTrue(YouTubeLiveClassifier.isAllowed(.endedReplay))
    }

    func testLiveClassifierRulesAreConsistentAcrossLayers() {
        // 检查层与执行层共用同一判定（第二轮 §P1-2 后的语义）：字段缺失/未知枚举归为 unknown。
        func phase(_ json: String) throws -> YouTubeLivePhase {
            let probe = try JSONDecoder().decode(
                YouTubeLiveStateProbe.self, from: Data(json.utf8))
            return YouTubeLiveClassifier.phase(probe.state)
        }
        XCTAssertEqual(try phase(#"{"is_live": true}"#), .currentlyLive)
        XCTAssertEqual(try phase(#"{"live_status": "is_live"}"#), .currentlyLive)
        XCTAssertEqual(try phase(#"{"live_status": "is_upcoming"}"#), .upcoming)
        XCTAssertEqual(try phase(#"{"live_status": "post_live"}"#), .replayNotReady)
        XCTAssertEqual(try phase(#"{"was_live": true}"#), .endedReplay)
        XCTAssertEqual(try phase(#"{"live_status": "was_live"}"#), .endedReplay)
        XCTAssertEqual(try phase(#"{"live_status": "not_live"}"#), .vod)
        // 字段缺失与未知枚举：不得放行。
        XCTAssertEqual(try phase(#"{}"#), .unknown)
        XCTAssertEqual(try phase(#"{"live_status": "some_future_state"}"#), .unknown)
        XCTAssertTrue(YouTubeLiveClassifier.isBlocked(.currentlyLive))
        XCTAssertTrue(YouTubeLiveClassifier.isBlocked(.upcoming))
        XCTAssertTrue(YouTubeLiveClassifier.isBlocked(.replayNotReady))
        XCTAssertFalse(YouTubeLiveClassifier.isBlocked(.endedReplay))
        XCTAssertFalse(YouTubeLiveClassifier.isBlocked(.vod))
        XCTAssertFalse(YouTubeLiveClassifier.isBlocked(.unknown))
    }

    // MARK: - inspect 双日志（technical-spec §3.1.7）

    func testInspectFailureWritesDualLogsWithSharedEventID() async throws {
        // 常规日志只有安全摘要；私密日志按同一 event id 保留完整 URL 与
        // 原始 stderr；原始 stderr 不得跨过 Bridge（错误仍是分类后的枚举）。
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stderr = "ERROR: [youtube] abc123: 绝密标题 https://cdn.example.com/x.mp4?signature=SECRETSIG"
        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let regularLines = InspectorRegularSinkCapture()
        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: true
        )
        let (inspector, failingDir) = try makeFailingExecutable(
            stderr: stderr, diagnosticLog: log)
        defer { try? FileManager.default.removeItem(at: failingDir) }

        do {
            _ = try await inspector.inspect(
                url: URL(string: "https://www.youtube.com/watch?v=abc123#height=720")!,
                requestContext: nil,
                mediaKind: .http
            )
            XCTFail("expected inspection to fail")
        } catch let error as MediaInspectionError {
            // 跨过 Bridge 的只有分类后的错误，不含原始输出。
            XCTAssertFalse(error.localizedDescription.contains("SECRETSIG"))
        }

        let regular = try XCTUnwrap(regularLines.values.last)
        XCTAssertTrue(regular.contains("event=media.inspectFailed"))
        XCTAssertTrue(regular.contains("stage=inspect"))
        XCTAssertTrue(regular.contains("exit=1"))
        XCTAssertTrue(regular.contains("cookieSupplied=false"))
        XCTAssertNotNil(regular.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression))
        // 常规行不含完整 URL 与签名 query 原值（摘要按既有清洗框架保留
        // 错误行正文，完整原始输出只在私密日志）。
        XCTAssertFalse(regular.contains("watch?v=abc123"))
        XCTAssertFalse(regular.contains("SECRETSIG"))
        let eventID = try XCTUnwrap(
            regular.range(of: #"eventId=[0-9A-Fa-f-]+"#, options: .regularExpression)
                .map { String(regular[$0].dropFirst("eventId=".count)) })

        // 私密记录：同一 event id 下保留完整 URL 与原始输出。
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("eventId=\(eventID)"))
        XCTAssertTrue(privateText.contains("url: https://www.youtube.com/watch?v=abc123#height=720"))
        XCTAssertTrue(privateText.contains("SECRETSIG"))
        XCTAssertTrue(privateText.contains("绝密标题"))
    }

    func testGenericInspectFailureWritesDiagnosticAndReturnsNil() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-yt-dlp")
        let script = "#!/bin/sh\necho 'ERROR: unsupported url' >&2\nexit 1\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let privateURL = directory.appendingPathComponent("macidm-private.log")
        let regularLines = InspectorRegularSinkCapture()
        let log = YouTubeDiagnosticEventLog(
            privateLogURL: privateURL,
            regularSink: { regularLines.append($0) },
            enabled: true
        )
        let inspector = YouTubeMediaInspector(executableURL: executable, diagnosticLog: log)
        let result = try await inspector.inspectGeneric(
            url: URL(string: "https://vimeo.example.com/12345")!,
            requestContext: nil
        )
        XCTAssertNil(result)

        let regular = try XCTUnwrap(regularLines.values.last)
        XCTAssertTrue(regular.contains("event=media.genericInspectFailed"))
        XCTAssertTrue(regular.contains("exit=1"))
        let privateText = try String(contentsOf: privateURL, encoding: .utf8)
        XCTAssertTrue(privateText.contains("url: https://vimeo.example.com/12345"))
        XCTAssertTrue(privateText.contains("unsupported url"))
    }

    /// `-J` 的完整 JSON 可达数 MB，远超管道缓冲；只在进程退出后读管道会让
    /// 子进程在写阻塞中假死直到超时（真实环境验收发现）。输出必须被增量
    /// 排空，大 stdout 既不死锁也不丢失。
    func testInspectProcessStreamsLargeStdoutWithoutPipeDeadlock() async throws {
        let executable = URL(fileURLWithPath: "/bin/sh")
        // ~200 KB stdout：远超 64 KB 管道缓冲。
        let script =
            "for i in $(seq 1 3000); do echo '0123456789abcdef0123456789abcdef0123456789abcdef'; done"
        let operation = try YouTubeInspectProcess(
            executableURL: executable,
            arguments: ["-c", script]
        )
        let start = Date()
        let (status, output, _) = try await operation.run(timeout: 20)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.count, 3_000 * 49, "大输出不得丢失")
        XCTAssertLessThan(elapsed, 10, "大输出不得在管道上死锁到超时")
    }

    func testCleanupFailedBlocksInspectionOutput() async throws {
        // §4：注入 cleanupFailed 后 run() 必须抛明确错误，任何调用点都不得解码/
        // 返回本次 stdout。脚本输出合法 JSON 且 exit 0，正说明阻断与退出码无关。
        let executable = URL(fileURLWithPath: "/bin/sh")
        let operation = try YouTubeInspectProcess(
            executableURL: executable,
            arguments: ["-c", "echo '{\"formats\":[]}'"],
            terminationGrace: 0.2,
            settleBudget: 0.4,
            groupLivenessProbe: { _ in .live }
        )
        do {
            let result = try await operation.run(timeout: 10)
            XCTFail("cleanupFailed 必须阻断本次输出，却得到 \(result)")
        } catch MediaInspectionError.processCleanupFailed {
            // 预期：错误文案不携带原始输出，调用点不解码 stdout。
        }
    }

    func testCancelBeforeLaunchSpawnsNothingAndCompletesOnce() async throws {
        // §4 竞态：取消发生在「读取未取消 → 真正启动」之间时，旧实现会一边结束
        // continuation 一边继续 spawn，留下无人管理的进程。用可注入的启动屏障把
        // 竞态变成确定性：屏障卡住启动、触发取消、再放行。多轮重复，不得依赖概率。
        for _ in 0..<5 {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacIDMInspectorRaceTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let marker = directory.appendingPathComponent("started")
            let executable = directory.appendingPathComponent("slow-fake-yt-dlp")
            let script =
                [
                    "#!/bin/bash",
                    "echo 1 > \"\(marker.path)\"",
                    "sleep 300",
                ].joined(separator: "\n") + "\n"
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let barrier = DispatchSemaphore(value: 0)
            let process = try YouTubeInspectProcess(
                executableURL: executable,
                arguments: [],
                launchBarrier: { barrier.wait() }
            )
            let task = Task {
                try await process.run(timeout: 60)
            }
            // 让 run() 进入 launching 并停在屏障上。
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            barrier.signal()

            do {
                _ = try await task.value
                XCTFail("expected cancellation to end the inspect call")
            } catch is CancellationError {
                // 预期路径。
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                "取消先于启动到达时不得真正 spawn 子进程")
        }
    }
}

private final class InspectorRegularSinkCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}
