import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const overlaySource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/overlay.js", import.meta.url),
  "utf8",
);
// youtube-format-utils.js loads before overlay.js in the manifest content
// scripts; the overlay's YouTube inspection path calls into it.
const youtubeFormatUtilsSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/youtube-format-utils.js", import.meta.url),
  "utf8",
);
const mediaPresentationSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/media-presentation.js", import.meta.url),
  "utf8",
);
// panel-ui.js provides the shared toast used by submission failure feedback.
const panelUiSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/panel-ui.js", import.meta.url),
  "utf8",
);

// ---- minimal DOM shim (enough for the overlay's shadow-DOM flows) ----

class FakeElement {
  constructor(tagName) {
    this.tagName = String(tagName ?? "div").toUpperCase();
    this.attributes = {};
    this.childNodes = [];
    this.parentNode = null;
    this.listeners = {};
    this.style = { cssText: "" };
    this.rootOwner = null;
    // Real DOM behavior: setting scrollTop on a detached element has no effect;
    // the panel must be assigned after insertion or its scroll position resets
    // to the top (the regression test relies on this behavior).
    this._scrollTop = 0;
    this._scrollHeight = 0;
    this._clientHeight = 0;
    this._text = "";
    this._isFragment = false;
    this._isShadowRoot = false;
    this._isDocumentRoot = false;
    this._title = "";
  }

  get className() {
    return this.getAttribute("class") ?? "";
  }
  set className(value) {
    this.setAttribute("class", value);
  }

  get classList() {
    const self = this;
    const current = () => new Set(self.className.split(/\s+/).filter(Boolean));
    return {
      add(...names) {
        const set = current();
        for (const name of names) set.add(name);
        self.setAttribute("class", [...set].join(" "));
      },
      remove(...names) {
        const set = current();
        for (const name of names) set.delete(name);
        self.setAttribute("class", [...set].join(" "));
      },
      contains(name) {
        return current().has(name);
      },
    };
  }

  get textContent() {
    let out = this._text;
    for (const child of this.childNodes) out += child.textContent;
    return out;
  }
  set textContent(value) {
    this._text = String(value ?? "");
    this.childNodes = [];
  }

  get title() {
    return this._title;
  }
  set title(value) {
    this._title = String(value ?? "");
  }

  get id() {
    return this.getAttribute("id") ?? "";
  }
  set id(value) {
    this.setAttribute("id", value);
  }

  get type() {
    return this.getAttribute("type") ?? "";
  }
  set type(value) {
    this.setAttribute("type", value);
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  getAttribute(name) {
    return Object.hasOwn(this.attributes, name) ? this.attributes[name] : null;
  }
  hasAttribute(name) {
    return Object.hasOwn(this.attributes, name);
  }

  append(...nodes) {
    for (const node of nodes) {
      if (node && node._isFragment) {
        for (const child of [...node.childNodes]) this.appendChild(child);
      } else {
        this.appendChild(node);
      }
    }
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    if (this._isShadowRoot) child.rootOwner = this;
    else if (this.rootOwner) child.rootOwner = this.rootOwner;
    this.childNodes.push(child);
    return child;
  }

  removeChild(child) {
    const index = this.childNodes.indexOf(child);
    if (index >= 0) this.childNodes.splice(index, 1);
    child.parentNode = null;
    return child;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  replaceWith(replacement) {
    const parent = this.parentNode;
    if (!parent) return;
    const index = parent.childNodes.indexOf(this);
    if (index < 0) return;
    if (replacement._isFragment) {
      const children = [...replacement.childNodes];
      parent.childNodes.splice(index, 1, ...children);
      for (const child of children) {
        child.parentNode = parent;
        if (parent.rootOwner) child.rootOwner = parent.rootOwner;
      }
    } else {
      parent.childNodes.splice(index, 1, replacement);
      replacement.parentNode = parent;
      if (parent.rootOwner) replacement.rootOwner = parent.rootOwner;
    }
  }

  get parentElement() {
    return this.parentNode instanceof FakeElement ? this.parentNode : null;
  }

  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    // Both shadow roots and documents count as connected roots: the panel is
    // mounted under a shadow root in this scenario.
    return Boolean(node._isDocumentRoot || node._isShadowRoot);
  }

  get scrollTop() {
    return this.isConnected ? this._scrollTop : 0;
  }

  set scrollTop(value) {
    if (this.isConnected) this._scrollTop = value;
  }

  get scrollHeight() {
    return this._scrollHeight;
  }

  get clientHeight() {
    return this._clientHeight;
  }

  getRootNode() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    if (node._isShadowRoot) return node;
    return node._isDocumentRoot ? fakeDocument : (this.rootOwner ?? fakeDocument);
  }

  attachShadow() {
    this.shadowRoot = createShadowRoot(this);
    return this.shadowRoot;
  }

  focus() {}

  addEventListener(type, listener) {
    (this.listeners[type] ??= []).push(listener);
  }

  querySelector(selector) {
    return queryDescendants(this, selector)[0] ?? null;
  }

  querySelectorAll(selector) {
    return queryDescendants(this, selector);
  }
}

function collectDescendants(node, out) {
  for (const child of node.childNodes ?? []) {
    out.push(child);
    collectDescendants(child, out);
  }
  return out;
}

function queryDescendants(root, selector) {
  return collectDescendants(root, []).filter((element) => matchesSelector(element, selector));
}

function matchesSelector(element, rawSelector) {
  return rawSelector
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .some((selector) => matchesSingleSelector(element, selector));
}

function matchesSingleSelector(element, selector) {
  if (!selector || element._isFragment) return false;
  const attrRe = /\[([a-zA-Z0-9_-]+)(?:="([^"]*)")?\]/g;
  const attributes = [...selector.matchAll(attrRe)];
  for (const [, name, value] of attributes) {
    if (value === undefined) {
      if (!element.hasAttribute(name)) return false;
    } else if (element.getAttribute(name) !== value) {
      return false;
    }
  }
  const rest = selector.replace(attrRe, "").trim();
  if (rest) {
    const match = rest.match(/^([a-zA-Z0-9-]+)?((?:\.[a-zA-Z0-9_-]+)*)$/);
    if (!match) return false;
    if (match[1] && element.tagName !== match[1].toUpperCase()) return false;
    if (match[2]) {
      const have = element.className.split(/\s+/);
      for (const className of match[2].slice(1).split(".")) {
        if (className && !have.includes(className)) return false;
      }
    }
  }
  return true;
}

function parseHTMLInto(parent, html) {
  const stack = [parent];
  const tagRe = /<\/?([a-zA-Z0-9-]+)((?:"[^"]*"|'[^']*'|[^>"'])*)>/g;
  let lastIndex = 0;
  let match;
  while ((match = tagRe.exec(html))) {
    const text = html.slice(lastIndex, match.index);
    if (text.trim()) stack[stack.length - 1]._text += text;
    lastIndex = tagRe.lastIndex;
    const [full, tag, attrText] = match;
    if (full.startsWith("</")) {
      if (stack.length > 1) stack.pop();
      continue;
    }
    const element = new FakeElement(tag);
    const attrRe = /([a-zA-Z0-9_-]+)(?:\s*=\s*"([^"]*)"|\s*=\s*'([^']*)')?/g;
    let attrMatch;
    while ((attrMatch = attrRe.exec(attrText))) {
      element.setAttribute(attrMatch[1], attrMatch[2] ?? attrMatch[3] ?? "");
    }
    stack[stack.length - 1].appendChild(element);
    const selfClosing = /\/>\s*$/.test(full) || /^(br|img|input|path|meta|link)$/i.test(tag);
    if (!selfClosing) stack.push(element);
  }
}

function createShadowRoot(host) {
  const shadow = new FakeElement("#shadow-root");
  shadow._isShadowRoot = true;
  shadow.host = host;
  Object.defineProperty(shadow, "innerHTML", {
    set(value) {
      shadow.childNodes = [];
      parseHTMLInto(shadow, String(value));
    },
    get() {
      return "";
    },
    configurable: true,
  });
  return shadow;
}

let fakeDocument;

function createEnv({ realScope = false } = {}) {
  const documentElement = new FakeElement("html");
  documentElement._isDocumentRoot = true;
  fakeDocument = {
    documentElement,
    title: "Fixture Page",
    createElement(tag) {
      return new FakeElement(tag);
    },
    createTextNode(text) {
      const node = new FakeElement("#text");
      node._text = String(text);
      return node;
    },
    createDocumentFragment() {
      const fragment = new FakeElement("#fragment");
      fragment._isFragment = true;
      return fragment;
    },
    querySelector(selector) {
      return queryDescendants(documentElement, selector)[0] ?? null;
    },
    querySelectorAll(selector) {
      return queryDescendants(documentElement, selector);
    },
  };

  class HTMLMediaElement extends FakeElement {}
  const video = new HTMLMediaElement("video");
  video.getClientRects = undefined;
  video.getBoundingClientRect = () => ({
    left: 0, right: 640, top: 0, bottom: 360, width: 640, height: 360,
  });
  documentElement.appendChild(video);

  // vm-visible timer that does not keep the Node process alive for the
  // overlay's 60s inspection-timeout race.
  const unrefTimeout = (callback, ms) => {
    const timer = setTimeout(callback, ms);
    timer.unref?.();
    return timer;
  };

  const sentMessages = [];
  let respondWith = { ok: true };
  let pendingMode = false;
  let heldResolve = null;
  // Controllable overlay.tabTitle stub: return null immediately by default
  // (matching the existing cases); holdTabTitle() suspends requests and
  // releases them in enqueue order to exercise asynchronous reply races.
  let holdTabTitleMode = false;
  const heldTabTitles = [];
  // Capture the floating panel's MutationObserver callback so tests can
  // manually trigger a DOM change and verify the immediate URL-generation
  // barrier in the 0.5-second timing window.
  let mutationCallback = null;
  // Capture the chrome.runtime.onMessage subscription so tests can push
  // service-worker events such as authorization changes.
  const messageListeners = [];

  const context = vm.createContext({
    HTMLMediaElement,
    document: fakeDocument,
    location: { href: "https://example.com/watch", search: "" },
    // YouTube identity normalization uses videoIdFromPageURL, so the VM needs
    // a URL constructor.
    URL,
    URLSearchParams,
    MutationObserver: class {
      constructor(callback) {
        mutationCallback = callback;
      }
      observe() {}
    },
    requestAnimationFrame(callback) {
      setTimeout(callback, 0);
    },
    getComputedStyle() {
      return { display: "block", visibility: "visible" };
    },
    addEventListener() {},
    removeEventListener() {},
    scrollX: 0,
    scrollY: 0,
    innerWidth: 1280,
    innerHeight: 800,
    setTimeout: unrefTimeout,
    clearTimeout,
    console,
    chrome: {
      runtime: {
        onMessage: {
          addListener(listener) {
            messageListeners.push(listener);
          },
        },
        sendMessage(message) {
          sentMessages.push(message);
          if (message.type === "overlay.tabTitle") {
            if (holdTabTitleMode) {
              return new Promise((resolve) => {
                heldTabTitles.push(resolve);
              });
            }
            return Promise.resolve(null);
          }
          if (pendingMode) {
            return new Promise((resolve) => {
              heldResolve = resolve;
            });
          }
          return Promise.resolve(respondWith);
        },
      },
    },
  });
  context.globalThis = context;
  vm.runInContext(youtubeFormatUtilsSource, context);
  vm.runInContext(mediaPresentationSource, context);
  vm.runInContext(panelUiSource, context);
  vm.runInContext(fs.readFileSync(new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url), "utf8"), context);
  if (!realScope) {
    // Presentation fixtures explicitly declare their rows as <source> URLs.
    // Keep unrelated coalescing/display behavior stubbed in these UI tests.
    context.MacIDMMediaUtils = { filterCandidatesForElementScope: context.MacIDMMediaUtils.filterCandidatesForElementScope };
  }
  vm.runInContext(fs.readFileSync(new URL("../../../BrowserExtension/chrome/src/content/media-element-scope.js", import.meta.url), "utf8"), context);
  vm.runInContext(overlaySource, context);

  return {
    context,
    video,
    sentMessages,
    addMedia(tag = "video") {
      const media = new HTMLMediaElement(tag);
      media.getClientRects = undefined;
      media.getBoundingClientRect = video.getBoundingClientRect;
      documentElement.appendChild(media);
      return media;
    },
    hosts() { return fakeDocument.querySelectorAll("[data-macidm-overlay]"); },
    setResponse(value) {
      respondWith = value;
    },
    holdNextSend() {
      pendingMode = true;
    },
    releaseHeld(response) {
      pendingMode = false;
      if (heldResolve) {
        const resolve = heldResolve;
        heldResolve = null;
        resolve(response);
      }
    },
    /// Hold subsequent overlay.tabTitle requests until releaseNextTabTitle
    /// releases them one at a time.
    holdTabTitle() {
      holdTabTitleMode = true;
    },
    /// Release the oldest suspended tab-title request in enqueue order.
    releaseNextTabTitle(result) {
      const resolve = heldTabTitles.shift();
      if (resolve) resolve(result);
    },
    heldTabTitleCount() {
      return heldTabTitles.length;
    },
    /// Manually trigger the floating panel's MutationObserver callback to
    /// simulate the DOM change after SPA navigation.
    fireMutations() {
      if (mutationCallback) mutationCallback([], {});
    },
    /// Simulate the service worker/runtime pushing a message to the floating
    /// panel's onMessage subscriber.
    emit(message) {
      for (const listener of messageListeners) listener(message);
    },
    async flush(ms = 20) {
      await new Promise((resolve) => setTimeout(resolve, ms));
    },
    sync(snapshot) {
      if (!realScope) {
        for (const source of video.querySelectorAll("source")) source.remove();
        for (const candidate of snapshot.candidates ?? []) {
          const source = new FakeElement("source");
          source.setAttribute("src", candidate.url);
          video.appendChild(source);
        }
      }
      context.MacIDMOverlay.syncCandidates(snapshot);
    },
    host() {
      return fakeDocument.querySelector("[data-macidm-overlay]");
    },
    shadow() {
      return this.host().shadowRoot;
    },
    fire(element, type, extra = {}) {
      const event = {
        type,
        key: "",
        stopPropagation() {},
        preventDefault() {},
        ...extra,
      };
      for (const listener of element.listeners[type] ?? []) listener(event);
    },
    click(element) {
      this.fire(element, "click");
    },
  };
}

// ---- tests ----

test("overlay rows and submenu items expose button semantics and live region", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/video.mp4", format: "video", size: 12_345 },
      {
        url: "https://cdn.example/master.m3u8",
        format: "hls",
        variants: [{ label: "720P", url: "https://cdn.example/v720.m3u8" }],
      },
    ],
  });
  await env.flush();

  const shadow = env.shadow();
  const fab = shadow.querySelector(".fab");
  assert.equal(fab.tagName, "BUTTON");
  assert.equal(fab.getAttribute("aria-label"), "overlay.fabTitle");
  assert.equal(fab.getAttribute("aria-expanded"), "false");

  // Live region is a dedicated, visually hidden status area inside .wrap.
  const live = shadow.querySelector(".sr-status");
  assert.ok(live);
  assert.equal(live.getAttribute("role"), "status");
  assert.equal(live.getAttribute("aria-live"), "polite");
  assert.equal(live.textContent, "");

  env.click(fab);
  const panel = shadow.querySelector(".panel");
  assert.ok(panel);
  assert.equal(fab.getAttribute("aria-expanded"), "true");

  const directRow = panel.querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(directRow.getAttribute("role"), "button");
  assert.equal(directRow.getAttribute("tabindex"), "0");

  const accordionRow = panel.querySelector('[data-macidm-item-url="https://cdn.example/master.m3u8"]');
  assert.equal(accordionRow.getAttribute("role"), "button");
  assert.equal(accordionRow.getAttribute("tabindex"), "0");
  assert.equal(accordionRow.getAttribute("aria-expanded"), "false");
  const controls = accordionRow.getAttribute("aria-controls");
  assert.match(controls, /^macidm-submenu-\d+$/);
  assert.equal(panel.querySelector('[data-macidm-submenu]'), null);
});

test("accordion expands and collapses with keyboard and pairs the submenu", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      {
        url: "https://cdn.example/master.m3u8",
        format: "hls",
        variants: [{ label: "720P", url: "https://cdn.example/v720.m3u8" }],
      },
    ],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let panel = shadow.querySelector(".panel");
  let row = panel.querySelector('[data-macidm-item-url="https://cdn.example/master.m3u8"]');

  // Enter expands the accordion.
  env.fire(row, "keydown", { key: "Enter" });
  panel = shadow.querySelector(".panel");
  row = panel.querySelector('[data-macidm-item-url="https://cdn.example/master.m3u8"]');
  assert.equal(row.getAttribute("aria-expanded"), "true");

  const submenu = panel.querySelector('[data-macidm-submenu]');
  assert.ok(submenu);
  assert.equal(submenu.getAttribute("role"), "group");
  assert.equal(submenu.getAttribute("aria-label"), "overlay.qualitiesGroup");
  assert.equal(submenu.id, row.getAttribute("aria-controls"));

  // Variant options are real buttons (native Enter/Space activation).
  const options = submenu.querySelectorAll(".sub-item");
  assert.equal(options.length, 1);
  assert.equal(options[0].tagName, "BUTTON");
  assert.equal(options[0].getAttribute("type"), "button");
  assert.equal(options[0].getAttribute("data-macidm-variant-label"), "720P");

  // Space collapses again.
  env.fire(row, "keydown", { key: " " });
  panel = shadow.querySelector(".panel");
  row = panel.querySelector('[data-macidm-item-url="https://cdn.example/master.m3u8"]');
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.equal(panel.querySelector('[data-macidm-submenu]'), null);
});

test("row meta shows a loading spinner while parsing and swaps in the size estimate", async () => {
  // User contract: the parsing state must not be hidden only in the drawer.
  // The main-row metadata area (to the right of the format label) shows a
  // spinner directly, then the estimated-size slot replaces it on completion.
  const env = createEnv();
  env.holdNextSend(); // media.inspect 挂起 → 解析保持进行中
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/master.m3u8", format: "hls", fileExtension: "m3u8" }],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  await env.flush(320); // 面板构建（200ms 自动解析排期）→ inspectVariants 启动并立即刷新

  const rowUrl = '[data-macidm-item-url="https://cdn.example/master.m3u8"]';
  let panel = shadow.querySelector(".panel");
  let row = panel.querySelector(rowUrl);
  assert.ok(row, "candidate row rendered");
  assert.equal(row.getAttribute("data-macidm-item-status"), "inspecting");
  assert.ok(row.querySelector(".meta-spinner"), "主行 meta 在解析中显示加载图标（无需展开抽屉）");

  // Completed parsing: the variant carries estimatedSize directly, so the
  // main-row estimate replaces the spinner. The test context does not load
  // media-utils, so bandwidth-by-duration estimation is unavailable here.
  env.releaseHeld({
    ok: true,
    variants: [
      { label: "720P", url: "https://cdn.example/v720.m3u8", estimatedSize: 300_000_000 },
    ],
  });
  await env.flush(320);

  panel = shadow.querySelector(".panel");
  row = panel.querySelector(rowUrl);
  assert.ok(row, "candidate row still rendered");
  assert.equal(row.querySelector(".meta-spinner"), null, "解析完成后加载图标被结果取代");
  assert.equal(row.getAttribute("data-macidm-item-status"), "ready");
  // The test context does not load i18n, so the slot text is the raw key;
  // seeing the estimate key confirms that the size slot was rendered.
  assert.ok(
    row.querySelector(".meta-text").textContent.includes("common.approxHighestSize"),
    `主行 meta 显示最高规格估算，实际为：${row.querySelector(".meta-text").textContent}`,
  );
});

test("Enter and Space submit a direct-link row and announce the outcome", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let panel = shadow.querySelector(".panel");
  let row = panel.querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');

  // Unified drawer behavior: direct-link rows also expand first and provide
  // at least one download item inside the drawer.
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();
  panel = shadow.querySelector(".panel");
  row = panel.querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(row.getAttribute("aria-expanded"), "true");
  let direct = panel.querySelector('[data-macidm-btn-direct]');
  assert.ok(direct, "无子下载项的候选必须提供点击下载子项");
  assert.equal(direct.textContent, "overlay.downloadNow");

  env.click(direct);
  await env.flush();
  const downloads = env.sentMessages.filter((message) => message.type === "media.download");
  assert.equal(downloads.length, 1);
  assert.equal(downloads[0].url, "https://cdn.example/video.mp4");
  row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(row.getAttribute("data-macidm-item-status"), "submitted");
  assert.equal(shadow.querySelector(".sr-status").textContent, "overlay.toastSent");
  // A successful submission no longer shows a visual toast: the app's
  // confirmation window provides the feedback.
  assert.equal(
    shadow.querySelector("[data-macidm-toast]"),
    null,
    "发送成功后不应出现「已发送给 MacIDM」视觉 toast",
  );

  // Submit again after the first submission has settled and the row is no
  // longer busy.
  direct = shadow.querySelector(".panel").querySelector('[data-macidm-btn-direct]');
  env.click(direct);
  await env.flush();
  assert.equal(env.sentMessages.filter((message) => message.type === "media.download").length, 2);
});

test("failed inspection shows no error text, only the direct download entry", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://www.bilibili.com/video/BV1xx411c7mD",
    title: "B站视频",
    candidates: [
      { url: "https://upos.example.com/media.mp4", format: "video", size: 4_000, siteAdapter: "bilibili" },
    ],
  });
  // Wait for the 200 ms automatic inspection timer to fire and settle as a
  // failure; the test environment has no inspection coordinator, so this
  // must take the failure branch.
  await env.flush(260);

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  await env.flush();
  const panel = shadow.querySelector(".panel");
  assert.ok(panel, "点击悬浮球应展开面板");
  const row = panel.querySelector('[data-macidm-item-url="https://upos.example.com/media.mp4"]');
  assert.ok(row, "B 站候选应渲染候选行");

  // The 200 ms automatic inspection is scheduled only when the candidate row
  // is rendered; wait for it to fire and settle as a failure.
  await env.flush(260);

  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();
  const reopened = shadow.querySelector(".panel");
  assert.equal(
    reopened.querySelector("[data-macidm-failure]"),
    null,
    "解析失败不再渲染生硬的错误文案",
  );
  const direct = reopened.querySelector("[data-macidm-btn-direct]");
  assert.ok(direct, "解析失败的候选仍保留点击下载入口");
  assert.equal(direct.textContent, "overlay.downloadNow");
});

test("Escape and the close button close the panel and restore aria-expanded", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();

  const shadow = env.shadow();
  const fab = shadow.querySelector(".fab");
  env.click(fab);
  assert.ok(shadow.querySelector(".panel"));

  env.fire(shadow.querySelector(".panel"), "keydown", { key: "Escape" });
  assert.equal(shadow.querySelector(".panel"), null);
  assert.equal(fab.getAttribute("aria-expanded"), "false");

  env.click(fab);
  const close = shadow.querySelector(".close");
  assert.equal(close.tagName, "BUTTON");
  assert.equal(close.getAttribute("aria-label"), "overlay.closeAria");
  env.click(close);
  assert.equal(shadow.querySelector(".panel"), null);
  assert.equal(fab.getAttribute("aria-expanded"), "false");
});

test("panel header merges the count into the title and offers cookie authorization when unauthorized", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();
  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  const panel = shadow.querySelector(".panel");
  const header = panel.querySelector("header");

  // The count appears in parentheses beside the title in the left group,
  // matching the panel count attribute.
  const titleGroup = header.querySelector(".header-titlegroup");
  assert.ok(titleGroup, "标题与计数应合并进左侧组");
  assert.equal(titleGroup.querySelector(".header-title").textContent, "overlay.panelTitle");
  assert.equal(
    titleGroup.querySelector(".header-count").textContent,
    `(${panel.getAttribute("data-macidm-panel-count")})`,
  );

  // Without authorization, the header shows an authorization entry on the
  // right, immediately to the left of the close button.
  const actions = header.querySelector(".header-actions");
  const authorize = actions.querySelector(".authorize");
  assert.ok(authorize, "未授权时应显示站点 Cookie 授权入口");
  assert.equal(authorize.textContent, "overlay.authorizeCookies");
  assert.equal(
    actions.childNodes[actions.childNodes.length - 1].className,
    "close",
    "关闭按钮应在最后（授权入口在其左边）",
  );

  // Clicking the authorization entry asks the service worker to open the
  // extension Popup, which contains one-click authorization. If openPopup is
  // unavailable, the service worker falls back to a small authorization
  // window because a content script cannot open the permission prompt itself.
  env.click(authorize);
  await env.flush();
  assert.ok(
    env.sentMessages.some((message) => message.type === "overlay.openPopup"),
    "点击授权入口应请求 SW 唤起 popup（或退回小授权窗）",
  );
});

test("panel header shows an authorized hint instead of the authorize entry when granted", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();

  // The service worker pushes an authorization-success event after the
  // authorization page or Popup completes.
  env.emit({ type: "macidm.cookieAuthorized", granted: true });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  const actions = shadow.querySelector(".panel").querySelector("header").querySelector(".header-actions");
  const hint = actions.querySelector(".cookie-granted");
  assert.ok(hint, "已授权时头部应出现常驻已授权提示");
  assert.equal(hint.textContent, "overlay.cookieAuthorizedHint");
  assert.equal(actions.querySelector(".authorize"), null, "已授权后不应再显示授权入口");
  assert.equal(
    actions.childNodes[actions.childNodes.length - 1].className,
    "close",
    "关闭按钮仍应在最后",
  );

  // When the service worker revokes authorization (granted: false), the hint
  // is hidden and the authorization entry returns.
  env.emit({ type: "macidm.cookieAuthorized", granted: false });
  await env.flush();
  const refreshedActions = shadow.querySelector(".panel").querySelector("header").querySelector(".header-actions");
  assert.equal(refreshedActions.querySelector(".cookie-granted"), null);
  assert.ok(refreshedActions.querySelector(".authorize"), "撤销授权后授权入口应回归");
});

test("expanding a submenu preserves the panel scroll position", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/a.mp4", format: "video", size: 1_000 },
      { url: "https://cdn.example/b.mp4", format: "video", size: 2_000 },
    ],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let panel = shadow.querySelector(".panel");
  // After the user scrolls down and expands a drawer, rebuilding the whole
  // panel must not reset the scroll position to the top.
  panel._scrollHeight = 1000;
  panel._clientHeight = 340;
  panel.scrollTop = 42;
  assert.equal(panel.scrollTop, 42);
  const row = panel.querySelector('[data-macidm-item-url="https://cdn.example/b.mp4"]');
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();

  panel = shadow.querySelector(".panel");
  const expandedRow = panel.querySelector('[data-macidm-item-url="https://cdn.example/b.mp4"]');
  assert.equal(expandedRow.getAttribute("aria-expanded"), "true");
  assert.equal(panel.scrollTop, 42, "展开重建后面板必须保持滚动位置");
});

test("悬浮滚动条只在面板进入 shadow DOM 后挂载，重建与关闭路径均不残留", async () => {
  const env = createEnv();
  // Regression: the old implementation attached inside buildPanel while the
  // node was detached, leaving the thumb inside the container and invisible.
  // attach must now happen after insertion, when the container has a parent
  // (.wrap); rebuilding first detaches the old accessory, and closing must
  // detach it as well.
  const attaches = [];
  const detaches = [];
  env.context.MacIDMSlimScrollbar = {
    attach(container) {
      attaches.push({ container, parent: container.parentElement });
      return () => detaches.push(container);
    },
  };
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/a.mp4", format: "video", size: 1_000 },
      { url: "https://cdn.example/b.mp4", format: "video", size: 2_000 },
    ],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  // Mount once on open: the container is already inserted into .wrap
  // (parentElement is non-null), otherwise the thumb is clipped by its
  // container.
  assert.equal(attaches.length, 1);
  assert.equal(attaches[0].container, shadow.querySelector(".panel"));
  assert.equal(attaches[0].parent, shadow.querySelector(".wrap"));
  assert.equal(detaches.length, 0);

  // Expanding a drawer rebuilds the whole panel: detach the old accessory
  // first, then insert the new panel and mount the accessory.
  const row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/b.mp4"]');
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();
  assert.equal(attaches.length, 2);
  assert.equal(attaches[1].container, shadow.querySelector(".panel"));
  assert.equal(attaches[1].parent, shadow.querySelector(".wrap"));
  assert.equal(detaches.length, 1);
  assert.equal(detaches[0], attaches[0].container);

  // Closing the panel detaches the current accessory and leaves no dangling
  // thumb.
  env.click(shadow.querySelector(".fab"));
  assert.equal(attaches.length, 2);
  assert.equal(detaches.length, 2);
  assert.equal(detaches[1], attaches[1].container);
});

test("busy rows reject duplicate submissions until the round trip settles", async () => {
  const env = createEnv();
  env.holdNextSend();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');

  // After expanding, click the download item and verify that the row becomes
  // busy while submission is pending.
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();
  let panel = shadow.querySelector(".panel");
  env.click(panel.querySelector('[data-macidm-btn-direct]'));
  await env.flush();
  row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(row.getAttribute("data-macidm-item-status"), "submitting");
  assert.equal(row.classList.contains("busy"), true);

  // Repeated clicks while busy are ignored.
  env.click(shadow.querySelector(".panel").querySelector('[data-macidm-btn-direct]'));
  await env.flush();
  assert.equal(env.sentMessages.filter((message) => message.type === "media.download").length, 1);

  env.releaseHeld({ ok: true });
  await env.flush();
  row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(row.getAttribute("data-macidm-item-status"), "submitted");
  assert.equal(row.classList.contains("busy"), false);
});

test("in-flight parsing renders a status sub-item and announces parsing", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/stream.m3u8", format: "hls" }],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/stream.m3u8"]');
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush(20);

  let panel = shadow.querySelector(".panel");
  const parsing = panel.querySelector(".sub-item.parsing");
  assert.ok(parsing);
  assert.equal(parsing.getAttribute("role"), "status");

  // Inspection resolves: the submenu swaps to real variant buttons and the
  // dedicated live region carried the parsing announcement.
  env.setResponse({ ok: true, variants: [{ label: "480P", url: "https://cdn.example/v480.m3u8" }] });
  await env.flush(300);
  assert.equal(shadow.querySelector(".sr-status").textContent, "overlay.statusParsing");
  panel = shadow.querySelector(".panel");
  row = panel.querySelector('[data-macidm-item-url="https://cdn.example/stream.m3u8"]');
  assert.equal(row.getAttribute("aria-expanded"), "true");
  const options = panel.querySelectorAll('[data-macidm-btn-variant]');
  assert.equal(options.length, 1);
  assert.equal(options[0].tagName, "BUTTON");
  assert.equal(options[0].getAttribute("data-macidm-variant-label"), "480P");
});

test("failed submissions announce the failure message in the live region", async () => {
  const env = createEnv();
  env.setResponse({ ok: false, message: "app rejected" });
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 12_345 }],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  env.fire(row, "keydown", { key: "Enter" });
  await env.flush();
  env.click(shadow.querySelector(".panel").querySelector('[data-macidm-btn-direct]'));
  await env.flush();

  row = shadow.querySelector(".panel").querySelector('[data-macidm-item-url="https://cdn.example/video.mp4"]');
  assert.equal(row.getAttribute("data-macidm-item-status"), "submit_failed");
  assert.equal(shadow.querySelector(".sr-status").textContent, "app rejected");
});

test("page-wide filtered noise counts stay out of an element panel", async () => {
  const env = createEnv();
  env.sync({
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video" }],
    filteredSummary: { diagnosticAudio: 2, streamSegments: 1, smallResources: 99 },
  });
  await env.flush();
  env.click(env.shadow().querySelector(".fab"));
  await env.flush();
  assert.equal(env.shadow().querySelector("[data-macidm-filtered-note]"), null);
});

// ---- Same-video parameter changes preserve overlay inspection state by videoId ----

test("同视频参数变化：悬浮窗仍按 videoId 消费已有终态与画质", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const paramURL = `${watchURL}&t=60s`;
  const variants = [
    { url: "https://cdn.example/v1080#height=1080", itag: 137, height: 1080, label: "1080P" },
    { url: "https://cdn.example/v720#height=720", itag: 136, height: 720, label: "720P" },
  ];
  env.setResponse({
    ok: true,
    snapshot: {
      tabId: 1,
      pageUrl: watchURL,
      videoId: "abc123",
      stage: "complete",
      variants,
      variantCount: 2,
      mayComplete: false,
      retryable: false,
    },
  });
  env.sync({
    pageUrl: watchURL,
    title: "Fixture",
    candidates: [{ url: watchURL, siteAdapter: "youtube" }],
  });
  await env.flush();
  // Automatic inspection is scheduled while the panel is built: expand the
  // panel first, then wait for the 200 ms delay.
  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  await env.flush(300);
  assert.equal(
    env.sentMessages.filter((m) => m.type === "youtube.ensureInspection").length,
    1,
    "自动解析只应触发一次",
  );

  // Only &t=60s is added to the same video: candidates are rebuilt with the
  // new URL, but inspection state must not be cleared.
  env.sync({
    pageUrl: paramURL,
    title: "Fixture",
    candidates: [{ url: paramURL, siteAdapter: "youtube" }],
  });
  await env.flush(300);
  assert.equal(
    env.sentMessages.filter((m) => m.type === "youtube.ensureInspection").length,
    1,
    "同视频参数变化不得重新触发解析",
  );

  // Expand the candidate for the new URL: the submenu still renders the
  // existing qualities instead of a parsing placeholder.
  let panel = shadow.querySelector(".panel");
  const row = panel.querySelector(`[data-macidm-item-url="${paramURL}"]`);
  assert.ok(row, "新 URL 的候选必须渲染");
  env.click(row);
  await env.flush();
  panel = shadow.querySelector(".panel");
  const options = panel.querySelectorAll('[data-macidm-btn-variant]');
  assert.equal(options.length, 2, "参数变化后已有画质必须仍可消费");
  assert.equal(
    panel.querySelector("[data-macidm-submenu] .parsing"),
    null,
    "不得退回解析中占位",
  );
});

test("A→B 换视频：悬浮窗仍丢弃旧视频的解析状态", async () => {
  const env = createEnv();
  const urlA = "https://www.youtube.com/watch?v=aaaa1111";
  const urlB = "https://www.youtube.com/watch?v=bbbb2222";
  env.setResponse({
    ok: true,
    snapshot: {
      tabId: 1,
      pageUrl: urlA,
      videoId: "aaaa1111",
      stage: "complete",
      variants: [{ url: "https://cdn.example/vA#height=1080", itag: 137, height: 1080, label: "1080P" }],
      variantCount: 1,
      mayComplete: false,
      retryable: false,
    },
  });
  env.sync({
    pageUrl: urlA,
    title: "Fixture",
    candidates: [{ url: urlA, siteAdapter: "youtube" }],
  });
  await env.flush();
  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  await env.flush(300);
  // Precondition: expanding video A's row shows its qualities.
  let panel = shadow.querySelector(".panel");
  const rowA = panel.querySelector(`[data-macidm-item-url="${urlA}"]`);
  env.click(rowA);
  await env.flush();
  panel = shadow.querySelector(".panel");
  assert.equal(
    panel.querySelectorAll('[data-macidm-btn-variant]').length,
    1,
    "前置条件：A 的画质已渲染",
  );

  // Switch to video B: a real generation change must immediately close A's
  // panel; the state key differs, so A's snapshot must not be consumed by B's
  // candidates, and automatic inspection is reopened for B.
  env.setResponse({ ok: false });
  env.sync({
    pageUrl: urlB,
    title: "Fixture",
    candidates: [{ url: urlB, siteAdapter: "youtube" }],
  });
  assert.equal(shadow.querySelector(".panel"), null, "A→B 换代必须立即关闭面板");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "false");
  await env.flush(300);

  // After the user clicks again, B's candidates render normally without A's
  // qualities.
  env.click(shadow.querySelector(".fab"));
  await env.flush();
  panel = shadow.querySelector(".panel");
  const row = panel.querySelector(`[data-macidm-item-url="${urlB}"]`);
  assert.ok(row);
  env.click(row);
  await env.flush();
  panel = shadow.querySelector(".panel");
  assert.equal(
    panel.querySelectorAll('[data-macidm-btn-variant]').length,
    0,
    "B 的候选不得显示 A 的画质",
  );
});

// ---- Page-session isolation while the panel is open ----

/// Common setup: open the panel on a watch page and expand the YouTube
/// quality submenu.
async function openExpandedYouTubePanel(env, watchURL, videoId, variants) {
  env.setResponse({
    ok: true,
    snapshot: {
      tabId: 1,
      pageUrl: watchURL,
      videoId,
      stage: "complete",
      variants,
      variantCount: variants.length,
      mayComplete: false,
      retryable: false,
    },
  });
  env.sync({
    pageUrl: watchURL,
    title: "Fixture",
    candidates: [{ url: watchURL, siteAdapter: "youtube" }],
  });
  await env.flush();
  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  // Automatic inspection fires 200 ms after the panel is built; wait for the
  // response to settle before expanding the item.
  await env.flush(300);
  let panel = shadow.querySelector(".panel");
  const row = panel.querySelector('[data-macidm-item-site="youtube"]');
  env.click(row);
  await env.flush();
  panel = shadow.querySelector(".panel");
  assert.ok(panel, "前置条件：面板已打开");
  assert.ok(
    panel.querySelectorAll('[data-macidm-btn-variant]').length > 0,
    "前置条件：画质已展开",
  );
  return shadow;
}

test("watch→首页：面板立即同步关闭，旧视频元素仍在 DOM 也不继承打开态", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const shadow = await openExpandedYouTubePanel(env, watchURL, "abc123", [
    { url: "https://cdn.example/v1080#height=1080", itag: 137, height: 1080, label: "1080P" },
  ]);

  // Home-page snapshot: valid ordinary media (JPG/GIF). The stub does not
  // move the old <video>; the old media element intentionally remains in the
  // DOM.
  env.sync({
    pageUrl: "https://www.youtube.com/",
    title: "Home",
    candidates: [
      { url: "https://cdn.example/hq720.jpg", mime: "image/jpeg", size: 12_345 },
      { url: "https://cdn.example/tiny.gif", mime: "image/gif", size: 42 },
    ],
  });

  // Synchronous assertion: the panel is closed before candidates are
  // applied; do not wait for attachment detachment.
  assert.equal(shadow.querySelector(".panel"), null, "换页必须同步删除打开的面板");
  assert.equal(
    shadow.querySelector(".fab").getAttribute("aria-expanded"),
    "false",
    "FAB 必须回到折叠态",
  );

  // Later RAF synchronization and snapshot replay must not reopen the panel
  // automatically.
  await env.flush();
  env.sync({
    pageUrl: "https://www.youtube.com/",
    title: "Home",
    candidates: [
      { url: "https://cdn.example/hq720.jpg", mime: "image/jpeg", size: 12_345 },
      { url: "https://cdn.example/tiny.gif", mime: "image/gif", size: 42 },
    ],
  });
  await env.flush();
  assert.equal(shadow.querySelector(".panel"), null, "后续 sync 不得重开面板");
  assert.ok(
    !String(shadow.textContent ?? "").includes("1080P"),
    "旧视频画质不得出现在新页面",
  );

  assert.equal(env.host(), null, "首页图片只属于 Popup，不为残留 video 创建入口");
});

test("watch→搜索页：旧媒体元素继续存在时仍立即关闭，后续同步不重开", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const shadow = await openExpandedYouTubePanel(env, watchURL, "abc123", [
    { url: "https://cdn.example/v720#height=720", itag: 136, height: 720, label: "720P" },
  ]);

  env.sync({
    pageUrl: "https://www.youtube.com/results?search_query=cats",
    title: "Search",
    candidates: [{ url: "https://cdn.example/thumb.jpg", mime: "image/jpeg", size: 1_000 }],
  });
  assert.equal(shadow.querySelector(".panel"), null, "搜索页换页必须立即关闭面板");
  assert.equal(
    shadow.querySelector(".fab").getAttribute("aria-expanded"),
    "false",
  );

  // Multiple later synchronizations (simulating mutation-driven updates) must
  // not reopen it either.
  for (let i = 0; i < 2; i += 1) {
    env.sync({
      pageUrl: "https://www.youtube.com/results?search_query=cats",
      title: "Search",
      candidates: [{ url: "https://cdn.example/thumb.jpg", mime: "image/jpeg", size: 1_000 }],
    });
    await env.flush();
  }
  assert.equal(shadow.querySelector(".panel"), null, "后续 mutation/sync 不得重开面板");
});

test("watch A→watch B：A 的面板与展开态关闭，B 可正常重新建立", async () => {
  const env = createEnv();
  const urlA = "https://www.youtube.com/watch?v=aaaa1111";
  const urlB = "https://www.youtube.com/watch?v=bbbb2222";
  const shadow = await openExpandedYouTubePanel(env, urlA, "aaaa1111", [
    { url: "https://cdn.example/vA#height=1080", itag: 137, height: 1080, label: "1080P" },
  ]);

  // Switch to B: the panel closes immediately.
  env.setResponse({
    ok: true,
    snapshot: {
      tabId: 1,
      pageUrl: urlB,
      videoId: "bbbb2222",
      stage: "complete",
      variants: [{ url: "https://cdn.example/vB#height=720", itag: 136, height: 720, label: "720P" }],
      variantCount: 1,
      mayComplete: false,
      retryable: false,
    },
  });
  env.sync({
    pageUrl: urlB,
    title: "Video B",
    candidates: [{ url: urlB, siteAdapter: "youtube" }],
  });
  assert.equal(shadow.querySelector(".panel"), null, "A→B 必须立即关闭 A 的面板");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "false");

  // After the user clicks, B's panel can be created normally and shows B's
  // qualities.
  await env.flush();
  env.click(shadow.querySelector(".fab"));
  await env.flush(300);
  let panel = shadow.querySelector(".panel");
  assert.ok(panel.querySelector(`[data-macidm-item-url="${urlB}"]`), "B 的候选行已渲染");
  env.click(panel.querySelector('[data-macidm-item-site="youtube"]'));
  await env.flush();
  panel = shadow.querySelector(".panel");
  const options = panel.querySelectorAll('[data-macidm-btn-variant]');
  assert.equal(options.length, 1, "B 的画质可正常重新建立");
  assert.equal(options[0].getAttribute("data-macidm-variant-label"), "720P");
});

test("同视频参数变化：面板、子菜单与画质保留，item URL 更新，不重复解析", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const paramURL = `${watchURL}&t=60s`;
  const shadow = await openExpandedYouTubePanel(env, watchURL, "abc123", [
    { url: "https://cdn.example/v1080#height=1080", itag: 137, height: 1080, label: "1080P" },
    { url: "https://cdn.example/v720#height=720", itag: 136, height: 720, label: "720P" },
  ]);
  const ensuresBefore = env.sentMessages.filter(
    (m) => m.type === "youtube.ensureInspection",
  ).length;

  env.sync({
    pageUrl: paramURL,
    title: "Fixture",
    candidates: [{ url: paramURL, siteAdapter: "youtube" }],
  });
  await env.flush(300);

  // The panel and expanded state are preserved; it is not closed and reopened.
  const panel = shadow.querySelector(".panel");
  assert.ok(panel, "同视频参数变化不得关闭已打开面板");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "true");
  assert.ok(panel.querySelector("[data-macidm-submenu]"), "展开的画质子菜单保留");
  assert.equal(
    panel.querySelectorAll('[data-macidm-btn-variant]').length,
    2,
    "画质保留",
  );
  assert.ok(
    panel.querySelector(`[data-macidm-item-url="${paramURL}"]`),
    "item URL 更新为新参数 URL",
  );
  assert.equal(
    env.sentMessages.filter((m) => m.type === "youtube.ensureInspection").length,
    ensuresBefore,
    "不得重新触发解析",
  );
});

test("异步 tab-title 竞态：旧回包被 epoch 拦截，新页面请求正常生效", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const homeURL = "https://www.youtube.com/";
  env.holdTabTitle();

  env.sync({
    pageUrl: watchURL,
    title: "Fixture",
    candidates: [{ url: watchURL, siteAdapter: "youtube" }],
  });
  await env.flush();
  assert.equal(env.heldTabTitleCount(), 1, "watch 页发出第一条 tab-title 请求");
  env.click(env.shadow().querySelector(".fab"));
  await env.flush();

  // Switch to the home page: close the panel and issue a second request for
  // the new page.
  env.sync({
    pageUrl: homeURL,
    title: "Home",
    candidates: [{ url: "https://cdn.example/hq720.jpg", mime: "image/jpeg", size: 12_345 }],
  });
  await env.flush();
  assert.equal(env.host()?.shadowRoot.querySelector(".panel") ?? null, null);
  assert.equal(env.heldTabTitleCount(), 2, "新页面必须再发一条 tab-title 请求");

  // A late response for the old page is ignored entirely; it must not rebuild
  // candidates from the old URL or reopen the panel.
  env.releaseNextTabTitle({ ok: true, title: "Old Video", url: watchURL, tabId: 1 });
  await env.flush();
  assert.equal(env.host(), null, "旧回包不得为首页图片恢复媒体浮窗");

  // The new page's response is applied normally without reopening the panel
  // or polluting candidates.
  env.releaseNextTabTitle({ ok: true, title: "Home", url: homeURL, tabId: 1 });
  await env.flush();
  assert.equal(env.host(), null, "新回包也不得为首页图片创建浮窗");
});

test("连续快速 A→首页→B：旧回包与候选更新都不能自动打开 B 页面板", async () => {
  const env = createEnv();
  const urlA = "https://www.youtube.com/watch?v=aaaa1111";
  const urlB = "https://www.youtube.com/watch?v=bbbb2222";
  const homeURL = "https://www.youtube.com/";
  env.holdTabTitle();

  env.sync({
    pageUrl: urlA,
    title: "Video A",
    candidates: [{ url: urlA, siteAdapter: "youtube" }],
  });
  await env.flush();
  env.click(env.shadow().querySelector(".fab"));
  await env.flush();

  // Rapid navigation A -> home -> B: the panel must remain closed at every
  // step.
  env.sync({
    pageUrl: homeURL,
    title: "Home",
    candidates: [{ url: "https://cdn.example/hq720.jpg", mime: "image/jpeg", size: 12_345 }],
  });
  env.sync({
    pageUrl: urlB,
    title: "Video B",
    candidates: [{ url: urlB, siteAdapter: "youtube" }],
  });
  await env.flush();
  const shadow = env.shadow();
  assert.equal(shadow.querySelector(".panel"), null, "连续换页后面板不得保持打开");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "false");

  // Suspended old tab-title responses arrive late one by one; none may open
  // B's panel automatically.
  env.releaseNextTabTitle({ ok: true, title: "Video A", url: urlA, tabId: 1 });
  await env.flush();
  env.releaseNextTabTitle({ ok: true, title: "Home", url: homeURL, tabId: 1 });
  await env.flush();
  env.releaseNextTabTitle({ ok: true, title: "Video B", url: urlB, tabId: 1 });
  await env.flush();
  assert.equal(shadow.querySelector(".panel"), null, "旧回包不得自动打开 B 页面板");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "false");

  // Discovery on page B still works: after a user click, candidates and
  // inspection proceed normally.
  env.setResponse({
    ok: true,
    snapshot: {
      tabId: 1,
      pageUrl: urlB,
      videoId: "bbbb2222",
      stage: "complete",
      variants: [{ url: "https://cdn.example/vB#height=720", itag: 136, height: 720, label: "720P" }],
      variantCount: 1,
      mayComplete: false,
      retryable: false,
    },
  });
  env.click(shadow.querySelector(".fab"));
  await env.flush(300);
  let panel = shadow.querySelector(".panel");
  assert.ok(panel.querySelector(`[data-macidm-item-url="${urlB}"]`), "B 的候选正常渲染");
  env.click(panel.querySelector('[data-macidm-item-site="youtube"]'));
  await env.flush();
  panel = shadow.querySelector(".panel");
  assert.equal(
    panel.querySelectorAll('[data-macidm-btn-variant]').length,
    1,
    "B 的画质正常补全",
  );
});

test("URL 换代即时防线：不等换代快照，DOM 变化回调即关闭打开的面板", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const shadow = await openExpandedYouTubePanel(env, watchURL, "abc123", [
    { url: "https://cdn.example/v1080#height=1080", itag: 137, height: 1080, label: "1080P" },
  ]);

  // After SPA pushState and before the generation snapshot arrives (within the
  // 120 ms debounce window), location has changed and the page DOM begins to
  // change; the floating panel's observer must close the panel immediately.
  env.context.location.href = "https://www.youtube.com/";
  env.fireMutations();
  assert.equal(shadow.querySelector(".panel"), null, "DOM 变化回调必须立即关闭面板");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "false");

  // The home-page snapshot that arrives later must not reopen the panel.
  env.sync({
    pageUrl: "https://www.youtube.com/",
    title: "Home",
    candidates: [{ url: "https://cdn.example/hq720.jpg", mime: "image/jpeg", size: 12_345 }],
  });
  await env.flush();
  assert.equal(shadow.querySelector(".panel"), null, "换代快照不得重开面板");
});

test("URL 即时防线不误伤同视频参数变化：面板与画质保留", async () => {
  const env = createEnv();
  const watchURL = "https://www.youtube.com/watch?v=abc123";
  const shadow = await openExpandedYouTubePanel(env, watchURL, "abc123", [
    { url: "https://cdn.example/v720#height=720", itag: 136, height: 720, label: "720P" },
  ]);

  // Same video with only parameter changes: a DOM-change callback must not
  // close the panel.
  env.context.location.href = `${watchURL}&t=60s`;
  env.fireMutations();
  assert.ok(shadow.querySelector(".panel"), "同视频参数变化不得触发即时关闭");
  assert.equal(shadow.querySelector(".fab").getAttribute("aria-expanded"), "true");
  assert.ok(
    shadow.querySelector(".panel").querySelectorAll('[data-macidm-btn-variant]').length === 1,
    "画质保留",
  );
});

test("页面重报候选时主行估算不得闪烁消失", async () => {
  // Reproduce the reported flicker where "highest quality: xx MB" appears and
  // disappears: inspection results live only in the inspectedVariants cache,
  // while each page refresh sends a new candidate without variants. If the
  // main-row slot is finalized before the cache is merged back, the estimate
  // alternates between present and absent across adjacent rebuilds.
  const env = createEnv();
  env.setResponse({
    ok: true,
    variants: [
      { label: "1080P", url: "https://cdn.example/1080.m3u8", estimatedSize: 150 * 1024 * 1024, duration: 300 },
    ],
  });
  const snapshot = () => ({
    pageUrl: "https://example.com/stream",
    title: "Stream Video",
    candidates: [{ url: "https://cdn.example/master.m3u8", format: "hls", duration: 300 }],
  });

  env.sync(snapshot());
  await env.flush();
  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  await env.flush(320); // 自动画质解析在 200ms 后发起并写入缓存

  const metaText = () => {
    // The test stub supports only simple querySelector selectors, so obtain
    // the row in two steps.
    const panel = shadow.querySelector(".panel");
    const row = panel && panel.querySelector(
      '[data-macidm-item-url="https://cdn.example/master.m3u8"]',
    );
    return row ? row.querySelector(".meta-text").textContent : "<row missing>";
  };

  for (const attempt of [1, 2, 3]) {
    env.sync(snapshot());
    await env.flush();
    assert.ok(
      metaText().includes("common.approxHighestSize"),
      `第 ${attempt} 次重报后主行必须仍然显示最高规格估算，实际为: ${metaText()}`,
    );
  }
});

test("多规格流媒体悬浮窗：主行显示最高规格估算，展开后显示各自估算且缺失不伪造，提交携带选中变体大小与时长", async () => {
  const env = createEnv();

  env.sync({
    pageUrl: "https://example.com/stream",
    title: "Stream Video",
    candidates: [
      {
        url: "https://cdn.example/master.m3u8",
        format: "hls",
        duration: 300,
        variants: [
          { label: "1080P", url: "https://cdn.example/1080.m3u8", estimatedSize: 150 * 1024 * 1024, duration: 300 },
          { label: "720P", url: "https://cdn.example/720.m3u8", estimatedSize: 50 * 1024 * 1024, duration: 300 },
          { label: "480P", url: "https://cdn.example/480.m3u8", duration: 300 }, // missing size
        ],
      },
    ],
  });
  await env.flush();

  const shadow = env.shadow();
  env.click(shadow.querySelector(".fab"));
  let panel = shadow.querySelector(".panel");
  let row = panel.querySelector('[data-macidm-item-url="https://cdn.example/master.m3u8"]');
  assert.ok(row);

  // The main-row metadata must contain the highest-quality estimate key.
  const metaEl = row.querySelector(".meta-text");
  assert.ok(metaEl, "必须存在 meta-text");
  assert.ok(metaEl.textContent.includes("common.approxHighestSize"), `主行必须显示最高规格估算，实际为: ${metaEl.textContent}`);

  // Expand the drawer.
  env.fire(row, "keydown", { key: "Enter" });
  panel = shadow.querySelector(".panel");
  const submenu = panel.querySelector('[data-macidm-submenu]');
  assert.ok(submenu, "必须展开子菜单");

  const variantButtons = submenu.querySelectorAll(".sub-item[data-macidm-btn-variant]");
  assert.equal(variantButtons.length, 3);

  // Variant 1: 1080P · common.approxSize.
  assert.ok(variantButtons[0].textContent.includes("1080P"));
  assert.ok(variantButtons[0].textContent.includes("common.approxSize"), `变体1显示估算大小: ${variantButtons[0].textContent}`);

  // Variant 2: 720P · common.approxSize.
  assert.ok(variantButtons[1].textContent.includes("720P"));
  assert.ok(variantButtons[1].textContent.includes("common.approxSize"), `变体2显示估算大小: ${variantButtons[1].textContent}`);

  // Variant 3: 480P (missing size; do not fabricate an estimate).
  assert.equal(variantButtons[2].textContent, "480P", `缺失大小时不伪造估算，实际为: ${variantButtons[2].textContent}`);

  // Click variant 2 to submit the download.
  env.click(variantButtons[1]);
  await env.flush();

  const downloadMsg = env.sentMessages.find((m) => m.type === "media.download");
  assert.ok(downloadMsg, "必须发送 media.download 消息");
  assert.equal(downloadMsg.url, "https://cdn.example/720.m3u8");
  assert.equal(downloadMsg.estimatedSize, 50 * 1024 * 1024, "提交必须携带 720P 变体自身的 estimatedSize");
  assert.equal(downloadMsg.duration, 300, "提交必须携带变体的 duration");
});


test("production overlay isolates X main and reply players and updates reused elements", async () => {
  const env = createEnv({ realScope: true });
  env.context.location.href = "https://x.com/user/status/100";
  const reply = env.addMedia();
  env.video.setAttribute("src", "blob:https://x.com/main");
  env.video.setAttribute("poster", "https://pbs.twimg.com/amplify_video_thumb/111/img/main.jpg");
  reply.setAttribute("src", "blob:https://x.com/reply");
  reply.setAttribute("poster", "https://pbs.twimg.com/amplify_video_thumb/222/img/reply.jpg");
  const mainURL = "https://video.twimg.com/amplify_video/111/vid/main.mp4";
  const replyURL = "https://video.twimg.com/amplify_video/222/vid/reply.mp4";
  const unrelatedURL = "https://video.twimg.com/amplify_video/333/vid/other.mp4";
  const snapshot = { pageUrl: env.context.location.href, candidates: [mainURL, replyURL, unrelatedURL].map(url => ({ url, format: "video" })), filteredSummary: { smallResources: 99 } };
  env.sync(snapshot);
  await env.flush();
  assert.equal(env.hosts().length, 2);
  const urls = shadow => shadow.querySelectorAll("[data-macidm-item-url]").map(row => row.getAttribute("data-macidm-item-url"));
  const mainHost = env.hosts()[0];
  env.click(mainHost.shadowRoot.querySelector(".fab"));
  await env.flush();
  assert.deepEqual(urls(mainHost.shadowRoot), [mainURL]);
  assert.equal(mainHost.shadowRoot.querySelector("[data-macidm-filtered-note]"), null);
  env.click(env.hosts()[1].shadowRoot.querySelector(".fab"));
  await env.flush();
  assert.deepEqual(urls(env.hosts()[1].shadowRoot), [replyURL]);
  // X can reuse the same video node for another post without a page change.
  reply.setAttribute("poster", "https://pbs.twimg.com/amplify_video_thumb/333/img/other.jpg");
  env.fireMutations();
  await env.flush();
  assert.deepEqual(urls(env.hosts()[1].shadowRoot), [unrelatedURL]);
  // A delayed snapshot must not reintroduce the old region's resources.
  env.sync(snapshot);
  await env.flush();
  assert.deepEqual(urls(env.hosts()[1].shadowRoot), [unrelatedURL]);
  reply.setAttribute("poster", "");
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 1, "no attributable download means no floating entry");
  assert.equal(snapshot.candidates.length, 3, "whole-page Popup data is not mutated");
});

test("production overlay isolates direct audio/video and fails closed without scope dependency", async () => {
  const env = createEnv({ realScope: true });
  const audio = env.addMedia("audio");
  const mainURL = "https://cdn.example/movie.mp4?signature=a";
  const audioURL = "https://cdn.example/sound.m4a";
  env.video.setAttribute("src", mainURL);
  audio.setAttribute("src", audioURL);
  env.sync({ candidates: [
    { url: mainURL, format: "video" },
    { url: "https://cdn.example/movie.mp4?signature=b", format: "video" },
    { url: audioURL, format: "audio" },
  ] });
  await env.flush();
  assert.equal(env.hosts().length, 2);
  env.click(env.hosts()[1].shadowRoot.querySelector(".fab"));
  await env.flush();
  assert.deepEqual(env.hosts()[1].shadowRoot.querySelectorAll("[data-macidm-item-url]").map(row => row.getAttribute("data-macidm-item-url")), [audioURL]);
  vm.runInContext("delete globalThis.MacIDMMediaElementScope", env.context);
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 0);
});

test("unattributed MSE and same-title page candidates do not create empty or cross-card FABs", async () => {
  const env = createEnv({ realScope: true });
  env.video.currentSrc = "blob:https://example.com/uuid-1";
  env.video.readyState = 1;
  env.sync({ pageUrl: env.context.location.href, title: "Fixture", candidates: [
    { url: "https://cdn.example/other.mp4", format: "video", cardTitle: "同名标题" },
  ] });
  await env.flush();
  assert.equal(env.hosts().length, 0);
});

// ---- FAB visibility under site modals and off-screen anchors ----

function setRect(element, left, top, width, height) {
  element.getBoundingClientRect = () => ({
    left, top, width, height, right: left + width, bottom: top + height,
  });
}

test("site modal scrim hides covered FABs and restores them when the modal closes", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const modalRoot = doc.createElement("div");
  setRect(modalRoot, 0, 0, 1280, 800);
  doc.documentElement.appendChild(modalRoot);
  const scrim = doc.createElement("div");
  modalRoot.appendChild(scrim);
  // x.com-style in-card click catcher: tops the hit test even without a modal.
  const cardCatcher = doc.createElement("div");
  doc.documentElement.appendChild(cardCatcher);
  const modalVideo = env.addMedia();
  modalVideo.remove();
  modalRoot.appendChild(modalVideo);
  setRect(modalVideo, 300, 50, 700, 700);
  const modalSource = doc.createElement("source");
  modalSource.setAttribute("src", "https://cdn.example/modal.mp4");
  modalVideo.appendChild(modalSource);

  let modalOpen = false;
  env.context.getComputedStyle = (element) => (element === modalRoot
    ? { display: "block", visibility: "visible", position: "fixed" }
    : { display: "block", visibility: "visible", position: "static" });
  // Hit stacks: the modal's own video paints above the scrim; every grid
  // point sits below the scrim once the modal is open.
  doc.elementsFromPoint = (x, y) => {
    if (!modalOpen) return [cardCatcher, env.video, modalVideo];
    if (x === 650 && y === 400) return [modalVideo, scrim, modalRoot];
    return [scrim, modalRoot, cardCatcher, env.video];
  };

  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/video.mp4", format: "video", size: 10 },
      { url: "https://cdn.example/modal.mp4", format: "video", size: 10 },
    ],
  });
  await env.flush();
  assert.equal(env.hosts().length, 2);
  assert.notEqual(env.hosts()[0].style.display, "none");
  assert.notEqual(env.hosts()[1].style.display, "none");

  // Lightbox opens: the grid video stays mounted behind the scrim, but its
  // FAB must hide; the modal's own video keeps its FAB.
  modalOpen = true;
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 2, "occlusion hides, never detaches");
  assert.equal(env.hosts()[0].style.display, "none", "covered grid FAB hides above the modal");
  assert.notEqual(env.hosts()[1].style.display, "none", "the modal's own video keeps its FAB");

  // Closing the modal restores the grid FAB without any re-attach.
  modalOpen = false;
  env.fireMutations();
  await env.flush();
  assert.notEqual(env.hosts()[0].style.display, "none");
});

test("FAB hides while the anchor parks the button off-screen and returns after the carousel scrolls", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const row = doc.createElement("div");
  setRect(row, 900, 0, 2500, 800);
  doc.documentElement.appendChild(row);
  const next = env.addMedia();
  next.remove();
  row.appendChild(next);
  setRect(next, 2000, 100, 700, 300);
  const source = doc.createElement("source");
  source.setAttribute("src", "https://cdn.example/next.mp4");
  next.appendChild(source);

  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/video.mp4", format: "video", size: 10 },
      { url: "https://cdn.example/next.mp4", format: "video", size: 10 },
    ],
  });
  await env.flush();
  assert.equal(env.hosts().length, 2);
  assert.notEqual(env.hosts()[0].style.display, "none");
  assert.equal(env.hosts()[1].style.display, "none", "off-screen carousel slide keeps its FAB hidden");

  // Swiping the carousel brings the slide into the viewport: the element
  // itself becomes usable again and the FAB returns.
  setRect(next, 300, 100, 700, 300);
  env.fireMutations();
  await env.flush();
  assert.notEqual(env.hosts()[1].style.display, "none");
});

test("viewport-overflowing modal player keeps a clamped FAB instead of hiding", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const player = env.addMedia();
  player.remove();
  doc.documentElement.appendChild(player);
  // Douyin-style modal video box: laid out wider than the 1280px viewport
  // while the visible picture is letterboxed inside it.
  setRect(player, -380, 0, 2040, 800);
  const source = doc.createElement("source");
  source.setAttribute("src", "https://cdn.example/overflow.mp4");
  player.appendChild(source);

  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/video.mp4", format: "video", size: 10 },
      { url: "https://cdn.example/overflow.mp4", format: "video", size: 10 },
    ],
  });
  await env.flush();
  const hosts = env.hosts();
  const overflowHost = hosts[hosts.length - 1];
  assert.notEqual(overflowHost.style.display, "none", "viewport-covering player keeps its FAB");
  // The button clamps to the viewport's right edge instead of parking
  // off-screen at the anchor's real (overflowing) right edge.
  assert.equal(Number.parseFloat(overflowHost.style.left), 1286);
});

test("fixed site header owning the outside band falls the FAB back inside", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const header = doc.createElement("div");
  setRect(header, 0, 0, 1280, 56);
  doc.documentElement.appendChild(header);
  const player = env.addMedia();
  player.remove();
  doc.documentElement.appendChild(player);
  setRect(player, 200, 60, 900, 600);
  const source = doc.createElement("source");
  source.setAttribute("src", "https://cdn.example/detail.mp4");
  player.appendChild(source);
  env.context.getComputedStyle = (element) => (element === header
    ? { display: "block", visibility: "visible", position: "fixed" }
    : { display: "block", visibility: "visible", position: "static" });
  // The 32px band above the player's top-right lands on the fixed header.
  doc.elementsFromPoint = (x, y) => (y < 56 ? [header] : [player]);

  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [
      { url: "https://cdn.example/video.mp4", format: "video", size: 10 },
      { url: "https://cdn.example/detail.mp4", format: "video", size: 10 },
    ],
  });
  await env.flush();
  const hosts = env.hosts();
  const playerHost = hosts[hosts.length - 1];
  assert.notEqual(playerHost.style.display, "none");
  // No outside room: inside top-right (rect.top + 6), anchor edge left.
  assert.equal(Number.parseFloat(playerHost.style.top), 66);
  assert.equal(Number.parseFloat(playerHost.style.left), 1100);
});

test("hover-card persistent FAB still engages without a modal", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const card = doc.createElement("div");
  setRect(card, 100, 100, 300, 300);
  doc.documentElement.appendChild(card);
  card.appendChild(doc.createElement("img"));
  env.video.remove();
  card.appendChild(env.video);
  env.sync({
    pageUrl: "https://example.com/feed",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  assert.equal(env.hosts().length, 1);
  // A second sync populates the retained candidate snapshot that persistent
  // mode hands to the panel after the preview video leaves.
  env.fireMutations();
  await env.flush();
  // Hover preview ends: the transient video leaves but the cover card stays,
  // so the FAB persists on the card.
  env.video.remove();
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 1, "cover card keeps the FAB after the preview video leaves");
  assert.notEqual(env.hosts()[0].style.display, "none");
});

test("a modal covering the cover card blocks persistent-FAB takeover", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const modalRoot = doc.createElement("div");
  setRect(modalRoot, 0, 0, 1280, 800);
  doc.documentElement.appendChild(modalRoot);
  const scrim = doc.createElement("div");
  modalRoot.appendChild(scrim);
  const card = doc.createElement("div");
  setRect(card, 100, 100, 300, 300);
  doc.documentElement.appendChild(card);
  card.appendChild(doc.createElement("img"));
  env.video.remove();
  card.appendChild(env.video);
  env.context.getComputedStyle = (element) => (element === modalRoot
    ? { display: "block", visibility: "visible", position: "fixed" }
    : { display: "block", visibility: "visible", position: "static" });
  doc.elementsFromPoint = () => [scrim, modalRoot, card, env.video];
  env.sync({
    pageUrl: "https://example.com/feed",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  assert.equal(env.hosts().length, 1);
  // Populate the retained snapshot so the only remaining reason to refuse
  // persistent mode is the modal occlusion guard.
  env.fireMutations();
  await env.flush();
  // The site modal took the video away (lightbox promotion): the card left
  // behind must not grow a persistent FAB above the modal.
  env.video.remove();
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 0, "occluded card detaches instead of persisting");
});

test("persistent panel keeps the title cached while the hover preview was live", async () => {
  const env = createEnv();
  const doc = env.context.document;
  let cardCaption = "文案甲";
  env.context.MacIDMMediaUtils.resolveContentTitle = () => cardCaption;
  const card = doc.createElement("div");
  setRect(card, 100, 100, 300, 300);
  doc.documentElement.appendChild(card);
  card.appendChild(doc.createElement("img"));
  env.video.remove();
  card.appendChild(env.video);
  env.sync({
    pageUrl: "https://example.com/feed",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  // Second sync populates the live-time snapshot (candidates + title).
  env.fireMutations();
  await env.flush();
  // Hover ends: the detached element's proximity now resolves outside its
  // (gone) card — it must not overwrite the cached title.
  cardCaption = "别的卡片文案乙";
  env.video.remove();
  env.fireMutations();
  await env.flush();
  const host = env.hosts()[0];
  assert.notEqual(host.style.display, "none", "FAB persists on the cover card");
  env.click(host.shadowRoot.querySelector(".fab"));
  const names = host.shadowRoot
    .querySelectorAll("[data-macidm-item-name]")
    .map((n) => n.textContent);
  assert.deepEqual(names, ["文案甲"], "persistent panel keeps the live-cached title");
});

test("short hover retains candidates from the first attachment and repeated hover has one FAB", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const card = doc.createElement("div");
  setRect(card, 100, 100, 300, 300);
  doc.documentElement.appendChild(card);
  const image = doc.createElement("img"); image.setAttribute("src", "https://cdn.example/cover-a.jpg");
  card.appendChild(image);
  env.video.remove(); card.appendChild(env.video);
  env.sync({ pageUrl: env.context.location.href, title: "A", candidates: [{ url: "https://cdn.example/a.mp4", format: "video" }] });
  await env.flush();
  const position = env.hosts()[0].style.left;
  env.video.remove(); env.fireMutations(); await env.flush();
  assert.equal(env.hosts().length, 1, "first attachment already has a retained snapshot");
  assert.equal(env.hosts()[0].style.left, position);
  const next = new env.context.HTMLMediaElement();
  setRect(next, 110, 110, 280, 200); card.appendChild(next);
  env.fireMutations(); await env.flush();
  assert.equal(env.hosts().length, 1, "a replacement preview does not duplicate the card FAB");
  next.remove(); env.fireMutations(); await env.flush();
  image.setAttribute("src", "https://cdn.example/cover-b.jpg");
  env.fireMutations(); await env.flush();
  assert.equal(env.hosts().length, 0, "recycled card cannot retain the previous media");
});

test("a connected preview changing src cannot persist the previous resource", async () => {
  const env = createEnv({ realScope: true });
  const doc = env.context.document;
  const card = doc.createElement("div"); setRect(card, 100, 100, 300, 300);
  card.appendChild(doc.createElement("img")); doc.documentElement.appendChild(card);
  env.video.remove(); card.appendChild(env.video);
  env.video.setAttribute("src", "https://cdn.example/a.mp4");
  env.sync({ pageUrl: env.context.location.href, title: "A", candidates: [{url:"https://cdn.example/a.mp4",format:"video"}] });
  await env.flush(); assert.equal(env.hosts().length, 1);
  env.video.setAttribute("src", "https://cdn.example/b.mp4");
  env.fireMutations(); await env.flush();
  assert.equal(env.hosts().length, 0);
});

test("hover teardown can empty a connected preview before removing it without losing the FAB", async () => {
  const env = createEnv({ realScope: true });
  const doc = env.context.document;
  const card = doc.createElement("div"); setRect(card,100,100,300,300);
  card.appendChild(doc.createElement("img")); doc.documentElement.appendChild(card);
  env.video.remove(); card.appendChild(env.video);
  env.video.setAttribute("src","https://cdn.example/a.mp4");
  env.sync({pageUrl:env.context.location.href,title:"A",candidates:[{url:"https://cdn.example/a.mp4",format:"video"}]});
  await env.flush(); assert.equal(env.hosts().length,1);
  env.video.setAttribute("src", ""); env.video.currentSrc = "";
  env.fireMutations(); await env.flush(); assert.equal(env.hosts().length,1);
  env.video.remove(); env.fireMutations(); await env.flush(); assert.equal(env.hosts().length,1);
});

// 回归（抖音精选）：打开/关闭详情弹窗属于路由切换，但持久 FAB 属于
// 卡片而非路由——弹窗打开时被遮挡隐藏，关闭后必须恢复，不得被卸载。
test("persistent hover-card FAB survives modal open/close route changes", async () => {
  const env = createEnv();
  const doc = env.context.document;
  const card = doc.createElement("div");
  setRect(card, 100, 100, 300, 300);
  doc.documentElement.appendChild(card);
  card.appendChild(doc.createElement("img"));
  env.video.remove();
  card.appendChild(env.video);
  env.sync({
    pageUrl: "https://example.com/feed",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  env.fireMutations();
  await env.flush();
  env.video.remove();
  env.fireMutations();
  await env.flush();
  assert.equal(env.hosts().length, 1, "preview 结束后 FAB 钉在卡片上");
  // 打开弹窗（路由加 modal_id）：持久 FAB 不得卸载。
  env.sync({
    pageUrl: "https://example.com/feed?modal_id=123",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  assert.equal(env.hosts().length, 1, "弹窗打开（路由切换）后持久 FAB 存活");
  // 关闭弹窗回到feed：FAB 仍在。
  env.sync({
    pageUrl: "https://example.com/feed",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/video.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  assert.equal(env.hosts().length, 1, "弹窗关闭后持久 FAB 恢复");
});

// 回归（抖音弹窗切集/嗅探重启）：瞬时空候选窗口不得卸载存活播放器上
// 的 FAB；只有持续超过宽限期的空候选才卸载。
test("transient empty candidates keep the FAB; sustained emptiness beyond the grace unmounts it", async () => {
  const env = createEnv();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "A",
    candidates: [{ url: "https://cdn.example/a.mp4", format: "video", size: 10 }],
  });
  await env.flush();
  assert.equal(env.hosts().length, 1);
  // 切集/嗅探重启瞬间发布空列表：FAB 保留。
  env.sync({ pageUrl: "https://example.com/watch", title: "A", candidates: [] });
  await env.flush();
  assert.equal(env.hosts().length, 1, "空候选窗口内 FAB 保留");
  // 持续空候选超过 10s 宽限期后卸载。
  const ContextDate = vm.runInContext("Date", env.context);
  const frozenNow = ContextDate.now() + 15_000;
  env.context.Date = Object.create(ContextDate);
  env.context.Date.now = () => frozenNow;
  try {
    env.sync({ pageUrl: "https://example.com/watch", title: "A", candidates: [] });
    await env.flush();
  } finally {
    env.context.Date = ContextDate;
  }
  assert.equal(env.hosts().length, 0, "持续空候选超过宽限期后卸载");
});

// 主行时长槽：App 逐 variant 回传 duration，解析成功后回填 candidate；
// candidate 对象每次 sync 重建，时长必须跨快照保留。
test("inspection backfills the main-row duration slot and survives candidate rebuilds", async () => {
  const env = createEnv();
  env.context.MacIDMMediaUtils.formatDuration = (seconds) => {
    if (!Number.isFinite(seconds) || seconds <= 0) return null;
    const total = Math.floor(seconds);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
  };
  env.holdNextSend();
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/master.m3u8", format: "hls", fileExtension: "m3u8" }],
  });
  await env.flush();
  const host = env.hosts()[0];
  env.click(host.shadowRoot.querySelector(".fab"));
  await env.flush(320); // 面板构建（200ms 自动解析排期）→ media.inspect 挂起
  const metaOf = () =>
    [...host.shadowRoot.querySelectorAll(".meta-text")].map((n) => n.textContent).join(" ");
  env.releaseHeld({
    ok: true,
    variants: [
      { label: "720P", url: "https://cdn.example/v720.m3u8", estimatedSize: 300_000_000, duration: 492 },
    ],
  });
  await env.flush(320); // 面板重建后结果落位
  assert.match(metaOf(), /08:12/, "解析结果回填主行时长槽");
  // 重新 sync：candidate 对象重建，时长从缓存恢复，不丢。
  env.sync({
    pageUrl: "https://example.com/watch",
    title: "Fixture",
    candidates: [{ url: "https://cdn.example/master.m3u8", format: "hls", fileExtension: "m3u8" }],
  });
  await env.flush(320);
  if (!host.shadowRoot.querySelector(".panel")) {
    env.click(host.shadowRoot.querySelector(".fab"));
    await env.flush(50);
  }
  assert.match(metaOf(), /08:12/, "candidate 重建后主行时长槽不丢");
});
