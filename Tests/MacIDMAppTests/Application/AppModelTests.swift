import IDMEngine
import MacIDMBridge
import XCTest

@testable import MacIDMApp

@MainActor
final class AppModelTests: XCTestCase {
    func testSuggestedFilenameKeepsNonMediaExtensionsFromServerNames() throws {
        // GitHub 重定向后的 CDN 地址没有扩展名：文件名完全来自
        // Content-Disposition，扩展名（AppImage/apk）必须原样保留，
        // 不能被 mp4 兜底覆盖。
        let extensionlessCDN = URL(string: "https://objects.example.com/repositories/9f3a/uuid")!
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: extensionlessCDN,
                sourceKind: .http,
                filenameHint: "Obsidian-1.14.16.AppImage",
                pageTitle: nil,
                resourceInfo: nil
            ),
            "Obsidian-1.14.16.AppImage"
        )
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: extensionlessCDN,
                sourceKind: .http,
                filenameHint: "app-release.apk",
                pageTitle: nil,
                resourceInfo: nil
            ),
            "app-release.apk"
        )
        // 页面标题带版本号尾巴："16" 不是扩展名，应回落到 URL 扩展名。
        let assetURL = URL(string: "https://github.com/org/repo/releases/download/v1.14.16/Obsidian-1.14.16.AppImage")!
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: assetURL,
                sourceKind: .http,
                filenameHint: nil,
                pageTitle: "Obsidian 1.14.16",
                resourceInfo: nil
            ),
            "Obsidian 1.14.appimage"
        )
        // 域名后缀（.io）不是扩展名，同样剥离后回落 URL 扩展名。
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: URL(string: "https://cdn.example.com/files/report.pdf")!,
                sourceKind: .http,
                filenameHint: nil,
                pageTitle: "obsidian.io",
                resourceInfo: nil
            ),
            "obsidian.pdf"
        )
    }

    func testSuggestedFilenameTrustOrderKeepsURLTailHintBelowPageTitle() throws {
        // hanime1 回归（技术规范 §8.1 命名可信度模型）：嗅探候选的 URL 尾段
        // hint（如 "407788-1080p.mp4"）不得压过用户在嗅探面板认出的标题。
        let streamURL = URL(string: "https://vdownload.example.com/407788-1080p.mp4?secure=abc")!
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: streamURL,
                sourceKind: .http,
                filenameHint: "407788-1080p.mp4",
                pageTitle: "Chika Fujiwara - Kaguya-sama",
                resourceInfo: nil
            ),
            "Chika Fujiwara - Kaguya-sama.mp4"
        )
        // 没有标题时，URL 尾段 hint 仍然可用。
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: streamURL,
                sourceKind: .http,
                filenameHint: "407788-1080p.mp4",
                pageTitle: nil,
                resourceInfo: nil
            ),
            "407788-1080p.mp4"
        )
        // 权威来源（浏览器解析名）的 hint 仍然压过标签页标题。
        XCTAssertEqual(
            DownloadNaming.suggestedFilename(
                url: URL(string: "https://example.com/file.zip")!,
                sourceKind: .http,
                filenameHint: "release-1.2.3.zip",
                pageTitle: "Download Page - Example",
                resourceInfo: nil,
                hintSource: .browserResolved
            ),
            "release-1.2.3.zip"
        )
    }

    func testGenericFilenameListCoversPlaylistPlaceholderNames() throws {
        // 与扩展 JS 侧 smartMediaName 的泛化清单保持一致（双端锁定测试在
        // Tests/BrowserExtensionTests/Unit/filename-naming-trust.test.mjs）。
        for generic in [
            "download", "media.mp4", "video", "audio.m4a",
            "index.m3u8", "master.m3u8", "playlist.m3u8", "manifest.mpd",
        ] {
            XCTAssertTrue(DownloadNaming.isGenericFilename(generic), "\(generic) 应判为泛化占位名")
        }
        XCTAssertFalse(DownloadNaming.isGenericFilename("407788-1080p.mp4"))
        XCTAssertFalse(DownloadNaming.isGenericFilename("release-1.2.3.zip"))
    }

    func testSemanticPageTitleStripsOnlyHostMatchingBrandSuffix() throws {
        // 品牌尾巴与页面 host 匹配才剥离；真实标题中的分隔符不受影响。
        XCTAssertEqual(
            DownloadNaming.semanticPageTitle(
                "[Dorozz] Chika Fujiwara - Kaguya-sama - H動漫/裏番/線上看 - Hanime1.me",
                hosts: ["hanime1.me", nil]
            ),
            "[Dorozz] Chika Fujiwara - Kaguya-sama - H動漫/裏番/線上看"
        )
        // host 首标签也参与匹配（去 www、去 TLD 后的 "Hanime1"）。
        XCTAssertEqual(
            DownloadNaming.semanticPageTitle("某视频 - Hanime1", hosts: [nil, "www.hanime1.me"]),
            "某视频"
        )
        XCTAssertEqual(
            DownloadNaming.semanticPageTitle("Love is War - Episode 3", hosts: ["example.com"]),
            "Love is War - Episode 3"
        )
        // Bilibili's og:title uses "标题_bilibili"; underscore must be a
        // recognized separator so the App-side mirror of stripBrandSuffix
        // stays aligned with the extension (technical spec §8.1).
        XCTAssertEqual(
            DownloadNaming.semanticPageTitle("某视频_bilibili", hosts: ["www.bilibili.com"]),
            "某视频"
        )
        // A real underscore inside the title (no host-matching tail) survives.
        XCTAssertEqual(
            DownloadNaming.semanticPageTitle("Episode_1", hosts: ["example.com"]),
            "Episode_1"
        )
        XCTAssertNil(DownloadNaming.semanticPageTitle("   ", hosts: ["example.com"]))
    }

    func testFilenameRecoveredFromContentDispositionQueryParameter() throws {
        // 签名 blob URL：路径末尾是 UUID，真名藏在
        // response-content-disposition 查询参数里。
        let signed = URL(
            string:
                "https://release-assets.example.com/n-release-asset/678716433/a97e5f5b-31b9-4a46-88f2-9a257283edd0"
                + "?sp=r&sv=2018-11-09&response-content-disposition=attachment%3B%20filename%3Dtool-1.2.3.apk"
        )!
        XCTAssertEqual(
            DownloadNaming.filenameFromContentDispositionQuery(of: signed),
            "tool-1.2.3.apk"
        )
        // RFC 6266 filename* 编码形式优先，且支持中文。
        let starred = URL(
            string: "https://cdn.example.com/blob/uuid?response-content-disposition="
                + "attachment%3B%20filename*%3DUTF-8''%E5%AE%89%E8%A3%85%E5%8C%85.dmg"
        )!
        XCTAssertEqual(
            DownloadNaming.filenameFromContentDispositionQuery(of: starred),
            "安装包.dmg"
        )
        // 无该参数时返回 nil，由上层继续兜底。
        XCTAssertNil(
            DownloadNaming.filenameFromContentDispositionQuery(
                of: URL(string: "https://cdn.example.com/blob/uuid?token=abc")!
            )
        )
    }

    func testFileExtensionForMIMETypeCompletesExtensionlessNames() {
        XCTAssertEqual(DownloadNaming.fileExtensionForMIMEType("application/zip"), "zip")
        XCTAssertEqual(DownloadNaming.fileExtensionForMIMEType("application/zip; charset=binary"), "zip")
        XCTAssertEqual(DownloadNaming.fileExtensionForMIMEType("image/svg+xml"), "svg")
        XCTAssertEqual(DownloadNaming.fileExtensionForMIMEType("video/x-matroska"), "mkv")
        XCTAssertEqual(DownloadNaming.fileExtensionForMIMEType("audio/mpeg"), "mp3")
        // 无语义的类型不补扩展名，避免把未知二进制伪装成某种文件。
        XCTAssertNil(DownloadNaming.fileExtensionForMIMEType("application/octet-stream"))
        XCTAssertNil(DownloadNaming.fileExtensionForMIMEType(nil))
        XCTAssertNil(DownloadNaming.fileExtensionForMIMEType(""))
    }

    func testIsRealFileExtensionRejectsDomainsAndVersionTails() {
        XCTAssertTrue(DownloadNaming.isRealFileExtension("mp4"))
        XCTAssertTrue(DownloadNaming.isRealFileExtension("appimage"))
        XCTAssertTrue(DownloadNaming.isRealFileExtension("apk"))
        XCTAssertFalse(DownloadNaming.isRealFileExtension("io"))
        XCTAssertFalse(DownloadNaming.isRealFileExtension("tv"))
        XCTAssertFalse(DownloadNaming.isRealFileExtension("16"))
        XCTAssertFalse(DownloadNaming.isRealFileExtension("a"))
        XCTAssertFalse(DownloadNaming.isRealFileExtension(""))
    }

    func testDuplicateDestinationIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let destination = directory.appendingPathComponent("file.zip")

        try model.addDownload(
            urlString: "https://example.com/file.zip",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )

        XCTAssertThrowsError(
            try model.addDownload(
                urlString: "https://example.com/other.zip",
                destination: destination,
                maximumParallelRequests: 8,
                expectedSHA256: nil,
                startImmediately: false
            )
        )
        XCTAssertEqual(model.tasks.count, 1)
    }

    func testAutomaticFilenameCollisionUsesNextAvailableSequence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMAutomaticRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let preferred = directory.appendingPathComponent("课程标题.mp4")
        try model.addDownload(
            urlString: "https://example.com/one.mp4",
            destination: preferred,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        try Data("existing".utf8).write(
            to: directory.appendingPathComponent("课程标题 (1).mp4")
        )

        try model.addDownload(
            urlString: "https://example.com/two.mp4",
            destination: preferred,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            automaticRename: true
        )

        XCTAssertEqual(model.tasks.map(\.filename), ["课程标题 (2).mp4", "课程标题.mp4"])
    }

    func testRuntimeFilenameConflictAutoRenamesAndRequeuesTheTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMConflictRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: ImmediateDownloadRunner()
        )
        let destination = directory.appendingPathComponent("file.zip")
        try model.addDownload(
            urlString: "https://example.com/file.zip",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)

        // A file appears at the destination after submission; the engine
        // reports filenameConflict. The model must suffix and re-queue the
        // task instead of parking it in the manual conflict state.
        try Data("existing".utf8).write(to: destination)
        model.finish(task.id, error: IDMError.filenameConflict(destination.path))

        let updated = try XCTUnwrap(model.tasks.first)
        // Re-queueing restarts the task immediately, so it may already have
        // advanced past .queued; it must never stay in the conflict state.
        XCTAssertTrue(
            [.queued, .probing, .running, .verifying, .completed].contains(updated.status),
            "expected the conflicted task to be re-queued, got \(updated.status)"
        )
        XCTAssertEqual(
            URL(fileURLWithPath: updated.destinationPath).lastPathComponent,
            "file (1).zip"
        )
        // The conflicting file must never be overwritten.
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }

    func testPausedSignedURLTaskStaysResumableAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRestartResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeDirectory = directory.appendingPathComponent("state")
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: storeDirectory,
            settings: AppSettings(defaults: defaults)
        )
        let signedURL = "https://cdn.example.com/file.bin?sig=abc123"
        try model.addDownload(
            urlString: signedURL,
            destination: directory.appendingPathComponent("file.bin"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)
        try model.persist()

        // "Restart": a fresh model over the same store must keep the paused
        // task resumable. The persisted task row only keeps the redacted URL,
        // so without the source-URL vault the load path would force the task
        // into failed/NEEDS_REFETCH and the user could never resume it.
        let restartedDefaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let restarted = AppModel(
            storeDirectory: storeDirectory,
            settings: AppSettings(defaults: restartedDefaults)
        )
        let reloaded = try XCTUnwrap(restarted.tasks.first { $0.id == task.id })

        XCTAssertEqual(reloaded.status, .paused)
        XCTAssertNil(reloaded.errorCode)
        XCTAssertEqual(
            restarted.transientSourceURLs[task.id]?.absoluteString,
            signedURL
        )
    }

    func testFailedTaskRestoresVaultURLAcrossRestartForRetry() throws {
        // 失败任务重启后的重试必须复用 Vault 里的原始链接：持久化行只保留
        // 脱敏 URL（YouTube watch 链接会丢失 v= 参数），不恢复时重试会去执行
        // 首页链接，yt-dlp 报告「未生成媒体文件」（真实环境验收发现）。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMFailedVaultTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeDirectory = directory.appendingPathComponent("state")
        let defaults = try XCTUnwrap(makeIsolatedDefaults())
        let model = AppModel(
            storeDirectory: storeDirectory,
            settings: AppSettings(defaults: defaults)
        )
        let watchURL = "https://www.youtube.com/watch?v=abc123#height=360&itag=134"
        try model.addDownload(
            urlString: watchURL,
            destination: directory.appendingPathComponent("video.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            backend: .youtubeExtractor
        )
        let task = try XCTUnwrap(model.tasks.first)
        model.update(task.id) {
            $0.status = .failed
            $0.errorCode = "YTDLP_NO_MEDIA"
            $0.errorMessage = "fixture failure"
        }
        try model.persist()

        let restartedDefaults = try XCTUnwrap(makeIsolatedDefaults())
        let restarted = AppModel(
            storeDirectory: storeDirectory,
            settings: AppSettings(defaults: restartedDefaults)
        )
        let reloaded = try XCTUnwrap(restarted.tasks.first { $0.id == task.id })

        XCTAssertEqual(reloaded.status, .failed)
        XCTAssertEqual(reloaded.errorCode, "YTDLP_NO_MEDIA")
        XCTAssertEqual(
            restarted.transientSourceURLs[task.id]?.absoluteString,
            watchURL,
            "失败任务重启后重试必须拿到未脱敏的原始链接"
        )
    }

    func testFailedTaskKeepsUnredactedURLForSameSessionRetry() throws {
        // 同会话内的重试同样需要未脱敏链接：失败清理不能把内存中的原始
        // URL 一并丢弃，否则当次会话的重试仍会执行脱敏后的 URL。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSessionRetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(makeIsolatedDefaults())
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let watchURL = "https://www.youtube.com/watch?v=abc123#height=360&itag=134"
        try model.addDownload(
            urlString: watchURL,
            destination: directory.appendingPathComponent("video.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            backend: .youtubeExtractor
        )
        let task = try XCTUnwrap(model.tasks.first)

        model.finish(task.id, error: YouTubeDownloadError.mediaNotProduced)

        XCTAssertEqual(model.tasks.first?.status, .failed)
        XCTAssertEqual(
            model.transientSourceURLs[task.id]?.absoluteString,
            watchURL,
            "失败清理后同会话重试仍须保留未脱敏链接"
        )
    }

    func testCategorySubdirectoryIsUsedForNewDownloadsWhenEnabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCategoryDirectoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "organizeByCategory")
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )

        try model.addDownload(
            urlString: "https://example.com/lesson.mp4",
            destination: directory.appendingPathComponent("lesson.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            priority: 8
        )

        let task = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(task.destinationPath, directory.appendingPathComponent("video/lesson.mp4").path)
        XCTAssertEqual(task.category, .video)
        XCTAssertEqual(task.priority, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("video").path))
    }

    /// Extension-less CDN URLs (the common browser-takeover shape) must land
    /// in the MIME-derived category — both for the save path and the task —
    /// matching what the new-download window previewed.
    func testMimeTypeFallbackCategorizesExtensionlessDownload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMMimeCategoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "organizeByCategory")
        let stateDirectory = directory.appendingPathComponent("state")
        let model = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults)
        )

        try model.addDownload(
            urlString: "https://cdn.example.com/videoplayback",
            destination: directory.appendingPathComponent("videoplayback"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            mimeType: "video/mp4"
        )

        let task = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(task.destinationPath, directory.appendingPathComponent("video/videoplayback").path)
        XCTAssertEqual(task.category, .video)
        XCTAssertEqual(task.detectedCategory, .video)

        // The MIME survives a restart so the detail panel keeps the same
        // "自动" preview as the submission window showed.
        let restarted = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults)
        )
        let reloaded = try XCTUnwrap(restarted.tasks.first)
        XCTAssertEqual(reloaded.mimeType, "video/mp4")
        XCTAssertEqual(reloaded.category, .video)
    }

    func testManualDashPairPersistsSourceKindForTheEngineRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMManualDASHTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false
        )

        try model.addDownload(
            urlString: "https://video.example.test/100116.m4s",
            destination: directory.appendingPathComponent("manual.mp4"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: false,
            sourceKind: .dash,
            pairAudioURL: URL(string: "https://audio.example.test/30280.m4s"),
            pairCID: "fixture-cid"
        )

        let task = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(task.sourceKind, .dash)
        let persisted = try AppTaskStore(directory: directory.appendingPathComponent("state")).load()
        XCTAssertEqual(persisted.first?.sourceKind, .dash)
    }

    func testTransientDashPairDoesNotRetryWithoutAudioContextAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMDASHRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let stateDirectory = directory.appendingPathComponent("state")
        let model = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false
        )
        try model.addDownload(
            urlString: "https://video.example.test/100116.m4s?token=secret",
            destination: directory.appendingPathComponent("recovered.mp4"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: false,
            sourceKind: .dash,
            pairAudioURL: URL(string: "https://audio.example.test/30280.m4s?token=secret"),
            pairCID: "fixture-cid"
        )

        let restarted = AppModel(
            storeDirectory: stateDirectory,
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false
        )
        let task = try XCTUnwrap(restarted.tasks.first)
        XCTAssertEqual(task.status, .failed)
        XCTAssertEqual(task.errorCode, "NEEDS_REFETCH")
    }

    func testBilibiliPairSubmissionArchivesPageOriginCookieAndIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMBilibiliArchiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let sessionStore = SessionStore(
            directory: directory.appendingPathComponent("sessions"),
            secrets: FakeSessionSecretStore()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false,
            sessionStore: sessionStore
        )
        let pageURL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!
        try model.addDownload(
            urlString: "https://upos.bilivideo.com/x/12345678-1-30080.m4s?deadline=9",
            destination: directory.appendingPathComponent("v.mp4"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: false,
            sourceKind: .dash,
            requestContext: DownloadRequestContext(
                cookie: "SESSDATA=archived",
                referer: pageURL.absoluteString,
                userAgent: "TestAgent/1.0"
            ),
            pairAudioURL: URL(string: "https://upos.bilivideo.com/x/12345678-1-30280.m4s?deadline=9"),
            pairCID: "12345678"
        )
        let task = try XCTUnwrap(model.tasks.first)
        // 页面 URL 取 referer（B 站页），而非签名 CDN 轨地址；身份与画质落盘。
        XCTAssertEqual(task.pageURL, pageURL.absoluteString)
        XCTAssertEqual(task.mediaCID, "12345678")
        XCTAssertEqual(task.selectedQuality, 30080)
        // 登录 Cookie 按页面 origin 归档，重启后可供重解析复用。
        let stored = try XCTUnwrap(sessionStore.lookup(url: pageURL))
        XCTAssertEqual(sessionStore.cookieHeader(for: stored), "SESSDATA=archived")
    }

    func testBilibiliPairStaysResumableAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMBilibiliResumeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        var task = AppTask(
            id: UUID(),
            sourceURL: "https://upos.bilivideo.com/x/12345678-1-30080.m4s",
            destinationPath: directory.appendingPathComponent("v.mp4").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .dash,
            browserClientID: "chrome:test",
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: "profile:dl-1",
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
            receivedBytes: 100,
            totalBytes: 1000,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        task.pageURL = "https://www.bilibili.com/video/BV1xx411c7mD"
        task.mediaCID = "12345678"
        task.selectedQuality = 30080
        try store.save([task])

        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false
        )
        let loaded = try XCTUnwrap(model.tasks.first)
        // 可重解析的 B 站配对不再被判死为 NEEDS_REFETCH，保持可续传。
        XCTAssertNotEqual(loaded.status, .failed)
        XCTAssertNil(loaded.errorCode)
        XCTAssertFalse(model.requiresBrowserRefetch(loaded))
    }

    func testRequiresBrowserRefetchAllowsReresolvableBilibiliPair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRefetchGuardTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults),
            useEnvironmentFFmpeg: false
        )
        var task = AppTask(
            id: UUID(),
            sourceURL: "https://upos.bilivideo.com/x/12345678-1-30080.m4s",
            destinationPath: directory.appendingPathComponent("v.mp4").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .dash,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .failed,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: "NEEDS_REFETCH",
            errorMessage: "带参数的下载地址未持久化",
            segments: []
        )
        task.pageURL = "https://www.bilibili.com/video/BV1xx411c7mD"
        // 可重解析：即便带着旧版本遗留的 NEEDS_REFETCH，也不再拦截 resume。
        XCTAssertFalse(model.requiresBrowserRefetch(task))
        // 对照：非 B 站页面的配对仍被拦截。
        task.pageURL = "https://example.com/watch"
        XCTAssertTrue(model.requiresBrowserRefetch(task))
    }

    func testReresolveSiteAdapterPairPicksPersistedTrackAndRestoresCookie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMReresolveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let sessionStore = SessionStore(
            directory: directory.appendingPathComponent("sessions"),
            secrets: FakeSessionSecretStore()
        )
        let pageURL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!
        sessionStore.store(url: pageURL, cookie: "SESSDATA=archived", userAgent: "TestAgent/1.0")
        let playurlJSON = """
            {"code":0,"data":{"dash":{"duration":100,"video":[\
            {"id":112,"baseUrl":"https://u.test/x/12345678-1-30112.m4s","bandwidth":4000000},\
            {"id":80,"baseUrl":"https://u.test/x/12345678-1-30080.m4s","bandwidth":2000000}],\
            "audio":[{"id":30280,"baseUrl":"https://u.test/x/12345678-1-30280.m4s","bandwidth":320000}]}}}
            """
        let playurl = Data(playurlJSON.utf8)
        let client = FakeBilibiliClient(responses: [
            "/x/web-interface/view": Data(#"{"code":0,"data":{"title":"T","cid":12345678,"aid":999}}"#.utf8),
            "/x/web-interface/nav": Data(#"{"code":-101,"data":{}}"#.utf8),
            "/x/player/wbi/playurl": playurl,
        ])
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            bilibiliAdapter: BilibiliPlayurlAdapter(client: client),
            useEnvironmentFFmpeg: false,
            sessionStore: sessionStore
        )
        let id = UUID()
        var record = AppTask(
            id: id,
            sourceURL: "https://upos.bilivideo.com/x/12345678-1-30080.m4s",
            destinationPath: directory.appendingPathComponent("v.mp4").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .dash,
            browserClientID: nil,
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
            receivedBytes: 100,
            totalBytes: 1000,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        record.pageURL = pageURL.absoluteString
        record.mediaCID = "12345678"
        record.selectedQuality = 30080
        // 主机变化防线：重解析主机（u.test）与原下载主机（upos.bilivideo.com）
        // 不同时，旧断点的资源定位符必不匹配，必须清理以免 needsRestart 循环。
        let pairDirectory = directory.appendingPathComponent(
            "." + id.uuidString + ".macidm.dash-pair", isDirectory: true)
        try FileManager.default.createDirectory(at: pairDirectory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: pairDirectory.appendingPathComponent("video.m4s"))

        let request = try await model.reresolveSiteAdapterPair(id: id, record: record)
        let resolved = try XCTUnwrap(request)
        // 选中持久化的那一档（30080），而不是重解析结果里的最高档（30112）。
        XCTAssertEqual(resolved.url.lastPathComponent, "12345678-1-30080.m4s")
        XCTAssertEqual(resolved.sourceKind, .dash)
        XCTAssertEqual(resolved.pairAudioURL?.lastPathComponent, "12345678-1-30280.m4s")
        // 临时配对地址与上下文回填，供本次执行与后续同会话续传复用。
        XCTAssertEqual(model.transientSourceURLs[id]?.lastPathComponent, "12345678-1-30080.m4s")
        XCTAssertEqual(model.transientPairAudioURLs[id]?.lastPathComponent, "12345678-1-30280.m4s")
        XCTAssertEqual(model.transientPairCIDs[id], "12345678")
        var mismatchedRecord = record
        mismatchedRecord.mediaCID = "999999"
        do {
            _ = try await SiteMediaResumeResolver(adapter: BilibiliPlayurlAdapter(client: client)).resolve(
                record: mismatchedRecord, pageURL: pageURL, context: nil)
            XCTFail("same quality does not permit a different content identity")
        } catch SiteMediaResumeError.selectedTrackUnavailable {}

        // 归档的页面 Cookie 被恢复进重解析上下文。
        XCTAssertEqual(model.transientRequestContexts[id]?.value.cookie, "SESSDATA=archived")
        // 主机不同：旧断点已清理，该轨干净重下但任务照常继续。
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pairDirectory.path),
            "resolver must not delete artifacts; executor owns checkpoint validation")
    }

    func testReresolveSiteAdapterPairKeepsSidecarWhenHostUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMReresolveSameHost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let playurlJSON = """
            {
              "code": 0,
              "data": {
                "dash": {
                  "duration": 100,
                  "video": [
                    {"id": 80, "baseUrl": "https://u.test/x/12345678-1-30080.m4s", "bandwidth": 2000000}
                  ],
                  "audio": [
                    {"id": 30280, "baseUrl": "https://u.test/x/12345678-1-30280.m4s", "bandwidth": 320000}
                  ]
                }
              }
            }
            """
        let client = FakeBilibiliClient(responses: [
            "/x/web-interface/view": Data(#"{"code":0,"data":{"title":"T","cid":12345678,"aid":999}}"#.utf8),
            "/x/web-interface/nav": Data(#"{"code":-101,"data":{}}"#.utf8),
            "/x/player/wbi/playurl": Data(playurlJSON.utf8),
        ])
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            bilibiliAdapter: BilibiliPlayurlAdapter(client: client),
            useEnvironmentFFmpeg: false
        )
        let id = UUID()
        var record = AppTask(
            id: id,
            sourceURL: "https://u.test/x/12345678-1-30080.m4s",
            destinationPath: directory.appendingPathComponent("v.mp4").path,
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            sourceKind: .dash,
            browserClientID: nil,
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
            receivedBytes: 100,
            totalBytes: 1000,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        record.pageURL = "https://www.bilibili.com/video/BV1xx411c7mD"
        record.mediaCID = "12345678"
        record.selectedQuality = 30080
        // 主机一致（upos 镜像稳定时成立）：保留 sidecar 以便字节级续传。
        let pairDirectory = directory.appendingPathComponent(
            "." + id.uuidString + ".macidm.dash-pair", isDirectory: true)
        try FileManager.default.createDirectory(at: pairDirectory, withIntermediateDirectories: true)

        _ = try await model.reresolveSiteAdapterPair(id: id, record: record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pairDirectory.path))
    }

    func testActiveTaskIsRecoveredAsPaused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: directory.appendingPathComponent("file.zip").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .running,
            receivedBytes: 100,
            totalBytes: 1_000,
            bytesPerSecond: 20,
            speedHistory: [SpeedSample(timestamp: Date(), bytesPerSecond: 20)],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        try store.save([task])
        let defaults = makeIsolatedDefaults()

        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )

        XCTAssertEqual(model.tasks.first?.status, .paused)
        XCTAssertEqual(model.tasks.first?.errorCode, "INTERRUPTED")
        XCTAssertEqual(model.tasks.first?.bytesPerSecond, 0)
    }

    func testBrowserTaskRequiresRefetchAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMBrowserRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/video.mp4",
            destinationPath: directory.appendingPathComponent("video.mp4").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            sourceKind: .http,
            browserClientID: "chrome:test",
            browserSubmissionType: "download.enqueue",
            browserSubmissionKey: "profile:download-1",
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        try store.save([task])

        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )

        XCTAssertEqual(model.tasks.first?.status, .failed)
        XCTAssertEqual(model.tasks.first?.errorCode, "NEEDS_REFETCH")
        model.resume(task.id)
        XCTAssertEqual(model.tasks.first?.status, .failed)
    }

    func testParameterizedTaskRequiresRefetchAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMParameterizedRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip?signature=private",
            destinationPath: directory.appendingPathComponent("file.zip").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        try store.save([task])

        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )

        XCTAssertEqual(model.tasks.first?.status, .failed)
        XCTAssertEqual(model.tasks.first?.errorCode, "NEEDS_REFETCH")
        XCTAssertFalse(model.tasks.first?.sourceURL.contains("private") == true)
    }

    func testQueuedTaskIsScheduledAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMQueuedRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("file.zip")
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: destination.path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: nil,
            errorMessage: nil,
            segments: []
        )
        try store.save([task])

        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults),
            downloadRunner: ImmediateDownloadRunner()
        )

        for _ in 0..<100 {
            if model.tasks.first?.status == .completed { break }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(model.tasks.first?.status, .completed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("fixture".utf8))
    }

    func testNeedsRestartCanBeCancelledWithoutAWorker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMCancelRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppTaskStore(directory: directory)
        let task = AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: directory.appendingPathComponent("file.zip").path,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .needsRestart,
            receivedBytes: 100,
            totalBytes: 1_000,
            bytesPerSecond: 0,
            speedHistory: [],
            sha256: nil,
            verification: nil,
            errorCode: "RESOURCE_CHANGED",
            errorMessage: "资源已变化",
            segments: []
        )
        try store.save([task])

        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory,
            settings: AppSettings(defaults: defaults)
        )

        model.cancel(task.id)

        XCTAssertEqual(model.tasks.first?.status, .cancelled)
    }

    func testRemovingSelectedCompletedTaskClearsSelectionSafely() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRemoveSelectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let destination = directory.appendingPathComponent("finished.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try model.addDownload(
            urlString: "https://example.com/finished.mp4",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let taskID = try XCTUnwrap(model.tasks.first?.id)

        model.remove(taskID)

        XCTAssertTrue(model.tasks.first?.isArchived == true)
        XCTAssertNil(model.selectedTaskID)
    }

    func testRemovingRunningTaskStopsItAndArchivesTheRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMRemoveActiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let destination = directory.appendingPathComponent("streaming.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try model.addDownload(
            urlString: "https://example.com/streaming.mp4",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let taskID = try XCTUnwrap(model.tasks.first?.id)
        model.update(taskID) {
            $0.status = .running
            $0.bytesPerSecond = 1024
        }

        // Deleting a live download must stop it first, then archive it.
        model.remove(taskID)

        XCTAssertEqual(model.tasks.first?.status, .cancelled)
        XCTAssertTrue(model.tasks.first?.isArchived == true)
        XCTAssertNil(model.executions[taskID].control)
        XCTAssertNil(model.executions[taskID].task)
    }

    func testHistoryFilterShowsEveryAddedTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHistoryFilterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try model.addDownload(
            urlString: "https://example.com/kept.mp4",
            destination: directory.appendingPathComponent("kept.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        try model.addDownload(
            urlString: "https://example.com/deleted.mp4",
            destination: directory.appendingPathComponent("deleted.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let archivedID = try XCTUnwrap(model.tasks.first?.id)
        model.remove(archivedID)

        // History records every added download: live and archived rows alike.
        model.sidebarFilter = .history
        XCTAssertEqual(model.filteredTasks.count, 2)
        model.sidebarFilter = .all
        XCTAssertEqual(model.filteredTasks.count, 1)
    }

    func testSearchMatchesJobIDCaseInsensitively() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMJobIDSearchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try model.addDownload(
            urlString: "https://example.com/video.mp4",
            destination: directory.appendingPathComponent("video.mp4"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)

        // The Job ID is searchable regardless of filename redaction.
        model.searchText = task.jobID
        XCTAssertEqual(model.filteredTasks.count, 1)
        model.settings.redactFilenames = true
        XCTAssertEqual(model.filteredTasks.count, 1)
        model.settings.redactFilenames = false

        // Lowercase input matches the uppercase base32 Job ID.
        model.searchText = task.jobID.lowercased()
        XCTAssertEqual(model.filteredTasks.count, 1)

        model.searchText = "no-such-task"
        XCTAssertEqual(model.filteredTasks.count, 0)
    }

    func testInteractiveBrowserMediaOpensAnEditableDraftWithoutCreatingTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInteractiveDraftTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let captured = DraftBox()
        // Interactive drafts now open in standalone confirmation windows;
        // the presenter seam captures the draft without creating a window.
        model.newDownloadPresenter = { captured.value = $0 }

        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:interactive-1",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/video.mp4?token=temporary"),
                "filenameHint": .string("课程标题.mp4"),
                "mediaKind": .string("http"),
                "interactive": .bool(true),
                "pageTitle": .string("课程标题"),
            ]
        )
        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.type, "media.downloadRequested")
        XCTAssertEqual(captured.value?.url.absoluteString, "https://example.com/video.mp4?token=temporary")
        XCTAssertEqual(captured.value?.filenameHint, "课程标题.mp4")
        XCTAssertEqual(captured.value?.pageTitle, "课程标题")
        // 未标注来源的旧版扩展 payload 保守降级为 urlPath。
        XCTAssertEqual(captured.value?.filenameHintSource, .urlPath)
        XCTAssertTrue(model.tasks.isEmpty)

        let duplicateResponse = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(duplicateResponse.type, "media.downloadRequested")
        XCTAssertEqual(captured.value?.filenameHint, "课程标题.mp4")
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testInteractiveDraftTreatsBrowserZeroTotalBytesAsUnknownSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInteractiveDraftSizeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let captured = DraftBox()
        model.newDownloadPresenter = { captured.value = $0 }

        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:interactive-zero-size",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/archive.zip"),
                "filenameHint": .string("archive.zip"),
                "mediaKind": .string("http"),
                "interactive": .bool(true),
                // Chrome reports 0 while the size is still unknown; the draft
                // must degrade to "大小未知" instead of a confident "0 KB".
                "totalBytes": .number(0),
            ]
        )
        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.type, "media.downloadRequested")
        XCTAssertNil(captured.value?.estimatedSize)
        XCTAssertEqual(captured.value?.sizeProbed, false)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testInteractiveDraftRecordsHintSourceAndStripsSiteBrandFromTitle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMInteractiveHintSourceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        let captured = DraftBox()
        model.newDownloadPresenter = { captured.value = $0 }

        // hanime1 场景：URL 尾段 hint + 带站点品牌尾巴的标题，referer 提供
        // 页面 host 供品牌剥离交叉验证。
        let request = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:interactive-hint-source",
            type: "download.enqueue",
            payload: [
                "url": .string("https://vdownload.example.com/407788-1080p.mp4?secure=abc"),
                "filenameHint": .string("407788-1080p.mp4"),
                "filenameHintSource": .string("urlPath"),
                "mediaKind": .string("http"),
                "interactive": .bool(true),
                "pageTitle": .string("Chika Fujiwara - Kaguya-sama - Hanime1.me"),
                "requestContext": .object([
                    "referer": .string("https://hanime1.me/watch?v=407788")
                ]),
            ]
        )
        let response = await model.handleBrowserBridgeRequest(
            request,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )

        XCTAssertEqual(response.type, "media.downloadRequested")
        XCTAssertEqual(captured.value?.filenameHintSource, .urlPath)
        XCTAssertEqual(captured.value?.pageTitle, "Chika Fujiwara - Kaguya-sama")
        XCTAssertTrue(model.tasks.isEmpty)

        // 接管类 payload 的 browserResolved 来源必须原样进入草稿。
        let takeoverRequest = MessageRequest(
            requestId: UUID().uuidString,
            idempotencyKey: "profile:interactive-hint-source-takeover",
            type: "download.enqueue",
            payload: [
                "url": .string("https://example.com/file.zip"),
                "filenameHint": .string("release-1.2.3.zip"),
                "filenameHintSource": .string("browserResolved"),
                "mediaKind": .string("http"),
                "interactive": .bool(true),
                "pageTitle": .string("Download Page"),
            ]
        )
        _ = await model.handleBrowserBridgeRequest(
            takeoverRequest,
            clientID: "chrome:test",
            secret: Data(repeating: 1, count: 32)
        )
        XCTAssertEqual(captured.value?.filenameHintSource, .browserResolved)
    }

    func testWebPageLinkResolvesDiscoveredMediaWithoutOpeningThePage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPageResolveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let mediaURL = URL(string: "https://cdn.example.com/lesson.mp4?sig=short-lived")!
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in throw IDMError.httpStatus(405) },
            pageMediaDiscoverer: FixturePageMediaDiscoverer(
                discovery: WebPageMediaDiscovery(
                    pageURL: URL(string: "https://example.com/watch")!,
                    title: "课程标题",
                    candidates: [
                        WebPageMediaCandidate(
                            url: mediaURL,
                            sourceKind: .http,
                            filenameHint: "lesson.mp4",
                            label: "lesson"
                        )
                    ]
                )
            )
        )

        let options = try await model.resolveDownloadOptions(
            urlString: "https://example.com/watch",
            pageTitle: "课程标题"
        )

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.url, mediaURL)
        XCTAssertEqual(options.first?.filename, "课程标题.mp4")
        XCTAssertEqual(options.first?.sourceKind, .http)
    }

    func testPageWithUnknownProbeMIMEUsesDiscoveredMediaAndPageTitle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMUnknownMIMEPageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = makeIsolatedDefaults()
        let pageURL = URL(string: "https://example.com/watch")!
        let mediaURL = URL(string: "https://cdn.example.com/media.mp4?sig=short-lived")!
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                ResourceInfo(
                    finalURL: pageURL,
                    size: nil,
                    supportsRange: false
                )
            },
            pageMediaDiscoverer: FixturePageMediaDiscoverer(
                discovery: WebPageMediaDiscovery(
                    pageURL: pageURL,
                    title: "课程标题",
                    candidates: [
                        WebPageMediaCandidate(
                            url: mediaURL,
                            sourceKind: .http,
                            filenameHint: "media.mp4",
                            label: "media"
                        )
                    ]
                )
            )
        )

        let options = try await model.resolveDownloadOptions(urlString: pageURL.absoluteString)

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.url, mediaURL)
        XCTAssertEqual(options.first?.filename, "课程标题.mp4")
    }

    func testYouTubeVideoplaybackURLWithMediaMIMESkipsPageProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYouTubeDirectMediaTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            browserProbe: { _ in
                XCTFail("a URL-declared media candidate must not be probed as a web page")
                throw IDMError.httpStatus(403)
            }
        )

        let options = try await model.resolveDownloadOptions(
            urlString: "https://rr1---sn.example.googlevideo.com/videoplayback?mime=video%2Fmp4",
            pageTitle: "YouTube 测试视频"
        )

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.sourceKind, .http)
        XCTAssertEqual(options.first?.filename, "YouTube 测试视频.mp4")
    }

    func testSuccessfulDownloadWithCookieArchivesSiteSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSessionCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let sessionStore = SessionStore(
            directory: directory.appendingPathComponent("sessions"),
            secrets: FakeSessionSecretStore()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: ImmediateDownloadRunner(),
            sessionStore: sessionStore
        )
        let destination = directory.appendingPathComponent("video.mp4")
        try model.addDownload(
            urlString: "https://www.example.com/watch?v=abc123",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            requestContext: DownloadRequestContext(
                cookie: "sid=authenticated-session",
                userAgent: "TestAgent/1.0"
            )
        )
        let task = try XCTUnwrap(model.tasks.first)

        // Successful completion of an authenticated download must archive
        // the session under the normalized host (the extension capture
        // path ends in the same finish(result:) call).
        model.finish(
            task.id,
            result: DownloadResult(
                destination: destination,
                byteCount: 7,
                sha256: "fixture",
                usedParallelRequests: 1,
                resumed: false,
                verification: "test"
            )
        )

        let stored = try XCTUnwrap(sessionStore.lookup(url: URL(string: "https://www.example.com/watch?v=abc123")!))
        XCTAssertEqual(
            sessionStore.cookieHeader(for: stored), "sid=authenticated-session")
        XCTAssertEqual(stored.userAgent, "TestAgent/1.0")
        XCTAssertNil(stored.lastAuthFailureAt)
        // Sessions are scoped to exact hosts by design, so www and apex do not share credentials.
        XCTAssertNil(
            sessionStore.lookup(url: URL(string: "https://example.com/")!),
            "the www capture must not serve the apex host")
        // A sibling subdomain must not inherit the credential: the archived value
        // is a raw Cookie header with no Domain/Path/Secure attributes, so a
        // host-only cookie would be disclosed to cdn.example.com.
        XCTAssertNil(sessionStore.lookup(url: URL(string: "https://cdn.example.com/")!))
        // The archive must be persisted to the store directory.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("sessions/sessions.json").path
            )
        )
    }

    func testCompletedDownloadWithoutCookieDoesNotArchiveSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMNoSessionCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let sessionStore = SessionStore(
            directory: directory.appendingPathComponent("sessions"),
            secrets: FakeSessionSecretStore()
        )
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: settings,
            downloadRunner: ImmediateDownloadRunner(),
            sessionStore: sessionStore
        )
        let destination = directory.appendingPathComponent("plain.zip")
        try model.addDownload(
            urlString: "https://example.com/plain.zip",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)

        model.finish(
            task.id,
            result: DownloadResult(
                destination: destination,
                byteCount: 7,
                sha256: "fixture",
                usedParallelRequests: 1,
                resumed: false,
                verification: "test"
            )
        )

        XCTAssertNil(sessionStore.lookup(url: URL(string: "https://example.com/")!))

        // With the setting disabled, even a cookie-bearing download must
        // not archive anything.
        settings.rememberSiteSessions = false
        let secondDestination = directory.appendingPathComponent("second.mp4")
        try model.addDownload(
            urlString: "https://example.com/second.mp4",
            destination: secondDestination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false,
            requestContext: DownloadRequestContext(cookie: "sid=disabled-setting")
        )
        let secondTask = try XCTUnwrap(model.tasks.first)
        model.finish(
            secondTask.id,
            result: DownloadResult(
                destination: secondDestination,
                byteCount: 7,
                sha256: "fixture",
                usedParallelRequests: 1,
                resumed: false,
                verification: "test"
            )
        )
        XCTAssertNil(sessionStore.lookup(url: URL(string: "https://example.com/")!))
    }

    func testRetryWithYtdlpSwitchesBackendAndRequeues() throws {
        // Re-queueing through the yt-dlp backend probes the real binary
        // resolution order, so this test needs an installed yt-dlp and skips
        // when one is absent; the youtube-ytdlp integration job covers the
        // toolchain itself.
        try XCTSkipIf(!YTDlpManager.isAvailable, "yt-dlp not installed")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMYtdlpFallbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults),
            downloadRunner: ImmediateDownloadRunner()
        )
        let destination = directory.appendingPathComponent("page-video.mp4")
        try model.addDownload(
            urlString: "https://example.com/watch/video123",
            destination: destination,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)
        XCTAssertNil(task.browserSubmissionType)

        // A native failure (e.g. the page has no direct media) is eligible
        // for the yt-dlp fallback: the backend marker flips and the task is
        // re-queued with a clean error state.
        model.finish(task.id, error: IDMError.httpStatus(404))
        XCTAssertEqual(model.tasks.first?.status, .failed)

        model.retryWithYtdlp(task.id)

        let retried = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(retried.browserSubmissionType, "youtube.extractor")
        XCTAssertNil(retried.errorMessage)
        XCTAssertNil(retried.errorCategory)
        // ImmediateDownloadRunner re-runs the requeued task to completion.
        XCTAssertTrue(
            [.queued, .probing, .running, .verifying, .completed].contains(retried.status),
            "expected the fallback task to be re-queued, got \(retried.status)"
        )

        // A task already on the yt-dlp backend must not flip again; a plain
        // resume is the only sensible action.
        model.finish(retried.id, error: IDMError.httpStatus(500))
        model.retryWithYtdlp(retried.id)
        XCTAssertEqual(model.tasks.first?.browserSubmissionType, "youtube.extractor")
    }

    func testUserPauseAndCancelDoNotSurfaceAsErrors() throws {
        // Pause and cancel are user control actions: the detail panel's
        // error area must stay empty for them instead of showing a
        // "PAUSED 任务已暂停" card.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMPauseErrorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            makeIsolatedDefaults()
        )
        let model = AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: defaults)
        )
        try model.addDownload(
            urlString: "https://example.com/file.zip",
            destination: directory.appendingPathComponent("file.zip"),
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            startImmediately: false
        )
        let task = try XCTUnwrap(model.tasks.first)

        model.finish(task.id, error: IDMError.paused)
        let paused = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertNil(paused.errorCode)
        XCTAssertNil(paused.errorMessage)

        model.finish(task.id, error: IDMError.cancelled)
        let cancelled = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.errorCode)
        XCTAssertNil(cancelled.errorMessage)
    }

    /// 产品契约（technical-spec §3.4）：YouTube 下载的源变体容器（如
    /// VP9 的 webm）不是最终输出容器；最终文件统一输出 MP4，标题自带的
    /// 容器后缀也被覆盖。普通直链保持自身扩展名不受影响。
    func testYouTubeOutputFilenameIsAlwaysMP4RegardlessOfSourceContainer() throws {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=fixture")!

        // 选了 VP9 变体（源容器 webm）时，最终文件名仍为 .mp4。
        XCTAssertEqual(
            DownloadNaming.filenameWithOutputExtension(
                "标题.webm",
                sourceKind: .http,
                url: watchURL,
                resourceInfo: nil,
                backend: .youtubeExtractor
            ),
            "标题.mp4"
        )
        // 标题无后缀时补齐 .mp4。
        XCTAssertEqual(
            DownloadNaming.filenameWithOutputExtension(
                "标题",
                sourceKind: .http,
                url: watchURL,
                resourceInfo: nil,
                backend: .youtubeExtractor
            ),
            "标题.mp4"
        )
        // 对照组：普通直链保留自身的 webm 扩展名（MP4 不等于 H.264，
        // 容器与编码是两回事）。
        XCTAssertEqual(
            DownloadNaming.filenameWithOutputExtension(
                "标题.webm",
                sourceKind: .http,
                url: URL(string: "https://cdn.example.com/video.webm")!,
                resourceInfo: nil,
                backend: .native
            ),
            "标题.webm"
        )
    }
}

private struct ImmediateDownloadRunner: AppDownloadRunning {
    func run(
        _ request: DownloadRequest,
        control: @escaping @Sendable () -> DownloadControl,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        try FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: request.destination, options: .atomic)
        progress(DownloadProgress(receivedBytes: 7, totalBytes: 7))
        return DownloadResult(
            destination: request.destination,
            byteCount: 7,
            sha256: "fixture",
            usedParallelRequests: 1,
            resumed: false,
            verification: "test"
        )
    }
}

private struct FixturePageMediaDiscoverer: WebPageMediaDiscovering {
    let discovery: WebPageMediaDiscovery

    func discover(
        url: URL,
        requestContext: DownloadRequestContext?
    ) async throws -> WebPageMediaDiscovery {
        discovery
    }
}

private final class DraftBox: @unchecked Sendable {
    var value: DownloadDraft?
}

/// Minimal Bilibili playurl client keyed by request path, so the resume
/// re-resolution test can drive `BilibiliPlayurlAdapter` without network.
private struct FakeBilibiliClient: HLSResourceClient {
    let responses: [String: Data]

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        guard let data = responses[request.url.path] else {
            return HLSFetchResponse(data: Data(), finalURL: request.url, statusCode: 404)
        }
        return HLSFetchResponse(data: data, finalURL: request.url, statusCode: 200)
    }
}

// 回归：带音轨提交的 sourceKind 改判。Bilibili m4s（requested .dash 或
// .http 推断）维持 DASH pair；X 的 HLS 独立音轨变体（requested .hls）必须
// 保持 .hls 走 HLS pair 执行器——误判 .dash 会把 m3u8 清单当直链分片下载，
// FFmpeg 报「Not detecting m3u8/hls with non standard extension」。
@MainActor
final class EffectiveSourceKindTests: XCTestCase {
    private func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSourceKindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults())
        )
    }

    func testHLSPairKeepsHLS() {
        let model = makeModel()
        let variant = URL(string: "https://video.twimg.com/amplify_video/1/pl/avc1/720x1280/x.m3u8")!
        let audio = URL(string: "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/y.m3u8")!
        XCTAssertEqual(
            model.effectiveSourceKind(for: variant, requested: .hls, pairAudioURL: audio),
            .hls
        )
    }

    func testNonHLSPairFallsBackToDASH() {
        let model = makeModel()
        let video = URL(string: "https://upos-sz-mirror08c.bilivideo.com/123/video.m4s")!
        let audio = URL(string: "https://upos-sz-mirror08c.bilivideo.com/123/audio.m4s")!
        XCTAssertEqual(
            model.effectiveSourceKind(for: video, requested: .dash, pairAudioURL: audio),
            .dash
        )
        XCTAssertEqual(
            model.effectiveSourceKind(for: video, requested: .http, pairAudioURL: audio),
            .dash
        )
    }

    func testHLSAddDownloadAcceptsPairAudioURL() throws {
        // addDownload 的第二道闸：.hls + pairAudioURL 必须被接受（此前
        // 只允许 .dash，确认窗提交会在任务创建前直接抛 invalidURL）。
        let model = makeModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMSourceKindAdd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try model.addDownload(
            urlString: "https://video.twimg.com/amplify_video/1/pl/avc1/720x1280/x.m3u8",
            destination: directory.appendingPathComponent("out.mp4"),
            maximumParallelRequests: 4,
            expectedSHA256: nil,
            startImmediately: false,
            sourceKind: .hls,
            pairAudioURL: URL(string: "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/y.m3u8")
        )
    }
}

// URL 判据兜底：扩展候选 format 被观察链兜底成 video 时 mediaKind 会是
// "video"→解析回落 http→改判 DASH→m3u8 文本当分片下载失败。任一侧 URL
// 是 .m3u8 媒体清单必须走 HLS pair，不依赖 mediaKind。
@MainActor
final class HLSPlaylistURLEnforcementTests: XCTestCase {
    private func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDMHLSURLTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppModel(
            storeDirectory: directory.appendingPathComponent("state"),
            settings: AppSettings(defaults: makeIsolatedDefaults())
        )
    }

    func testM3U8PairURLForcesHLSRegardlessOfMediaKind() {
        let model = makeModel()
        let variant = URL(string: "https://video.twimg.com/amplify_video/1/pl/avc1/720x1280/x.m3u8")!
        let audio = URL(string: "https://video.twimg.com/amplify_video/1/pl/mp4a/128000/y.m3u8")!
        for requested in [DownloadSourceKind.http, .dash, .hls] {
            XCTAssertEqual(
                model.effectiveSourceKind(for: variant, requested: requested, pairAudioURL: audio),
                .hls,
                "requested=\(requested) 时 .m3u8 pair 都应保持 .hls"
            )
        }
    }

    func testM4SPairURLStillUsesDASH() {
        let model = makeModel()
        let video = URL(string: "https://upos-sz-mirror08c.bilivideo.com/123/video.m4s")!
        let audio = URL(string: "https://upos-sz-mirror08c.bilivideo.com/123/audio.m4s")!
        XCTAssertEqual(
            model.effectiveSourceKind(for: video, requested: .http, pairAudioURL: audio),
            .dash
        )
    }
}
