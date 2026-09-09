import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

final class MediaInspectorTests: XCTestCase {
    func testDASHInspectionReturnsACombinedAudioVideoCandidate() async throws {
        let url = URL(string: "https://media.example.test/manifest.mpd")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT2S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="v-init.m4s" media="v-$Number$.m4s"/>
                  <Representation id="video" bandwidth="800" width="1280" height="720"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="a-init.m4s" media="a-$Number$.m4s"/>
                  <Representation id="audio" bandwidth="128" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        XCTAssertEqual(result.mediaKind, .dash)
        XCTAssertEqual(result.variants.count, 1)
        XCTAssertEqual(result.variants.first?.url, url)
        XCTAssertEqual(result.variants.first?.width, 1280)
        XCTAssertEqual(result.variants.first?.height, 720)
        // 统一槽位文法：清晰度档位 + 轨道组成；800 bit/s 不足 1 kbps 不展示码率。
        XCTAssertEqual(result.variants.first?.label, "720P · 视频+音频")
        XCTAssertEqual(result.variants.first?.duration, 2)
        // 体积估算按「视频+音频」合计总码率：(800 + 128) × 2s / 8 = 232 bytes
        XCTAssertEqual(result.variants.first?.estimatedSize, 232)
    }

    func testDASHInspectionSumsVideoAndAudioBandwidthForEstimatedSize() async throws {
        let url = URL(string: "https://media.example.test/merged.mpd")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT120S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="v-init.m4s" media="v-$Number$.m4s"/>
                  <Representation id="video" bandwidth="8000000" width="1920" height="1080"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="a-init.m4s" media="a-$Number$.m4s"/>
                  <Representation id="audio" bandwidth="192000" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        // (8_000_000 + 192_000) × 120 / 8 = 122_880_000；bandwidth 字段保留视频轨码率语义。
        XCTAssertEqual(result.variants.first?.estimatedSize, 122_880_000)
        XCTAssertEqual(result.variants.first?.bandwidth, 8_000_000)
    }

    func testDASHInspectionUsesVideoBandwidthAloneWithoutAudioTrack() async throws {
        let url = URL(string: "https://media.example.test/video-only.mpd")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT10S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="v-init.m4s" media="v-$Number$.m4s"/>
                  <Representation id="video" bandwidth="800000" width="1280" height="720"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        // 仅视频轨：沿用该轨码率 800_000 × 10 / 8 = 1_000_000
        XCTAssertEqual(result.variants.first?.estimatedSize, 1_000_000)
    }

    func testDASHInspectionUsesAudioBandwidthAloneWithoutVideoTrack() async throws {
        let url = URL(string: "https://media.example.test/audio-only.mpd")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT10S">
              <Period>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="a-init.m4s" media="a-$Number$.m4s"/>
                  <Representation id="audio" bandwidth="128000" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        // 仅音频轨：沿用该轨码率 128_000 × 10 / 8 = 160_000
        XCTAssertEqual(result.variants.first?.estimatedSize, 160_000)
    }

    func testDASHInspectionDegradesToUnknownWhenBandwidthInvalid() async throws {
        let url = URL(string: "https://media.example.test/invalid-bandwidth.mpd")!
        let manifest = """
            <MPD type="static" mediaPresentationDuration="PT10S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="v-init.m4s" media="v-$Number$.m4s"/>
                  <Representation id="video" bandwidth="0" width="1280" height="720"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" initialization="a-init.m4s" media="a-$Number$.m4s"/>
                  <Representation id="audio" bandwidth="-192" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        // 非正码率全部忽略，无法估算体积，保持未知；时长照常展示。
        XCTAssertNil(result.variants.first?.estimatedSize)
        XCTAssertEqual(result.variants.first?.duration, 10)
    }

    func testDASHInspectionLeavesEstimatedSizeNilWithoutDuration() async throws {
        let url = URL(string: "https://media.example.test/no-duration.mpd")!
        let manifest = """
            <MPD type="static">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <SegmentTemplate timescale="1" initialization="v-init.m4s" media="v-$Time$.m4s">
                    <SegmentTimeline>
                      <S t="0" d="1"/>
                    </SegmentTimeline>
                  </SegmentTemplate>
                  <Representation id="video" bandwidth="800000" width="640" height="360"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        let inspector = DASHMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(manifest.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)

        XCTAssertNil(result.variants.first?.estimatedSize)
        XCTAssertNil(result.variants.first?.duration)
    }

    func testHLSMasterInspectionSharesSubPlaylistDurationAcrossVariants() async throws {
        let masterURL = URL(string: "https://media.example.test/master.m3u8")!
        let master = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
            720.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
            360.m3u8
            """
        let subPlaylist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:5.0,
            seg0.ts
            #EXTINF:5.0,
            seg1.ts
            #EXT-X-ENDLIST
            """
        let client = ScriptedClient(responses: [
            masterURL.absoluteString: HLSFetchResponse(data: Data(master.utf8), finalURL: masterURL),
            "https://media.example.test/720.m3u8": HLSFetchResponse(
                data: Data(subPlaylist.utf8),
                finalURL: URL(string: "https://media.example.test/720.m3u8")!
            ),
        ])
        let inspector = HLSMediaInspector(client: client)

        let result = try await inspector.inspect(url: masterURL, requestContext: nil, mediaKind: .hls)

        XCTAssertEqual(result.variants.count, 2)
        // 所有变体共享最高码率变体子播放列表的总时长（5+5=10s）
        XCTAssertEqual(result.variants.map(\.duration), [10, 10])
        // 2_000_000 × 10 / 8 与 800_000 × 10 / 8
        XCTAssertEqual(result.variants.map(\.estimatedSize), [2_500_000, 1_000_000])
    }

    func testHLSMasterInspectionDegradesSilentlyWhenSubPlaylistFetchFails() async throws {
        let masterURL = URL(string: "https://media.example.test/master.m3u8")!
        let master = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
            720.m3u8
            """
        // 只提供 master 响应：子播放列表抓取失败时静默降级，不报错。
        let client = ScriptedClient(responses: [
            masterURL.absoluteString: HLSFetchResponse(data: Data(master.utf8), finalURL: masterURL)
        ])
        let inspector = HLSMediaInspector(client: client)

        let result = try await inspector.inspect(url: masterURL, requestContext: nil, mediaKind: .hls)

        XCTAssertEqual(result.variants.count, 1)
        XCTAssertNil(result.variants.first?.duration)
        XCTAssertNil(result.variants.first?.estimatedSize)
    }

    func testHLSMediaPlaylistKeepsDurationWithoutEstimateWhenBandwidthUnknown() async throws {
        let url = URL(string: "https://media.example.test/media.m3u8")!
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:6.0,
            seg0.ts
            #EXTINF:4.0,
            seg1.ts
            #EXT-X-ENDLIST
            """
        let inspector = HLSMediaInspector(
            client: InspectorClient(response: HLSFetchResponse(data: Data(playlist.utf8), finalURL: url))
        )

        let result = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .hls)

        XCTAssertEqual(result.variants.first?.duration, 10)
        // 单画质流没有 BANDWIDTH，无从估算，保持 nil（UI 显示「未知」）
        XCTAssertNil(result.variants.first?.estimatedSize)
    }

    func testEstimatedSizeFormulaRequiresBothInputs() {
        XCTAssertEqual(MediaVariant.estimatedSize(bandwidth: 800_000, duration: 10), 1_000_000)
        XCTAssertNil(MediaVariant.estimatedSize(bandwidth: nil, duration: 10))
        XCTAssertNil(MediaVariant.estimatedSize(bandwidth: 800_000, duration: nil))
        XCTAssertNil(MediaVariant.estimatedSize(bandwidth: 0, duration: 10))
    }

    func testDASHInspectionRejectsDynamicManifest() async throws {
        let url = URL(string: "https://media.example.test/live.mpd")!
        let inspector = DASHMediaInspector(
            client: InspectorClient(
                response: HLSFetchResponse(
                    data: Data("<MPD type=\"dynamic\"></MPD>".utf8),
                    finalURL: url
                )
            )
        )

        do {
            _ = try await inspector.inspect(url: url, requestContext: nil, mediaKind: .dash)
            XCTFail("dynamic DASH should be rejected")
        } catch let error as MediaInspectionError {
            if case .unsupportedLiveStream = error {
                // expected
            } else {
                XCTFail("unexpected media inspection error: \(error)")
            }
        }
    }
}

private actor InspectorClient: HLSResourceClient {
    let response: HLSFetchResponse

    init(response: HLSFetchResponse) {
        self.response = response
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        response
    }
}

/// 按 URL 分发响应的测试客户端；未命中的 URL 抛错，模拟二次抓取失败。
private actor ScriptedClient: HLSResourceClient {
    let responses: [String: HLSFetchResponse]

    init(responses: [String: HLSFetchResponse]) {
        self.responses = responses
    }

    func fetch(_ request: HLSFetchRequest) async throws -> HLSFetchResponse {
        guard let response = responses[request.url.absoluteString] else {
            throw URLError(.fileDoesNotExist)
        }
        return response
    }
}
