import CryptoKit
import Foundation
import XCTest

@testable import IDMEngine

/// Separate-audio HLS masters (EXT-X-MEDIA audio groups, e.g. X/Twitter):
/// parser rendition resolution, inspector pairAudioURL exposure, executor
/// audio download + FFmpeg merge, explicit downloadPair entry, and the
/// DownloadEngine routing for pairAudioURL.
final class HLSSeparateAudioTests: XCTestCase {
    private struct URLs {
        let master: URL
        let variant: URL
        let segment: URL
        let audioPlaylist: URL
        let audioSegment: URL
    }

    private func makeURLs() -> URLs {
        let base = URL(string: "https://video.example.test/amplify/1/pl")!
        let master = base.appendingPathComponent("master.m3u8")
        let variant = base.appendingPathComponent("avc1/720.m3u8")
        let audioPlaylist = base.appendingPathComponent("audio/index.m3u8")
        return URLs(
            master: master,
            variant: variant,
            segment: base.appendingPathComponent("avc1/seg1.ts"),
            audioPlaylist: audioPlaylist,
            audioSegment: base.appendingPathComponent("audio/aseg1.m4s")
        )
    }

    private let separateAudioMaster = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="aud"
        avc1/720.m3u8
        """

    private let mediaPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-ENDLIST
        """

    private let audioMediaPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4.0,
        aseg1.m4s
        #EXT-X-ENDLIST
        """

    // MARK: - 解析层

    func testAudioRenditionResolvePrefersDefaultRenditionWithURI() throws {
        let urls = makeURLs()
        let parsed = try HLSParser().parse(separateAudioMaster, baseURL: urls.master)
        guard case .master(let master) = parsed else {
            return XCTFail("expected a master playlist")
        }
        let rendition = HLSAudioRendition.resolve(variant: master.variants[0], in: master)
        XCTAssertEqual(rendition?.groupID, "aud")
        XCTAssertEqual(rendition?.url, urls.audioPlaylist)
        XCTAssertEqual(rendition?.isDefault, true)
    }

    func testAudioRenditionResolveReturnsNilForMuxedOrInlineOnlyMasters() throws {
        let urls = makeURLs()
        let muxed = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
            avc1/720.m3u8
            """
        guard case .master(let muxedMaster) = try HLSParser().parse(muxed, baseURL: urls.master) else {
            return XCTFail("expected a master playlist")
        }
        XCTAssertNil(HLSAudioRendition.resolve(variant: muxedMaster.variants[0], in: muxedMaster))

        // Renditions without URI are inline alternates, not downloadable tracks.
        let inlineOnly = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio"
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="aud"
            avc1/720.m3u8
            """
        guard case .master(let inlineMaster) = try HLSParser().parse(inlineOnly, baseURL: urls.master) else {
            return XCTFail("expected a master playlist")
        }
        XCTAssertNil(HLSAudioRendition.resolve(variant: inlineMaster.variants[0], in: inlineMaster))
    }

    // MARK: - 检查器

    func testInspectorExposesPairAudioURLForSeparateAudioMaster() async throws {
        let urls = makeURLs()
        let client = SeparateAudioClient(responses: [
            urls.master.absoluteString: HLSFetchResponse(
                data: Data(separateAudioMaster.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
        ])
        let inspection = try await HLSMediaInspector(client: client).inspect(
            url: urls.master,
            requestContext: nil,
            mediaKind: .hls
        )
        XCTAssertEqual(inspection.variants.count, 1)
        XCTAssertEqual(inspection.variants[0].pairAudioURL, urls.audioPlaylist)
    }

    func testInspectorLeavesMuxedMasterVariantsWithoutPairAudioURL() async throws {
        let urls = makeURLs()
        let muxed = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
            avc1/720.m3u8
            """
        let client = SeparateAudioClient(responses: [
            urls.master.absoluteString: HLSFetchResponse(
                data: Data(muxed.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
        ])
        let inspection = try await HLSMediaInspector(client: client).inspect(
            url: urls.master,
            requestContext: nil,
            mediaKind: .hls
        )
        XCTAssertNil(inspection.variants[0].pairAudioURL)
    }

    // MARK: - 执行器：master 自动解析音频组

    func testSeparateAudioMasterDownloadsRenditionAndMergesIntoDestination() async throws {
        let urls = makeURLs()
        let client = SeparateAudioClient(responses: [
            urls.master.absoluteString: HLSFetchResponse(
                data: Data(separateAudioMaster.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.audioPlaylist.absoluteString: HLSFetchResponse(
                data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist),
            urls.segment.absoluteString: HLSFetchResponse(
                data: Data("video-bytes".utf8), finalURL: urls.segment),
            urls.audioSegment.absoluteString: HLSFetchResponse(
                data: Data("audio-bytes".utf8), finalURL: urls.audioSegment),
        ])
        let merger = SeparateAudioMerger()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = DownloadRequest(
            url: urls.master,
            destination: destination,
            maximumParallelRequests: 2,
            taskID: UUID()
        )

        let result = try await HLSDownloadExecutor(client: client, merger: merger).download(request)

        XCTAssertEqual(result.verification, "hls-ffmpeg-ffprobe")
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("video-bytesaudio-bytes".utf8)
        )
        let fetchedURLs = await client.requestedURLs
        XCTAssertTrue(fetchedURLs.contains(urls.audioPlaylist), "音频清单必须被请求")
        let mergeRequest = await merger.request
        XCTAssertNotNil(mergeRequest?.videoURL)
        XCTAssertNotNil(mergeRequest?.audioURL)
        // 合并完成后引擎侧临时产物全部清理，只留 destination。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("macidm") }
        XCTAssertEqual(leftovers, [], "合并后不得残留 macidm 临时文件，实际: \(leftovers)")
    }

    func testSeparateAudioMasterWithoutMergerKeepsVideoOnlyPath() async throws {
        let urls = makeURLs()
        let client = SeparateAudioClient(responses: [
            urls.master.absoluteString: HLSFetchResponse(
                data: Data(separateAudioMaster.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(
                data: Data("video-bytes".utf8), finalURL: urls.segment),
        ])
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = DownloadRequest(
            url: urls.master,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        let result = try await HLSDownloadExecutor(client: client).download(request)

        XCTAssertEqual(result.verification, "segments-and-size")
        XCTAssertEqual(try Data(contentsOf: destination), Data("video-bytes".utf8))
        let fetchedURLs = await client.requestedURLs
        XCTAssertFalse(
            fetchedURLs.contains(urls.audioPlaylist),
            "无合并服务时不得请求音频清单（维持原视频直写行为）"
        )
    }

    func testSeparateAudioMasterFailsClosedWhenRenditionIsUnavailable() async throws {
        let urls = makeURLs()
        // 音频清单缺席：客户端对缺失 URL 抛 404。fail-closed：整任务失败，
        // 绝不静默产出无声视频。
        let client = SeparateAudioClient(responses: [
            urls.master.absoluteString: HLSFetchResponse(
                data: Data(separateAudioMaster.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(
                data: Data("video-bytes".utf8), finalURL: urls.segment),
        ])
        let merger = SeparateAudioMerger()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = DownloadRequest(
            url: urls.master,
            destination: destination,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        do {
            _ = try await HLSDownloadExecutor(client: client, merger: merger).download(request)
            XCTFail("音频清单缺失时必须失败，不得产出无声视频")
        } catch let error as IDMError {
            XCTAssertEqual(error.code, IDMError.httpStatus(404).code)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - 最终进度上报

    /// 小体积快下载的全部组提交都落在最终 quiesce：最后一个进度事件的
    /// 分段必须已是完成态，否则 App 分段面板与总进度脱节（全 0% vs 100%）。
    func testFinalProgressEventMarksAllSegmentsCompleted() async throws {
        let urls = makeURLs()
        let client = SeparateAudioClient(responses: [
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(
                data: Data("video-bytes".utf8), finalURL: urls.segment),
        ])
        final class ProgressBox: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [DownloadProgress] = []
            func append(_ value: DownloadProgress) {
                lock.lock()
                events.append(value)
                lock.unlock()
            }
            var last: DownloadProgress? {
                lock.lock()
                defer { lock.unlock() }
                return events.last
            }
        }
        let box = ProgressBox()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = DownloadRequest(
            url: urls.variant,
            destination: destination,
            sourceKind: .hls,
            maximumParallelRequests: 1,
            taskID: UUID()
        )

        _ = try await HLSDownloadExecutor(client: client).download(
            request,
            control: { .continue },
            progress: { box.append($0) }
        )

        let last = box.last
        XCTAssertNotNil(last, "必须收到进度事件")
        let segments = last?.segments ?? []
        XCTAssertFalse(segments.isEmpty, "最终进度事件必须携带分段明细")
        XCTAssertTrue(
            segments.allSatisfy { $0.receivedBytes > 0 && $0.totalBytes != nil },
            "最后一个进度事件的分段必须全部已完成，实际: \(segments.map { ($0.receivedBytes, $0.totalBytes) })"
        )
    }

    // MARK: - 显式 pair 入口与引擎路由

    func testDownloadPairMergesExplicitTracksAndCleansUp() async throws {
        let urls = makeURLs()
        let client = SeparateAudioClient(responses: [
            urls.variant.absoluteString: HLSFetchResponse(
                data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.audioPlaylist.absoluteString: HLSFetchResponse(
                data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist),
            urls.segment.absoluteString: HLSFetchResponse(
                data: Data("video-bytes".utf8), finalURL: urls.segment),
            urls.audioSegment.absoluteString: HLSFetchResponse(
                data: Data("audio-bytes".utf8), finalURL: urls.audioSegment),
        ])
        let merger = SeparateAudioMerger()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await HLSDownloadExecutor(client: client, merger: merger).downloadPair(
            HLSPairDownloadRequest(
                videoURL: urls.variant,
                audioURL: urls.audioPlaylist,
                destination: destination,
                taskID: UUID()
            )
        )

        XCTAssertEqual(result.verification, "hls-pair-ffmpeg-ffprobe")
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("video-bytesaudio-bytes".utf8)
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("macidm") }
        XCTAssertEqual(leftovers, [], "合并后 pair 临时目录必须清理，实际: \(leftovers)")
    }

    func testDownloadPairWithoutMergerThrows() async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        do {
            _ = try await HLSDownloadExecutor().downloadPair(
                HLSPairDownloadRequest(
                    videoURL: urls.variant,
                    audioURL: urls.audioPlaylist,
                    destination: destination
                )
            )
            XCTFail("缺少合并服务时必须抛出 mergerUnavailable")
        } catch HLSDownloadError.mergerUnavailable {
            // 期望路径
        } catch {
            XCTFail("意外错误: \(error)")
        }
    }

    func testEngineRoutesHLSPairAudioURLToDownloadPair() async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        // 默认引擎的 HLS executor 未配置 merger：若路由正确走到 downloadPair，
        // 第一个错误就是 mergerUnavailable（而非任何网络错误）。
        let engine = DownloadEngine()
        let request = DownloadRequest(
            url: urls.variant,
            destination: destination,
            sourceKind: .hls,
            taskID: UUID(),
            pairAudioURL: urls.audioPlaylist
        )
        do {
            _ = try await engine.download(request)
            XCTFail("缺少合并服务时必须抛出 mergerUnavailable")
        } catch HLSDownloadError.mergerUnavailable {
            // 期望路径：pairAudioURL 已路由到 downloadPair
        } catch {
            XCTFail("意外错误（路由可能未生效）: \(error)")
        }
    }

    func testRetryAfterAudioFailure() async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let pair = HLSPairDownloadRequest(
            videoURL: urls.variant, audioURL: urls.audioPlaylist,
            destination: destination, taskID: UUID())
        var responses = [
            urls.variant.absoluteString: HLSFetchResponse(data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(data: Data("video".utf8), finalURL: urls.segment),
        ]
        do {
            _ = try await HLSDownloadExecutor(
                client: SeparateAudioClient(responses: responses), merger: SeparateAudioMerger()
            ).downloadPair(pair)
            XCTFail("Audio failure must fail first attempt")
        } catch IDMError.httpStatus(404) {}
        responses[urls.audioPlaylist.absoluteString] = HLSFetchResponse(
            data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist)
        responses[urls.audioSegment.absoluteString] = HLSFetchResponse(
            data: Data("audio".utf8), finalURL: urls.audioSegment)
        _ = try await HLSDownloadExecutor(
            client: SeparateAudioClient(responses: responses), merger: SeparateAudioMerger()
        ).downloadPair(pair)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMasterMustRejectWrongExpectedHash() async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let responses = [
            urls.master.absoluteString: HLSFetchResponse(data: Data(separateAudioMaster.utf8), finalURL: urls.master),
            urls.variant.absoluteString: HLSFetchResponse(data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(data: Data("video".utf8), finalURL: urls.segment),
            urls.audioPlaylist.absoluteString: HLSFetchResponse(
                data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist),
            urls.audioSegment.absoluteString: HLSFetchResponse(data: Data("audio".utf8), finalURL: urls.audioSegment),
        ]
        let request = DownloadRequest(
            url: urls.master, destination: destination, sourceKind: .hls,
            expectedSHA256: String(repeating: "0", count: 64))
        do {
            _ = try await HLSDownloadExecutor(
                client: SeparateAudioClient(responses: responses), merger: SeparateAudioMerger()
            ).download(request)
            XCTFail("Mismatched expectedSHA256 must reject publication")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPairMergeRetryReusesVerifiedTracks() async throws {
        try await assertPairRecovery(mutation: "none")
    }

    func testPairRetryRedownloadsCorruptTrack() async throws {
        try await assertPairRecovery(mutation: "corrupt")
    }

    func testPairRetryRejectsChangedURLIdentity() async throws {
        try await assertPairRecovery(mutation: "identity")
    }

    private func assertPairRecovery(mutation: String) async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        let directory = destination.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var responses = [
            urls.variant.absoluteString: HLSFetchResponse(data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(data: Data("video".utf8), finalURL: urls.segment),
            urls.audioPlaylist.absoluteString: HLSFetchResponse(
                data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist),
            urls.audioSegment.absoluteString: HLSFetchResponse(data: Data("audio".utf8), finalURL: urls.audioSegment),
        ]
        let pair = HLSPairDownloadRequest(
            videoURL: urls.variant, audioURL: urls.audioPlaylist,
            destination: destination, taskID: id)
        do {
            _ = try await HLSDownloadExecutor(
                client: SeparateAudioClient(responses: responses),
                merger: SeparateAudioMerger(failures: 1)
            ).downloadPair(pair)
            XCTFail("expected merge failure")
        } catch IDMError.paused {}
        let video = directory.appendingPathComponent(".\(id.uuidString).macidm.hls-pair/video.track")
        if mutation == "corrupt" { try Data("other".utf8).write(to: video) }
        let retryURL = mutation == "identity" ? URL(string: urls.variant.absoluteString + "?version=2")! : urls.variant
        responses[retryURL.absoluteString] = responses[urls.variant.absoluteString]
        let client = SeparateAudioClient(responses: responses)
        let result = try await HLSDownloadExecutor(client: client, merger: SeparateAudioMerger()).downloadPair(
            HLSPairDownloadRequest(
                videoURL: retryURL, audioURL: urls.audioPlaylist,
                destination: destination, taskID: id))
        XCTAssertEqual(try Data(contentsOf: result.destination), Data("videoaudio".utf8))
        let fetched = await client.requestedURLs
        XCTAssertEqual(fetched.contains(urls.segment), mutation != "none")
        XCTAssertEqual(fetched.contains(urls.audioSegment), mutation == "identity")
    }

    func testEngineHLSPairForwardsExpectedHashToFinalPublication() async throws {
        let urls = makeURLs()
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let client = SeparateAudioClient(responses: [
            urls.variant.absoluteString: HLSFetchResponse(data: Data(mediaPlaylist.utf8), finalURL: urls.variant),
            urls.segment.absoluteString: HLSFetchResponse(data: Data("video".utf8), finalURL: urls.segment),
            urls.audioPlaylist.absoluteString: HLSFetchResponse(
                data: Data(audioMediaPlaylist.utf8), finalURL: urls.audioPlaylist),
            urls.audioSegment.absoluteString: HLSFetchResponse(data: Data("audio".utf8), finalURL: urls.audioSegment),
        ])
        let engine = DownloadEngine(hlsExecutor: HLSDownloadExecutor(client: client, merger: SeparateAudioMerger()))
        do {
            _ = try await engine.download(
                DownloadRequest(
                    url: urls.variant, destination: destination,
                    sourceKind: .hls, expectedSHA256: String(repeating: "0", count: 64),
                    pairAudioURL: urls.audioPlaylist))
            XCTFail("expected hash mismatch")
        } catch IDMError.verificationFailed {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - helpers

    private func makeDestination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macidm-hls-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("video.mp4")
    }
}

private actor SeparateAudioClient: HLSResourceClient {
    let responses: [String: HLSFetchResponse]
    private(set) var requestedURLs: [URL] = []

    init(responses: [String: HLSFetchResponse]) {
        self.responses = responses
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        requestedURLs.append(request.url)
        try await Task.sleep(nanoseconds: 1_000_000)
        guard let response = responses[request.url.absoluteString] else {
            throw IDMError.httpStatus(404)
        }
        return response
    }
}

private actor SeparateAudioMerger: FFmpegMerging {
    var failures: Int
    init(failures: Int = 0) { self.failures = failures }
    private(set) var request: FFmpegMergeRequest?

    func merge(_ request: FFmpegMergeRequest) async throws -> FFmpegRemuxResult {
        self.request = request
        if failures > 0 {
            failures -= 1
            throw IDMError.paused
        }
        var output = Data()
        if let videoURL = request.videoURL {
            output.append(try Data(contentsOf: videoURL))
        }
        if let audioURL = request.audioURL {
            output.append(try Data(contentsOf: audioURL))
        }
        let temporary = request.outputURL.appendingPathExtension("merge-output")
        try output.write(to: temporary, options: .atomic)
        _ = try ArtifactVerifier().verifyAndPublish(
            temporary: temporary, destination: request.outputURL,
            expectedSHA256: request.expectedSHA256, byteCount: Int64(output.count),
            usedParallelRequests: 1, resumed: false)
        return FFmpegRemuxResult(
            destination: request.outputURL,
            byteCount: Int64(output.count),
            sha256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined(),
            probe: FFmpegProbeResult(formatName: "mp4", duration: nil, streams: [])
        )
    }
}
