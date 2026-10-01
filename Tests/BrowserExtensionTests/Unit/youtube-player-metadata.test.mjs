import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// YouTube 页内取轨（chrome-extension-spec §5.8）：列表/首页悬浮预览会自己拉一次
// `/youtubei/v1/player`，MAIN world 只取白名单元数据交给 ISOLATED world 缓存，
// 卡片行的画质由此走与 watch 页完全相同的页内管线，不再依赖 App/yt-dlp。
// 三件事必须被钉住：①签名 URL 一个都不过桥；②缓存有 TTL/容量上限且按 videoId 索引；
// ③选轨逻辑不复制——缓存产物直接喂给既有的 youtube-format-utils。
const read = (path) =>
  readFile(new URL(`../../../BrowserExtension/chrome/src/${path}`, import.meta.url), "utf8");

const interceptorSource = await read("content/fetch-interceptor.js");
const metadataSource = await read("shared/youtube-player-metadata.js");
const formatUtilsSource = await read("shared/youtube-format-utils.js");
const mediaUtilsSource = await read("shared/media-utils.js");
const i18nSource = await read("shared/i18n.js");
const localeZhSource = await read("shared/locale-zh-cn.js");
const localeEnSource = await read("shared/locale-en.js");
const discoverySource = await read("content/discovery.js");
const contentScriptSource = await read("content/content-script.js");

const HOME = "https://www.youtube.com/";
const CARD_ID = "528cyL9_OT8";
const CARD_URL = `https://www.youtube.com/watch?v=${CARD_ID}`;

function loadInterceptor() {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(interceptorSource, context);
  return context.MacIDMFetchInterceptor;
}

function loadMetadata() {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(metadataSource, context);
  return context.MacIDMYouTubePlayerMetadata;
}

/// Values crossing out of a vm realm keep their realm's prototypes; round-trip
/// them so deepEqual compares plain host-realm data.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

/// A player response shaped like the one a hover preview really fetches
/// (measured: ~125 KB, formats + adaptiveFormats, explicit live flags).
function playerResponseJSON({ videoId = CARD_ID, live = false, extraFormatFields = {} } = {}) {
  return JSON.stringify({
    videoDetails: {
      videoId,
      title: "Unc to Champ 3: How a 41 year old hit MASTER 2",
      lengthSeconds: "837",
      isLive: live,
      isUpcomingLive: false,
      isLiveContent: true,
      ...extraFormatFields,
    },
    streamingData: {
      expiresInSeconds: "21540",
      formats: [
        {
          itag: 18,
          width: 640,
          height: 360,
          bitrate: 500_000,
          fps: 30,
          mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
          contentLength: "40000000",
          approxDurationMs: "837000",
          // 这两个字段必须被丢掉：签名直链绝不进缓存，也不进任何下游消息。
          url: "https://rr4---sn-x.googlevideo.com/videoplayback?sig=SECRET&n=THROTTLE",
          signatureCipher: "sp=sig&url=https://rr4---sn-x.googlevideo.com/c",
        },
      ],
      adaptiveFormats: [
        {
          itag: 137,
          width: 1920,
          height: 1080,
          bitrate: 3_000_000,
          fps: 30,
          mimeType: 'video/mp4; codecs="avc1.640028"',
          contentLength: "240000000",
          url: "https://rr4---sn-x.googlevideo.com/videoplayback?itag=137&sig=SECRET2",
        },
        {
          itag: 140,
          bitrate: 128_000,
          mimeType: 'audio/mp4; codecs="mp4a.40.2"',
          contentLength: "13000000",
          url: "https://rr4---sn-x.googlevideo.com/videoplayback?itag=140&sig=SECRET3",
        },
      ],
    },
  });
}

// ---------------------------------------------------------------------------
// MAIN world：URL 判定与元数据提取
// ---------------------------------------------------------------------------

test("interceptor: only the YouTube player endpoint matches", () => {
  const kit = loadInterceptor();
  assert.equal(kit.isYouTubePlayerURL("https://www.youtube.com/youtubei/v1/player?key=AIza&prettyPrint=false"), true);
  assert.equal(kit.isYouTubePlayerURL("https://youtube.com/youtubei/v1/player"), true);
  assert.equal(kit.isYouTubePlayerURL("https://m.youtube.com/youtubei/v1/player?x=1"), true);
  assert.equal(kit.isYouTubePlayerURL("https://www.youtube.com/youtubei/v1/browse"), false);
  assert.equal(kit.isYouTubePlayerURL("https://www.youtube.com/youtubei/v1/playerfoo"), false);
  assert.equal(kit.isYouTubePlayerURL("https://evil.example/youtubei/v1/player"), false);
  assert.equal(kit.isYouTubePlayerURL("https://rr4---sn-x.googlevideo.com/videoplayback"), false);
  assert.equal(kit.isYouTubePlayerURL(""), false);
});

test("interceptor: the parsed payload is metadata only — no signed URL survives", () => {
  const kit = loadInterceptor();
  const payload = kit.parseYouTubePlayerMetadata(playerResponseJSON());
  assert.ok(payload, "真实形态的 player 响应必须被解析");
  assert.equal(payload.videoId, CARD_ID);
  assert.equal(payload.formats.length, 1);
  assert.equal(payload.adaptiveFormats.length, 2);
  assert.equal(payload.isLive, false);
  assert.equal(payload.isLiveContent, true);
  assert.equal(payload.lengthSeconds, "837");

  const serialized = JSON.stringify(payload);
  assert.ok(!serialized.includes("SECRET"), "签名不得进入 payload");
  assert.ok(!serialized.includes("googlevideo"), "媒体 URL 不得进入 payload");
  assert.ok(!serialized.includes("signatureCipher"), "cipher 字段名也不得出现");
  assert.ok(!serialized.includes("expiresInSeconds"), "非白名单字段一律丢弃");
  assert.deepEqual(
    Object.keys(payload.formats[0]).sort(),
    ["bitrate", "contentLength", "fps", "height", "itag", "mimeType", "width"],
  );
});

test("interceptor: malformed, oversized and track-less responses are rejected", () => {
  const kit = loadInterceptor();
  assert.equal(kit.parseYouTubePlayerMetadata("{ truncated"), null);
  assert.equal(kit.parseYouTubePlayerMetadata(""), null);
  assert.equal(kit.parseYouTubePlayerMetadata(JSON.stringify({ videoDetails: { videoId: CARD_ID } })), null, "没有任何轨道不得入缓存");
  assert.equal(
    kit.parseYouTubePlayerMetadata(JSON.stringify({ videoDetails: { videoId: "bad" }, streamingData: { formats: [{ itag: 18, height: 360 }] } })),
    null,
    "videoId 不合规必须拒绝",
  );
  const oversized = `{"videoDetails":{"videoId":"${CARD_ID}"},` + `"padding":"${"x".repeat(kit.YOUTUBE_PLAYER_MAX_BYTES)}"}`;
  assert.equal(kit.parseYouTubePlayerMetadata(oversized), null, "超出体积上限必须跳过");
  // 无 itag 且无 height 的条目不构成可选轨道。
  const payload = kit.parseYouTubePlayerMetadata(
    JSON.stringify({ videoDetails: { videoId: CARD_ID }, streamingData: { adaptiveFormats: [{ bitrate: 1 }, { itag: 251, height: 0, mimeType: "audio/webm" }] } }),
  );
  assert.equal(payload.adaptiveFormats.length, 1);
  assert.equal(payload.adaptiveFormats[0].itag, 251);
});

// ---------------------------------------------------------------------------
// ISOLATED world：缓存边界
// ---------------------------------------------------------------------------

test("cache: keyed by videoId, TTL-bounded and capacity-bounded", () => {
  const cache = loadMetadata();
  const kit = loadInterceptor();
  const payload = kit.parseYouTubePlayerMetadata(playerResponseJSON());
  const now = 1_000_000;
  assert.equal(cache.store(payload, now), true);
  assert.equal(cache.store(payload, now + 1), false, "同一份元数据重复上报不算变化");
  assert.equal(cache.has(CARD_ID, now + 1_000), true);
  assert.deepEqual(plain(cache.videoIds(now + 1_000)), [CARD_ID]);
  // 上一次 store 在 now+1 重新计时：窗口内仍有效，超出即失效。
  const restamped = now + 1;
  assert.equal(cache.has(CARD_ID, restamped + cache.TTL_MS - 1), true);
  assert.equal(cache.has(CARD_ID, restamped + cache.TTL_MS + 1), false, "超出 TTL 必须失效");

  for (let index = 0; index < cache.MAX_ENTRIES + 2; index += 1) {
    cache.store(
      { videoId: `bulk${index}0`, formats: [{ itag: 18, height: 360 }], adaptiveFormats: [] },
      now + index,
    );
  }
  assert.ok(cache.videoIds(now + cache.MAX_ENTRIES + 5).length <= cache.MAX_ENTRIES, "容量必须有上限");
  assert.equal(cache.has(CARD_ID, now + cache.MAX_ENTRIES + 5), false, "最旧条目先被淘汰");
  cache.clear();
  assert.deepEqual(plain(cache.videoIds(now)), []);
});

test("cache: re-whitelists on the way in, so a hostile payload cannot smuggle URLs", () => {
  const cache = loadMetadata();
  cache.store(
    {
      videoId: CARD_ID,
      title: "标题",
      formats: [
        {
          itag: 18,
          height: 360,
          url: "https://signed.example/media?token=SECRET",
          signatureCipher: "sp=sig&url=https://signed.example/c",
          mimeType: "video/mp4",
        },
      ],
    },
    5,
  );
  const serialized = JSON.stringify(cache.playerResponseFor(CARD_ID, 5));
  assert.ok(!serialized.includes("SECRET"), "缓存侧必须再次过滤，不得存放签名 URL");
  assert.ok(!serialized.includes("signatureCipher"));
  assert.deepEqual(Object.keys(JSON.parse(serialized).streamingData.formats[0]).sort(), [
    "height",
    "itag",
    "mimeType",
  ]);
});

// ---------------------------------------------------------------------------
// 契约：缓存产物直接喂给既有选轨管线（不复制逻辑）
// ---------------------------------------------------------------------------

function loadFormatsContext() {
  const context = vm.createContext({ URL, URLSearchParams });
  context.globalThis = context;
  for (const source of [i18nSource, localeZhSource, localeEnSource, mediaUtilsSource, formatUtilsSource, metadataSource, interceptorSource]) {
    vm.runInContext(source, context);
  }
  return context;
}

test("cached metadata answers card qualities through the shared watch-page pipeline", () => {
  const context = loadFormatsContext();
  const result = vm.runInContext(
    `(() => {
      const payload = MacIDMFetchInterceptor.parseYouTubePlayerMetadata(${JSON.stringify(playerResponseJSON())});
      MacIDMYouTubePlayerMetadata.store(payload, 10);
      const pr = MacIDMYouTubePlayerMetadata.playerResponseFor("${CARD_ID}", 10);
      return MacIDMYouTubeFormats.extractFromPlayerResponseObject(pr, "${CARD_URL}");
    })()`,
    context,
  );
  assert.equal(result.ok, true);
  assert.equal(result.videoId, CARD_ID);
  const heights = plain(result.variants.map((variant) => variant.height).sort((a, b) => b - a));
  assert.deepEqual(heights, [1080, 360], "自适应 1080p 与渐进式 360p 都必须出现");
  const top = result.variants.find((variant) => variant.height === 1080);
  assert.equal(top.itag, 137);
  assert.equal(top.fileExtension, "mp4");
  assert.ok(top.url.endsWith(`#height=1080&itag=137`), "变体 URL 仍是页面 URL + MacIDM 自有 fragment");
  assert.ok(top.url.startsWith(CARD_URL), "不得出现任何 googlevideo 直链");
});

test("cached live flags short-circuit a card row in-page (fail-closed preserved)", () => {
  const context = loadFormatsContext();
  const result = vm.runInContext(
    `(() => {
      const payload = MacIDMFetchInterceptor.parseYouTubePlayerMetadata(
        ${JSON.stringify(playerResponseJSON({ live: true }))});
      MacIDMYouTubePlayerMetadata.store(payload, 10);
      const pr = MacIDMYouTubePlayerMetadata.playerResponseFor("${CARD_ID}", 10);
      return MacIDMYouTubeFormats.extractFromPlayerResponseObject(pr, "${CARD_URL}");
    })()`,
    context,
  );
  assert.equal(result.ok, false);
  assert.equal(result.reason, "liveUnsupported", "页内明确识别的直播必须短路，不必再跑 yt-dlp");
});

// ---------------------------------------------------------------------------
// content-script 装配：页内阶段优先查缓存，查不到才终止
// ---------------------------------------------------------------------------

function createContentScriptVM({ startURL = HOME } = {}) {
  const posted = [];
  const windowListeners = [];
  let listener = null;
  const context = vm.createContext({ URL, URLSearchParams, console });
  context.globalThis = context;
  context.location = { href: startURL, hostname: new URL(startURL).hostname, origin: new URL(startURL).origin, search: new URL(startURL).search, pathname: new URL(startURL).pathname };
  context.document = {
    title: "YouTube",
    documentElement: {},
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener() {},
  };
  context.performance = { getEntriesByType: () => [], now: () => 1 };
  context.MutationObserver = class { observe() {} };
  context.setTimeout = (fn, ms) => setTimeout(fn, ms);
  context.setInterval = () => 0;
  context.clearTimeout = (handle) => clearTimeout(handle);
  context.postMessage = (data) => posted.push(data);
  context.addEventListener = (type, fn) => {
    if (type === "message") windowListeners.push(fn);
  };
  context.chrome = {
    runtime: {
      onMessage: { addListener(fn) { listener = fn; } },
      sendMessage: () => Promise.resolve(undefined),
    },
  };
  context.window = context;
  context.top = context;
  for (const source of [
    i18nSource,
    localeZhSource,
    localeEnSource,
    mediaUtilsSource,
    formatUtilsSource,
    discoverySource,
    metadataSource,
    contentScriptSource,
  ]) {
    vm.runInContext(source, context);
  }
  const self = vm.runInContext("window", context);
  const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  return {
    context,
    posted,
    settle,
    dispatchWindowMessage: (data) => {
      for (const fn of windowListeners) fn({ source: self, data });
    },
    askQualities: async (pageUrl, waitMs = 0) => {
      let response = null;
      listener({ type: "macidm.getYouTubeQualities", pageUrl, waitMs }, {}, (value) => {
        response = value;
      });
      await settle(60);
      return response;
    },
    /// A scan is what runs the SPA transition handler (location.href compare).
    scan: () => {
      listener({ type: "macidm.scanMedia" }, {}, () => {});
    },
  };
}

test("content script: a hovered card's qualities are answered from captured metadata", async () => {
  const env = createContentScriptVM();
  env.dispatchWindowMessage({
    type: "macidm.youtube.playerMetadata",
    payload: loadInterceptor().parseYouTubePlayerMetadata(playerResponseJSON()),
  });

  const response = await env.askQualities(CARD_URL);
  assert.equal(response?.ok, true, "列表页卡片行必须能页内应答，而不是 pageDataUnavailable");
  assert.equal(response.videoId, CARD_ID);
  assert.ok(response.variants.length >= 2);
  assert.ok(
    response.variants.every((variant) => String(variant.url).startsWith(CARD_URL)),
    "变体 URL 只能是页面 URL + 选择 fragment",
  );
});

test("content script: without captured metadata the card row stays terminally unavailable", async () => {
  const env = createContentScriptVM();
  const response = await env.askQualities(CARD_URL);
  assert.equal(response?.ok, false);
  assert.equal(
    response?.reason,
    "pageDataUnavailable",
    "页内既无本页数据也无缓存元数据时，必须终止而不是空等页内预算",
  );
});

test("content script: SPA navigation drops captured metadata", async () => {
  const env = createContentScriptVM();
  env.dispatchWindowMessage({
    type: "macidm.youtube.playerMetadata",
    payload: loadInterceptor().parseYouTubePlayerMetadata(playerResponseJSON()),
  });
  assert.equal((await env.askQualities(CARD_URL))?.ok, true);

  env.context.location.href = "https://www.youtube.com/feed/subscriptions";
  env.scan();
  await env.settle(30);
  const after = await env.askQualities(CARD_URL);
  assert.equal(after?.ok, false);
  assert.equal(after?.reason, "pageDataUnavailable", "路由切换后旧页面的元数据不得继续应答");
});
