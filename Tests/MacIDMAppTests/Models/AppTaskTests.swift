import XCTest

@testable import MacIDMApp

final class AppTaskTests: XCTestCase {
    func testCategoryUsesFilenameExtension() {
        XCTAssertEqual(DownloadCategory(filename: "archive.ZIP"), .archive)
        XCTAssertEqual(DownloadCategory(filename: "paper.pdf"), .document)
        XCTAssertEqual(DownloadCategory(filename: "movie.mp4"), .video)
        XCTAssertEqual(DownloadCategory(filename: "without-extension"), .other)
    }

    /// The extension table must stay aligned with the browser extension's
    /// takeover list (DEFAULT_SETTINGS.extensions): every type the extension
    /// can hand over lands in a specific category instead of "其他".
    func testCategoryCoversBrowserTakeoverExtensions() {
        XCTAssertEqual(DownloadCategory(filename: "bundle.tgz"), .archive)
        XCTAssertEqual(DownloadCategory(filename: "book.epub"), .document)
        XCTAssertEqual(DownloadCategory(filename: "table.csv"), .document)
        XCTAssertEqual(DownloadCategory(filename: "photo.bmp"), .image)
        XCTAssertEqual(DownloadCategory(filename: "voice.opus"), .audio)
        XCTAssertEqual(DownloadCategory(filename: "clip.m4v"), .video)
        XCTAssertEqual(DownloadCategory(filename: "clip.flv"), .video)
        XCTAssertEqual(DownloadCategory(filename: "app.apk"), .application)
        XCTAssertEqual(DownloadCategory(filename: "setup.msi"), .application)
        XCTAssertEqual(DownloadCategory(filename: "image.iso"), .application)
        // Linux 通用打包格式同样属于应用程序，而不是「其他」。
        XCTAssertEqual(DownloadCategory(filename: "Obsidian-1.14.16.AppImage"), .application)
        XCTAssertEqual(DownloadCategory(filename: "editor.flatpak"), .application)
        XCTAssertEqual(DownloadCategory(filename: "tool.snap"), .application)
    }

    /// The broadened market-format table: each category recognizes the
    /// common formats users actually download, sampled per category.
    func testCategoryCoversCommonMarketFormats() {
        // 压缩包：新一代算法与系统映像
        XCTAssertEqual(DownloadCategory(filename: "rootfs.tar.zst"), .archive)
        XCTAssertEqual(DownloadCategory(filename: "image.wim"), .archive)
        XCTAssertEqual(DownloadCategory(filename: "old.lzh"), .archive)
        // 文档：iWork / Kindle / 数据文件
        XCTAssertEqual(DownloadCategory(filename: "简历.pages"), .document)
        XCTAssertEqual(DownloadCategory(filename: "book.azw3"), .document)
        XCTAssertEqual(DownloadCategory(filename: "scan.djvu"), .document)
        XCTAssertEqual(DownloadCategory(filename: "config.yaml"), .document)
        XCTAssertEqual(DownloadCategory(filename: "data.json"), .document)
        // 图片：RAW 与设计源文件
        XCTAssertEqual(DownloadCategory(filename: "photo.cr2"), .image)
        XCTAssertEqual(DownloadCategory(filename: "shot.avif"), .image)
        XCTAssertEqual(DownloadCategory(filename: "design.psd"), .image)
        // 音频：无损与有声书
        XCTAssertEqual(DownloadCategory(filename: "track.ape"), .audio)
        XCTAssertEqual(DownloadCategory(filename: "book.m4b"), .audio)
        XCTAssertEqual(DownloadCategory(filename: "hires.dsf"), .audio)
        // 视频：传输流与老格式
        XCTAssertEqual(DownloadCategory(filename: "segment.ts"), .video)
        XCTAssertEqual(DownloadCategory(filename: "cam.m2ts"), .video)
        XCTAssertEqual(DownloadCategory(filename: "movie.rmvb"), .video)
        XCTAssertEqual(DownloadCategory(filename: "old.wmv"), .video)
        // 应用程序：现代打包与插件包
        XCTAssertEqual(DownloadCategory(filename: "app.aab"), .application)
        XCTAssertEqual(DownloadCategory(filename: "signed.ipa"), .application)
        XCTAssertEqual(DownloadCategory(filename: "modern.msix"), .application)
        XCTAssertEqual(DownloadCategory(filename: "extension.crx"), .application)
        // 脚本不是安装器，保持「其他」
        XCTAssertEqual(DownloadCategory(filename: "install.sh"), .other)
        XCTAssertEqual(DownloadCategory(filename: "run.bat"), .other)
    }

    func testCategoryFallsBackToMIMEWhenExtensionIsUnknown() {
        XCTAssertEqual(
            DownloadCategory(filename: "download", mimeType: "application/zip"),
            .archive
        )
        XCTAssertEqual(
            DownloadCategory(filename: "seg-0001", mimeType: "image/png; charset=binary"),
            .image
        )
        XCTAssertEqual(DownloadCategory(filename: "stream", mimeType: "video/mp2t"), .video)
        // octet-stream carries no semantics and stays in "其他".
        XCTAssertEqual(
            DownloadCategory(filename: "blob", mimeType: "application/octet-stream"),
            .other
        )
        // A recognized extension always wins over a conflicting MIME.
        XCTAssertEqual(
            DownloadCategory(filename: "paper.pdf", mimeType: "application/octet-stream"),
            .document
        )
    }

    func testCategoryOverrideAndQueuePriorityAreStable() {
        var task = makeTask()
        XCTAssertEqual(task.category, .archive)
        task.categoryOverride = .video
        task.priority = 250
        XCTAssertEqual(task.category, .video)
        XCTAssertEqual(task.queuePriority, 100)
        task.priority = -250
        XCTAssertEqual(task.queuePriority, -100)
    }

    /// The detection preview (detail panel "自动（X）") must reflect pure
    /// filename/MIME inference and never echo the user's manual override.
    func testDetectedCategoryIgnoresOverrideAndUsesMIMEFallback() {
        var task = makeTask()
        // Extension-less CDN-style filename: the declared MIME decides.
        task.destinationPath = "/tmp/signed-media"
        task.mimeType = "video/mp4"
        XCTAssertEqual(task.detectedCategory, .video)
        XCTAssertEqual(task.category, .video)

        // An override changes the effective category only; the detected
        // preview keeps reporting what "自动" would resolve to.
        task.categoryOverride = .document
        XCTAssertEqual(task.category, .document)
        XCTAssertEqual(task.detectedCategory, .video)

        // Without MIME the same filename falls back to "其他".
        task.mimeType = nil
        XCTAssertEqual(task.detectedCategory, .other)
    }

    func testEffectiveParallelismReflectsActualBehavior() {
        // Active with segments: the engine's live segment list is the
        // real concurrency.
        var task = makeTask()
        task.status = .running
        task.segments = [
            SegmentSnapshot(index: 0, receivedBytes: 0, totalBytes: 100),
            SegmentSnapshot(index: 1, receivedBytes: 0, totalBytes: 100),
        ]
        XCTAssertEqual(task.effectiveParallelism, 2)

        // Active without segments (yt-dlp transfers serially): serial.
        task.segments = []
        XCTAssertEqual(task.effectiveParallelism, 1)

        // Terminal: the recorded result wins over the configured maximum.
        task.status = .completed
        task.usedParallelRequests = 1
        XCTAssertEqual(task.effectiveParallelism, 1)

        // Legacy rows without a recorded result keep the setting.
        task.usedParallelRequests = nil
        XCTAssertEqual(task.effectiveParallelism, task.maximumParallelRequests)

        // Not started yet: show what will be used.
        task.status = .queued
        XCTAssertEqual(task.effectiveParallelism, task.maximumParallelRequests)
    }

    func testStageAwareProgressOverridesRawBytesUntilCompletion() {
        var task = makeTask()
        task.status = .running
        task.receivedBytes = 100
        task.totalBytes = 100
        task.overallProgressFraction = 0.82

        XCTAssertEqual(task.fractionCompleted, 0.82, accuracy: 0.0001)

        task.status = .completed
        XCTAssertEqual(task.fractionCompleted, 1, accuracy: 0.0001)
    }

    func testFractionCompletedCapsAt99PercentUntilCompleted() {
        // 回归（X.com HLS“卡验证”根因之一）：估算总量偏小时 receivedBytes
        // 会超过 totalBytes，旧逻辑 min(1,…) 让进度条提前谎报 100%，用户
        // 以为下载完成，实际引擎还在下音频轨/尾段。非完成态封顶 0.99，
        // 100% 只属于 completed，配合“正在验证”文案传达“接近完成、收尾中”。
        var task = makeTask()
        task.status = .running
        task.overallProgressFraction = nil
        task.receivedBytes = 6_500_000  // 超过偏小的估算总量
        task.totalBytes = 6_000_000
        XCTAssertEqual(task.fractionCompleted, 0.99, accuracy: 0.0001)

        // stage-aware 比例路径同样封顶 0.99。
        task.overallProgressFraction = 1.0
        XCTAssertEqual(task.fractionCompleted, 0.99, accuracy: 0.0001)

        // 只有真正完成才允许 100%。
        task.status = .completed
        XCTAssertEqual(task.fractionCompleted, 1.0, accuracy: 0.0001)
    }

    func testSettleSegmentProgressRepairsStaleSplitParentsOnCompletedTasks() {
        // Reproduces the split-parent snapshot bug: the coordinator divided
        // segments 4, 8, and 9 mid-transfer, but their totals kept the
        // pre-split range while the transfers stopped at the split point,
        // so a finished download displayed as "9/12 已完成".
        var task = makeTask()
        task.status = .completed
        task.receivedBytes = 149_915_928
        task.totalBytes = 149_915_928
        task.segments = [
            SegmentSnapshot(index: 0, receivedBytes: 18_739_491, totalBytes: 18_739_491),
            SegmentSnapshot(index: 4, receivedBytes: 17_132_404, totalBytes: 18_739_491),
            SegmentSnapshot(index: 8, receivedBytes: 401_408, totalBytes: 1_607_087),
            SegmentSnapshot(index: 9, receivedBytes: 401_408, totalBytes: 804_271),
            SegmentSnapshot(index: 10, receivedBytes: 401_408, totalBytes: 401_408),
        ]

        task.settleSegmentProgress()

        // Every segment of a completed task must report received == total,
        // matching the detail panel's completion-count rule.
        for segment in task.segments {
            XCTAssertEqual(segment.receivedBytes, segment.totalBytes)
        }
    }

    func testSettleSegmentProgressLeavesActiveTasksUntouched() {
        var task = makeTask()
        task.status = .running
        task.segments = [
            SegmentSnapshot(index: 0, receivedBytes: 512, totalBytes: 1024),
            SegmentSnapshot(index: 1, receivedBytes: 0, totalBytes: nil),
        ]
        let original = task.segments

        task.settleSegmentProgress()

        XCTAssertEqual(task.segments, original)

        // A completed task's unknown-size segments stay untouched too:
        // there is no total to snap them to.
        task.status = .completed
        task.settleSegmentProgress()
        XCTAssertEqual(task.segments[1].receivedBytes, 0)
        XCTAssertNil(task.segments[1].totalBytes)
    }

    func testRedactedURLDoesNotExposeQueryOrCredentials() {
        var task = makeTask()
        task = AppTask(
            id: task.id,
            sourceURL: "https://user:secret@example.com/file.zip?token=signed#private",
            destinationPath: task.destinationPath,
            maximumParallelRequests: task.maximumParallelRequests,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            status: task.status,
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

        XCTAssertFalse(task.redactedSourceURL.contains("secret"))
        XCTAssertFalse(task.redactedSourceURL.contains("signed"))
        XCTAssertFalse(task.redactedSourceURL.contains("private"))
    }

    func testJobIDIsShortStableAndRedactionAware() {
        let task = makeTask()
        // Deterministic: the same task always reports the same Job ID.
        XCTAssertEqual(task.jobID, task.jobID)
        XCTAssertEqual(task.jobID.count, 8)
        // Crockford base32 alphabet only: no I/L/O/U ambiguity.
        XCTAssertNil(task.jobID.first { "ILOU".contains($0) })
        // A different task ID produces a different Job ID (collision-free
        // enough for support-reference purposes at this scale).
        let other = AppTask(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceURL: task.sourceURL,
            destinationPath: task.destinationPath,
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
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
        XCTAssertNotEqual(task.jobID, other.jobID)
        XCTAssertEqual(task.displayName(redacted: false), task.filename)
        XCTAssertEqual(task.displayName(redacted: true), task.jobID)
    }

    private func makeTask() -> AppTask {
        AppTask(
            id: UUID(),
            sourceURL: "https://example.com/file.zip",
            destinationPath: "/tmp/file.zip",
            maximumParallelRequests: 8,
            expectedSHA256: nil,
            browserClientID: nil,
            browserSubmissionType: nil,
            browserSubmissionKey: nil,
            createdAt: Date(),
            updatedAt: Date(),
            status: .paused,
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
    }
}
