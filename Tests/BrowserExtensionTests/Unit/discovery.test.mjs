import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/discovery.js", import.meta.url),
  "utf8",
);
const mediaUtilsSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const contentSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
  "utf8",
);
const fetchInterceptorSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/fetch-interceptor.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(source, context);
const discovery = context.MacIDMDiscovery;

test("link collection keeps unique HTTP links and removes fragments", () => {
  const result = discovery.collectLinks(
    [
      { href: "/file.zip#part", textContent: " File  ZIP " },
      { href: "https://example.com/file.zip", textContent: "duplicate" },
      { href: "javascript:alert(1)", textContent: "unsafe" },
    ],
    "https://example.com/page",
  );
  assert.deepEqual(JSON.parse(JSON.stringify(result)), [
    { url: "https://example.com/file.zip", text: "File ZIP" },
  ]);
});

test("media classification recognizes manifests and direct media", () => {
  assert.equal(discovery.mediaFormat("https://cdn.example/live/master.m3u8"), "hls");
  assert.equal(discovery.mediaFormat("https://cdn.example/movie.mpd"), "dash");
  assert.equal(discovery.isMediaCandidate("https://cdn.example/video", "video/mp4"), true);
  assert.equal(discovery.isMediaCandidate("https://cdn.example/image.jpg", "image/jpeg"), false);
});

test("m4s and other DASH/container extensions are recognized as media candidates", () => {
  for (const ext of ["m4s", "ts", "mp2t", "mkv", "avi", "wmv", "flv", "opus", "wav"]) {
    assert.equal(
      discovery.isMediaCandidate(`https://cdn.example/track.${ext}`, ""),
      true,
      `expected ${ext} to be a media candidate`,
    );
  }
  // m4s classifies as video (pairing noise reduction aggregates by cid on
  // the service-worker side)
  assert.equal(
    discovery.mediaFormat("https://cdn.example/1550776785-1-100022.m4s", ""),
    "video",
  );
  // opus / wav classify as audio
  assert.equal(discovery.mediaFormat("https://cdn.example/song.opus", ""), "audio");
  assert.equal(discovery.mediaFormat("https://cdn.example/song.wav", ""), "audio");
});

test("query-embedded media URLs (analytics beacons) are not candidates", () => {
  // Observed on Bilibili: the data.bilibili.com/log/web beacon copies the
  // whole CDN m4s URL into its query string, and every log entry was
  // misreported as an "M4S · 2 B" candidate that accumulated during playback.
  // Extension detection must only look at the URL path; media addresses
  // embedded in query/fragment are not evidence.
  const beacon = "https://data.bilibili.com/log/web?0011111|Default:Ugc:0|4.9.95|heartbeat|https://cn-hbyc-ct-01-05.bilivideo.com/upgcxcode/82/76/40214857682/40214857682-1-30011.m4s?e=ig8euxZM2rNcNbdlhoNvNC8BqJIzNbfqXBvEqxTEto8BTrNvN0GvT90W5JZMkX&deadline=1788937854&platform=pc&mid=0&gen=playurlv3";
  assert.equal(discovery.isMediaCandidate(beacon, ""), false);
  assert.equal(discovery.isMediaCandidate("https://example.com/collect?payload=.mp4", ""), false);
  assert.equal(discovery.isMediaCandidate("https://example.com/page#https://cdn.example/v.mp4", ""), false);
  // Real media has its extension on the path: the signed-query CDN URL is
  // still recognized.
  assert.equal(
    discovery.isMediaCandidate(
      "https://cn-hbyc-ct-01-05.bilivideo.com/upgcxcode/82/76/40214857682/40214857682-1-30011.m4s?e=abc&deadline=123",
      "",
    ),
    true,
  );
  // Explicit ?mime= declarations keep working.
  assert.equal(discovery.isMediaCandidate("https://example.com/stream?mime=video/mp4", ""), true);
});

test("link collection applies the product limit before task creation", () => {
  const anchors = Array.from({ length: 1_001 }, (_, index) => ({
    href: `https://example.com/file-${index}.zip`,
    textContent: `file ${index}`,
  }));

  assert.equal(discovery.collectLinks(anchors, "https://example.com/page").length, 1_000);
});

test("content script automatically reports DOM and performance media candidates", async () => {
  const mediaUtilsSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
    "utf8",
  );
  const contentSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
    "utf8",
  );
  const listeners = [];
  const notifications = [];
  let intervalCallback;
  const video = {
    currentSrc: "https://cdn.example/video.mp4?token=secret",
    src: "https://cdn.example/video.mp4?token=secret",
    type: "video/mp4",
    closest() { return this; },
    getAttribute(name) { return name === "src" ? this.src : null; },
  };
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    console,
    location: { href: "https://example.com/watch" },
    document: {
      title: "Fixture video",
      documentElement: {},
      querySelectorAll(selector) {
        return selector.includes("video") ? [video] : [];
      },
      // SPA navigation event subscriptions (yt-navigate-finish etc.): no real
      // dispatch needed in the stub.
      addEventListener() {},
    },
    performance: {
      getEntriesByType() {
        return [{ name: "https://cdn.example/master.m3u8?token=secret" }];
      },
    },
    MutationObserver: class {
      observe() {}
    },
    window: {
      setTimeout,
      setInterval(callback) { intervalCallback = callback; },
    },
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { listeners.push(listener); } },
        sendMessage(message) {
          notifications.push(message);
          return Promise.resolve();
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(source, context);
  vm.runInContext(contentSource, context);
  await new Promise((resolve) => setTimeout(resolve, 160));

  assert.equal(notifications.length, 1);
  assert.equal(
    JSON.stringify(notifications[0].candidates.map((candidate) => candidate.format)),
    JSON.stringify(["video", "hls"]),
  );
  assert.equal(notifications[0].candidates[0].displayURL.includes("secret"), false);
  assert.equal(listeners.length, 1);
  let response;
  listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 2);

  context.location.href = "https://example.com/next";
  intervalCallback();
  await new Promise((resolve) => setTimeout(resolve, 160));
  assert.equal(notifications.length, 2);
  assert.equal(notifications[1].pageUrl, "https://example.com/next");
});

test("content script suppresses synchronous runtime errors after extension reload", async () => {
  const mediaUtilsSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
    "utf8",
  );
  const contentSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
    "utf8",
  );
  const listeners = [];
  let intervalCallback;
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    console,
    location: { href: "https://example.com/watch" },
    document: {
      title: "Fixture video",
      documentElement: {},
      querySelectorAll() { return []; },
      addEventListener() {},
    },
    performance: { getEntriesByType() { return []; } },
    MutationObserver: class { observe() {} },
    window: {
      setTimeout,
      setInterval(callback) { intervalCallback = callback; },
    },
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { listeners.push(listener); } },
        sendMessage() {
          throw new Error("Extension context invalidated.");
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(contentSource, context);
  await new Promise((resolve) => setTimeout(resolve, 160));
  intervalCallback?.();
  await new Promise((resolve) => setTimeout(resolve, 160));
  assert.equal(listeners.length, 1);
});

test("content script collapses same-cid m4s fragments to protect the FIFO limit", async () => {
  const mediaUtilsSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
    "utf8",
  );
  const contentSource = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
    "utf8",
  );
  const listeners = [];
  const notifications = [];
  const video = {
    currentSrc: "https://cdn.example/video.mp4",
    src: "https://cdn.example/video.mp4",
    type: "video/mp4",
    closest() { return this; },
    getAttribute(name) { return name === "src" ? this.src : null; },
  };
  // Simulate Bilibili DASH: multiple video tracks + audio track m4s
  // fragments of the same cid
  const resourceEntries = [
    { name: "https://upgz.bilivideo.com/1550776785-1-100022.m4s" },
    { name: "https://upgz.bilivideo.com/1550776785-1-100116.m4s" },
    { name: "https://upgz.bilivideo.com/1550776785-1-100072.m4s" },
    { name: "https://upgz.bilivideo.com/1550776785-1-30280.m4s" },
    { name: "https://upgz.bilivideo.com/1550776785-1-30216.m4s" },
  ];
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    console,
    location: { href: "https://example.com/video" },
    document: {
      title: "B站测试视频",
      documentElement: {},
      querySelectorAll(selector) {
        return selector.includes("video") ? [video] : [];
      },
      addEventListener() {},
    },
    performance: {
      getEntriesByType() {
        return resourceEntries;
      },
    },
    MutationObserver: class {
      observe() {}
    },
    window: {
      setTimeout,
      setInterval() {},
    },
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { listeners.push(listener); } },
        sendMessage(message) {
          notifications.push(message);
          return Promise.resolve();
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(source, context);
  vm.runInContext(contentSource, context);
  await new Promise((resolve) => setTimeout(resolve, 160));

  // Pairing folds same-CID fragments but must not remove the independent
  // video.mp4.
  let response;
  listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 2);
  assert.ok(response.candidates.some(c => c.url.endsWith("video.mp4")));
  const paired = response.candidates.find((c) => c.pairKind === "m4s-pair");
  assert.ok(paired, "same-cid video/audio m4s should become a merge candidate");
  assert.ok(paired.pairVideoUrl.endsWith("-1-100116.m4s"));
  assert.ok(paired.pairAudioUrl.endsWith("-1-30280.m4s"));
});

// ===== MAIN world fetch-interceptor (pure functions) =====

function loadFetchInterceptor() {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(fetchInterceptorSource, context);
  return context.MacIDMFetchInterceptor;
}

test("fetch interceptor manifest magic detects HLS/DASH without false positives", () => {
  const kit = loadFetchInterceptor();
  assert.equal(kit.sniffManifestMagic("#EXTM3U\n#EXT-X-VERSION:3\n"), "hls");
  assert.equal(kit.sniffManifestMagic("  \t\r\n\uFEFF#EXTM3U"), "hls");
  assert.equal(
    kit.sniffManifestMagic('<?xml version="1.0" encoding="UTF-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011">'),
    "dash",
  );
  assert.equal(kit.sniffManifestMagic('{"data":{"url":"https://cdn.example/video.mp4"}}'), null);
  assert.equal(kit.sniffManifestMagic("<html><body>#EXTM3U is not at the start</body></html>"), null);
  assert.equal(kit.sniffManifestMagic(""), null);
});

test("fetch interceptor isMediaLikeURL ignores media extensions embedded in query strings", () => {
  // Same policy as discovery.isMediaCandidate: CDN m4s addresses copied into
  // Bilibili beacon-log query strings must not trigger fetch/XHR URL
  // capture candidates.
  const kit = loadFetchInterceptor();
  const beacon = "https://data.bilibili.com/log/web?0011|Default:Ugc:0|https://cn-hbyc-ct-01-05.bilivideo.com/upgcxcode/82/76/40214857682/40214857682-1-30011.m4s?e=abc&deadline=123";
  assert.equal(kit.isMediaLikeURL(beacon), false);
  assert.equal(kit.isMediaLikeURL("https://example.com/redir?url=https://cdn.example/v.mp4"), false);
  assert.equal(kit.isMediaLikeURL("https://example.com/page#https://cdn.example/v.mp4"), false);
  // Path extensions (with signed queries) and explicit ?mime=/?type=
  // declarations stay recognized.
  assert.equal(kit.isMediaLikeURL("https://cdn.example/track.m4s?e=abc"), true);
  assert.equal(kit.isMediaLikeURL("https://cdn.example/stream?type=video/mp4"), true);
});

test("fetch interceptor JSON deep scan extracts embedded media URLs", () => {
  const kit = loadFetchInterceptor();
  const result = kit.scanJSONForMedia(
    {
      code: 0,
      data: {
        cover: "https://cdn.example/cover.jpg",
        hls: "https://cdn.example/live/master.m3u8?token=a",
        sources: [{ src: "https://cdn.example/a/video.mp4" }, { src: "/relative/audio.m4a" }],
      },
    },
    "https://api.example.com/v1/play",
  );
  assert.ok(result.urls.includes("https://cdn.example/live/master.m3u8?token=a"));
  assert.ok(result.urls.includes("https://cdn.example/a/video.mp4"));
  assert.ok(result.urls.includes("https://api.example.com/relative/audio.m4a"));
  assert.ok(!result.urls.some((url) => url.includes("cover.jpg")));
  assert.equal(result.dashJsonManifest, false);
});

test("fetch interceptor JSON deep scan honors depth/width/field budgets", () => {
  const kit = loadFetchInterceptor();
  // Depth budget: a media URL at depth 8 is not extracted; a shallow one is.
  const deep = { a: { b: { c: { d: { e: { f: { g: { url: "https://cdn.example/deep.mp4" } } } } } } } };
  assert.equal(kit.scanJSONForMedia(deep, "https://api.example.com").urls.length, 0);
  const shallow = { a: { b: { c: { d: { url: "https://cdn.example/shallow.mp4" } } } } };
  assert.deepEqual([...kit.scanJSONForMedia(shallow, "https://api.example.com").urls], [
    "https://cdn.example/shallow.mp4",
  ]);
  // Width budget: at most 50 elements are visited per level.
  const wide = { list: Array.from({ length: 200 }, (_, i) => `https://cdn.example/w-${i}.mp4`) };
  assert.equal(kit.scanJSONForMedia(wide, "https://api.example.com").urls.length, 50);
  // Cumulative field budget: scanning stops early at 3000 subtrees; not
  // everything is extracted.
  const huge = {};
  for (let i = 0; i < 3_000; i += 1) huge[`k${i}`] = { u: `https://cdn.example/v-${i}.mp4` };
  const hugeResult = kit.scanJSONForMedia(huge, "https://api.example.com");
  assert.ok(hugeResult.urls.length > 0);
  assert.ok(hugeResult.urls.length < 3_000);
  assert.ok(hugeResult.urls.includes("https://cdn.example/v-0.mp4"));
});

test("fetch interceptor recognizes DASH JSON manifest structures", () => {
  const kit = loadFetchInterceptor();
  const tracks = kit.scanJSONForMedia(
    {
      video: [{ baseURL: "https://cdn.example/video.m4s" }],
      audio: [{ baseURL: "https://cdn.example/audio.m4s" }],
    },
    "https://api.example.com/manifest",
  );
  assert.equal(tracks.dashJsonManifest, true);
  const durl = kit.scanJSONForMedia(
    { durl: [{ url: "https://cdn.example/stream.flv?sig=x" }] },
    "https://api.example.com/playurl",
  );
  assert.equal(durl.dashJsonManifest, true);
  assert.ok(durl.urls.includes("https://cdn.example/stream.flv?sig=x"));
  const plain = kit.scanJSONForMedia({ title: "no tracks" }, "https://api.example.com");
  assert.equal(plain.dashJsonManifest, false);
});

// ===== Normalization and dedup =====

function loadMediaUtils() {
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  return context.MacIDMMediaUtils;
}

test("normalizeResourceURL strips only explicit tracking params", () => {
  const mediaUtils = loadMediaUtils();
  assert.equal(
    mediaUtils.normalizeResourceURL(
      "https://cdn.example/v.mp4?utm_source=a&utm_medium=b&fbclid=1&gclid=2&gopvid=3&spm=4&share_from=x&sig=keep#frag",
    ),
    "https://cdn.example/v.mp4?sig=keep",
  );
  // x_ signature-style params and unknown params are always kept (downloads
  // may need them).
  assert.equal(
    mediaUtils.normalizeResourceURL("https://cdn.example/v.mp4?x_signature=1&token=t"),
    "https://cdn.example/v.mp4?x_signature=1&token=t",
  );
  assert.equal(mediaUtils.normalizeResourceURL("not a url"), "not a url");
});

// ===== MAIN world postMessage -> content script candidates =====

function bootContentScript() {
  const listeners = [];
  const notifications = [];
  const windowListeners = {};
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    console,
    location: { href: "https://example.com/watch" },
    document: {
      title: "Fixture video",
      documentElement: {},
      querySelectorAll() { return []; },
      addEventListener() {},
    },
    performance: { getEntriesByType() { return []; } },
    MutationObserver: class { observe() {} },
    window: {
      setTimeout,
      setInterval() {},
      addEventListener(type, listener) {
        (windowListeners[type] ??= []).push(listener);
      },
    },
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { listeners.push(listener); } },
        sendMessage(message) {
          notifications.push(message);
          return Promise.resolve();
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(source, context);
  vm.runInContext(contentSource, context);
  return { context, listeners, notifications, windowListeners };
}

function postFetchCapture(boot, data, { source } = {}) {
  const messageListeners = boot.windowListeners.message ?? [];
  for (const listener of messageListeners) {
    listener({ source: source ?? boot.context.window, data });
  }
}

test("MAIN world fetch capture becomes a fetch-confidence candidate", () => {
  const kit = loadFetchInterceptor();
  const boot = bootContentScript();
  assert.ok((boot.windowListeners.message ?? []).length >= 1);
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/dyn/video.mp4?sig=abc",
    mime: "",
    format: "",
    via: "fetch",
  });
  // Defense: postMessages with a non-window source or an unknown type are
  // ignored.
  postFetchCapture(boot, { type: kit.MESSAGE_TYPE, url: "https://cdn.example/forged.mp4" }, { source: {} });
  postFetchCapture(boot, { type: "other.message", url: "https://cdn.example/noise.mp4" });

  let response;
  boot.listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 1);
  assert.equal(response.candidates[0].url, "https://cdn.example/dyn/video.mp4?sig=abc");
  assert.equal(response.candidates[0].confidence, "fetch");
});

test("response-body magic reports carry magic confidence and manifest format", () => {
  const kit = loadFetchInterceptor();
  const boot = bootContentScript();
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://api.example.com/stream/playlist",
    mime: "application/vnd.apple.mpegurl",
    format: "hls",
    via: "magic",
  });
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://api.example.com/playurl",
    mime: "",
    format: "dash-json",
    via: "magic",
  });

  let response;
  boot.listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  const hls = response.candidates.find((c) => c.url === "https://api.example.com/stream/playlist");
  assert.equal(hls.confidence, "magic");
  assert.equal(hls.format, "hls");
  const dashJson = response.candidates.find((c) => c.url === "https://api.example.com/playurl");
  assert.equal(dashJson.confidence, "magic");
  assert.equal(dashJson.format, "dash-json");
});

test("tracking-param variants of one URL dedupe to a single candidate", () => {
  const kit = loadFetchInterceptor();
  const boot = bootContentScript();
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/movie.mp4?sig=abc&utm_source=share&utm_campaign=x",
    via: "fetch",
  });
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/movie.mp4?fbclid=123&sig=abc",
    via: "fetch",
  });

  let response;
  boot.listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 1);
  // Display keeps the original first-reported URL (with its raw params).
  assert.equal(
    response.candidates[0].url,
    "https://cdn.example/movie.mp4?sig=abc&utm_source=share&utm_campaign=x",
  );
});

test("repeat reports keep the higher confidence", () => {
  const kit = loadFetchInterceptor();
  const boot = bootContentScript();
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/track/master.m3u8",
    via: "fetch",
  });
  postFetchCapture(boot, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/track/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
    format: "hls",
    via: "magic",
  });

  let response;
  boot.listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 1);
  assert.equal(response.candidates[0].confidence, "magic");
});

// ===== Sniff false-positive governance (content-script snapshot pipeline) =====

const sniffGovernanceSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/sniff-governance.js", import.meta.url),
  "utf8",
);

test("content script snapshot applies sniff governance and reports filtered counts", async () => {
  const kit = loadFetchInterceptor();
  const listeners = [];
  const notifications = [];
  const windowListeners = {};
  const storageListeners = [];
  let storedSettings = {
    settings: {
      sniffGovernance: { enabled: true, audioMinimumBytes: 64 * 1024, segmentMaximumBytes: 16 * 1024 },
    },
  };
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    console,
    location: { href: "https://example.com/watch" },
    document: {
      title: "Fixture video",
      documentElement: {},
      querySelectorAll() { return []; },
      addEventListener() {},
    },
    performance: { getEntriesByType() { return []; } },
    MutationObserver: class { observe() {} },
    window: {
      setTimeout,
      setInterval() {},
      addEventListener(type, listener) {
        (windowListeners[type] ??= []).push(listener);
      },
    },
    chrome: {
      runtime: {
        onMessage: { addListener(listener) { listeners.push(listener); } },
        sendMessage(message) {
          notifications.push(message);
          return Promise.resolve();
        },
      },
      storage: {
        local: {
          get(key) {
            return Promise.resolve(key === "settings" ? storedSettings : {});
          },
        },
        onChanged: {
          addListener(listener) { storageListeners.push(listener); },
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(sniffGovernanceSource, context);
  vm.runInContext(source, context);
  vm.runInContext(contentSource, context);

  // One real video + one diagnostic audio (below the size threshold; size
  // injected via the background webRequest backfill path — fetch capture
  // does not carry size).
  postFetchCapture({ context, windowListeners }, {
    type: kit.MESSAGE_TYPE,
    url: "https://cdn.example/movie.mp4",
    via: "fetch",
  });
  listeners[0]({ type: "macidm.addMediaCandidate", candidate: { url: "https://cdn.example/success.mp3", size: 2048, mime: "audio/mpeg" } }, {}, () => {});

  let response;
  listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  // vm realm array prototypes differ from the host's; copy into the host
  // realm before deepEqual.
  assert.deepEqual(
    [...response.candidates.map((candidate) => candidate.url)],
    ["https://cdn.example/movie.mp4"],
    "diagnostic audio is suppressed from the snapshot",
  );
  assert.deepEqual({ ...response.filteredSummary }, { diagnosticAudio: 1, streamSegments: 0, smallResources: 0 });

  // Governance toggled off from the Popup: after the storage change the
  // content script republishes under the new settings, the suppressed
  // candidates return to the snapshot, and the counts reset to zero.
  storedSettings = { settings: { sniffGovernance: { enabled: false } } };
  for (const listener of storageListeners) {
    listener(
      { settings: { newValue: storedSettings.settings, oldValue: { sniffGovernance: { enabled: true } } } },
      "local",
    );
  }
  await new Promise((resolve) => setTimeout(resolve, 160));
  listeners[0]({ type: "macidm.getMediaCandidates" }, {}, (value) => { response = value; });
  assert.equal(response.candidates.length, 2, "disabled governance keeps every candidate");
  assert.deepEqual({ ...response.filteredSummary }, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
  assert.ok(
    notifications.some((message) => message.type === "media.candidatesUpdated"
      && message.filteredSummary != null),
    "candidate updates carry the desensitized summary",
  );
});
