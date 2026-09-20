import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// Frame routing for macidm.getYouTubeQualities (a real-environment finding):
// tabs.sendMessage broadcasts to every frame on the page. Persistent YouTube
// iframes such as accounts.youtube.com/RotateCookiesPage also receive the
// content script. If an iframe sends "no player data" first, the correct
// top-frame result is discarded and the Popup incorrectly falls back to the
// app/yt-dlp. Contract: only the top frame answers quality queries; iframes
// remain silent.
const contentScriptSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
  "utf8",
);

const PAGE_URL = "https://www.youtube.com/watch?v=abc123";

// Minimal chrome/DOM stubs covering every access made while content-script.js
// loads (MutationObserver, performance fallback, optional storage chaining,
// and related APIs).
function createContentScriptVM({ qualities = null, snapshotQualities = null } = {}) {
  let messageListener = null;
  const windowMessageListeners = [];
  const postedMessages = [];
  const context = {
    location: { href: PAGE_URL },
    document: {
      title: "fixture title",
      querySelector() {
        return null;
      },
      querySelectorAll() {
        return [];
      },
      documentElement: {},
      // SPA navigation subscriptions such as yt-navigate-finish do not need
      // real dispatching in this test harness.
      addEventListener() {},
    },
    performance: {
      getEntriesByType() {
        return [];
      },
    },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    // The bounded-wait path depends on the host's real timers; stubbed timers
    // would deadlock the retry loop.
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    setInterval: () => 0,
    clearTimeout: (handle) => clearTimeout(handle),
    clearInterval() {},
    addEventListener(type, fn) {
      if (type === "message") windowMessageListeners.push(fn);
    },
    postMessage(data) {
      postedMessages.push(data);
    },
    chrome: {
      runtime: {
        onMessage: {
          addListener(listener) {
            messageListener = listener;
          },
        },
        sendMessage() {
          return Promise.resolve(undefined);
        },
      },
    },
    // Routing tests focus on message dispatch rather than the module's
    // internal parsing (see youtube-format-utils.test.mjs); use recognizable
    // sentinel values.
    MacIDMYouTubeFormats: {
      // The second barrier depends on normalized identity; return the ID that
      // matches the test video from inside the stub.
      videoIdFromPageURL(url) {
        const match = String(url ?? "").match(/[?&]v=([A-Za-z0-9_-]{5,})/);
        return match ? match[1] : null;
      },
      extractPageQualities(pageUrl) {
        return qualities ?? { ok: true, videoId: "abc123", variants: [{ url: pageUrl }] };
      },
      extractFromPlayerResponseObject(playerResponse, pageUrl) {
        if (!snapshotQualities) return { ok: false, reason: "noPlayerData" };
        if (playerResponse?.videoDetails?.videoId !== "abc123") {
          return { ok: false, reason: "urlMismatch" };
        }
        return { ok: true, videoId: "abc123", variants: snapshotQualities };
      },
    },
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(contentScriptSource, context);
  return {
    context,
    getListener: () => messageListener,
    // Message-source validation requires the event to come from window itself.
    // In the VM, window is a global proxy and differs from the host-side
    // sandbox object, so dispatch with the VM-local reference.
    dispatchWindowMessage: (data) => {
      const win = vm.runInContext("window", context);
      for (const fn of windowMessageListeners) {
        fn({ source: win, data });
      }
    },
    postedMessages,
  };
}

test("顶层 frame 用共享模块的结果应答 getYouTubeQualities", async () => {
  const { context, getListener } = createContentScriptVM();
  const listener = getListener();
  assert.ok(typeof listener === "function", "content script 应注册消息监听器");

  // window.top === window means the top frame; bounded waiting requires an
  // asynchronous response.
  context.top = context;
  let response = null;
  const returned = listener(
    { type: "macidm.getYouTubeQualities", pageUrl: PAGE_URL },
    {},
    (value) => {
      response = value;
    },
  );

  assert.equal(returned, true, "异步应答应返回 true 保持消息通道");
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(
    response,
    { ok: true, videoId: "abc123", variants: [{ url: PAGE_URL }] },
    "顶层 frame 应把共享模块的结果原样交回调用方",
  );
});

test("首次 noPlayerData 后桥快照到达，页内数据就地补全应答", async () => {
  // Direct inspection has no data, which is normal in the ISOLATED world:
  // wait for the bridge snapshot within the deadline instead of immediately
  // giving up with noPlayerData.
  const variants = [{ url: PAGE_URL, height: 1080 }];
  const {
    context,
    getListener,
    dispatchWindowMessage,
    postedMessages,
  } = createContentScriptVM({
    qualities: { ok: false, reason: "noPlayerData" },
    snapshotQualities: variants,
  });
  const listener = getListener();
  context.top = context;

  let response = null;
  listener(
    { type: "macidm.getYouTubeQualities", pageUrl: PAGE_URL, waitMs: 2_000 },
    {},
    (value) => {
      response = value;
    },
  );
  // While waiting, request an immediate reread from the MAIN-world bridge.
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(
    postedMessages.some((m) => m?.type === "macidm.requestYouTubePlayerData"),
    "等待补全期间应请求桥重读播放器数据",
  );
  assert.equal(response, null, "数据到达前不得提前应答失败");

  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "abc123",
      videoDetails: { videoId: "abc123" },
      streamingData: { formats: [], adaptiveFormats: [] },
    },
  });
  // The retry loop polls with the production 400 ms backoff and waits for the
  // next checkpoint to observe the snapshot.
  await new Promise((resolve) => setTimeout(resolve, 550));
  assert.deepEqual(
    response,
    { ok: true, videoId: "abc123", variants },
    "桥快照到达后应就地补全并成功应答",
  );
});

test("等待窗口耗尽仍无数据时以结构化 noPlayerData 应答", async () => {
  const { context, getListener } = createContentScriptVM({
    qualities: { ok: false, reason: "noPlayerData" },
    snapshotQualities: null,
  });
  const listener = getListener();
  context.top = context;

  let response = null;
  listener(
    { type: "macidm.getYouTubeQualities", pageUrl: PAGE_URL, waitMs: 100 },
    {},
    (value) => {
      response = value;
    },
  );
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.deepEqual(response, { ok: false, reason: "noPlayerData" });
});

test("iframe 对 getYouTubeQualities 保持沉默，避免抢占顶层 frame 的应答", () => {
  const { context, getListener } = createContentScriptVM();
  const listener = getListener();

  // window.top !== window means an iframe such as RotateCookiesPage.
  context.top = {};
  let responded = false;
  const returned = listener(
    { type: "macidm.getYouTubeQualities", pageUrl: PAGE_URL },
    {},
    () => {
      responded = true;
    },
  );

  assert.equal(returned, false);
  assert.equal(responded, false, "iframe 不得调用 sendResponse 抢先应答");
});

test("iframe 仍应答 scanMedia 快照：仅画质查询按顶层 frame 门控", () => {
  const { context, getListener } = createContentScriptVM();
  const listener = getListener();

  context.top = {};
  let response = null;
  listener({ type: "macidm.scanMedia" }, {}, (value) => {
    response = value;
  });

  assert.equal(response?.ok, true, "scanMedia 的既有广播语义不应被画质门静默影响");
  assert.equal(response?.pageUrl, PAGE_URL);
});

// —— First SPA navigation from the home page to the first watch page ——
// Finding: when navigating from an uncached home page to a watch page, the
// floating panel stays at zero candidates until refresh if there is no
// observed DOM-attribute change or media Performance entry. The navigation
// entry point must therefore be explicit.

const mediaUtilsSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);

// Title ownership depends on the shared module's videoIdFromPageURL; real
// YouTube pages load both scripts as well.
const youTubeFormatUtilsSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/youtube-format-utils.js", import.meta.url),
  "utf8",
);

function createSPAContentScriptVM({ startURL = "https://www.youtube.com/" } = {}) {
  const sentMessages = [];
  const documentListeners = new Map();
  const windowMessageListeners = [];
  let messageListener = null;
  const context = {
    location: { href: startURL },
    // The shared module depends on the URL constructor, which is not a Web API
    // provided by the VM context by default.
    URL,
    URLSearchParams,
    document: {
      title: "fixture title",
      querySelector() {
        return null;
      },
      querySelectorAll() {
        return [];
      },
      documentElement: {},
      addEventListener(type, fn) {
        (documentListeners.get(type) ?? documentListeners.set(type, []).get(type)).push(fn);
      },
    },
    performance: {
      getEntriesByType() {
        return [];
      },
    },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    setInterval: () => 0,
    clearTimeout: (handle) => clearTimeout(handle),
    clearInterval() {},
    addEventListener(type, fn) {
      if (type === "message") windowMessageListeners.push(fn);
    },
    postMessage() {},
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { messageListener = listener; } },
        sendMessage(message) {
          sentMessages.push(message);
          return Promise.resolve(undefined);
        },
      },
    },
  };
  context.window = context;
  vm.createContext(context);
  // Site-adapter entry candidates are built by coalesceMediaCandidates, so
  // the real shared module is required.
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(youTubeFormatUtilsSource, context);
  vm.runInContext(contentScriptSource, context);
  return {
    context,
    sentMessages,
    getListener: () => messageListener,
    dispatchDocumentEvent: (type) => {
      for (const fn of documentListeners.get(type) ?? []) fn({ type });
    },
    dispatchWindowMessage: (data) => {
      const win = vm.runInContext("window", context);
      for (const fn of windowMessageListeners) {
        fn({ source: win, data });
      }
    },
  };
}

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("首页→首个 watch：无 DOM/Performance 触发也能发布 YouTube 入口候选", async () => {
  const { context, sentMessages, dispatchDocumentEvent } = createSPAContentScriptVM();
  await settle(250);
  const homepage = sentMessages.at(-1);
  assert.equal(homepage?.pageUrl, "https://www.youtube.com/");
  assert.ok(
    !homepage.candidates.some((candidate) => candidate.siteAdapter === "youtube"),
    "首页不应合成 watch 页的站点适配候选",
  );

  // Change only the URL and dispatch yt-navigate-finish: this produces neither
  // an observed DOM-attribute change nor a media Performance entry.
  context.location.href = "https://www.youtube.com/watch?v=def456";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  const watch = sentMessages.at(-1);
  assert.equal(watch?.pageUrl, "https://www.youtube.com/watch?v=def456");
  assert.ok(
    watch.candidates.some((candidate) => candidate.siteAdapter === "youtube"),
    "首次 SPA 导航后必须立即发布页面级入口候选",
  );
});

test("桥快照先到达触发导航兜底；相同快照轮询不重复发布", async () => {
  const { context, sentMessages, dispatchWindowMessage } = createSPAContentScriptVM({
    startURL: "https://www.youtube.com/watch?v=abc123",
  });
  await settle(250);

  // The URL has changed but the SPA event has not fired; the new video's player
  // snapshot arrives first through the fallback path.
  context.location.href = "https://www.youtube.com/watch?v=ghi789";
  const snapshot = {
    type: "macidm.youTubePlayerData",
    payload: { videoId: "ghi789", videoDetails: { videoId: "ghi789" } },
  };
  dispatchWindowMessage(snapshot);
  await settle(250);

  const watch = sentMessages.at(-1);
  assert.equal(watch?.pageUrl, "https://www.youtube.com/watch?v=ghi789");
  assert.ok(
    watch.candidates.some((candidate) => candidate.siteAdapter === "youtube"),
    "桥快照先到达也必须触发新页面候选发布",
  );

  // Duplicate snapshots with the same URL and videoId (from the bridge's
  // one-second polling) must not be published twice.
  const countAfterFirst = sentMessages.length;
  for (let i = 0; i < 3; i += 1) {
    dispatchWindowMessage(snapshot);
    await settle(150);
  }
  assert.equal(sentMessages.length, countAfterFirst, "相同快照重复到达不得重复发布");
});

test("导航后旧标题、旧候选被清除，不得串到新页面", async () => {
  // Start from a non-YouTube page. The watch-page coalescer returns only site
  // adapter candidates; direct-link candidates do not enter the snapshot and
  // cannot act as an old candidate.
  const { context, sentMessages, dispatchWindowMessage, dispatchDocumentEvent } =
    createSPAContentScriptVM({ startURL: "https://example.com/some-page" });
  // A direct-link candidate from the old page (the fetch-capture path).
  dispatchWindowMessage({
    type: "macidm.fetchCapture",
    url: "https://cdn.example.com/old-video.mp4",
    mime: "video/mp4",
  });
  await settle(250);
  const old = sentMessages.at(-1);
  assert.ok(
    old.candidates.some((candidate) => (candidate.url ?? "").includes("old-video.mp4")),
    "前置条件：旧候选已发布",
  );

  context.location.href = "https://www.youtube.com/watch?v=xyz999";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  const watch = sentMessages.at(-1);
  assert.equal(watch?.pageUrl, "https://www.youtube.com/watch?v=xyz999");
  assert.ok(
    !watch.candidates.some((candidate) => (candidate.url ?? "").includes("old-video.mp4")),
    "旧视频的候选不得在新 URL 下继续显示",
  );
  assert.ok(
    watch.candidates.some((candidate) => candidate.siteAdapter === "youtube"),
    "新页面入口候选应在旧结果清理后立即出现",
  );
});

test("SPA 换代不得在新 URL 下发布旧标题；归属成立后新标题只发布一次", async () => {
  // §7 确定性测试：视频 A → B 改 URL 时 document.title 刻意保持为 A；
  // 第一个 B 快照的 title／candidate displayName 都不得含 A；随后更新 B 标题并
  // 派发匹配 videoId 的快照，B 标题只发布一次。
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=aaaa1111" });

  // 页面 A：先改标题再派发匹配的播放器快照，使 A 标题成为已确认会话标题。
  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: { videoId: "aaaa1111", videoDetails: { videoId: "aaaa1111" } },
  });
  await settle(250);
  assert.ok(
    sentMessages.some((m) => m.title === "视频 A - YouTube"),
    "前置条件：A 标题已在归属成立后发布",
  );

  // 换代到 B：document.title 刻意仍为 A（YouTube pushState 的真实时序）。
  context.location.href = "https://www.youtube.com/watch?v=bbbb2222";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  const firstB = sentMessages.at(-1);
  assert.equal(firstB?.pageUrl, "https://www.youtube.com/watch?v=bbbb2222");
  assert.ok(!String(firstB?.title ?? "").includes("视频 A"), "新 URL 下不得发布旧标题");
  assert.ok(
    !firstB.candidates.some((c) => String(c.displayName ?? "").includes("视频 A")),
    "候选 displayName 也不得携带旧标题",
  );

  // 更新 B 标题并派发匹配 videoId 的快照（归属证据）→ B 标题恰好发布一次。
  context.document.title = "视频 B - YouTube";
  const bSnapshot = {
    type: "macidm.youTubePlayerData",
    payload: { videoId: "bbbb2222", videoDetails: { videoId: "bbbb2222" } },
  };
  dispatchWindowMessage(bSnapshot);
  await settle(250);

  const publishedB = () => sentMessages.filter((m) => m.title === "视频 B - YouTube").length;
  assert.equal(publishedB(), 1, "归属成立后 B 标题必须发布");
  assert.ok(
    !sentMessages.some(
      (m) => m.pageUrl === "https://www.youtube.com/watch?v=bbbb2222"
        && String(m.title ?? "").includes("视频 A"),
    ),
    "B 页的全部快照都不得携带 A 标题",
  );

  // 重复快照（桥 1 秒轮询）不得重复发布标题。
  dispatchWindowMessage(bSnapshot);
  await settle(200);
  assert.equal(publishedB(), 1, "B 标题只发布一次");
});

test("播放器快照先于标题更新到达时不得发布换代瞬间的旧标题", async () => {
  // §7 反向顺序：桥的 1 秒轮询可能先于 SPA 标题写入送达新页快照，此时
  // document.title 仍是旧页标题——归属判定必须拒收换代瞬间的旧值。
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=cccc3333" });

  // 页面 C：确认 C 标题。
  context.document.title = "视频 C - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: { videoId: "cccc3333", videoDetails: { videoId: "cccc3333" } },
  });
  await settle(250);

  // 换代到 D：title 刻意仍为 C；桥快照（videoId 匹配 D）立即到达。
  context.location.href = "https://www.youtube.com/watch?v=dddd4444";
  dispatchDocumentEvent("yt-navigate-finish");
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: { videoId: "dddd4444", videoDetails: { videoId: "dddd4444" } },
  });
  await settle(250);

  assert.ok(
    !sentMessages.some(
      (m) => m.pageUrl === "https://www.youtube.com/watch?v=dddd4444"
        && String(m.title ?? "").includes("视频 C"),
    ),
    "快照先到、标题未更新时不得把旧页标题发布到新 URL",
  );

  // SPA 随后写入 D 标题（变化检测 + 匹配快照都在）→ D 标题正常发布。
  context.document.title = "视频 D - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: { videoId: "dddd4444", videoDetails: { videoId: "dddd4444" } },
  });
  await settle(250);
  assert.ok(
    sentMessages.some((m) => m.title === "视频 D - YouTube"),
    "标题更新后新标题应正常发布",
  );
});

// —— §3：同视频仅参数变化与同标题换代（chrome-extension-spec §5.7/§5.8）——

test("同 videoId 参数变化：已确认标题与候选不被清空", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=abc123" });

  // 确认标题：快照携带受限标题作为归属证据（桥白名单新增字段）。
  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "abc123",
      videoDetails: { videoId: "abc123", title: "视频 A - YouTube" },
    },
  });
  await settle(250);
  assert.ok(
    sentMessages.some((m) => m.title === "视频 A - YouTube"),
    "前置条件：受限标题经归属确认后发布",
  );

  // 同视频仅追加 &t=60s：videoId 不变，不是换代。
  context.location.href = "https://www.youtube.com/watch?v=abc123&t=60s";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  const latest = sentMessages.at(-1);
  assert.equal(latest?.pageUrl, "https://www.youtube.com/watch?v=abc123&t=60s");
  assert.equal(latest?.title, "视频 A - YouTube", "同视频的已确认标题不得被清空");
  assert.ok(
    latest.candidates.some((candidate) => candidate.siteAdapter === "youtube"),
    "同视频的入口候选不得被清空",
  );
});

test("同 videoId 参数变化：已匹配的播放器快照不被丢弃", async () => {
  const { context, getListener, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=abc123" });
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "abc123",
      videoDetails: { videoId: "abc123", title: "视频 A - YouTube", isLiveContent: false },
      streamingData: {
        formats: [{
          itag: 18,
          width: 640,
          height: 360,
          bitrate: 500_000,
          fps: 30,
          mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
        }],
        adaptiveFormats: [],
      },
    },
  });
  await settle(250);

  context.location.href = "https://www.youtube.com/watch?v=abc123&t=60s";
  await settle(250);

  // 快照仍在页面会话内：新 URL 的画质查询能直接消费它；若快照被换代清空，
  // 直读路径在 vm 内无数据，只能退化应答失败。
  const listener = getListener();
  context.top = context;
  let response = null;
  listener(
    { type: "macidm.getYouTubeQualities", pageUrl: context.location.href, waitMs: 100 },
    {},
    (value) => {
      response = value;
    },
  );
  await settle(400);
  assert.equal(response?.ok, true, "参数变化后已匹配的快照必须仍可消费");
  assert.ok(
    Array.isArray(response?.variants) && response.variants.length > 0,
    "快照中的画质不得丢失",
  );
});

test("不同 videoId、不同标题：新 URL 下从未发布 A 标题（含受限标题字段）", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=aaaa1111" });

  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "aaaa1111",
      videoDetails: { videoId: "aaaa1111", title: "视频 A - YouTube" },
    },
  });
  await settle(250);

  // A→B：DOM 标题与受限标题都属于 B。
  context.location.href = "https://www.youtube.com/watch?v=bbbb2222";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);
  context.document.title = "视频 B - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "bbbb2222",
      videoDetails: { videoId: "bbbb2222", title: "视频 B - YouTube" },
    },
  });
  await settle(250);

  assert.ok(
    !sentMessages.some(
      (m) => m.pageUrl === "https://www.youtube.com/watch?v=bbbb2222"
        && String(m.title ?? "").includes("视频 A"),
    ),
    "B 页的全部快照都不得携带 A 标题",
  );
  assert.ok(
    sentMessages.some((m) => m.title === "视频 B - YouTube"),
    "B 的受限标题应被确认发布",
  );
});

test("不同 videoId、相同标题：匹配 B 的快照仍能确认并发布该标题", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=aaaa1111" });

  context.document.title = "同名标题 - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "aaaa1111",
      videoDetails: { videoId: "aaaa1111", title: "同名标题 - YouTube" },
    },
  });
  await settle(250);

  // A→B：两个视频标题完全相同，DOM 标题从不变化；字符串相等不能证明归属，
  // 但匹配 B 的受限标题可以。
  context.location.href = "https://www.youtube.com/watch?v=bbbb2222";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);
  const firstB = sentMessages.at(-1);
  assert.equal(firstB?.pageUrl, "https://www.youtube.com/watch?v=bbbb2222");
  assert.equal(String(firstB?.title ?? ""), "", "换代瞬间不得抢先确认同名的旧标题");

  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: {
      videoId: "bbbb2222",
      videoDetails: { videoId: "bbbb2222", title: "同名标题 - YouTube" },
    },
  });
  await settle(250);
  assert.ok(
    sentMessages.some(
      (m) => m.pageUrl === "https://www.youtube.com/watch?v=bbbb2222"
        && m.title === "同名标题 - YouTube",
    ),
    "归属证据成立后，同名标题不得被「必须不同于旧标题」的门槛永久拒收",
  );
});

// —— 非视频页旧播放器快照隔离（chrome-extension-spec §5.8）——

/// 构造一个合法的匹配快照载荷（带画质与受限标题）。
function playerPayload(videoId, title) {
  return {
    videoId,
    videoDetails: { videoId, title, isLiveContent: false },
    streamingData: {
      formats: [{
        itag: 18,
        width: 640,
        height: 360,
        bitrate: 500_000,
        fps: 30,
        mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
      }],
      adaptiveFormats: [],
    },
  };
}

test("watch→首页：导航清理后延迟到达的旧播放器消息不得恢复快照与标题", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage, getListener } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=aaaa1111" });

  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("aaaa1111", "视频 A - YouTube"),
  });
  await settle(250);
  assert.ok(
    sentMessages.some((m) => m.title === "视频 A - YouTube"),
    "前置条件：A 的标题已发布",
  );

  // 导航回首页并完成清理。
  context.location.href = "https://www.youtube.com/";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);
  const countAfterTransition = sentMessages.length;

  // 延迟到达的 A 旧消息（模拟导航前排队的 postMessage）：整条忽略。
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("aaaa1111", "视频 A - YouTube"),
  });
  await settle(250);
  assert.equal(sentMessages.length, countAfterTransition, "旧消息不得触发任何新发布");
  assert.ok(
    !sentMessages.some(
      (m) => m.pageUrl === "https://www.youtube.com/"
        && String(m.title ?? "").includes("视频 A"),
    ),
    "首页不得恢复 A 的标题",
  );

  // 快照未被写入：画质查询消费不到旧快照（直读路径在 vm 内无数据）。
  const listener = getListener();
  context.top = context;
  let response = null;
  listener(
    {
      type: "macidm.getYouTubeQualities",
      pageUrl: "https://www.youtube.com/watch?v=aaaa1111",
      waitMs: 100,
    },
    {},
    (value) => {
      response = value;
    },
  );
  await settle(400);
  assert.equal(
    response?.reason,
    "noPlayerData",
    "延迟旧消息不得把旧快照写回页面会话",
  );
});

test("watch→搜索页：延迟旧消息不得发布带旧标题的候选", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=aaaa1111" });

  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("aaaa1111", "视频 A - YouTube"),
  });
  await settle(250);

  context.location.href = "https://www.youtube.com/results?search_query=cats";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("aaaa1111", "视频 A - YouTube"),
  });
  await settle(250);

  assert.ok(
    !sentMessages.some(
      (m) => String(m.pageUrl ?? "").includes("/results")
        && (String(m.title ?? "").includes("视频 A")
          || (Array.isArray(m.candidates)
            && m.candidates.some((c) => String(c.displayName ?? "").includes("视频 A")))),
    ),
    "搜索页的全部快照都不得携带 A 的标题或候选",
  );
});

test("首页收到任意带 videoId 的播放器消息：整条忽略", async () => {
  const { context, sentMessages, dispatchWindowMessage, getListener } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/" });
  await settle(250);
  const countBefore = sentMessages.length;

  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("oldvideo1", "OLD TITLE"),
  });
  await settle(250);

  assert.equal(sentMessages.length, countBefore, "首页不得因旧消息强制发布");
  assert.ok(
    !sentMessages.some((m) => String(m.title ?? "").includes("OLD TITLE")),
    "旧标题不得被采用",
  );

  // 快照未写入：针对旧视频 URL 的画质查询无数据可消费。
  const listener = getListener();
  context.top = context;
  let response = null;
  listener(
    {
      type: "macidm.getYouTubeQualities",
      pageUrl: "https://www.youtube.com/watch?v=oldvideo1",
      waitMs: 100,
    },
    {},
    (value) => {
      response = value;
    },
  );
  await settle(400);
  assert.equal(response?.reason, "noPlayerData", "首页不得持有旧视频快照");
});

test("watch B 收到 A 的延迟消息被忽略，随后 B 的匹配消息正常采用", async () => {
  const { context, sentMessages, dispatchWindowMessage, getListener } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=bbbb2222" });

  // A 的延迟消息：与当前 URL videoId 不匹配，整条忽略。
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("aaaa1111", "标题 A"),
  });
  await settle(250);
  assert.ok(
    !sentMessages.some((m) => String(m.title ?? "").includes("标题 A")),
    "videoId 不匹配的消息不得发布",
  );

  // B 的匹配消息：标题与画质正常采用。
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("bbbb2222", "标题 B"),
  });
  await settle(250);
  assert.ok(
    sentMessages.some((m) => m.title === "标题 B"),
    "匹配消息的受限标题必须被确认发布",
  );

  // 快照可被画质查询消费。
  const listener = getListener();
  context.top = context;
  let response = null;
  listener(
    {
      type: "macidm.getYouTubeQualities",
      pageUrl: "https://www.youtube.com/watch?v=bbbb2222",
      waitMs: 100,
    },
    {},
    (value) => {
      response = value;
    },
  );
  await settle(400);
  assert.equal(response?.ok, true, "B 的快照必须可被画质查询消费");
  assert.ok(Array.isArray(response?.variants) && response.variants.length > 0);
});

test("同视频参数变化后新到达的匹配快照仍正常接收，既有状态不回退", async () => {
  const { context, sentMessages, dispatchDocumentEvent, dispatchWindowMessage, getListener } =
    createSPAContentScriptVM({ startURL: "https://www.youtube.com/watch?v=abc123" });

  context.document.title = "视频 A - YouTube";
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("abc123", "视频 A - YouTube"),
  });
  await settle(250);

  context.location.href = "https://www.youtube.com/watch?v=abc123&t=60s";
  dispatchDocumentEvent("yt-navigate-finish");
  await settle(250);

  // 参数变化后桥再次送达同视频快照：正常接收，标题保留、画质可消费。
  dispatchWindowMessage({
    type: "macidm.youTubePlayerData",
    payload: playerPayload("abc123", "视频 A - YouTube"),
  });
  await settle(250);
  const latest = sentMessages.at(-1);
  assert.equal(latest?.title, "视频 A - YouTube", "同视频标题不得丢失");

  const listener = getListener();
  context.top = context;
  let response = null;
  listener(
    {
      type: "macidm.getYouTubeQualities",
      pageUrl: "https://www.youtube.com/watch?v=abc123&t=60s",
      waitMs: 100,
    },
    {},
    (value) => {
      response = value;
    },
  );
  await settle(400);
  assert.equal(response?.ok, true, "参数变化后匹配快照仍能被消费");
});
