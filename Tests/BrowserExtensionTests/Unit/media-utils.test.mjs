import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(source, context);
const mediaUtils = context.MacIDMMediaUtils;

test("media candidates preserve request URLs but redact query strings for display", () => {
  const candidate = mediaUtils.normalizeMediaCandidate(
    { url: "/video/master.m3u8?token=secret", mime: "application/vnd.apple.mpegurl" },
    "https://example.com/watch",
  );

  assert.equal(candidate.url, "https://example.com/video/master.m3u8?token=secret");
  assert.equal(candidate.displayURL, "https://example.com/video/master.m3u8");
  assert.equal(candidate.format, "hls");
  assert.equal(candidate.fileExtension, "m3u8");
  assert.equal(candidate.filenameHint, "master.mp4");
});

test("blob candidates remain visible but cannot be submitted", () => {
  const candidate = mediaUtils.normalizeMediaCandidate({ url: "blob:https://example.com/id" });

  assert.equal(candidate.format, "blob");
  assert.equal(candidate.supported, false);
  assert.equal(candidate.displayURL, "blob:");
});

test("MIME and URL classification recognizes audio and DASH", () => {
  assert.equal(mediaUtils.mediaFormat("https://cdn.example/audio", "audio/mp4"), "audio");
  assert.equal(mediaUtils.mediaFormat("https://cdn.example/manifest.mpd", "video/mp4"), "dash");
  assert.equal(mediaUtils.mediaFormat("https://cdn.example/manifest.mpd.json", ""), "video");
});

test("direct media candidates receive a usable filename with an extension", () => {
  const candidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example/video", mime: "video/mp4" },
    "https://example.com/watch",
  );

  assert.equal(candidate.format, "video");
  assert.equal(candidate.fileExtension, "mp4");
  assert.equal(candidate.filenameHint, "video.mp4");
});

test("YouTube videoplayback URLs use the MIME query parameter", () => {
  const candidate = mediaUtils.normalizeMediaCandidate(
    {
      url: "https://rr.example.googlevideo.com/videoplayback?expire=1&mime=video%2Fmp4&itag=18",
    },
    "https://www.youtube.com/watch?v=fixture",
  );

  assert.equal(candidate.format, "video");
  assert.equal(candidate.fileExtension, "mp4");
  assert.equal(candidate.mime, "video/mp4");
  assert.equal(candidate.filenameHint, "videoplayback.mp4");
});

test("media inspection exposes the concrete container instead of a generic video label", () => {
  assert.equal(mediaUtils.mediaExtension("https://cdn.example/track.m4s"), "m4s");
  assert.equal(mediaUtils.mediaExtension("https://cdn.example/segment", "video/mp4"), "mp4");
  assert.equal(mediaUtils.mediaExtension("https://cdn.example/playlist", "application/dash+xml"), "mpd");
  assert.equal(
    mediaUtils.normalizeMediaCandidate(
      { url: "https://cdn.example/track.m4s", size: 48_000 },
      "https://example.com/watch",
    ).fileExtension,
    "m4s",
  );
});

test("m4s and other DASH/container extensions are recognized as media", () => {
  for (const ext of ["m4s", "ts", "mp2t", "mkv", "avi", "wmv", "flv", "opus", "wav"]) {
    const candidate = mediaUtils.normalizeMediaCandidate(
      { url: `https://cdn.example/track.${ext}` },
      "https://example.com/watch",
    );
    assert.ok(candidate, `expected ${ext} to be recognized as media`);
    assert.equal(candidate.supported, true);
  }
});

test("m4s audio extensions are classified as audio format", () => {
  assert.equal(
    mediaUtils.mediaFormat("https://cdn.example/song.opus", ""),
    "audio",
  );
  assert.equal(
    mediaUtils.mediaFormat("https://cdn.example/song.wav", ""),
    "audio",
  );
  // m4s itself is a DASH fragment container, classified as video (pairing
  // noise reduction happens on the service-worker side)
  assert.equal(
    mediaUtils.mediaFormat("https://cdn.example/1550776785-1-100022.m4s", ""),
    "video",
  );
});

test("extractM4sInfo parses cid / formatId / kind from bilibili-style URLs", () => {
  // Objects created in the VM context have different prototypes than the
  // outer realm; compare via JSON bridging
  const video = mediaUtils.extractM4sInfo(
    "https://upgz.bilivideo.com/upgcxcode/1550776785-1-100022.m4s",
  );
  assert.deepEqual(JSON.parse(JSON.stringify(video)), {
    cid: "1550776785",
    formatId: 100022,
    kind: "video",
  });
  // audio track: 302xx
  const audio = mediaUtils.extractM4sInfo(
    "https://upgz.bilivideo.com/1550776785-1-30216.m4s?token=abc",
  );
  assert.deepEqual(JSON.parse(JSON.stringify(audio)), {
    cid: "1550776785",
    formatId: 30216,
    kind: "audio",
  });
  // non-m4s / naming rule not matched -> null
  assert.equal(mediaUtils.extractM4sInfo("https://cdn.example/video.mp4"), null);
  assert.equal(mediaUtils.extractM4sInfo("https://cdn.example/notm4s.m4s"), null);
  assert.equal(mediaUtils.extractM4sInfo("blob:https://example.com/id"), null);
});

test("m4sGroupKey collapses same cid+kind into one key", () => {
  assert.equal(
    mediaUtils.m4sGroupKey("https://cdn.example/1550776785-1-100022.m4s"),
    "m4s:1550776785:video",
  );
  assert.equal(
    mediaUtils.m4sGroupKey("https://cdn.example/1550776785-1-30216.m4s"),
    "m4s:1550776785:audio",
  );
  // different cid, different key
  assert.notEqual(
    mediaUtils.m4sGroupKey("https://cdn.example/1550776785-1-100022.m4s"),
    mediaUtils.m4sGroupKey("https://cdn.example/9999999999-1-100022.m4s"),
  );
  // non-m4s returns null
  assert.equal(mediaUtils.m4sGroupKey("https://cdn.example/video.mp4"), null);
});

test("coalesceMediaCandidates keeps X-style manifests and folds internal segments", () => {
  const pageURL = "https://x.com/user/status/123";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate(
        { url: "https://video.twimg.com/amplify/playlist.m3u8", mime: "application/vnd.apple.mpegurl" },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://video.twimg.com/amplify/seg-1.m4s", size: 50_000 },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://video.twimg.com/amplify/bootstrap.mp4", mime: "video/mp4", size: 904 },
        pageURL,
      ),
    ],
    "X 测试帖子",
    pageURL,
  );

  assert.equal(result.length, 2);
  assert.equal(result[0].fileExtension, "m3u8");
  assert.equal(result[1].pairKind, "stream-segment");
  assert.equal(result[1].supported, false);
  assert.equal(result[1].segmentCount, 2);
  assert.equal(result[1].fileExtension, "m4s/mp4");
});

test("coalesceMediaCandidates removes YouTube player sounds and duplicate manifests", () => {
  const pageURL = "https://www.youtube.com/watch?v=fixture";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate(
        { url: "https://www.youtube.com/s/player/abc/failure.mp3" },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://www.youtube.com/s/player/abc/open.mp3" },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://video.example/playlist.m3u8?tag=14", mime: "application/vnd.apple.mpegurl" },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://video.example/playlist.m3u8?tag=15", mime: "application/vnd.apple.mpegurl" },
        pageURL,
      ),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://rr.example.googlevideo.com/videoplayback?mime=video%2Fmp4&itag=18" },
        pageURL,
      ),
    ],
    "YouTube 测试视频",
    pageURL,
  );

  assert.equal(result.length, 1);
  assert.equal(result.filter((candidate) => candidate.format === "hls").length, 0);
  assert.equal(result.filter((candidate) => candidate.fileExtension === "mp4").length, 1);
  assert.equal(result[0].siteAdapter, "youtube");
  assert.equal(result[0].url, pageURL);
  assert.equal(result[0].supported, true);
  assert.ok(result.every((candidate) => !candidate.url.endsWith("failure.mp3")));
  assert.ok(result.every((candidate) => !candidate.url.endsWith("open.mp3")));
});

test("coalesceMediaCandidates adds one Bilibili page adapter candidate", () => {
  const pageURL = "https://www.bilibili.com/video/BV1234";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate(
        { url: "https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", mime: "video/mp4", size: 2 },
        pageURL,
      ),
    ],
    "B 站标题",
    pageURL,
  );

  assert.equal(result.length, 1);
  assert.equal(result[0].siteAdapter, "bilibili");
  assert.equal(result[0].url, pageURL);
  assert.equal(result[0].fileExtension, "mp4");
});

test("coalesceMediaCandidates adds the Bilibili adapter on the watchlater list page", () => {
  // The watchlater list page embeds the same player; the current video
  // identity lives in the bvid/oid query parameters, so it must collapse into
  // one site-resolution candidate exactly like a /video/ page, not dozens of
  // m4s fragments.
  const pageURL =
    "https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9&oid=117229555292053&spm_id_from=333.881.0.0";
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate(
        { url: "https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", mime: "video/mp4", size: 2 },
        pageURL,
      ),
    ],
    "稍后再看标题",
    pageURL,
  );

  assert.equal(result.length, 1);
  assert.equal(result[0].siteAdapter, "bilibili");
  assert.equal(result[0].url, pageURL);
});

test("coalesceMediaCandidates keeps a watchlater page without video identity unadapted", () => {
  // A bare list page has no single-video identity: synthesizing a site
  // candidate would treat the whole list as one video.
  for (const pageURL of [
    "https://www.bilibili.com/list/watchlater/",
    "https://www.bilibili.com/list/watchlater/?bvid=not-a-bvid",
    "https://www.bilibili.com/list/ml/?bvid=BV1B6bN6HEX9",
  ]) {
    const result = mediaUtils.coalesceMediaCandidates(
      [
        mediaUtils.normalizeMediaCandidate(
          { url: "https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", mime: "video/mp4", size: 2 },
          pageURL,
        ),
      ],
      "标题",
      pageURL,
    );
    assert.ok(
      result.every((candidate) => candidate.siteAdapter !== "bilibili"),
      `${pageURL} 不应合成站点候选`,
    );
  }
});

test("isBilibiliPageURL accepts exactly the pages the App adapter can resolve", () => {
  const accepted = [
    "https://www.bilibili.com/video/BV1B6bN6HEX9/",
    "https://bilibili.com/video/av12345?p=2",
    "https://www.bilibili.com/bangumi/play/ep123456",
    "https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9&oid=117229555292053",
    "https://www.bilibili.com/list/watchlater/?oid=117229555292053",
    "https://m.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9",
  ];
  const rejected = [
    "",
    "https://www.bilibili.com/list/watchlater/",
    "https://www.bilibili.com/list/watchlater/?bvid=not-a-bvid",
    "https://www.bilibili.com/list/ml/?bvid=BV1B6bN6HEX9",
    "https://www.bilibili.com/space/1",
    "https://example.com/list/watchlater/?bvid=BV1B6bN6HEX9",
    "https://notbilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9",
  ];
  for (const url of accepted) assert.equal(mediaUtils.isBilibiliPageURL(url), true, url);
  for (const url of rejected) assert.equal(mediaUtils.isBilibiliPageURL(url), false, url);
});

test("URLs without extension or MIME return empty extension (no URL guessing)", () => {
  // agedm.io-style URLs that carry no standard media extension and no
  // MIME type must NOT guess the format from URL path keywords.
  // Format detection must use technical means (HTTP Content-Type header),
  // not URL path guessing.
  const candidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://agedm.io/play/12345" },
    "https://agedm.io/watch/123",
  );
  assert.equal(candidate.fileExtension, "");
  assert.equal(candidate.format, "video");

  // /stream/ path keyword — no guessing
  const streamCandidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example.com/stream/abc" },
    "https://cdn.example.com/watch",
  );
  assert.equal(streamCandidate.fileExtension, "");

  // /video/ path keyword — no guessing
  const videoCandidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example.com/video/def" },
    "https://cdn.example.com/watch",
  );
  assert.equal(videoCandidate.fileExtension, "");

  // BUT: with a video MIME type, the extension IS detected technically
  const mimeCandidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://agedm.io/play/12345", mime: "video/mp4" },
    "https://agedm.io/watch/123",
  );
  assert.equal(mimeCandidate.fileExtension, "mp4");

  // With audio MIME type, extension is detected
  const audioCandidate = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example.com/stream/abc", mime: "audio/mpeg" },
    "https://cdn.example.com/watch",
  );
  assert.equal(audioCandidate.fileExtension, "mp3");
  assert.equal(audioCandidate.format, "audio");
});

test("codecFamily maps known prefixes to family names and hides FourCC detail", () => {
  assert.equal(mediaUtils.codecFamily("avc1.640033"), "H.264");
  assert.equal(mediaUtils.codecFamily("hev1.2.4.L153.B0"), "H.265");
  assert.equal(mediaUtils.codecFamily("hvc1.1.6.L150.B0"), "H.265");
  assert.equal(mediaUtils.codecFamily("av01.0.05M.08"), "AV1");
  assert.equal(mediaUtils.codecFamily("vp09.00.31.08"), "VP9");
  assert.equal(mediaUtils.codecFamily("mp4a.40.2"), "AAC");
  assert.equal(mediaUtils.codecFamily("opus"), "Opus");
  // For combined strings take the first comma-separated part (usually the
  // video codec).
  assert.equal(mediaUtils.codecFamily("avc1.640028,mp4a.40.2"), "H.264");
  // Unknown codecs do not show FourCC; return an empty string and let the
  // caller omit the slot.
  assert.equal(mediaUtils.codecFamily("vp8"), "");
  assert.equal(mediaUtils.codecFamily(""), "");
  assert.equal(mediaUtils.codecFamily(null), "");
});

test("variantDisplayLabel follows the unified slot grammar", () => {
  assert.equal(
    mediaUtils.variantDisplayLabel({
      width: 1920,
      height: 1080,
      fps: 60,
      codecs: "avc1.640033,mp4a.40.2",
      bandwidth: 6_500_000,
    }),
    "1080P · 60fps · H.264 · 6.5 Mbps",
  );
  // Missing slots are skipped with no "unknown" placeholder; only height
  // uses {h}p.
  assert.equal(
    mediaUtils.variantDisplayLabel({ height: 720, bandwidth: 800_000 }),
    "720p · 800 kbps",
  );
  // Non-standard resolutions fall back to W×H; unknown codecs omit the whole
  // slot.
  assert.equal(
    mediaUtils.variantDisplayLabel({ width: 1088, height: 608, codecs: "vp8" }),
    "1088×608",
  );
  // Bitrates below 1 kbps are not shown (avoiding "0 kbps" noise).
  assert.equal(
    mediaUtils.variantDisplayLabel({ width: 1280, height: 720, bandwidth: 800 }),
    "720P",
  );
  assert.equal(mediaUtils.variantDisplayLabel({}), "");
  assert.equal(mediaUtils.variantDisplayLabel(null), "");
});

test("bilibili m4s qualityLabel uses the unified grammar with codec families", () => {
  // 100xxx -> H.264 family name (the old format no longer writes AVC); this
  // formatId has no quality-table entry, so only the codec slot appears.
  assert.equal(
    mediaUtils.qualityLabel({
      url: "https://upgz.bilivideo.com/upgcxcode/1550776785-1-100022.m4s",
    }),
    "H.264",
  );
  // 30xxx is classified as AV1 by the existing heuristic; separators and
  // slot grammar stay consistent.
  assert.equal(
    mediaUtils.qualityLabel({
      url: "https://upgz.bilivideo.com/upgcxcode/1550776785-1-30080.m4s",
    }),
    "1080P · AV1",
  );
});

// —— estimateYouTubeMergedSize: the estimate must match the App's download
// formula (bv*[ext=mp4][height<=h]+ba[ext=m4a]), i.e. the best mp4 video
// track + the best m4a audio track.
const youTubeFormatsFixture = [
  // progressive: audio and video are already merged; no extra audio track.
  {
    itag: 22, width: 1280, height: 720, bitrate: 2_500_000,
    contentLength: "15000000",
    mimeType: "video/mp4; codecs=\"avc1.64001F,mp4a.40.2\"", isAdaptive: false,
  },
  // adaptive video: both mp4 and webm exist at the same height.
  {
    itag: 137, width: 1920, height: 1080, bitrate: 4_500_000,
    contentLength: "60000000", mimeType: "video/mp4; codecs=\"avc1.640028\"", isAdaptive: true,
  },
  {
    itag: 248, width: 1920, height: 1080, bitrate: 3_000_000,
    contentLength: "40000000", mimeType: "video/webm; codecs=\"vp9\"", isAdaptive: true,
  },
  {
    itag: 136, width: 1280, height: 720, bitrate: 2_000_000,
    contentLength: "25000000", mimeType: "video/mp4; codecs=\"avc1.4d401f\"", isAdaptive: true,
  },
  // adaptive audio: opus has the higher bitrate, but m4a must win (aligning
  // with ba[ext=m4a]).
  {
    itag: 140, bitrate: 129_000, contentLength: "1800000",
    mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", isAdaptive: true,
  },
  {
    itag: 251, bitrate: 160_000, contentLength: "2100000",
    mimeType: "audio/webm; codecs=\"opus\"", isAdaptive: true,
  },
];

test("YouTube merged estimate adds the best m4a audio track to the best mp4 video track", () => {
  // No height cap: 137 (60 MB) + 140 (1.8 MB).
  assert.equal(
    mediaUtils.estimateYouTubeMergedSize(youTubeFormatsFixture, null, 360),
    61_800_000,
  );
});

test("YouTube merged estimate honors the height cap of the chosen variant", () => {
  // Choosing the 720p variant must not count the 1080p track: 136 (25 MB) +
  // 140 (1.8 MB).
  assert.equal(
    mediaUtils.estimateYouTubeMergedSize(youTubeFormatsFixture, 720, 360),
    26_800_000,
  );
});

test("YouTube merged estimate prefers mp4 video over webm at the same height", () => {
  // At the same 1080p height, mp4's 137 must win over webm's 248.
  const size = mediaUtils.estimateYouTubeMergedSize(youTubeFormatsFixture, 1080, 360);
  assert.equal(size, 60_000_000 + 1_800_000);
});

test("YouTube progressive formats do not add a second audio track", () => {
  const progressiveOnly = [youTubeFormatsFixture[0], youTubeFormatsFixture[4]];
  assert.equal(
    mediaUtils.estimateYouTubeMergedSize(progressiveOnly, null, 360),
    15_000_000,
  );
});

test("YouTube merged estimate falls back to duration times bitrate without contentLength", () => {
  const formats = [
    { width: 640, height: 360, bitrate: 800_000, mimeType: "video/mp4", isAdaptive: true },
    { bitrate: 128_000, mimeType: "audio/mp4", isAdaptive: true },
  ];
  // 100s × 800 kbps / 8 = 10 MB; 100s × 128 kbps / 8 = 1.6 MB.
  assert.equal(mediaUtils.estimateYouTubeMergedSize(formats, null, 100), 11_600_000);
});

test("YouTube merged estimate returns null when no track can be sized", () => {
  const formats = [{ width: 640, height: 360, mimeType: "video/mp4", isAdaptive: true }];
  assert.equal(mediaUtils.estimateYouTubeMergedSize(formats, null, null), null);
  assert.equal(mediaUtils.estimateYouTubeMergedSize([], null, 100), null);
  assert.equal(mediaUtils.estimateYouTubeMergedSize(null, null, 100), null);
});

test("YouTube merged estimate falls back to webm pools when no mp4 tracks exist", () => {
  const formats = [
    {
      width: 1920, height: 1080, bitrate: 3_000_000, contentLength: "40000000",
      mimeType: "video/webm; codecs=\"vp9\"", isAdaptive: true,
    },
    {
      bitrate: 160_000, contentLength: "2100000",
      mimeType: "audio/webm; codecs=\"opus\"", isAdaptive: true,
    },
  ];
  assert.equal(mediaUtils.estimateYouTubeMergedSize(formats, null, 360), 42_100_000);
});

test("YouTube single-video URL rules are unified and reject missing IDs (§4.5)", () => {
  // Valid: /watch?v=<id>, /shorts/<id>, /live/<id>, and youtu.be/<id>.
  assert.equal(
    mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v=abc12345_-"),
    "abc12345_-",
  );
  assert.equal(
    mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?list=PL1&v=abc123"),
    "abc123",
  );
  assert.equal(
    mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/shorts/sh0rt1d"),
    "sh0rt1d",
  );
  assert.equal(
    mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/live/liv3id99"),
    "liv3id99",
  );
  assert.equal(
    mediaUtils.youTubeVideoIDFromURL("https://youtu.be/sh0rt1d"),
    "sh0rt1d",
  );

  // Missing ID: bare /watch, empty /live/, empty /shorts/, empty v, and
  // non-YouTube domains.
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v="), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/live/"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/shorts/"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://example.com/watch?v=abc123"), null);

  // §4.3: same sample set as the App-side isYouTubePage/isValidVideoID; the
  // verdicts must match exactly: too short, illegal characters, extra paths,
  // and youtu.be short links.
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v=abc_-12345"), "abc_-12345");
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v=a"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v=ab!d"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/watch?v=abcd!efgh"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/live/abc"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://www.youtube.com/live/liv3id99/extra"), "liv3id99");
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://youtu.be/"), null);
  assert.equal(mediaUtils.youTubeVideoIDFromURL("https://youtu.be/abc"), null);

  // Shallow candidate synthesis and deep in-page parsing share the same
  // verdict.
  assert.equal(mediaUtils.isYouTubeWatchPage("https://www.youtube.com/watch?v=abc123"), true);
  assert.equal(mediaUtils.isYouTubeWatchPage("https://www.youtube.com/watch"), false);
  assert.equal(mediaUtils.isYouTubeWatchPage("https://www.youtube.com/feed/subscriptions"), false);
});

test("image candidates carry real image format instead of unknown", () => {
  // Images are downloadable media too: format and extension must not degrade
  // to "unknown format" (observed on x.com).
  const byURL = mediaUtils.normalizeMediaCandidate(
    { url: "https://pbs.twimg.com/media/photo.jpg" },
    "https://x.com/status/1",
  );
  assert.equal(byURL.format, "image");
  assert.equal(byURL.fileExtension, "jpg");
  assert.equal(byURL.filenameHint, "photo.jpg");

  const byMime = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example/blob?id=1", mime: "image/png" },
    "https://example.com/",
  );
  assert.equal(byMime.format, "image");
  assert.equal(byMime.fileExtension, "png");

  const webp = mediaUtils.normalizeMediaCandidate(
    { url: "https://cdn.example/pic.webp?format=webp" },
    "https://example.com/",
  );
  assert.equal(webp.fileExtension, "webp");
});

test("display sort puts video/audio before images across sites", () => {
  // Observed on x.com: avatar/emoji images ranked ahead of videos. Display
  // sorting must prioritize video/audio candidates and push decorative
  // images to the end (a rule consistent across sites).
  const image = { url: "https://pbs.twimg.com/profile_images/1/a.jpg", format: "image", mime: "image/jpeg", confidence: "headers" };
  const emoji = { url: "https://abs.twimg.com/emoji/v2/svg/1f514.svg", format: "image", mime: "image/svg+xml", confidence: "headers" };
  const video = { url: "https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/x.mp4", format: "video", mime: "video/mp4", confidence: "headers" };
  const mse = { url: "mse:player", format: "blob", mime: "video/mp4" };
  const audio = { url: "https://cdn.example/a.mp3", format: "audio", mime: "audio/mpeg", confidence: "fetch" };
  const site = { url: "https://www.youtube.com/watch?v=abc123", siteAdapter: "youtube" };

  const sorted = mediaUtils.sortCandidatesForDisplay([image, emoji, video, audio, mse, site]);
  const urls = sorted.map((candidate) => candidate.url);
  // Video kinds (site adapters / direct videos / MSE players) all come before
  // images.
  assert.ok(urls.indexOf(video.url) < urls.indexOf(image.url));
  assert.ok(urls.indexOf(mse.url) < urls.indexOf(emoji.url));
  assert.ok(urls.indexOf(site.url) < urls.indexOf(image.url));
  // Audio also comes before images.
  assert.ok(urls.indexOf(audio.url) < urls.indexOf(emoji.url));
  // Images keep their original stable order among themselves.
  assert.ok(urls.indexOf(image.url) < urls.indexOf(emoji.url));
});

test("display sort keeps confidence order within the same media priority", () => {
  const domVideo = { url: "https://cdn.example/v1.mp4", format: "video", confidence: "dom" };
  const fetchVideo = { url: "https://cdn.example/v2.mp4", format: "video", confidence: "fetch" };
  const headersImage = { url: "https://cdn.example/i1.jpg", format: "image", confidence: "headers" };
  const sorted = mediaUtils.sortCandidatesForDisplay([fetchVideo, headersImage, domVideo]);
  assert.deepEqual(sorted.map((candidate) => candidate.url), [
    "https://cdn.example/v1.mp4",
    "https://cdn.example/v2.mp4",
    "https://cdn.example/i1.jpg",
  ]);
});

test("display sort pins site adapter candidates above observed ones", () => {
  // B 站实测：适配器主候选（带规格选择「MP4 · 最高规格」）没有 confidence
  // 字段，曾在视频类内被 headers/extension 置信的观察型候选挤到列表中间。
  // 站点适配候选必须置顶；已配对 m4s 排在普通观察型视频之前。
  const adapter = { url: "https://www.bilibili.com/video/BV1sogS6yEpm/", siteAdapter: "bilibili", format: "video" };
  const domVideo = { url: "https://cdn.example/v1.mp4", format: "video", confidence: "dom" };
  const headersVideo = { url: "https://cdn.example/v2.mp4", format: "video", confidence: "headers" };
  const pair = { url: "https://cdn.example/v3.m4s", format: "video", pairKind: "m4s-pair", confidence: "extension" };
  const audio = { url: "https://cdn.example/a.mp3", format: "audio", confidence: "dom" };

  const sorted = mediaUtils.sortCandidatesForDisplay([headersVideo, domVideo, pair, audio, adapter]);
  assert.equal(sorted[0].url, adapter.url);
  const at = (url) => sorted.findIndex((candidate) => candidate.url === url);
  // 配对 m4s 先于普通观察型视频；同层内按可信度降序。
  assert.ok(at(pair.url) < at(domVideo.url));
  assert.ok(at(domVideo.url) < at(headersVideo.url));
  // 视频类仍整体先于音频。
  assert.ok(at(headersVideo.url) < at(audio.url));
});

test("element scope only keeps explicitly attributed audio and video resources", () => {
  const candidates = [
    { url: "https://cdn.example/direct.mp4#quality=720", format: "video" },
    { url: "https://cdn.example/audio.m4a", format: "audio" },
    { url: "https://cdn.example/cover.jpg", format: "image" },
    { url: "https://cdn.example/unowned.m3u8", format: "hls" },
    { url: "https://cdn.example/unowned.mpd", format: "dash" },
    { url: "https://cdn.example/unowned", mime: "video/mp4" },
    { url: "https://cdn.example/unowned-page", siteAdapter: "bilibili" },
    { url: "blob:https://example.com/unowned", format: "blob" },
    { url: "mse:player", format: "blob" },
    { url: "https://cdn.example/other.m4s", pairKind: "m4s-pair", format: "video" },
  ];
  const own = new Set(["https://cdn.example/direct.mp4#other", "https://cdn.example/audio.m4a", "https://cdn.example/cover.jpg"]);
  assert.deepEqual(Array.from(mediaUtils.filterCandidatesForElementScope(candidates, own)), candidates.slice(0, 2));
  assert.equal(mediaUtils.filterCandidatesForElementScope(candidates, null).length, 0);
  assert.equal(mediaUtils.filterCandidatesForElementScope(null, own).length, 0);
});

test("element scope preserves signed query identity", () => {
  const candidates = [
    { url: "https://cdn.example/video.mp4?token=one", format: "video" },
    { url: "https://cdn.example/video.mp4?token=two", format: "video" },
  ];
  assert.deepEqual(Array.from(mediaUtils.filterCandidatesForElementScope(candidates, [candidates[0].url])), [candidates[0]]);
});

test("formatBytes matches App ByteCountFormatter decimal units, rounding, and precision", () => {
  // 指定规则与核心样本
  assert.equal(mediaUtils.formatBytes(1_234), "1 KB");
  assert.equal(mediaUtils.formatBytes(1_234_567), "1.2 MB");
  assert.equal(mediaUtils.formatBytes(123_456_789), "123.5 MB");
  assert.equal(mediaUtils.formatBytes(165_675_008), "165.7 MB");
  assert.equal(mediaUtils.formatBytes(578_000_000), "578 MB");
  assert.equal(mediaUtils.formatBytes(1_288_490_188), "1.29 GB");
  assert.equal(mediaUtils.formatBytes(123_456_789_000), "123.46 GB");
  assert.equal(mediaUtils.formatBytes(1_234_567_890_000), "1.23 TB");

  // 达到 1000 的进位晋级（TB 不再晋级）
  assert.equal(mediaUtils.formatBytes(999_500), "1 MB");
  assert.equal(mediaUtils.formatBytes(999_950_000), "1 GB");
  assert.equal(mediaUtils.formatBytes(999_995_000_000), "1 TB");
  assert.equal(mediaUtils.formatBytes(1_000_000_000_000_000), "1000 TB");

  // 单位边界 (1000 进制，最大单位 TB)
  assert.equal(mediaUtils.formatBytes(0), "0 B");
  assert.equal(mediaUtils.formatBytes(500), "500 B");
  assert.equal(mediaUtils.formatBytes(999), "999 B");
  assert.equal(mediaUtils.formatBytes(1_000), "1 KB");
  assert.equal(mediaUtils.formatBytes(999_000), "999 KB");
  assert.equal(mediaUtils.formatBytes(1_000_000), "1 MB");
  assert.equal(mediaUtils.formatBytes(999_000_000), "999 MB");
  assert.equal(mediaUtils.formatBytes(1_000_000_000), "1 GB");
  assert.equal(mediaUtils.formatBytes(999_000_000_000), "999 GB");
  assert.equal(mediaUtils.formatBytes(1_000_000_000_000), "1 TB");

  // 尾零去除 (整数与多余小数尾零不显示)
  assert.equal(mediaUtils.formatBytes(1_200_000), "1.2 MB");
  assert.equal(mediaUtils.formatBytes(1_200_000_000), "1.2 GB");
  assert.equal(mediaUtils.formatBytes(1_200_000_000_000), "1.2 TB");

  // 非法输入一律返回 null
  assert.equal(mediaUtils.formatBytes(-1), null);
  assert.equal(mediaUtils.formatBytes(-1000), null);
  assert.equal(mediaUtils.formatBytes(12.34), null);
  assert.equal(mediaUtils.formatBytes(NaN), null);
  assert.equal(mediaUtils.formatBytes(Infinity), null);
  assert.equal(mediaUtils.formatBytes(-Infinity), null);
  assert.equal(mediaUtils.formatBytes(null), null);
  assert.equal(mediaUtils.formatBytes(undefined), null);
  assert.equal(mediaUtils.formatBytes(""), null);
  assert.equal(mediaUtils.formatBytes("1000"), null);
  assert.equal(mediaUtils.formatBytes({}), null);
  assert.equal(mediaUtils.formatBytes([]), null);
  assert.equal(mediaUtils.formatBytes(true), null);
});

test("element scope isolates main and reply media even when they share a CDN", () => {
  const main = { url: "https://video.example/main.mp4", format: "video" };
  const reply = { url: "https://video.example/reply.mp4", format: "video" };
  const playlist = { url: "https://video.example/reply.m3u8", format: "hls" };
  const input = [main, reply, playlist];
  assert.deepEqual(Array.from(mediaUtils.filterCandidatesForElementScope(input, [main.url])), [main]);
  assert.deepEqual(Array.from(mediaUtils.filterCandidatesForElementScope(input, [reply.url])), [reply]);
  assert.equal(mediaUtils.filterCandidatesForElementScope(input, []).length, 0);
  assert.equal(input.length, 3, "Popup's page candidates remain intact");
});

test("coalescing preserves separate players whose manifest URLs differ only in query", () => {
  const candidates = [
    { url: "https://cdn.example/playlist.m3u8?video=main", format: "hls", supported: true },
    { url: "https://cdn.example/playlist.m3u8?video=reply", format: "hls", supported: true },
  ];
  const merged = mediaUtils.coalesceMediaCandidates(candidates, "Thread", "https://example.com/thread");
  assert.equal(merged.length, 2);
  for (const candidate of candidates) {
    assert.deepEqual(Array.from(mediaUtils.filterCandidatesForElementScope(merged, [candidate.url]), c => c.url), [candidate.url]);
  }
});

test("coalesce merges video/audio split streams into one FFmpeg-muxed pair row", () => {
  const video = {
    url: "https://v95-web-sz.douyinvod.com/d88e4c739f5045b9a0968e6436d20a4d/6aaa6547/video/tos/cn/tos-cn-vd-0026/o0haSIp3CakTAsA3iiqvpgIY5ikYAqABoAPhQ/media-video-hvc1/",
    format: "video", mime: "video/mp4", fileExtension: "mp4", supported: true, size: 95496286, duration: 461.2,
    filenameHint: "media-video-hvc1.mp4", displayName: "media-video-hvc1",
  };
  const audio = {
    url: "https://v95-web-sz.douyinvod.com/0c8f778a65e27ff0a84e1bb04c058305/6aaa6547/video/tos/cn/tos-cn-vd-0026/osBNAQRm7FEAuAmARqEDzGfCAAsegSFxAN1GV9/media-audio-und-mp4a/",
    format: "video", mime: "video/mp4", fileExtension: "mp4", supported: true, size: 3616338, duration: 461.4,
    filenameHint: "media-audio-und-mp4a.mp4", displayName: "media-audio-und-mp4a",
  };
  video.mediaOwner = audio.mediaOwner = "blob:https://www.douyin.com/one";
  const merged = mediaUtils.coalesceMediaCandidates([video, audio], "一锅山里的鲜味", "https://www.douyin.com/jingxuan");
  const pairs = merged.filter((c) => c.pairKind === "m4s-pair");
  assert.equal(pairs.length, 1, "同批次同长度的视频流+音频流应合成一行");
  assert.equal(pairs[0].pairVideoUrl, video.url);
  assert.equal(pairs[0].pairAudioUrl, audio.url);
  assert.equal(pairs[0].filenameHint, "一锅山里的鲜味.mp4");
  assert.equal(pairs[0].filenameHintSource, "titleDerived");
  assert.equal(
    merged.some((c) => c.url === audio.url && c.pairKind !== "m4s-pair"),
    false,
    "音频流不得再作为独立行出现",
  );
});

test("split-stream pairing refuses cross-batch and video-only groups", () => {
  const videoA = {
    url: "https://v95-web-sz.douyinvod.com/hash1/6aaa6547/video/tos/cn/tos-cn-vd-0026/idA/media-video-hvc1/",
    format: "video", mime: "video/mp4", supported: true, size: 90_000_000, duration: 461,
  };
  const audioOtherBatch = {
    url: "https://v95-web-sz.douyinvod.com/hash2/6aaa9999/video/tos/cn/tos-cn-vd-0026/idA/media-audio-und-mp4a/",
    format: "video", mime: "video/mp4", supported: true, size: 3_600_000, duration: 461,
  };
  const merged = mediaUtils.coalesceMediaCandidates([videoA, audioOtherBatch], "", "https://www.douyin.com/jingxuan");
  assert.equal(
    merged.some((c) => c.pairKind === "m4s-pair"),
    false,
    "不同批次目录的流不得配对",
  );
});

test("split-stream pairing works without duration and vetoes duration conflicts", () => {
  const base = "https://v95-web-sz.douyinvod.com";
  const videoNoDur = {
    url: `${base}/hashv/6aaa7000/video/tos/cn/tos-cn-vd-0026/idV/media-video-hvc1/`,
    format: "video", mime: "video/mp4", supported: true, size: 90_000_000,
  };
  const audioNoDur = {
    url: `${base}/hasha/6aaa7000/video/tos/cn/tos-cn-vd-0026/idA/media-audio-und-mp4a/`,
    format: "video", mime: "video/mp4", supported: true, size: 3_600_000,
  };
  videoNoDur.mediaOwner = audioNoDur.mediaOwner = "blob:https://www.douyin.com/one";
  const merged = mediaUtils.coalesceMediaCandidates([videoNoDur, audioNoDur], "", "https://www.douyin.com/jingxuan");
  const pair = merged.find((c) => c.pairKind === "m4s-pair");
  assert.ok(pair, "observed tracks with the same player owner pair without duration");
  assert.equal(pair.filenameHintSource, "urlPath", "no real title: the kept URL-tail hint must not claim titleDerived");
  assert.equal(pair.filenameHint, undefined, "gallery pairs must not bake a branding hint");
  assert.equal(pair.pairVideoUrl, videoNoDur.url);
  assert.equal(pair.pairAudioUrl, audioNoDur.url);

  const videoLong = { ...videoNoDur, duration: 461 };
  const audioShort = { ...audioNoDur, duration: 120 };
  const merged2 = mediaUtils.coalesceMediaCandidates([videoLong, audioShort], "", "https://www.douyin.com/jingxuan");
  assert.equal(
    merged2.some((c) => c.pairKind === "m4s-pair"),
    false,
    "同批次但时长冲突超过 2s 的流不得配对",
  );
});

test("coalescing an adapter with its raw page observation remains one row on every pass", () => {
  const url = "https://www.bilibili.com/video/BV1example";
  const raw = mediaUtils.normalizeMediaCandidate({url, sizeProbeFailed:true});
  const once = mediaUtils.coalesceMediaCandidates([raw], "当前视频", url);
  const twice = mediaUtils.coalesceMediaCandidates([...once, raw], "其他文案", url);
  assert.equal(once.length, 1); assert.equal(twice.length, 1);
  assert.equal(twice[0].siteAdapter, "bilibili");
});

test("split streams require one proven owner, not equal expiry directories or captions", () => {
  const video = {url:"https://v1.douyinvod.com/hash/expiry/media-video-hvc1/",format:"video"};
  const audio = {url:"https://v1.douyinvod.com/hash2/expiry/media-audio-mp4a/",format:"video"};
  const pair = list => mediaUtils.coalesceMediaCandidates(list).filter(c=>c.pairKind === "m4s-pair");
  assert.equal(pair([video,audio]).length,0);
  assert.equal(pair([{...video,mediaOwner:"a"},{...audio,mediaOwner:"b"}]).length,0);
  const paired = pair([{...video,mediaOwner:"a"},{...audio,url:audio.url.replace('/expiry/','/other-expiry/'),mediaOwner:"a"}]);
  assert.equal(paired.length,1);
  assert.equal(mediaUtils.filterCandidatesForElementScope(paired,[video.url]).length,0);
  assert.equal(mediaUtils.filterCandidatesForElementScope(paired,[video.url,paired[0].pairAudioUrl]).length,1);
});

// X/Twitter separate-audio masters: the player requests the master playlist
// plus every rendition playlist (video variants and the mp4a audio track).
// The rendition rows must fold into the master row instead of showing up as
// duplicate "HLS 流媒体" rows (a muted video variant or a bare audio list).
test("coalescing folds HLS rendition playlists under their observed master", () => {
  const master = "https://video.twimg.com/amplify_video/2099453445837299712/pl/ILEhdo8JQNMg-7Ns.m3u8";
  const videoRendition = "https://video.twimg.com/amplify_video/2099453445837299712/pl/avc1/720x1270/28Fj-P9P9fLr2ApF.m3u8";
  const audioRendition = "https://video.twimg.com/amplify_video/2099453445837299712/pl/mp4a/128000/kJcJOyJOyWx5mWq-.m3u8";
  const merged = mediaUtils.coalesceMediaCandidates(
    [
      { url: master, format: "hls", supported: true },
      { url: videoRendition, format: "hls", supported: true },
      { url: audioRendition, format: "hls", supported: true },
    ],
    "推文视频",
    "https://x.com/user/status/123",
  );
  assert.deepEqual(
    Array.from(merged, (candidate) => candidate.url),
    [master],
    "变体与音频清单折叠进 master 行",
  );
});

test("coalescing never folds two HLS masters sharing one directory", () => {
  const masterA = "https://video.twimg.com/amplify_video/111/pl/tokenA.m3u8";
  const masterB = "https://video.twimg.com/amplify_video/111/pl/tokenB.m3u8";
  const merged = mediaUtils.coalesceMediaCandidates(
    [
      { url: masterA, format: "hls", supported: true },
      { url: masterB, format: "hls", supported: true },
    ],
    "双视频",
    "https://x.com/user/status/456",
  );
  assert.equal(merged.length, 2, "同目录的两个 master 深度相同，互不折叠");
});

test("coalescing folds HLS renditions by host and directory prefix only", () => {
  const master = "https://video.twimg.com/amplify_video/111/pl/tokenA.m3u8";
  const otherHost = "https://backup.example.com/amplify_video/111/pl/deeper/v.m3u8";
  const merged = mediaUtils.coalesceMediaCandidates(
    [
      { url: master, format: "hls", supported: true },
      { url: otherHost, format: "hls", supported: true },
    ],
    "跨主机",
    "https://x.com/user/status/789",
  );
  assert.equal(merged.length, 2, "不同 host 的清单不折叠");
});
