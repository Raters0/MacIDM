import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// YouTube feed-preview identity (chrome-extension-spec §5.8).
//
// Real-site finding this suite pins down: the hover-preview player is a single
// app-level `ytd-video-preview` → `#inline-preview-player` floating player,
// mounted outside every card. Its DOM carries no video identity (the card link
// is not an ancestor, `#media-container-link` has no href), and the bytes it
// plays are SABR/UMP responses (`application/vnd.yt-ump`) that never become
// candidates. So the only sound attribution is: MAIN-world bridge reads the
// previewed videoId + title → shared cache → one `siteAdapter:"youtube"` row
// per live preview → element scope binds that row to the preview player.
const read = (path) =>
  readFile(new URL(`../../../BrowserExtension/chrome/src/${path}`, import.meta.url), "utf8");

const bridgeSource = await read("content/youtube-player-bridge.js");
const cacheSource = await read("shared/youtube-preview-identity.js");
const mediaUtilsSource = await read("shared/media-utils.js");
const i18nSource = await read("shared/i18n.js");
const localeZhSource = await read("shared/locale-zh-cn.js");
const localeEnSource = await read("shared/locale-en.js");
const scopeSource = await read("content/media-element-scope.js");
const discoverySource = await read("content/discovery.js");
const contentScriptSource = await read("content/content-script.js");

const PREVIEW_DATA_TYPE = "macidm.youTubePreviewIdentity";
const PREVIEW_REQUEST_TYPE = "macidm.requestYouTubePreviewIdentity";
const HOME = "https://www.youtube.com/";
const WATCH = "https://www.youtube.com/watch?v=pagevideo1";

/// Minimal DOM shim: tag / #id / [id="x"] / .class selectors, descendant
/// combinators and comma lists — exactly what the production selectors use.
function matchSimple(node, part) {
  const value = String(part).trim();
  if (!value) return false;
  const idAttr = value.match(/^\[id=["']([^"']+)["']\]$/u);
  if (idAttr) return node.id === idAttr[1];
  if (value.startsWith("#")) return node.id === value.slice(1);
  if (value.startsWith(".")) {
    return String(node.className ?? "").split(/\s+/u).includes(value.slice(1));
  }
  return String(node.tagName).toLowerCase() === value.toLowerCase();
}

function matchAny(node, selector) {
  return String(selector)
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .some((sel) => {
      const parts = sel.split(/\s+/u).filter(Boolean);
      if (parts.length === 0) return false;
      if (!matchSimple(node, parts[parts.length - 1])) return false;
      let index = parts.length - 2;
      let current = node.parentElement;
      while (index >= 0 && current) {
        if (matchSimple(current, parts[index])) index -= 1;
        current = current.parentElement;
      }
      return index < 0;
    });
}

function queryAll(root, selector) {
  const out = [];
  const walk = (node) => {
    for (const child of node.children ?? []) {
      if (matchAny(child, selector)) out.push(child);
      walk(child);
    }
  };
  walk(root);
  return out;
}

function el(tag, { id = "", className = "", attrs = {}, children = [], ...props } = {}) {
  const node = { nodeType: 1, tagName: String(tag).toUpperCase(), id, className, attrs, children, parentElement: null, ...props };
  for (const child of children) child.parentElement = node;
  node.getAttribute = (name) => (name === "id" ? node.id || null : node.attrs[name] ?? null);
  node.querySelectorAll = (selector) => queryAll(node, selector);
  node.querySelector = (selector) => queryAll(node, selector)[0] ?? null;
  node.closest = (selector) => {
    for (let current = node; current; current = current.parentElement) {
      if (matchAny(current, selector)) return current;
    }
    return null;
  };
  return node;
}

/// The live floating preview player YouTube mounts while a card is hovered.
function previewTree({ videoId = "ojxou7UH9u8", title = "卡片标题", live = true } = {}) {
  const video = el("video", {
    className: "video-stream",
    attrs: { src: live ? "blob:https://www.youtube.com/preview" : "" },
    readyState: live ? 4 : 0,
    currentSrc: live ? "blob:https://www.youtube.com/preview" : "",
  });
  const player = el("div", {
    id: "inline-preview-player",
    className: "html5-video-player",
    children: [video],
    getVideoData: () => ({
      video_id: videoId,
      title,
      // Must never be forwarded: the bridge payload is a bounded identity.
      url: "https://signed.example/videoplayback?token=SECRET",
      signatureCipher: "sp=sig&url=https://signed.example/c",
    }),
  });
  const host = el("ytd-video-preview", { children: [player] });
  return { host, player, video };
}

function documentShim(children) {
  const root = el("body", { children });
  return {
    title: "YouTube",
    root,
    documentElement: {},
    addEventListener() {},
    querySelector: (selector) => queryAll(root, selector)[0] ?? null,
    querySelectorAll: (selector) => queryAll(root, selector),
  };
}

// ---------------------------------------------------------------------------
// MAIN-world bridge
// ---------------------------------------------------------------------------

function createBridgeVM({ href = HOME, preview = null, flexy = null } = {}) {
  const posted = [];
  const intervals = [];
  const timeouts = [];
  const messageListeners = [];
  const documentListeners = [];
  const location = { pathname: "", search: "" };
  const navigate = (value) => {
    const url = new URL(value);
    location.pathname = url.pathname;
    location.search = url.search;
  };
  navigate(href);
  const context = {
    URLSearchParams,
    location,
    document: {
      querySelector(selector) {
        if (selector === "ytd-watch-flexy") return flexy;
        if (selector === "ytd-video-preview") return preview?.host ?? null;
        return null;
      },
      addEventListener(type, fn) {
        documentListeners.push({ type, fn });
      },
    },
    postMessage(data) {
      posted.push(data);
    },
    setTimeout(fn) {
      timeouts.push(fn);
      return timeouts.length;
    },
    setInterval(fn) {
      intervals.push(fn);
      return intervals.length;
    },
    addEventListener(type, fn) {
      if (type === "message") messageListeners.push(fn);
    },
  };
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  const self = vm.runInContext("globalThis", context);
  return {
    posted,
    navigate,
    previews: () => posted.filter((item) => item.type === PREVIEW_DATA_TYPE),
    flushScheduled() {
      while (timeouts.length > 0) timeouts.shift()();
    },
    tick() {
      for (const fn of intervals) fn();
    },
    dispatchDocumentEvent(type) {
      for (const listener of documentListeners) {
        if (listener.type === type) listener.fn();
      }
    },
    requestPreviewReread() {
      for (const fn of messageListeners) fn({ source: self, data: { type: PREVIEW_REQUEST_TYPE } });
    },
  };
}

test("bridge: a live hover preview publishes its videoId and title once", () => {
  const preview = previewTree({ videoId: "ojxou7UH9u8", title: "为什么 ARX 仍然是第一" });
  const env = createBridgeVM({ preview });
  env.flushScheduled();
  assert.equal(env.previews().length, 1, "首次读取必须发布预览身份");
  const payload = env.previews()[0].payload;
  assert.equal(payload.videoId, "ojxou7UH9u8");
  assert.equal(payload.title, "为什么 ARX 仍然是第一");
  assert.ok(Number.isFinite(payload.capturedAt), "发布时附加 capturedAt");

  env.tick();
  env.tick();
  assert.equal(env.previews().length, 1, "身份不变的重复轮询不得重复发布");
});

test("bridge: a preview player that is not playing publishes nothing (fail closed)", () => {
  // YouTube keeps `ytd-video-preview` mounted after the hover ends and empties
  // the video's src; a stale videoId must never label the next card.
  const stopped = previewTree({ videoId: "stalevideo1", live: false });
  const env = createBridgeVM({ preview: stopped });
  env.flushScheduled();
  env.tick();
  env.requestPreviewReread();
  env.flushScheduled();
  assert.equal(env.previews().length, 0, "未播放的预览不得发布旧身份");
});

test("bridge: hovering the next card republishes, and navigation re-arms the same video", () => {
  const preview = previewTree({ videoId: "firstvideo1", title: "甲" });
  const env = createBridgeVM({ preview });
  env.flushScheduled();
  assert.equal(env.previews().length, 1);

  preview.player.getVideoData = () => ({ video_id: "secondvideo2", title: "乙" });
  env.tick();
  assert.equal(env.previews().length, 2, "换卡必须立即发布新身份");
  assert.equal(env.previews().at(-1).payload.videoId, "secondvideo2");

  // SPA navigation clears the content-script cache; the bridge must be able to
  // republish the same identity afterwards instead of staying silent.
  env.dispatchDocumentEvent("yt-navigate-finish");
  env.flushScheduled();
  env.tick();
  assert.equal(env.previews().length, 3, "导航后同一视频仍可重新发布");
  assert.equal(env.previews().at(-1).payload.videoId, "secondvideo2");
});

test("bridge: an explicit reread request answers without waiting for the poll", () => {
  const preview = previewTree({ videoId: "nudgevideo1" });
  const env = createBridgeVM({ preview });
  env.previews().length = 0;
  env.posted.length = 0;
  env.requestPreviewReread();
  assert.equal(env.previews().length, 1, "内容脚本的即时重读请求必须立刻应答");
});

test("bridge: the preview payload is a bounded identity, never a media URL", () => {
  const preview = previewTree({ videoId: "whitelist1", title: "题".repeat(600) });
  const env = createBridgeVM({ preview });
  env.flushScheduled();
  const payload = env.previews()[0].payload;
  assert.deepEqual(Object.keys(payload).sort(), ["capturedAt", "title", "videoId"]);
  assert.equal(payload.title.length, 500, "标题必须被长度上限截断");
  const serialized = JSON.stringify(payload);
  assert.ok(!serialized.includes("signed.example"), "不得转发媒体 URL");
  assert.ok(!serialized.includes("signatureCipher"), "不得转发 signatureCipher");
});

test("bridge: a malformed videoId is rejected instead of published", () => {
  const preview = previewTree({ videoId: "bad" });
  const env = createBridgeVM({ preview });
  env.flushScheduled();
  env.tick();
  assert.equal(env.previews().length, 0);
});

// ---------------------------------------------------------------------------
// Shared cache
// ---------------------------------------------------------------------------

function createCacheVM({ doc = null } = {}) {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  context.document = doc;
  vm.runInContext(cacheSource, context);
  return { context, run: (code) => vm.runInContext(code, context) };
}

/// Results live in the vm realm; round-trip them so deepEqual compares plain
/// host-realm values.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test("cache: stores a bounded identity and rejects malformed payloads", () => {
  const env = createCacheVM();
  assert.equal(env.run(`MacIDMYouTubePreview.store({ videoId: "ab12" })`), false, "过短的 videoId 必须被拒绝");
  assert.equal(env.run(`MacIDMYouTubePreview.store({ videoId: "" })`), false);
  assert.equal(env.run(`MacIDMYouTubePreview.store(null)`), false);
  assert.equal(env.run(`MacIDMYouTubePreview.store({ videoId: "ojxou7UH9u8", title: "  甲   乙 " })`), true);
  assert.equal(env.run(`MacIDMYouTubePreview.store({ videoId: "ojxou7UH9u8", title: "甲 乙" })`), false, "同一身份重复上报不算变化");
  assert.deepEqual(
    plain(env.run(`MacIDMYouTubePreview.current(null, "${HOME}", { livePlayer: true })`)),
    {
      siteAdapter: "youtube",
      videoId: "ojxou7UH9u8",
      pageURL: "https://www.youtube.com/watch?v=ojxou7UH9u8",
      title: "甲 乙",
    },
  );
});

test("cache: identity is bound to youtube.com and to a live preview player", () => {
  const env = createCacheVM();
  env.run(`MacIDMYouTubePreview.store({ videoId: "ojxou7UH9u8", title: "甲" })`);
  assert.equal(
    env.run(`MacIDMYouTubePreview.current(null, "https://example.com/", { livePlayer: true })`),
    null,
    "非 YouTube 页面不得合成身份",
  );
  assert.deepEqual(
    plain(env.run(`MacIDMYouTubePreview.identities(null, "${HOME}", { livePlayer: true })`).map((item) => item.videoId)),
    ["ojxou7UH9u8"],
  );
  // The floating player is reused for the next hovered card: an identity must
  // not survive the moment its own playback ends, or it would label another
  // video's player.
  assert.equal(
    env.run(`MacIDMYouTubePreview.current(null, "${HOME}", { livePlayer: false })`),
    null,
    "预览停止后必须立刻丢弃身份",
  );
  env.run("MacIDMYouTubePreview.clear()");
  assert.equal(env.run(`MacIDMYouTubePreview.current(null, "${HOME}", { livePlayer: true })`), null);
});

test("cache: DOM liveness needs a preview video that is playing a blob source", () => {
  const live = previewTree({ live: true });
  const stopped = previewTree({ live: false });
  const liveEnv = createCacheVM({ doc: documentShim([live.host]) });
  assert.equal(liveEnv.run("MacIDMYouTubePreview.hasLivePreviewPlayer(document)"), true);
  const stoppedEnv = createCacheVM({ doc: documentShim([stopped.host]) });
  assert.equal(stoppedEnv.run("MacIDMYouTubePreview.hasLivePreviewPlayer(document)"), false);
  const emptyEnv = createCacheVM({ doc: documentShim([]) });
  assert.equal(emptyEnv.run("MacIDMYouTubePreview.hasLivePreviewPlayer(document)"), false);
});

// ---------------------------------------------------------------------------
// Candidate coalescing
// ---------------------------------------------------------------------------

function createMediaUtilsVM() {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(i18nSource, context);
  vm.runInContext(localeZhSource, context);
  vm.runInContext(localeEnSource, context);
  vm.runInContext(mediaUtilsSource, context);
  return context.MacIDMMediaUtils;
}

const mediaUtils = createMediaUtilsVM();
const previewIdentity = (videoId, title, pageURL = `https://www.youtube.com/watch?v=${videoId}`) => ({
  siteAdapter: "youtube",
  videoId,
  pageURL,
  title,
});

test("coalesce: a feed-page hover preview becomes one adapter row for that video", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [
      mediaUtils.normalizeMediaCandidate({ url: "https://i.ytimg.com/vi/x/hq720.jpg" }, HOME),
      mediaUtils.normalizeMediaCandidate(
        { url: "https://rr4---sn-x.googlevideo.com/videoplayback?itag=18&mime=video%2Fmp4" },
        HOME,
      ),
    ],
    "YouTube",
    HOME,
    [previewIdentity("ojxou7UH9u8", "为什么 ARX 仍然是第一")],
  );
  const adapters = result.filter((candidate) => candidate.siteAdapter === "youtube");
  assert.equal(adapters.length, 1);
  assert.equal(adapters[0].url, "https://www.youtube.com/watch?v=ojxou7UH9u8", "行 URL 是被预览视频的 watch 地址");
  assert.equal(adapters[0].displayName, "为什么 ARX 仍然是第一", "行标题用预览标题，不用页面品牌名");
  assert.equal(adapters[0].filenameHint, "为什么 ARX 仍然是第一.mp4");
  assert.equal(adapters[0].supported, true);
  assert.ok(result.every((candidate) => candidate.url !== HOME), "列表页自身不得被当成单个视频");
});

test("coalesce: without a live preview identity the homepage synthesizes no adapter row", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [mediaUtils.normalizeMediaCandidate({ url: "https://i.ytimg.com/vi/x/hq720.jpg" }, HOME)],
    "YouTube",
    HOME,
    [],
  );
  assert.ok(result.every((candidate) => candidate.siteAdapter !== "youtube"));
  const undefinedIdentities = mediaUtils.coalesceMediaCandidates([], "YouTube", HOME);
  assert.deepEqual(plain(undefinedIdentities), []);
});

test("coalesce: an unreadable preview title falls back to the generic YouTube label", () => {
  const result = mediaUtils.coalesceMediaCandidates([], "", HOME, [previewIdentity("notitle12345", "")]);
  const adapter = result.find((candidate) => candidate.siteAdapter === "youtube");
  assert.equal(adapter.displayName, "YouTube 视频");
  assert.equal(adapter.filenameHint, "YouTube 视频.mp4");
});

test("coalesce: repeated identities and a second pass never duplicate a videoId", () => {
  const identities = [
    previewIdentity("samevideo1", "甲"),
    previewIdentity("samevideo1", "乙"),
  ];
  const first = mediaUtils.coalesceMediaCandidates([], "", HOME, identities);
  assert.equal(first.filter((candidate) => candidate.siteAdapter === "youtube").length, 1);
  assert.equal(first[0].displayName, "甲");
  // The service worker coalesces the page-world output again.
  const second = mediaUtils.coalesceMediaCandidates(first, "", HOME, identities);
  assert.equal(second.filter((candidate) => candidate.siteAdapter === "youtube").length, 1);
});

test("coalesce: an identity whose URL carries another videoId is rejected", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [],
    "",
    HOME,
    [previewIdentity("mismatch1234", "甲", "https://www.youtube.com/watch?v=other98765")],
  );
  assert.deepEqual(plain(result), []);
});

test("coalesce: a watch page keeps its own row and adds a different previewed video", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [mediaUtils.normalizeMediaCandidate({ url: "https://rr4---sn-x.googlevideo.com/videoplayback?itag=18" }, WATCH)],
    "页面视频标题",
    WATCH,
    [previewIdentity("hoveredvid1", "悬浮卡片标题"), previewIdentity("pagevideo1", "同一个视频")],
  );
  const adapters = result.filter((candidate) => candidate.siteAdapter === "youtube");
  assert.equal(adapters.length, 2, "页面视频 + 被悬浮的另一个视频");
  assert.equal(adapters[0].url, WATCH);
  assert.equal(adapters[0].displayName, "页面视频标题");
  assert.equal(adapters[1].url, "https://www.youtube.com/watch?v=hoveredvid1");
  assert.equal(adapters[1].displayName, "悬浮卡片标题");
  assert.ok(adapters.every((candidate) => candidate.displayName !== "同一个视频"), "页面自身视频不得重复成第二行");
});

test("coalesce: Bilibili preview identities keep working beside YouTube ones", () => {
  const result = mediaUtils.coalesceMediaCandidates(
    [],
    "",
    "https://www.bilibili.com/",
    [
      { bvid: "BV1aaa", pageURL: "https://www.bilibili.com/video/BV1aaa", title: "B 站卡片" },
      previewIdentity("ytcard12345", "YT 卡片"),
    ],
  );
  assert.equal(result.filter((candidate) => candidate.siteAdapter === "bilibili").length, 1);
  assert.equal(result.filter((candidate) => candidate.siteAdapter === "youtube").length, 1);
});

// ---------------------------------------------------------------------------
// Element scope
// ---------------------------------------------------------------------------

function createScopeVM({ children, href = HOME }) {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  context.location = { href, origin: new URL(href).origin };
  context.document = documentShim(children);
  context.postMessage = () => {};
  context.addEventListener = () => {};
  context.setInterval = () => 0;
  vm.runInContext(i18nSource, context);
  vm.runInContext(localeZhSource, context);
  vm.runInContext(localeEnSource, context);
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(cacheSource, context);
  vm.runInContext(scopeSource, context);
  return context;
}

const adapterRow = {
  url: "https://www.youtube.com/watch?v=ojxou7UH9u8",
  mime: "text/html",
  format: "video",
  fileExtension: "mp4",
  supported: true,
  siteAdapter: "youtube",
  displayName: "卡片标题",
};
const rawRow = {
  url: "https://rr4---sn-x.googlevideo.com/videoplayback?itag=18",
  format: "video",
  supported: true,
};
const imageRow = { url: "https://i.ytimg.com/vi/x/hq720.jpg", format: "image", supported: true };

test("scope: the preview player owns its card's adapter row and nothing else", () => {
  const preview = previewTree({ videoId: "ojxou7UH9u8" });
  const context = createScopeVM({ children: [preview.host] });
  context.MacIDMYouTubePreview.store({ videoId: "ojxou7UH9u8", title: "卡片标题" });
  const scoped = context.MacIDMMediaElementScope.filterCandidates(
    preview.video,
    [adapterRow, rawRow, imageRow],
    HOME,
  );
  assert.deepEqual(scoped.map((candidate) => candidate.url), [adapterRow.url]);
});

test("scope: without a live preview identity the adapter row is not attributed", () => {
  // Fail closed: a stopped preview (or a missing bridge) must not keep binding
  // the last hovered video's row to whatever player is mounted.
  const preview = previewTree({ videoId: "ojxou7UH9u8", live: false });
  const context = createScopeVM({ children: [preview.host] });
  context.MacIDMYouTubePreview.store({ videoId: "ojxou7UH9u8", title: "卡片标题" });
  const scoped = context.MacIDMMediaElementScope.filterCandidates(
    preview.video,
    [adapterRow, rawRow],
    HOME,
  );
  assert.deepEqual(scoped, []);
});

test("scope: a watch page's main player keeps the page row while a preview is live", () => {
  const preview = previewTree({ videoId: "hoveredvid1" });
  const mainVideo = el("video", { attrs: { src: "blob:https://www.youtube.com/main" }, readyState: 4, currentSrc: "blob:https://www.youtube.com/main" });
  const moviePlayer = el("div", { id: "movie_player", children: [mainVideo] });
  const context = createScopeVM({ children: [moviePlayer, preview.host], href: WATCH });
  context.MacIDMYouTubePreview.store({ videoId: "hoveredvid1", title: "悬浮卡片" });
  const pageRow = { ...adapterRow, url: WATCH, displayName: "页面视频" };
  const previewRow = { ...adapterRow, url: "https://www.youtube.com/watch?v=hoveredvid1", displayName: "悬浮卡片" };

  const mainScoped = context.MacIDMMediaElementScope.filterCandidates(mainVideo, [pageRow, previewRow], WATCH);
  assert.deepEqual(mainScoped.map((candidate) => candidate.url), [WATCH], "主播放器仍归属页面视频");

  const previewScoped = context.MacIDMMediaElementScope.filterCandidates(preview.video, [pageRow, previewRow], WATCH);
  assert.deepEqual(
    previewScoped.map((candidate) => candidate.url),
    ["https://www.youtube.com/watch?v=hoveredvid1"],
    "悬浮预览归属它自己的视频",
  );
});

// ---------------------------------------------------------------------------
// Content-script wiring
// ---------------------------------------------------------------------------

function createContentScriptVM({ children, href = HOME }) {
  const posted = [];
  const windowListeners = [];
  const context = vm.createContext({ URL, console });
  context.globalThis = context;
  context.location = { href, hostname: new URL(href).hostname, origin: new URL(href).origin };
  context.document = documentShim(children);
  context.performance = { getEntriesByType: () => [], now: () => 1 };
  context.MutationObserver = class { observe() {} };
  context.setTimeout = (fn, ms) => setTimeout(fn, ms);
  context.setInterval = () => 0;
  context.clearTimeout = (handle) => clearTimeout(handle);
  context.postMessage = (data) => posted.push(data);
  context.addEventListener = (type, fn) => {
    if (type === "message") windowListeners.push(fn);
  };
  let listener = null;
  context.chrome = {
    runtime: {
      onMessage: { addListener(fn) { listener = fn; } },
      sendMessage: () => Promise.resolve(undefined),
    },
  };
  context.window = context;
  context.top = context;
  for (const source of [i18nSource, localeZhSource, localeEnSource, mediaUtilsSource, discoverySource, cacheSource, contentScriptSource]) {
    vm.runInContext(source, context);
  }
  const self = vm.runInContext("window", context);
  return {
    context,
    posted,
    dispatchWindowMessage: (data) => {
      for (const fn of windowListeners) fn({ source: self, data });
    },
    scan: () => {
      let reply = null;
      listener({ type: "macidm.getMediaCandidates" }, {}, (value) => { reply = value; });
      return reply;
    },
  };
}

test("content script: a bridge preview identity becomes a candidate row for the page", () => {
  const preview = previewTree({ videoId: "ojxou7UH9u8", title: "卡片标题" });
  const env = createContentScriptVM({ children: [preview.host] });
  env.dispatchWindowMessage({
    type: "macidm.youTubePreviewIdentity",
    payload: { videoId: "ojxou7UH9u8", title: "卡片标题", capturedAt: Date.now() },
  });
  const snapshot = env.scan();
  const adapters = snapshot.candidates.filter((candidate) => candidate.siteAdapter === "youtube");
  assert.equal(adapters.length, 1);
  assert.equal(adapters[0].url, "https://www.youtube.com/watch?v=ojxou7UH9u8");
  assert.equal(adapters[0].displayName, "卡片标题");
  assert.ok(snapshot.candidates.every((candidate) => candidate.url !== HOME), "首页自身不得成为候选");
});

test("content script: a live preview without an identity asks the bridge to reread", () => {
  const preview = previewTree({ videoId: "ojxou7UH9u8", title: "卡片标题" });
  const env = createContentScriptVM({ children: [preview.host] });
  env.scan();
  assert.ok(
    env.posted.some((message) => message?.type === "macidm.requestYouTubePreviewIdentity"),
    "预览已在播放但身份未到达时必须请求即时重读",
  );
});

test("content script: an SPA transition drops the previous page's preview identity", () => {
  const preview = previewTree({ videoId: "ojxou7UH9u8", title: "卡片标题" });
  const env = createContentScriptVM({ children: [preview.host] });
  env.dispatchWindowMessage({ type: "macidm.youTubePreviewIdentity", payload: { videoId: "ojxou7UH9u8", title: "卡片标题" } });
  assert.equal(env.scan().candidates.filter((candidate) => candidate.siteAdapter === "youtube").length, 1);

  env.context.location.href = "https://www.youtube.com/feed/subscriptions";
  const after = env.scan();
  assert.equal(
    after.candidates.filter((candidate) => candidate.siteAdapter === "youtube").length,
    0,
    "路由切换后不得残留上一页的预览身份",
  );
});
