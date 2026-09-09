import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// Self-contained tests for the MAIN world player bridge (AI handover doc
// §4.3): dedup must be guaranteed by the bridge itself — the fingerprint
// must not contain dynamic timestamps, a stable page stays silent, and any
// real change to videoId, live status, or the format set publishes
// immediately. Earlier content-script tests only re-dispatched the same
// message by hand, which cannot prove the bridge deduplicates on its own.
const bridgeSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/content/youtube-player-bridge.js", import.meta.url),
  "utf8",
);

function fmt(itag, height) {
  return { itag, height, width: Math.round((height * 16) / 9), bitrate: 1_000, mimeType: "video/mp4" };
}

function playerResponse(videoId, { title = "Fixture", formats = [], adaptiveFormats = [], isLive } = {}) {
  const details = { videoId, title, lengthSeconds: "120" };
  if (isLive !== undefined) details.isLive = isLive;
  return { videoDetails: details, streamingData: { formats, adaptiveFormats } };
}

const DATA_TYPE = "macidm.youTubePlayerData";
const REQUEST_TYPE = "macidm.requestYouTubePlayerData";

/// The bridge runs in an isolated vm: records postMessage output, exposes
/// manually triggered 120 ms debounce and 1 s polling, plus a switchable
/// page URL and playerData.
function createBridgeVM(href) {
  const posted = [];
  const intervalCallbacks = [];
  const timeoutCallbacks = [];
  const messageListeners = [];
  const state = { playerData: null };
  const location = { pathname: "", search: "" };
  const navigate = (value) => {
    const u = new URL(value);
    location.pathname = u.pathname;
    location.search = u.search;
  };
  navigate(href);
  const context = {
    URLSearchParams,
    location,
    document: {
      querySelector(selector) {
        return selector === "ytd-watch-flexy" ? state : null;
      },
      addEventListener() {},
    },
    postMessage(data) {
      posted.push(data);
    },
    setTimeout(fn) {
      timeoutCallbacks.push(fn);
      return timeoutCallbacks.length;
    },
    setInterval(fn) {
      intervalCallbacks.push(fn);
      return intervalCallbacks.length;
    },
    addEventListener(type, fn) {
      if (type === "message") messageListeners.push(fn);
    },
  };
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  return {
    posted,
    state,
    navigate,
    /// Runs pending 120 ms debounce work (the first read at install time and
    /// explicit reread requests).
    flushScheduled() {
      while (timeoutCallbacks.length > 0) timeoutCallbacks.shift()();
    },
    /// One 1 s poll.
    tick() {
      for (const fn of intervalCallbacks) fn();
    },
    /// An explicit reread request from the content script; the source must
    /// be the window itself.
    requestReread() {
      const source = vm.runInContext("globalThis", context);
      for (const fn of messageListeners) fn({ source, data: { type: REQUEST_TYPE } });
    },
  };
}

const WATCH_URL = "https://www.youtube.com/watch?v=abc123";

test("初次读取发布 1 次；连续多次相同轮询保持 1 次", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "首次读取必须发布");

  env.tick();
  env.tick();
  env.tick();
  assert.equal(env.posted.length, 1, "内容不变的重复轮询不得重复发布");
});

test("仅时间推进不发布：指纹不得包含动态时间戳", async () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);
  // The published payload still carries the capture time (consumers need
  // it), but it is not part of the fingerprint.
  const payload = env.posted[0].payload;
  assert.equal(env.posted[0].type, DATA_TYPE);
  assert.ok(Number.isFinite(payload.capturedAt), "发布时才附加 capturedAt");

  // Let the wall clock really advance: if the timestamp were part of the
  // fingerprint, this would necessarily republish.
  await new Promise((resolve) => setTimeout(resolve, 15));
  env.tick();
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "仅时间推进不构成发布理由");
});

test("显式重读请求触发重读，但业务内容未变化时不重发完整快照", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  env.requestReread();
  env.flushScheduled();
  env.tick();
  assert.equal(env.posted.length, 1, "内容未变化的重读不得重发");
});

test("videoId 变化立即发布", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  env.navigate("https://www.youtube.com/watch?v=def456");
  env.state.playerData = playerResponse("def456", { formats: [fmt(137, 1080)] });
  env.tick();
  assert.equal(env.posted.length, 2, "新视频必须立即发布");
  assert.equal(env.posted.at(-1).payload.videoId, "def456");
});

test("formats 晚到或集合变化立即发布", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "无格式的初始响应也发布一次");

  // Qualities arrive late: a set change publishes immediately.
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.tick();
  assert.equal(env.posted.length, 2, "formats 晚到必须立即发布");

  // The set changes again (an adaptive entry is added): keep publishing.
  env.state.playerData = playerResponse("abc123", {
    formats: [fmt(137, 1080)],
    adaptiveFormats: [fmt(140, 0)],
  });
  env.tick();
  assert.equal(env.posted.length, 3);

  // Set unchanged: silence.
  env.tick();
  assert.equal(env.posted.length, 3);
});

test("直播状态变化立即发布", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)], isLive: false });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)], isLive: true });
  env.tick();
  assert.equal(env.posted.length, 2, "直播状态变化必须立即发布");
});

test("旧 player response 不得泄漏到新页面（/watch 与 /watch 之间）", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  // Navigated to a new video but the player data has not updated: the old
  // data mismatches the current URL videoId, refuse to publish.
  env.navigate("https://www.youtube.com/watch?v=newvid99");
  env.tick();
  env.tick();
  assert.equal(env.posted.length, 1, "SPA 竞态下旧视频数据不得发布到新页面");

  env.state.playerData = playerResponse("newvid99", { formats: [fmt(136, 720)] });
  env.tick();
  assert.equal(env.posted.length, 2);
  assert.equal(env.posted.at(-1).payload.videoId, "newvid99");
});

test("/watch 离开到首页后残留的旧 playerData 不得发布（轮询与显式重读均静默）", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "前置条件：watch 页正常发布");

  // SPA navigation to the homepage; the ytd-watch-flexy component retains
  // the old video's playerData.
  env.navigate("https://www.youtube.com/");
  env.tick();
  env.tick();
  env.requestReread();
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "非视频页轮询与显式重读都不得发布旧响应");
});

test("首页初次加载桥时 DOM 已残留旧响应：首次读取不得发布", () => {
  const env = createBridgeVM("https://www.youtube.com/");
  env.state.playerData = playerResponse("oldvideo1", {
    title: "OLD TITLE",
    formats: [fmt(137, 1080)],
  });
  env.flushScheduled();
  env.tick();
  assert.equal(env.posted.length, 0, "首页残留的旧 playerData 必须失败关闭");
});

test("搜索结果页残留旧响应不得发布", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  env.navigate("https://www.youtube.com/results?search_query=cats");
  env.tick();
  env.requestReread();
  env.flushScheduled();
  assert.equal(env.posted.length, 1, "搜索页不得发布旧视频的响应");
});

test("非视频页失败关闭不是永久失活：回到新视频后匹配响应立即发布", () => {
  const env = createBridgeVM(WATCH_URL);
  env.state.playerData = playerResponse("abc123", { formats: [fmt(137, 1080)] });
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  // A watch -> home -> new video B round trip: the bridge must resume
  // publishing, not stay permanently silent from fail-closing.
  env.navigate("https://www.youtube.com/");
  env.tick();
  assert.equal(env.posted.length, 1, "首页保持静默");
  env.navigate("https://www.youtube.com/watch?v=newvid77");
  env.state.playerData = playerResponse("newvid77", { formats: [fmt(136, 720)] });
  env.tick();
  assert.equal(env.posted.length, 2, "回到视频页后匹配响应必须立即发布");
  assert.equal(env.posted.at(-1).payload.videoId, "newvid77");
});

test("/shorts/<id> 与 /live/<id> 的 URL videoId 校验与 /watch 一致", () => {
  // /shorts page: a matching player response publishes normally.
  const shorts = createBridgeVM("https://www.youtube.com/shorts/xyz98765");
  shorts.state.playerData = playerResponse("xyz98765", { formats: [fmt(137, 1080)] });
  shorts.flushScheduled();
  assert.equal(shorts.posted.length, 1, "/shorts 页面应正常发布匹配数据");

  // Leftover data of another video on the /shorts page must be rejected.
  shorts.navigate("https://www.youtube.com/shorts/other12345");
  shorts.tick();
  assert.equal(shorts.posted.length, 1, "/shorts 换代后旧数据不得泄漏");

  // /live page follows the same rule.
  const live = createBridgeVM("https://www.youtube.com/live/live98765");
  live.state.playerData = playerResponse("live98765", { formats: [fmt(137, 1080)] });
  live.flushScheduled();
  assert.equal(live.posted.length, 1, "/live 页面应正常发布匹配数据");
  live.navigate("https://www.youtube.com/live/other12345");
  live.tick();
  assert.equal(live.posted.length, 1, "/live 换代后旧数据不得泄漏");
});

test("载荷只含白名单字段：标题有长度上限，且不含 url/cipher/signatureCipher", () => {
  const env = createBridgeVM(WATCH_URL);
  const longTitle = "题".repeat(600);
  env.state.playerData = {
    videoDetails: { videoId: "abc123", title: longTitle, lengthSeconds: "120" },
    streamingData: {
      formats: [
        {
          ...fmt(137, 1080),
          url: "https://signed.example/media?token=SECRET",
          cipher: "sp=x&url=https://signed.example/c",
          signatureCipher: "sp=sig&url=https://signed.example/sc",
        },
      ],
      adaptiveFormats: [],
    },
  };
  env.flushScheduled();
  assert.equal(env.posted.length, 1);

  const payload = env.posted[0].payload;
  assert.equal(payload.videoDetails.title.length, 500, "标题必须被长度上限截断");
  const serialized = JSON.stringify(payload);
  assert.ok(!serialized.includes("signatureCipher"), "不得转发 signatureCipher");
  assert.ok(!serialized.includes("cipher"), "不得转发 cipher");
  assert.ok(!serialized.includes("signed.example"), "不得转发媒体签名 URL");
  const format = payload.streamingData.formats[0];
  assert.deepEqual(
    Object.keys(format).sort(),
    ["approxDurationMs", "bitrate", "contentLength", "fps", "height", "itag", "mimeType", "width"].sort(),
    "格式条目只保留画质所需的白名单字段",
  );
});
