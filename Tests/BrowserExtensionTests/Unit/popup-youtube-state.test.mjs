import assert from "node:assert/strict";
import test from "node:test";

// Popup 的 YouTube 状态键（docs/AI交接.md §2.4）：快照与候选 URL 仅参数不同但
// videoId 相同时，画质与终态仍正确显示；A→B 仍丢弃旧视频状态。
//
// popup.js 是 ES module 且在模块顶层执行 initialize()：先安装最小 DOM/
// chrome 桩，再动态导入。node --test 每个文件独立进程，桩不污染其它用例。
import "../../../BrowserExtension/chrome/src/shared/media-utils.js";
import "../../../BrowserExtension/chrome/src/shared/youtube-format-utils.js";
import "../../../BrowserExtension/chrome/src/shared/media-presentation.js";
import "../../../BrowserExtension/chrome/src/shared/category.js";
import "../../../BrowserExtension/chrome/src/shared/i18n-access.js";

const URL_A = "https://www.youtube.com/watch?v=abc123";
const URL_B = `${URL_A}&t=60s`;
const URL_C = "https://www.youtube.com/watch?v=cccc3333";

const VARIANT = {
  url: `${URL_A}#height=1080&itag=137`,
  itag: 137,
  width: 1920,
  height: 1080,
  bandwidth: 4_000_000,
  fps: 30,
  codecs: "avc1.640028",
  label: "1080P",
  estimatedSize: 165675008,
  duration: 600,
};

const VARIANT_WITHOUT_ESTIMATE = {
  url: `${URL_A}#height=720&itag=136`,
  itag: 136,
  width: 1280,
  height: 720,
  label: "720P",
};

// ---- 最小 DOM 桩：覆盖 popup.js 渲染路径的元素操作 ----

class El {
  constructor(tag) {
    this.tagName = String(tag ?? "div").toUpperCase();
    this.id = "";
    this.children = [];
    this.listeners = {};
    this.attributes = {};
    this.style = {};
    this.dataset = {};
    this.parentNode = null;
    this._fragment = false;
    this._text = "";
    this.className = "";
    this.hidden = false;
    this.disabled = false;
    this.checked = false;
    this.value = "";
    this._title = "";
    this._innerHTML = "";
  }

  get innerHTML() {
    return this._innerHTML;
  }
  set innerHTML(val) {
    this._innerHTML = String(val ?? "");
  }

  get classList() {
    const tokens = new Set(this.className ? this.className.split(/\s+/).filter(Boolean) : []);
    return {
      add: (...names) => {
        for (const name of names) if (name) tokens.add(name);
        this.className = [...tokens].join(" ");
      },
      remove: (...names) => {
        for (const name of names) tokens.delete(name);
        this.className = [...tokens].join(" ");
      },
      toggle: (name, force) => {
        const has = tokens.has(name);
        const next = typeof force === "boolean" ? force : !has;
        if (next) tokens.add(name);
        else tokens.delete(name);
        this.className = [...tokens].join(" ");
        return next;
      },
      contains: (name) => tokens.has(name),
    };
  }

  get title() {
    return this._title;
  }
  set title(val) {
    this._title = String(val ?? "");
  }

  get textContent() {
    if (this._text) return this._text;
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(val) {
    this._text = String(val ?? "");
    this.children = [];
  }

  setAttribute(k, v) {
    this.attributes[k] = String(v);
  }
  getAttribute(k) {
    return this.attributes[k] ?? null;
  }
  removeAttribute(k) {
    delete this.attributes[k];
  }

  append(...nodes) {
    for (const node of nodes) {
      if (!node) continue;
      if (node._fragment) {
        for (const child of node.children) {
          child.parentNode = this;
          this.children.push(child);
        }
        node.children = [];
        continue;
      }
      node.parentNode = this;
      this.children.push(node);
    }
  }

  replaceChildren(...nodes) {
    this.children = [];
    this._text = "";
    this.append(...nodes);
  }

  addEventListener(type, listener) {
    this.listeners[type] = this.listeners[type] || [];
    this.listeners[type].push(listener);
  }

  dispatch(type, event = {}) {
    const list = this.listeners[type] || [];
    for (const l of list) l({ target: this, currentTarget: this, ...event });
  }

  getBoundingClientRect() {
    return { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 };
  }

  walk(callback) {
    callback(this);
    for (const child of this.children) {
      if (child instanceof El) child.walk(callback);
    }
  }
}

const elementsById = new Map();
function elementFor(id) {
  if (!elementsById.has(id)) {
    const el = new El(id === "filtered-note" ? "p" : "div");
    el.id = id;
    elementsById.set(id, el);
  }
  return elementsById.get(id);
}

const mediaList = elementFor("media-list");
const mediaCount = elementFor("media-count");
const hostStatus = elementFor("host-status");
const takeoverToggle = elementFor("takeover-toggle");
const governanceToggle = elementFor("sniff-governance-toggle");
const cookieStatus = elementFor("cookie-status");
const downloadAll = elementFor("download-all");
const menu = elementFor("menu");
const menuButton = elementFor("menu-button");
const openApp = elementFor("open-app");
const languageSelect = elementFor("language-select");
const filteredNote = elementFor("filtered-note");

globalThis.document = {
  documentElement: new El("html"),
  body: new El("body"),
  getElementById: (id) => elementFor(id),
  createElement(tag) {
    return new El(tag);
  },
  createDocumentFragment() {
    const fragment = new El("#fragment");
    fragment._fragment = true;
    return fragment;
  },
  querySelector(selector) {
    if (typeof selector === "string" && selector.startsWith("#")) {
      return elementFor(selector.slice(1));
    }
    return null;
  },
  querySelectorAll() {
    return [];
  },
  addEventListener() {},
};

let refreshIntervalCallback = null;
globalThis.window = {
  addEventListener() {},
  setInterval(callback) {
    refreshIntervalCallback = callback;
    return 0;
  },
  clearInterval() {},
  innerHeight: 800,
};

const sent = [];
const mediaQueue = [];
const mockStorage = { settings: { language: "zh-CN" }, language: "zh-CN" };
const storageRemoveCalls = [];
const recordedToasts = [];
globalThis.MacIDMPanelUI = {
  showToast(container, message, options) {
    recordedToasts.push({ message, options });
  },
};
let currentPopupStatus = {
  connected: true,
  takeoverEnabled: true,
  sniffGovernanceEnabled: false,
};

let popupTabUrl = URL_A;
const permissionRequests = [];
const permissionState = { granted: false, requestResult: false };
// media.inspect 挂起控制：解析中加载图标的过渡态需要解析请求保持 in-flight。
let inspectHeld = false;
let inspectHeldResolve = null;
function holdMediaInspect() {
  inspectHeld = true;
}
function releaseMediaInspect(value) {
  inspectHeld = false;
  if (inspectHeldResolve) {
    const resolve = inspectHeldResolve;
    inspectHeldResolve = null;
    resolve(value);
  }
}
globalThis.chrome = {
  tabs: {
    query: async () => [{ id: 7, url: popupTabUrl }],
  },
  runtime: {
    sendMessage(message) {
      sent.push(message);
      switch (message?.type) {
        case "popup.status":
          return Promise.resolve(currentPopupStatus);
        case "popup.mediaCandidates":
          return Promise.resolve(
            mediaQueue.length > 0 ? mediaQueue.shift() : { ok: false, message: "empty" },
          );
        case "youtube.ensureInspection": {
          const url = String(message.url ?? "");
          if (url.includes("v=abc123")) {
            return Promise.resolve({
              ok: true,
              snapshot: {
                tabId: 7,
                pageUrl: url,
                videoId: "abc123",
                stage: "complete",
                variants: [VARIANT, VARIANT_WITHOUT_ESTIMATE],
                variantCount: 2,
                mayComplete: false,
                retryable: false,
              },
            });
          }
          return Promise.resolve({ ok: false });
        }
        case "media.inspect": {
          if (inspectHeld) {
            return new Promise((resolve) => {
              inspectHeldResolve = resolve;
            });
          }
          return Promise.resolve({ ok: true, variants: [] });
        }
        default:
          return Promise.resolve({ ok: true });
      }
    },
    onMessage: {
      addListener() {},
    },
  },
  storage: {
    local: {
      get: async (key) => {
        if (typeof key === "string") return { [key]: mockStorage[key] };
        if (Array.isArray(key)) {
          const res = {};
          for (const k of key) res[k] = mockStorage[k];
          return res;
        }
        return { ...mockStorage };
      },
      set: async (obj) => {
        Object.assign(mockStorage, obj);
      },
      remove: async (key) => {
        storageRemoveCalls.push(key);
        const keys = Array.isArray(key) ? key : [key];
        for (const k of keys) delete mockStorage[k];
      },
    },
    onChanged: {
      addListener() {},
    },
  },
  permissions: {
    contains: async () => permissionState.granted,
    request: async (query) => {
      permissionRequests.push(query);
      permissionState.granted = permissionState.requestResult;
      return permissionState.requestResult;
    },
  },
};

mediaQueue.push({
  ok: true,
  pageUrl: URL_A,
  title: "Fixture Video",
  candidates: [{ url: URL_A, siteAdapter: "youtube" }],
});

await import("../../../BrowserExtension/chrome/src/popup/popup.js");

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function ensureInspectionCount() {
  return sent.filter((message) => message.type === "youtube.ensureInspection").length;
}

/// 获取首个候选行渲染的标题文本
function getFirstRowTitleText() {
  const row = mediaList.children[0];
  if (!row) return "";
  let titleText = "";
  row.walk((el) => {
    if (el instanceof El && el.tagName === "STRONG") {
      titleText = el.textContent;
    }
  });
  return titleText;
}

/// 获取首个候选行渲染的 meta 文本（如 "MP4 · 约 165.7 MB"）
function getFirstRowMetaText() {
  const row = mediaList.children[0];
  if (!row) return "";
  let metaText = "";
  row.walk((el) => {
    if (el instanceof El && el.classList.contains("media-meta")) {
      metaText = el.textContent;
    }
  });
  return metaText;
}

/// 查找主行 meta 区的解析中加载图标（.meta-spinner）
function findMetaSpinner() {
  let found = null;
  mediaList.walk((el) => {
    if (el instanceof El && el.classList.contains("meta-spinner")) found = el;
  });
  return found;
}

/// 检查首个候选行抽屉是否处于展开态
function isFirstRowAccordionOpen() {
  const row = mediaList.children[0];
  return Boolean(row?.classList?.contains("open"));
}

/// 点击唯一的候选行并展开手风琴；已展开时不重复点击（再点会折叠）。
async function openFirstRowAccordion() {
  const row = mediaList.children[0];
  assert.ok(row, "候选行必须已渲染");
  if (!row.classList.contains("open")) row.dispatch("click");
  await settle(30);
  const options = [];
  mediaList.walk((el) => {
    if (el instanceof El && el.classList.contains("pv-opt")) options.push(el);
  });
  return options;
}

test("初始化后自动解析一次并落位终态快照，渲染完整标题与主行估算大小", async () => {
  await settle(350);
  assert.equal(ensureInspectionCount(), 1, "自动解析只应触发一次");
  assert.equal(getFirstRowTitleText(), "Fixture Video", "初始渲染必须显示完整标题");
  assert.ok(
    getFirstRowMetaText().includes("165.7 MB"),
    "初始 YouTube 候选解析后主行实际显示估算大小（如 MP4 · 约 165.7 MB）",
  );
  const options = await openFirstRowAccordion();
  assert.ok(
    options.some((option) => option.textContent === "1080P · 约 165.7 MB"),
    "终态快照的画质必须渲染",
  );
  assert.ok(
    options.some((option) => option.textContent === "720P"),
    "缺失估算的规格仍应显示规格标签，但不得伪造大小",
  );
  assert.ok(
    getFirstRowMetaText().includes("最高规格：约 165.7 MB"),
    "主行估算必须明确表示它代表最高规格",
  );
  assert.ok(isFirstRowAccordionOpen(), "手风琴处于展开态");
});

test("同 videoId 仅参数变化且 payload.title 为空、新候选不带 variants：保留完整标题、主行大小、抽屉与画质，不重新解析", async () => {
  // 1.2 s 定时器桩被捕获：手动推进一轮刷新，模拟页面 URL 参数变化后的候选到达。
  // 真实复现场景：payload.title 为空，候选不带 variants 且携带通用 filenameHint
  mediaQueue.push({
    ok: true,
    pageUrl: URL_B,
    title: "",
    candidates: [{ url: URL_B, siteAdapter: "youtube", filenameHint: "YouTube 视频.mp4" }],
  });
  assert.ok(refreshIntervalCallback, "Popup 的定时刷新必须已注册");
  refreshIntervalCallback();
  await settle(350);

  assert.equal(ensureInspectionCount(), 1, "同视频参数变化不得重新触发解析");
  assert.equal(
    getFirstRowTitleText(),
    "Fixture Video",
    "同 videoId 参数变化且 payload.title 为空时必须保留已确认完整标题",
  );
  assert.ok(
    getFirstRowMetaText().includes("165.7 MB"),
    "同 videoId URL 参数变化且新候选不带 variants 时，主行仍显示相同估算大小",
  );
  assert.ok(isFirstRowAccordionOpen(), "同视频参数变化必须保留抽屉展开态");
  const options = await openFirstRowAccordion();
  assert.ok(
    options.some((option) => option.textContent === "1080P · 约 165.7 MB"),
    "快照 URL 与候选 URL 仅参数不同时，画质与终态仍正确显示",
  );
  // 点击画质选项提交：验证提交消息中的 pageTitle 保持完整标题
  options[0].dispatch("click");
  const lastDownload = sent.filter((m) => m.type === "media.download").pop();
  assert.equal(lastDownload?.pageTitle, "Fixture Video", "单变体提交时使用的 pageTitle 必须是已确认的完整标题");
  assert.ok(lastDownload?.url.startsWith(URL_A), "提交的变体 URL 正确");
  assert.equal(lastDownload?.estimatedSize, VARIANT.estimatedSize, "选择的规格必须传递自身的 estimatedSize");
  assert.equal(lastDownload?.duration, VARIANT.duration, "选择的规格必须传递自身的 duration");
});

test("不同 videoId 换代且 payload.title 暂为空：DOM 绝不得出现 A 标题，丢弃 A 的解析状态与展开态", async () => {
  // 模拟 A→B 换代：upstream background 给出新 videoId 且 title 为空
  mediaQueue.push({
    ok: true,
    pageUrl: URL_C,
    title: "",
    candidates: [{ url: URL_C, siteAdapter: "youtube", filenameHint: "YouTube 视频.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(ensureInspectionCount(), 2, "换视频后自动解析重新开放");
  assert.equal(
    getFirstRowTitleText(),
    "YouTube 视频.mp4",
    "A→B 新 videoId 且 payload.title 为空时，DOM 显示安全通用占位文案，绝不得出现 A 标题",
  );
  assert.ok(
    !getFirstRowTitleText().includes("Fixture Video"),
    "A 视频标题绝不得在 B 视频候选行中出现",
  );
  assert.ok(
    !getFirstRowMetaText().includes("165.7 MB"),
    "A 到 B 且新候选不带 variants 时，旧大小不得显示",
  );
  assert.equal(isFirstRowAccordionOpen(), false, "换视频后抽屉展开态必须关闭");
  const options = await openFirstRowAccordion();
  assert.ok(
    !options.some((option) => option.textContent === "1080P"),
    "B 的候选不得显示 A 的画质",
  );
});

test("不同 videoId 后新标题到达：正确更新为新视频标题", async () => {
  mediaQueue.push({
    ok: true,
    pageUrl: URL_C,
    title: "Other Video",
    candidates: [{ url: URL_C, siteAdapter: "youtube" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(
    getFirstRowTitleText(),
    "Other Video",
    "新视频已确认标题到达后正确更新显示",
  );
});

test("同 videoId 仅 fragment 变化且 payload.title 为空、新候选不带 variants：保留完整标题、主行大小、抽屉与画质", async () => {
  const URL_C_FRAGMENT = `${URL_C}#t=90s`;
  mediaQueue.push({
    ok: true,
    pageUrl: URL_C_FRAGMENT,
    title: "",
    candidates: [{ url: URL_C_FRAGMENT, siteAdapter: "youtube", filenameHint: "YouTube 视频.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(ensureInspectionCount(), 2, "同 videoId fragment 变化不得重新触发解析");
  assert.equal(
    getFirstRowTitleText(),
    "Other Video",
    "同 videoId fragment 变化且 payload.title 为空时必须保留已确认完整标题",
  );
});

test("视频页导航到首页且 payload.title 为空：绝不保留上一视频的标题与大小", async () => {
  const URL_HOME = "https://www.youtube.com/";
  mediaQueue.push({
    ok: true,
    pageUrl: URL_HOME,
    title: "",
    candidates: [],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(
    getFirstRowTitleText(),
    "",
    "首页无候选时不得渲染任何旧视频的标题",
  );
  assert.equal(
    getFirstRowMetaText(),
    "",
    "首页无候选时不得渲染任何旧视频的大小",
  );
  assert.ok(
    mediaList.children[0]?.classList?.contains("empty-state"),
    "首页应显示空状态提示，绝不泄露上一页标题",
  );
});

test("非 YouTube 页面保持 exact URL 语义：同 URL 空标题保留，换 URL 空标题清空，新标题到达更新", async () => {
  const NON_YT_PAGE_1 = "https://example.com/article/1";
  const NON_YT_PAGE_2 = "https://example.com/article/2";

  // 1. 访问非 YouTube 页面 1，携带完整标题
  mediaQueue.push({
    ok: true,
    pageUrl: NON_YT_PAGE_1,
    title: "Article One Title",
    candidates: [{ url: "https://example.com/media1.mp4", format: "mp4", filenameHint: "media1.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "Article One Title", "非 YouTube 页面初始渲染显示页面标题");

  // 2. 同一非 YouTube 页面刷新，payload.title 为空：exact URL 匹配保留上一轮标题
  mediaQueue.push({
    ok: true,
    pageUrl: NON_YT_PAGE_1,
    title: "",
    candidates: [{ url: "https://example.com/media1.mp4", format: "mp4", filenameHint: "media1.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "Article One Title", "非 YouTube 页面同 URL 且 title 为空时保留既有标题");

  // 3. 换到非 YouTube 页面 2，payload.title 为空：URL 不匹配，不得保留页面 1 标题
  mediaQueue.push({
    ok: true,
    pageUrl: NON_YT_PAGE_2,
    title: "",
    candidates: [{ url: "https://example.com/media2.mp4", format: "mp4", filenameHint: "media2.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "media2.mp4", "非 YouTube 换 URL 且 title 为空时不得继承旧页面标题");

  // 4. 页面 2 确认标题到达：正常更新
  mediaQueue.push({
    ok: true,
    pageUrl: NON_YT_PAGE_2,
    title: "Article Two Title",
    candidates: [{ url: "https://example.com/media2.mp4", format: "mp4", filenameHint: "media2.mp4" }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "Article Two Title", "非 YouTube 页面新标题到达后正常更新");
});

test("多规格 HLS 候选：展开后每个规格直接显示自身预估大小，缺失时不伪造，主行显示最高规格估算，提交携带该规格的 estimatedSize 与 duration", async () => {
  const HLS_PAGE = "https://example.com/video-hls";
  const HLS_VARIANT_1080 = {
    url: "https://example.com/hls/1080p.m3u8",
    width: 1920,
    height: 1080,
    bandwidth: 5_000_000,
    duration: 120,
    label: "1080P",
    estimatedSize: 75_000_000, // 75 MB
  };
  const HLS_VARIANT_720 = {
    url: "https://example.com/hls/720p.m3u8",
    width: 1280,
    height: 720,
    bandwidth: 2_500_000,
    duration: 120,
    label: "720P",
    // 无 direct estimatedSize，通过 estimateVariantSize 自动估算: 2500000 * 120 / 8 = 37500000 bytes (37.5 MB)
  };
  const HLS_VARIANT_360_NO_ESTIMATE = {
    url: "https://example.com/hls/360p.m3u8",
    width: 640,
    height: 360,
    label: "360P",
  };

  mediaQueue.push({
    ok: true,
    pageUrl: HLS_PAGE,
    title: "HLS Stream Video",
    candidates: [{
      url: "https://example.com/master.m3u8",
      format: "hls",
      filenameHint: "master.m3u8",
      variants: [HLS_VARIANT_1080, HLS_VARIANT_720, HLS_VARIANT_360_NO_ESTIMATE],
    }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "HLS Stream Video");
  assert.ok(
    getFirstRowMetaText().includes("最高规格：约 75 MB"),
    "主行显示首个最高规格的估算大小，并明确最高规格语义",
  );

  const options = await openFirstRowAccordion();
  assert.equal(options.length, 3, "渲染全部 3 个画质规格");
  assert.equal(options[0].textContent, "1080P · 约 75 MB", "1080P 规格直接可见显示自身预估大小");
  assert.equal(options[1].textContent, "720P · 约 37.5 MB", "720P 规格通过 bandwidth*duration 估算并可见显示自身大小");
  assert.equal(options[2].textContent, "360P", "缺失估算的规格仅显示标签，绝不伪造大小");

  // 点击 720P 规格提交
  options[1].dispatch("click");
  const lastDownload = sent.filter((m) => m.type === "media.download").pop();
  assert.equal(lastDownload?.url, HLS_VARIANT_720.url, "提交 720P 规格的 URL");
  assert.equal(lastDownload?.mediaKind, "hls", "提交媒体类型为 hls");
  assert.equal(lastDownload?.estimatedSize, 37_500_000, "提交 720P 规格自身的 estimatedSize");
  assert.equal(lastDownload?.duration, 120, "提交 720P 规格自身的 duration");
  assert.equal(lastDownload?.pageTitle, "HLS Stream Video", "携带正确的页面标题");
});

test("主行 meta 区在解析中显示加载图标，完成后被最高规格估算取代", async () => {
  // 用户契约：解析中状态不得只藏在抽屉里——主行 meta 区（格式标签右侧）
  // 直接显示加载图标；解析完成后被「最高规格：约 XX MB」估算槽位取代。
  holdMediaInspect();
  mediaQueue.push({
    ok: true,
    pageUrl: "https://example.com/parsing-hls",
    title: "Parsing HLS",
    candidates: [{
      url: "https://example.com/parsing/master.m3u8",
      format: "hls",
      fileExtension: "m3u8",
      filenameHint: "master.m3u8",
    }],
  });
  refreshIntervalCallback();
  await settle(320); // 渲染 + 200ms 自动解析启动 → inspecting=true → 就地重渲染

  assert.ok(findMetaSpinner(), "解析中主行 meta 显示加载图标（无需展开抽屉）");
  assert.ok(
    getFirstRowMetaText().includes("HLS 流媒体"),
    `解析中主行仍显示格式标签，实际为：${getFirstRowMetaText()}`,
  );

  // 解析完成：变体带带宽/时长 → 估算槽位取代加载图标。
  releaseMediaInspect({
    ok: true,
    variants: [{
      url: "https://example.com/parsing/720p.m3u8",
      width: 1280,
      height: 720,
      bandwidth: 4_000_000,
      duration: 600,
      label: "720P",
    }],
  });
  await settle(120);

  assert.equal(findMetaSpinner(), null, "解析完成后加载图标被结果取代");
  assert.ok(
    getFirstRowMetaText().includes("最高规格：约 300 MB"),
    `主行显示最高规格估算（4,000,000 bps × 600 s / 8 = 300 MB），实际为：${getFirstRowMetaText()}`,
  );
});

test("Bilibili / DASH 候选：展开后每个规格直接显示自身预估大小，缺失时不伪造，提交携带该规格的 estimatedSize 与 duration", async () => {
  const BILI_PAGE = "https://www.bilibili.com/video/BV1xx411c7mD";
  const BILI_VARIANT_1080 = {
    url: "https://cn-up.bilivideo.com/1080p.m4s",
    width: 1920,
    height: 1080,
    codecs: "avc1.640028",
    label: "1080P",
    duration: 300,
    estimatedSize: 120_000_000, // 120 MB
    pairAudioUrl: "https://cn-up.bilivideo.com/audio.m4s",
    pairCid: "123456",
  };
  const BILI_VARIANT_720_NO_ESTIMATE = {
    url: "https://cn-up.bilivideo.com/720p.m4s",
    width: 1280,
    height: 720,
    codecs: "avc1.640028",
    label: "720P",
    pairAudioUrl: "https://cn-up.bilivideo.com/audio.m4s",
    pairCid: "123456",
  };

  mediaQueue.push({
    ok: true,
    pageUrl: BILI_PAGE,
    title: "Bilibili Sample Video",
    candidates: [{
      url: BILI_PAGE,
      siteAdapter: "bilibili",
      filenameHint: "sample.mp4",
      variants: [BILI_VARIANT_1080, BILI_VARIANT_720_NO_ESTIMATE],
    }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "Bilibili Sample Video");
  assert.ok(
    getFirstRowMetaText().includes("最高规格：约 120 MB"),
    "Bilibili 主行显示最高规格的估算大小",
  );

  const options = await openFirstRowAccordion();
  assert.equal(options.length, 2);
  assert.equal(options[0].textContent, "1080P · 约 120 MB", "Bilibili 1080P 规格显示自身估算大小");
  assert.equal(options[1].textContent, "720P", "Bilibili 720P 无估算时仅显示规格名，不伪造");

  // 点击 1080P 规格提交
  options[0].dispatch("click");
  const lastDownload = sent.filter((m) => m.type === "media.download").pop();
  assert.equal(lastDownload?.url, BILI_VARIANT_1080.url);
  assert.equal(lastDownload?.mediaKind, "dash");
  assert.equal(lastDownload?.pairAudioUrl, BILI_VARIANT_1080.pairAudioUrl);
  assert.equal(lastDownload?.pairCid, "123456");
  assert.equal(lastDownload?.estimatedSize, 120_000_000);
  assert.equal(lastDownload?.duration, 300);
});

test("Popup 候选行 DOM 结构与悬浮窗对齐：首行为 strong 标题，下接 meta 行包含 12px 分类图标与文本，无旧版 28px media-icon", async () => {
  mediaQueue.push({
    ok: true,
    pageUrl: "https://example.com/video",
    title: "DOM Structure Verification Video",
    candidates: [{
      url: "https://example.com/video.mp4",
      filenameHint: "video.mp4",
      fileExtension: "mp4",
      size: 50 * 1024 * 1024,
    }],
  });
  refreshIntervalCallback();
  await settle(350);

  const row = mediaList.children[0];
  assert.ok(row, "必须渲染出候选行");

  // 确认不存在旧版 28px 的独立 media-icon
  let oldMediaIconFound = false;
  row.walk((el) => {
    if (el instanceof El && el.classList.contains("media-icon") && !el.classList.contains("meta-icon")) {
      oldMediaIconFound = true;
    }
  });
  assert.equal(oldMediaIconFound, false, "不能存在旧版独立 28px media-icon");

  // 检查 media-content
  const content = row.children.find((c) => c instanceof El && c.classList.contains("media-content"));
  assert.ok(content, "必须存在 media-content 容器");

  // 首行必须是 strong 标题
  const firstChild = content.children[0];
  assert.ok(firstChild instanceof El && firstChild.tagName === "STRONG", "media-content 首行必须是 STRONG 标题");
  assert.equal(firstChild.textContent, "DOM Structure Verification Video");

  // 下方元数据行必须是 media-meta，且包含 meta-icon (12px) 与 meta-text
  const metaContainer = content.children[1];
  assert.ok(metaContainer instanceof El && metaContainer.classList.contains("media-meta"), "第二行必须是 media-meta");

  const metaIcon = metaContainer.children.find((c) => c instanceof El && c.classList.contains("meta-icon"));
  assert.ok(metaIcon, "media-meta 中必须包含 meta-icon");
  assert.ok(metaIcon.innerHTML.includes("<svg"), "meta-icon 中包含 SVG 图标");

  const metaText = metaContainer.children.find((c) => c instanceof El && c.classList.contains("meta-text"));
  assert.ok(metaText, "media-meta 中必须包含 meta-text");
  assert.ok(metaText.textContent.includes("MP4"), "meta-text 包含格式元数据");
});

test("Popup YouTube 候选：快照无变体时回退 candidate.variants 计算主行最高规格大小", async () => {
  mediaQueue.push({
    ok: true,
    pageUrl: "https://www.youtube.com/watch?v=fallback123",
    title: "YouTube Fallback Test",
    candidates: [{
      url: "https://www.youtube.com/watch?v=fallback123",
      siteAdapter: "youtube",
      filenameHint: "fallback.mp4",
      variants: [
        { label: "1080P", url: "https://cdn.example/1080.mp4", estimatedSize: 200 * 1024 * 1024, duration: 600 },
        { label: "720P", url: "https://cdn.example/720.mp4", estimatedSize: 100 * 1024 * 1024, duration: 600 },
      ],
    }],
  });
  refreshIntervalCallback();
  await settle(350);

  assert.equal(getFirstRowTitleText(), "YouTube Fallback Test");
  assert.ok(
    getFirstRowMetaText().includes("最高规格：约 209.7 MB"),
    `YouTube 快照无变体时应回退 candidate.variants，实际 meta: ${getFirstRowMetaText()}`,
  );
});

test("Popup 错误 Toast: 按 at 时间戳去重展示，且绝不删除 storage.local 中的 lastSafeError 记录", async () => {
  recordedToasts.length = 0;
  storageRemoveCalls.length = 0;
  mockStorage.lastSafeError = {
    code: "ENQUEUE_TIMEOUT",
    message: "等待 MacIDM 响应超时",
    at: 1700000000000,
  };
  delete mockStorage.lastSafeErrorShownAt;

  currentPopupStatus = {
    connected: true,
    takeoverEnabled: true,
    sniffGovernanceEnabled: false,
    lastError: mockStorage.lastSafeError,
  };

  // 触发 refreshStatus (通过 languageSelect change)
  languageSelect.value = "en";
  languageSelect.dispatch("change");
  await settle(100);

  // 1. 首次展示 Toast，并记录 lastSafeErrorShownAt
  assert.equal(recordedToasts.length, 1, "首次遇到新错误时应展示 Toast");
  assert.equal(recordedToasts[0].message, "等待 MacIDM 响应超时");
  assert.equal(mockStorage.lastSafeErrorShownAt, 1700000000000, "必须记录已展示的时间戳");

  // 2. 验证 Popup 绝不删除 storage 中的 lastSafeError（防止竞态删除 background 写入的新错误）
  assert.equal(
    storageRemoveCalls.includes("lastSafeError"),
    false,
    "Popup refreshStatus 绝不得调用 storage.local.remove('lastSafeError')",
  );
  assert.ok(mockStorage.lastSafeError, "storage.local 中的 lastSafeError 应完整保留");

  // 3. 同一时间戳的重复状态刷新绝不再触发 Toast
  languageSelect.value = "zh-CN";
  languageSelect.dispatch("change");
  await settle(100);
  assert.equal(recordedToasts.length, 1, "相同 at 时间戳不应重复弹 Toast");

  // 4. 新错误到达（时间戳更新为 1700000005000）
  currentPopupStatus.lastError = {
    code: "INSPECT_TIMEOUT",
    message: "解析媒体超时",
    at: 1700000005000,
  };
  mockStorage.lastSafeError = currentPopupStatus.lastError;

  languageSelect.value = "en";
  languageSelect.dispatch("change");
  await settle(100);

  assert.equal(recordedToasts.length, 2, "新时间戳的错误应成功触发新 Toast");
  assert.equal(recordedToasts[1].message, "解析媒体超时");
  assert.equal(mockStorage.lastSafeErrorShownAt, 1700000005000);
  assert.equal(storageRemoveCalls.includes("lastSafeError"), false);
});

// ---- 站点 Cookie 菜单行：常驻授权入口 + 静默游客降级可见 ----
// 注意：上一个用例把语言切到了 en，这里断言英文文案。

const cookieRow = elementFor("cookie-row");
const BILI_COOKIE_PAGE = "https://www.bilibili.com/video/BV1xx411c7mD";

test("cookie row spells out silent guest-quality downgrade for Bilibili candidates", async () => {
  permissionState.granted = false;
  mediaQueue.push({
    ok: true,
    pageUrl: BILI_COOKIE_PAGE,
    title: "B 站标题",
    candidates: [{ url: BILI_COOKIE_PAGE, siteAdapter: "bilibili", filenameHint: "b.mp4" }],
  });
  refreshIntervalCallback();
  await settle(400);

  assert.equal(cookieStatus.textContent, "Not granted · guest qualities (click to authorize)");
});

test("clicking the cookie row requests the current-site permission and re-parses", async () => {
  const inspectBefore = sent.filter((message) => message.type === "media.inspect").length;
  permissionState.requestResult = true;
  cookieRow.dispatch("click");
  await settle(400);

  // 只申请当前站点，不能顺带要全网站权限。
  assert.equal(permissionRequests.length, 1);
  assert.deepEqual(permissionRequests[0], {
    permissions: ["cookies"],
    origins: ["https://www.youtube.com/*"],
  });
    assert.equal(cookieStatus.textContent, "Authorized · click to re-sniff");
  // 授权只改变后续解析的请求上下文：不重问 App 的话面板会停留在游客画质。
  const inspectAfter = sent.filter((message) => message.type === "media.inspect").length;
  assert.ok(inspectAfter > inspectBefore, "授权后必须重新向 App 解析");
});

test("clicking the cookie row while granted re-parses without requesting again", async () => {
  const requestsBefore = permissionRequests.length;
  const inspectBefore = sent.filter((message) => message.type === "media.inspect").length;
  cookieRow.dispatch("click");
  await settle(400);

  assert.equal(permissionRequests.length, requestsBefore, "已授权时不得重复弹授权框");
  const inspectAfter = sent.filter((message) => message.type === "media.inspect").length;
  assert.ok(inspectAfter > inspectBefore, "已授权点击应仅重新解析");
});

// ---- 标题右侧一键授权快捷入口：未授权 + cookie 敏感候选才出现 ----

const cookieShortcut = elementFor("cookie-authorize-shortcut");

// popup.js 的 cookieGranted 只在 initialize / 语言切换 / 授权点击时经
// refreshPermission 同步；媒体刷新定时器不重查权限。用一次语言切换把
// cookieGranted 同步到当前桩状态，避免受前面用例遗留状态干扰。
async function syncPermissionState() {
  languageSelect.value = languageSelect.value === "en" ? "zh-CN" : "en";
  languageSelect.dispatch("change");
  await settle(200);
}

test("header cookie shortcut: visible when unauthorized, requests and hides on click", async () => {
  permissionState.granted = false;
  permissionState.requestResult = true;
  await syncPermissionState();
  mediaQueue.push({
    ok: true,
    pageUrl: BILI_COOKIE_PAGE,
    title: "B 站标题",
    candidates: [{ url: BILI_COOKIE_PAGE, siteAdapter: "bilibili", filenameHint: "b.mp4" }],
  });
  refreshIntervalCallback();
  await settle(400);
  assert.equal(cookieShortcut.hidden, false, "未授权且有 B 站候选时应显示快捷授权入口");

  const requestsBefore = permissionRequests.length;
  cookieShortcut.dispatch("click");
  await settle(400);
  assert.ok(permissionRequests.length > requestsBefore, "点击快捷入口应发起权限申请");
  assert.deepEqual(permissionRequests[permissionRequests.length - 1], {
    permissions: ["cookies"],
    origins: ["https://www.youtube.com/*"],
  });
  assert.equal(cookieShortcut.hidden, true, "授权成功后快捷入口应隐藏");
});
