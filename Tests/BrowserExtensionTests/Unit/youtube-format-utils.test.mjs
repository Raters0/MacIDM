import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// Both scripts run in one context, mirroring the manifest load order:
// media-utils.js first, youtube-format-utils.js second (it reads
// global.MacIDMMediaUtils lazily for size estimates and labels).
const mediaUtilsSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/youtube-format-utils.js", import.meta.url),
  "utf8",
);
const i18nSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/i18n.js", import.meta.url),
  "utf8",
);
const localeZhSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/locale-zh-cn.js", import.meta.url),
  "utf8",
);
const localeEnSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/locale-en.js", import.meta.url),
  "utf8",
);

function playerResponseFixture({ videoId = "abc123", lengthSeconds = "600", details = {} } = {}) {
  return {
    // 真实 YouTube 响应总携带显式直播标志；测试 fixture 同样显式声明，
    // 缺失标志会被视为“未知”并强制回退 App 检查（§3.1）。
    videoDetails: { videoId, lengthSeconds, isLive: false, isUpcomingLive: false, ...details },
    streamingData: {
      formats: [
        {
          itag: 18,
          width: 640,
          height: 360,
          bitrate: 500_000,
          contentLength: "40000000",
          mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
          fps: 30,
        },
      ],
      adaptiveFormats: [
        {
          itag: 137,
          width: 1920,
          height: 1080,
          bitrate: 3_000_000,
          contentLength: "240000000",
          mimeType: 'video/mp4; codecs="avc1.640028"',
          fps: 30,
        },
        {
          itag: 248,
          width: 1920,
          height: 1080,
          bitrate: 2_500_000,
          mimeType: 'video/webm; codecs="vp9"',
          fps: 30,
        },
        {
          itag: 136,
          width: 1280,
          height: 720,
          bitrate: 1_500_000,
          contentLength: "120000000",
          mimeType: 'video/mp4; codecs="avc1.4d401f"',
          fps: 30,
        },
        {
          itag: 140,
          bitrate: 128_000,
          contentLength: "9600000",
          mimeType: 'audio/mp4; codecs="mp4a.40.2"',
        },
      ],
    },
  };
}

function fakeDocument({ flexy = null, scripts = [] } = {}) {
  return {
    querySelector(selector) {
      return selector === "ytd-watch-flexy" ? flexy : null;
    },
    querySelectorAll(selector) {
      return selector === "script" ? scripts : [];
    },
  };
}

function createContext({ document, location, ytInitialPlayerResponse } = {}) {
  const context = vm.createContext({ URL, URLSearchParams });
  context.globalThis = context;
  if (document !== undefined) context.document = document;
  if (location !== undefined) context.location = location;
  if (ytInitialPlayerResponse !== undefined) {
    context.ytInitialPlayerResponse = ytInitialPlayerResponse;
  }
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(source, context);
  return context;
}

// Results live in the vm realm; round-trip them through JSON so
// assert.deepEqual compares plain host-realm values instead of failing on
// cross-realm prototypes.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test("videoIdFromPageURL extracts watch, shorts and live IDs, rejects non-video pages", () => {
  const context = createContext();
  const formats = context.MacIDMYouTubeFormats;

  assert.equal(formats.videoIdFromPageURL("https://www.youtube.com/watch?v=abc123"), "abc123");
  assert.equal(formats.videoIdFromPageURL("https://www.youtube.com/shorts/xyz98765"), "xyz98765");
  assert.equal(formats.videoIdFromPageURL("https://www.youtube.com/live/liv3id99"), "liv3id99");
  assert.equal(formats.videoIdFromPageURL("https://www.youtube.com/"), null);
  assert.equal(formats.videoIdFromPageURL("not a url"), null);
});

test("extractPageQualities returns normalized variants from the page player response", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture(),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );

  assert.equal(result.ok, true);
  assert.equal(result.videoId, "abc123");
  // Sorted by height desc; 1080 mp4 + 1080 webm are distinct variants.
  assert.deepEqual(
    plain(result.variants.map((variant) => variant.height)),
    [1080, 1080, 720, 360],
  );

  const [top] = result.variants;
  // The variant URL carries the verified itag so the download backend can
  // lock the exact codec: 1080 H.264 → itag 137, video-only (no `a=1`).
  assert.equal(top.url, "https://www.youtube.com/watch?v=abc123#height=1080&itag=137");
  assert.equal(top.width, 1920);
  assert.equal(top.bandwidth, 3_000_000);
  assert.equal(top.fileExtension, "mp4");
  assert.equal(top.fps, 30);
  assert.equal(top.duration, 600);
  // Merged size estimate mirrors the exact selector (itag 137 + best m4a).
  assert.equal(top.estimatedSize, 249_600_000);
  // Label grammar shared with the App/overlay rendering path.
  assert.equal(top.label, "1080P · 30fps · H.264 · 3.0 Mbps");
});

test("same-height variants carry distinct itags so codec selection is real", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture(),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, true);
  const [h264, vp9] = result.variants;
  assert.equal(h264.height, vp9.height);
  // Different codec/container picks must not collapse into one request.
  assert.notEqual(h264.url, vp9.url);
  assert.ok(h264.url.endsWith("#height=1080&itag=137"));
  assert.ok(vp9.url.endsWith("#height=1080&itag=248"));
  // itag 248 (vp9) has no contentLength: estimate falls back to
  // bitrate × duration + best m4a audio track.
  assert.equal(vp9.estimatedSize, Math.round((2_500_000 * 600) / 8) + 9_600_000);
});

test("variant fragments replace a pre-existing page fragment instead of appending", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture(),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123#t=90",
  );
  assert.equal(result.ok, true);
  // The MacIDM selection fragment replaces the page's own `#t=90`; a
  // doubled fragment would make the runner drop the user's selection.
  assert.equal(
    result.variants[0].url,
    "https://www.youtube.com/watch?v=abc123#height=1080&itag=137",
  );
});

test("progressive variants mark their built-in audio track", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture(),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  const progressive = result.variants.find((variant) => variant.height === 360);
  // itag 18 carries its own audio (`a=1`), so the runner must not stack a
  // second m4a track on top.
  assert.ok(progressive.url.endsWith("#height=360&itag=18&a=1"));
  // Progressive estimate is the single track's own size.
  assert.equal(progressive.estimatedSize, 40_000_000);
});

test("extractPageQualities refuses stale data when the page navigated to another video", () => {
  // The requested URL targets video B while the page still holds video A:
  // the shared module must never hand A's variants to B's candidate.
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture(),
  });

  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=next456",
  );
  assert.deepEqual(plain(result), { ok: false, reason: "urlMismatch" });
});

test("extractPageQualities reports structured reasons for missing data", () => {
  const missing = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
  });
  assert.deepEqual(
    plain(missing.MacIDMYouTubeFormats.extractPageQualities("https://www.youtube.com/watch?v=abc123")),
    { ok: false, reason: "noPlayerData" },
  );
  assert.deepEqual(
    plain(missing.MacIDMYouTubeFormats.extractPageQualities("https://www.youtube.com/feed/subscriptions")),
    { ok: false, reason: "notYouTubePage" },
  );

  const noFormats = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: {
      videoDetails: { videoId: "abc123", isLive: false, isUpcomingLive: false },
      streamingData: {},
    },
  });
  assert.deepEqual(
    plain(noFormats.MacIDMYouTubeFormats.extractPageQualities("https://www.youtube.com/watch?v=abc123")),
    { ok: false, reason: "noFormats" },
  );
});

test("extractPageQualities falls back to scanning script tags for the player response", () => {
  const embedded = playerResponseFixture();
  const context = createContext({
    document: fakeDocument({
      scripts: [{ textContent: `var ytInitialPlayerResponse = ${JSON.stringify(embedded)};` }],
    }),
    location: { search: "?v=abc123" },
  });

  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, true);
  assert.equal(result.videoId, "abc123");
  assert.ok(result.variants.length > 0);
});

test("extractPageQualities prefers the live watch player data over the initial response", () => {
  // SPA navigation: ytd-watch-flexy.playerData holds the CURRENT video while
  // window.ytInitialPlayerResponse still belongs to the previous one.
  const stale = playerResponseFixture({ videoId: "old111" });
  const fresh = playerResponseFixture({ videoId: "new222" });
  const flexy = { playerData: fresh };
  const context = createContext({
    document: fakeDocument({ flexy }),
    location: { search: "?v=new222" },
    ytInitialPlayerResponse: stale,
  });

  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=new222",
  );
  assert.equal(result.ok, true);
  assert.equal(result.videoId, "new222");
});

test("dedup keeps the best fps/bitrate within the same height+container+codec group", () => {
  const context = createContext();
  const pr = {
    videoDetails: { videoId: "abc123", lengthSeconds: "600" },
    streamingData: {
      formats: [],
      adaptiveFormats: [
        {
          itag: 137,
          width: 1920,
          height: 1080,
          bitrate: 3_000_000,
          mimeType: 'video/mp4; codecs="avc1.640028"',
          fps: 30,
        },
        {
          itag: 299,
          width: 1920,
          height: 1080,
          bitrate: 5_000_000,
          mimeType: 'video/mp4; codecs="avc1.64002a"',
          fps: 60,
        },
      ],
    },
  };

  const formats = context.MacIDMYouTubeFormats.formatsFromPlayerResponse(pr);
  // 同为 1080 MP4 H.264：保留帧率更高的 299，而不是先出现的 137；
  // 选中项的精确 itag 原样携带（technical-spec §3.4）。
  assert.equal(formats.length, 1);
  assert.equal(formats[0].itag, 299);
  assert.equal(formats[0].fps, 60);
});

test("dedup keeps distinct codec families that share height and container", () => {
  const context = createContext();
  const pr = {
    videoDetails: { videoId: "abc123", lengthSeconds: "600" },
    streamingData: {
      formats: [],
      adaptiveFormats: [
        {
          itag: 137,
          width: 1920,
          height: 1080,
          bitrate: 3_000_000,
          mimeType: 'video/mp4; codecs="avc1.640028"',
          fps: 30,
        },
        {
          itag: 399,
          width: 1920,
          height: 1080,
          bitrate: 2_000_000,
          mimeType: 'video/mp4; codecs="av01.0.08M.08"',
          fps: 30,
        },
        {
          itag: 248,
          width: 1920,
          height: 1080,
          bitrate: 2_500_000,
          mimeType: 'video/webm; codecs="vp9"',
          fps: 30,
        },
      ],
    },
  };

  const formats = context.MacIDMYouTubeFormats.formatsFromPlayerResponse(pr);
  // H.264/AV1 are both MP4 and VP9 is WebM: the three codec families are
  // distinct choices and must not be collapsed.
  assert.deepEqual(
    plain(formats.map((f) => f.itag).sort((a, b) => a - b)),
    [137, 248, 399],
  );
});

test("dedup prefers the better adaptive track over an earlier progressive one", () => {
  const context = createContext();
  const pr = {
    videoDetails: { videoId: "abc123", lengthSeconds: "600" },
    streamingData: {
      // progressive 常排在 adaptive 之前；同族同高度时不得用「第一项」遮蔽更好项。
      formats: [
        {
          itag: 22,
          width: 1280,
          height: 720,
          bitrate: 1_500_000,
          mimeType: 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
          fps: 30,
        },
      ],
      adaptiveFormats: [
        {
          itag: 136,
          width: 1280,
          height: 720,
          bitrate: 2_500_000,
          mimeType: 'video/mp4; codecs="avc1.4d401f"',
          fps: 30,
        },
      ],
    },
  };

  const formats = context.MacIDMYouTubeFormats.formatsFromPlayerResponse(pr);
  // Both are 720 MP4 H.264: at the same framerate compare bitrates and keep
  // the higher adaptive 136.
  assert.equal(formats.length, 1);
  assert.equal(formats[0].itag, 136);
});

test("resolveYouTubeQualities serves page data without calling the App", async () => {
  const context = createContext();
  const variants = [{ height: 1080, label: "1080p" }];
  let appCalls = 0;

  const result = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => ({ ok: true, variants }),
    requestAppInspection: async () => {
      appCalls += 1;
      return { ok: true, variants: [] };
    },
  });

  assert.deepEqual(plain(result), { ok: true, variants, source: "page" });
  assert.equal(appCalls, 0);
});

test("resolveYouTubeQualities falls back to the App when the page has no data", async () => {
  const context = createContext();
  const appVariants = [{ height: 720, label: "720p" }];
  let pageCalls = 0;

  const viaRejection = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => {
      pageCalls += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    requestAppInspection: async () => ({ ok: true, variants: appVariants }),
  });
  assert.deepEqual(plain(viaRejection), { ok: true, variants: appVariants, source: "app" });

  // A throwing page reader (content script unreachable) also falls back.
  const viaThrow = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => {
      pageCalls += 1;
      throw new Error("message channel closed");
    },
    requestAppInspection: async () => ({ ok: true, variants: appVariants }),
  });
  assert.deepEqual(plain(viaThrow), { ok: true, variants: appVariants, source: "app" });
  assert.equal(pageCalls, 2);
});

test("resolveYouTubeQualities propagates the structured App failure", async () => {
  const context = createContext();

  const result = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => ({ ok: false, reason: "noFormats" }),
    requestAppInspection: async () => ({
      ok: false,
      timedOut: true,
      message: "MEDIA_NETWORK_FAILURE",
    }),
  });

  assert.deepEqual(plain(result), {
    ok: false,
    timedOut: true,
    message: "MEDIA_NETWORK_FAILURE",
    source: "app",
  });
});

// §3.1: in-page parsing must decide live status first; the mere presence of
// "formats" must not be treated as VOD.
test("extractPageQualities blocks a currently live stream even when formats exist", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture({
      details: { isLive: true, isLiveContent: true },
    }),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported");
  assert.equal(result.livePhase, "currentlyLive");
});

test("extractPageQualities blocks an upcoming live stream", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture({
      details: { isUpcomingLive: true, isLiveContent: true },
    }),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported");
  assert.equal(result.livePhase, "upcoming");
});

test("extractPageQualities blocks live content whose replay is not generated yet", () => {
  const pr = {
    videoDetails: {
      videoId: "abc123",
      lengthSeconds: "0",
      isLive: false,
      isUpcomingLive: false,
      isLiveContent: true,
    },
    // 没有可下载轨道：回放尚未生成。
  };
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: pr,
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported");
  assert.equal(result.livePhase, "replayNotReady");
});

test("extractPageQualities allows an ended live replay with formats", () => {
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: playerResponseFixture({
      details: { isLiveContent: true },
    }),
  });
  const result = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, true);
  assert.ok(result.variants.length > 0);
});

test("resolveYouTubeQualities short-circuits liveUnsupported without calling the App (§P2-2)", async () => {
  const context = createContext();
  let appCalls = 0;

  const result = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => ({
      ok: false,
      reason: "liveUnsupported",
      livePhase: "currentlyLive",
    }),
    requestAppInspection: async () => {
      appCalls += 1;
      return { ok: true, variants: [{ height: 1080 }] };
    },
  });

  // A definitively identified live-stream block must not trigger the 30-60
  // second App fallback.
  assert.equal(appCalls, 0);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported");
  assert.equal(result.livePhase, "currentlyLive");
  assert.equal(result.source, "page");
  assert.ok(result.message, "structured localized message required");
});

test("liveUnsupported shared mapping covers zh-CN and en keys (§P2-2)", () => {
  // Popup and overlay share one mapping: load the real i18n with the zh-CN
  // and en catalogs to verify the copy comes from existing localized keys
  // instead of passing through raw page text.
  const context = vm.createContext({ URL, URLSearchParams });
  context.globalThis = context;
  vm.runInContext(i18nSource, context);
  vm.runInContext(localeZhSource, context);
  vm.runInContext(localeEnSource, context);
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(source, context);

  // 默认语言为 zh-CN：映射直接给出中文文案。
  const zh = context.MacIDMYouTubeFormats.liveUnsupportedResolution("currentlyLive");
  assert.equal(zh.ok, false);
  assert.equal(zh.reason, "liveUnsupported");
  assert.equal(zh.message, context.MacIDMI18n.messagesFor("zh-CN")["protocol.error.mediaUnsupported"]);
  assert.ok(zh.message.includes("直播") || zh.message.includes("不支持"));

  // The en key is registered and non-empty too; both ends reuse the same key.
  const enText = context.MacIDMI18n.messagesFor("en")["protocol.error.mediaUnsupported"];
  assert.ok(typeof enText === "string" && enText.length > 0);
  assert.notEqual(enText, zh.message);
});

test("resolveYouTubeQualities falls back to the App when page live status is unknown", async () => {
  // 直播标志缺失（旧页面/受限响应）：页内不得自行放行，必须调用 App 检查。
  const prWithoutLiveFlags = {
    videoDetails: { videoId: "abc123", lengthSeconds: "600" },
    streamingData: playerResponseFixture().streamingData,
  };
  const context = createContext({
    document: fakeDocument(),
    location: { search: "?v=abc123" },
    ytInitialPlayerResponse: prWithoutLiveFlags,
  });
  const pageResult = context.MacIDMYouTubeFormats.extractPageQualities(
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(pageResult.ok, false);
  assert.equal(pageResult.reason, "liveStatusUnknown");

  const appVariants = [{ height: 1080, label: "1080p" }];
  let appCalls = 0;
  const resolved = await context.MacIDMYouTubeFormats.resolveYouTubeQualities({
    pageUrl: "https://www.youtube.com/watch?v=abc123",
    requestPageQualities: async () => pageResult,
    requestAppInspection: async () => {
      appCalls += 1;
      return { ok: true, variants: appVariants };
    },
  });
  assert.equal(appCalls, 1);
  assert.deepEqual(plain(resolved), { ok: true, variants: appVariants, source: "app" });
});

// ---- §5.1/§5.3: object-based extraction entry, stable dedup keys, set merging ----

test("extractFromPlayerResponseObject normalizes a bridge snapshot like the page read", () => {
  const context = createContext();
  const result = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    playerResponseFixture(),
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, true);
  assert.equal(result.videoId, "abc123");
  assert.deepEqual(
    plain(result.variants.map((variant) => variant.height)),
    [1080, 1080, 720, 360],
  );
});

test("extractFromPlayerResponseObject rejects a snapshot for another video (SPA race)", () => {
  const context = createContext();
  const result = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    playerResponseFixture({ videoId: "other99" }),
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "urlMismatch");
});

test("extractFromPlayerResponseObject keeps blocked live phases structured", () => {
  const context = createContext();
  const result = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    playerResponseFixture({ details: { isLive: true } }),
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported");
});

test("variantStableKey prefers itag and falls back to height/container/codec/fps/audio", () => {
  const context = createContext();
  const { variantStableKey } = context.MacIDMYouTubeFormats;
  assert.equal(variantStableKey({ itag: 137, height: 1080 }), "itag:137");
  // Signed URLs rotate; two variants sharing a URL pattern must still dedupe
  // by metadata, and distinct metadata must never collide.
  const meta = variantStableKey({
    height: 1080, fileExtension: "mp4", codecs: "avc1.640028", fps: 30, hasAudio: false,
  });
  assert.equal(
    meta,
    variantStableKey({
      url: "https://cdn.example/file?sig=AAAA",
      height: 1080, fileExtension: "mp4", codecs: "avc1.640028", fps: 30, hasAudio: false,
    }),
  );
  assert.notEqual(
    meta,
    variantStableKey({
      height: 1080, fileExtension: "mp4", codecs: "av01.0.08M.08", fps: 30, hasAudio: false,
    }),
  );
});

test("mergeVariantLists dedupes by stable key and keeps the richer entry", () => {
  const context = createContext();
  const { mergeVariantLists } = context.MacIDMYouTubeFormats;
  const page = [{ itag: 137, height: 1080, label: "1080P · 30fps · H.264" }];
  const app = [
    { itag: 137, height: 1080, estimatedSize: 249_600_000 },
    { itag: 22, height: 720, label: "720P" },
  ];
  const merged = plain(mergeVariantLists(page, app));
  assert.equal(merged.length, 2);
  const h264 = merged.find((variant) => variant.itag === 137);
  // Same key: the entry with more complete fields (size estimate + label)
  // wins, so estimates computed by either side survive the merge.
  assert.equal(h264.estimatedSize, 249_600_000);
  assert.equal(h264.label, "1080P · 30fps · H.264");
});

test("variantSetSignature/areVariantSetsEqual ignore order and signed URL churn", () => {
  const context = createContext();
  const { areVariantSetsEqual } = context.MacIDMYouTubeFormats;
  const a = [
    { itag: 137, height: 1080, url: "https://x/watch?v=abc123#height=1080&itag=137" },
    { itag: 22, height: 720 },
  ];
  const b = [
    { itag: 22, height: 720 },
    { itag: 137, height: 1080, url: "https://x/watch?v=abc123&sig=rotated#height=1080&itag=137" },
  ];
  assert.equal(areVariantSetsEqual(a, b), true);
  assert.equal(areVariantSetsEqual(a, [{ itag: 22, height: 720 }]), false);
});

test("modern VOD responses without isLive flags pass via explicit isLiveContent=false", () => {
  // Found in real-environment acceptance: SABR-era VOD player responses
  // often omit isLive/isUpcomingLive and only carry an explicit
  // isLiveContent=false. After live is structurally ruled out, the in-page
  // channel must be allowed through, otherwise in-page parsing always falls
  // back to yt-dlp (chrome-extension-spec §5.8).
  const fixture = playerResponseFixture({ details: {} });
  delete fixture.videoDetails.isLive;
  delete fixture.videoDetails.isUpcomingLive;
  fixture.videoDetails.isLiveContent = false;
  const context = createContext();
  const result = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    fixture,
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(result.ok, true);
  assert.equal(result.videoId, "abc123");
});

test("live-looking responses without isLive flags stay fail-closed", () => {
  const liveContextFixture = playerResponseFixture({ details: {} });
  delete liveContextFixture.videoDetails.isLive;
  delete liveContextFixture.videoDetails.isUpcomingLive;
  liveContextFixture.videoDetails.isLiveContent = true;
  const context = createContext();
  const liveResult = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    liveContextFixture,
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(liveResult.ok, false);
  assert.equal(liveResult.reason, "liveStatusUnknown");

  // 全部直播标志缺失：同样保持 unknown，强制回退 App 检查。
  const bareFixture = playerResponseFixture({ details: {} });
  delete bareFixture.videoDetails.isLive;
  delete bareFixture.videoDetails.isUpcomingLive;
  const bareResult = context.MacIDMYouTubeFormats.extractFromPlayerResponseObject(
    bareFixture,
    "https://www.youtube.com/watch?v=abc123",
  );
  assert.equal(bareResult.ok, false);
  assert.equal(bareResult.reason, "liveStatusUnknown");
});
