import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/slim-scrollbar.js", import.meta.url),
  "utf8",
);

function loadModule(extraGlobals = {}) {
  const context = vm.createContext({
    setTimeout,
    clearTimeout,
    ...extraGlobals,
  });
  context.globalThis = context;
  vm.runInContext(source, context);
  return context.MacIDMSlimScrollbar;
}

test("thumbGeometry returns null when there is nothing to scroll", () => {
  const { thumbGeometry } = loadModule();
  assert.equal(thumbGeometry({ scrollTop: 0, scrollHeight: 200, clientHeight: 300, rectTop: 0, rectHeight: 300 }), null);
  assert.equal(thumbGeometry({ scrollTop: 0, scrollHeight: 0, clientHeight: 0, rectTop: 0, rectHeight: 0 }), null);
});

test("thumbGeometry tracks scroll progress and clamps to the track", () => {
  const { thumbGeometry } = loadModule();
  const base = { scrollHeight: 1000, clientHeight: 200, rectTop: 10, rectHeight: 200 };
  // Top: the thumb hugs the container top (vm objects cannot deepEqual;
  // assert field by field).
  let geo = thumbGeometry({ ...base, scrollTop: 0 });
  assert.equal(geo.top, 10);
  assert.equal(geo.height, 40);
  // Bottom: the thumb hugs the container bottom (10 + 200 - 40).
  geo = thumbGeometry({ ...base, scrollTop: 800 });
  assert.equal(geo.top, 170);
  assert.equal(geo.height, 40);
  // Midpoint: the thumb is centered.
  geo = thumbGeometry({ ...base, scrollTop: 400 });
  assert.equal(geo.top, 90);
  // Out-of-range scrolling is clamped.
  geo = thumbGeometry({ ...base, scrollTop: 9999 });
  assert.equal(geo.top, 170);
  assert.equal(geo.height, 40);
});

test("thumbGeometry honors the minimum thumb height", () => {
  const { thumbGeometry } = loadModule();
  // 2000px content / 200px viewport -> natural thumb 20px, but minimum 24px.
  const geo = thumbGeometry({ scrollTop: 0, scrollHeight: 2000, clientHeight: 200, rectTop: 0, rectHeight: 200 });
  assert.equal(geo.height, 24);
});

test("attach ignores containers that are not in the DOM yet", () => {
  // Regression: at buildPanel time the overlay panel is not yet inserted
  // into the shadow DOM, so the detached container has no parentElement. The
  // old implementation fell back to hanging the thumb inside the container,
  // where overflow clipping (plus backdrop-filter hijacking the fixed
  // reference) made it invisible forever — everything must stay disabled
  // until the caller attaches after insertion.
  const created = [];
  class FakeNode {
    constructor(tag) {
      this.tagName = tag;
      this.children = [];
      this.parentNode = null;
      this._classSet = new Set();
    }
    get classList() {
      const self = this;
      return {
        add: (...names) => names.forEach((n) => self._classSet.add(n)),
        remove: (...names) => names.forEach((n) => self._classSet.delete(n)),
        contains: (n) => self._classSet.has(n),
      };
    }
    append(node) {
      node.parentNode = this;
      this.children.push(node);
    }
  }
  const doc = {
    head: new FakeNode("head"),
    createElement: (tag) => {
      const node = new FakeNode(tag);
      created.push(node);
      return node;
    },
    getElementById: () => null,
  };
  const container = new FakeNode("div");
  container.ownerDocument = doc;
  // No parentNode: simulates a panel not yet inserted into the DOM.

  const { attach } = loadModule();
  const detachFn = attach(container);
  detachFn();
  // No nodes are created (no thumb/style injected) and the container does
  // not get the class that hides the native scrollbar.
  assert.equal(created.length, 0);
  assert.equal(container.children.length, 0);
  assert.ok(!container._classSet.has("macidm-slim-scroll"));
});

test("hovering the container must not reveal the thumb; only scrolling does", async () => {
  // Regression: the old implementation also revealed the thumb on
  // mouseenter (hover) — as soon as the overlay panel opened, the pointer
  // naturally entered and the scrollbar popped out before any scrolling,
  // violating the "appear only on scroll" rule.
  const listeners = [];
  class FakeNode {
    constructor(tag) {
      this.tagName = tag;
      this.className = "";
      this.style = {};
      this.children = [];
      this.parentNode = null;
      this._classSet = new Set();
      this.listeners = {};
    }
    get classList() {
      const self = this;
      return {
        add: (...names) => names.forEach((n) => self._classSet.add(n)),
        remove: (...names) => names.forEach((n) => self._classSet.delete(n)),
        contains: (n) => self._classSet.has(n),
      };
    }
    get parentElement() {
      return this.parentNode;
    }
    append(node) {
      node.parentNode = this;
      this.children.push(node);
    }
    addEventListener(type, fn) {
      (this.listeners[type] ??= []).push(fn);
    }
    removeEventListener(type, fn) {
      this.listeners[type] = (this.listeners[type] ?? []).filter((f) => f !== fn);
    }
    getBoundingClientRect() {
      return { top: 0, right: 300, height: 200 };
    }
    dispatch(type) {
      for (const fn of this.listeners[type] ?? []) fn({});
    }
  }
  const doc = {
    head: new FakeNode("head"),
    createElement: (tag) => new FakeNode(tag),
    getElementById: () => null,
  };
  const container = new FakeNode("div");
  container.ownerDocument = doc;
  container.scrollTop = 100;
  container.scrollHeight = 1000;
  container.clientHeight = 200;
  const parent = new FakeNode("section");
  parent.append(container);

  const { attach } = loadModule();
  attach(container);
  const thumb = parent.children.find((node) => node.className === "macidm-slim-thumb");
  assert.ok(thumb, "thumb 应挂在容器父节点上");

  // Pointer enters the container (hover): must not show.
  container.dispatch("mouseenter");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(!thumb._classSet.has("macidm-slim-thumb-visible"), "悬停不得显示滚动条");

  // Actual scrolling: show.
  container.scrollTop = 300;
  container.dispatch("scroll");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(thumb._classSet.has("macidm-slim-thumb-visible"), "滚动时应显示滚动条");

  // The hover path is fully removed: no mouseenter listener remains on the
  // container.
  assert.equal((container.listeners.mouseenter ?? []).length, 0);
});

test("attach hides the native scrollbar, renders a fixed thumb, and detach cleans up", async () => {
  const listeners = [];
  const globalListeners = [];
  const created = [];
  class FakeNode {
    constructor(tag) {
      this.tagName = tag;
      this.className = "";
      this.style = {};
      this.children = [];
      this.parentNode = null;
      this._classSet = new Set();
      this.listeners = {};
    }
    get classList() {
      const self = this;
      return {
        add: (...names) => names.forEach((n) => self._classSet.add(n)),
        remove: (...names) => names.forEach((n) => self._classSet.delete(n)),
        contains: (n) => self._classSet.has(n),
      };
    }
    get parentElement() {
      return this.parentNode;
    }
    append(node) {
      node.parentNode = this;
      this.children.push(node);
    }
    remove() {
      const siblings = this.parentNode?.children ?? [];
      const index = siblings.indexOf(this);
      if (index >= 0) siblings.splice(index, 1);
      this.parentNode = null;
    }
    addEventListener(type, fn) {
      (this.listeners[type] ??= []).push(fn);
    }
    removeEventListener(type, fn) {
      this.listeners[type] = (this.listeners[type] ?? []).filter((f) => f !== fn);
    }
    getBoundingClientRect() {
      return { top: 0, right: 300, height: 200 };
    }
    dispatch(type) {
      for (const fn of this.listeners[type] ?? []) fn({});
    }
  }

  const doc = {
    head: new FakeNode("head"),
    createElement: (tag) => {
      const node = new FakeNode(tag);
      created.push(node);
      return node;
    },
    getElementById: () => null,
  };
  const container = new FakeNode("div");
  container.ownerDocument = doc;
  container.scrollTop = 500;
  container.scrollHeight = 1000;
  container.clientHeight = 200;
  const parent = new FakeNode("section");
  parent.append(container);

  const globalStub = {
    setTimeout,
    clearTimeout,
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    cancelAnimationFrame: clearTimeout,
    addEventListener: (type, fn) => globalListeners.push([type, fn]),
    removeEventListener: (type, fn) => {
      const index = globalListeners.findIndex(([t, f]) => t === type && f === fn);
      if (index >= 0) globalListeners.splice(index, 1);
    },
  };
  const { attach } = loadModule(globalStub);

  const detach = attach(container);
  // Container tagged + style injected + thumb hung on the parent node (not
  // inside the container, to survive re-renders).
  assert.ok(container._classSet.has("macidm-slim-scroll"));
  assert.equal(created[0].id, "macidm-slim-scrollbar-style");
  const thumb = parent.children.find((node) => node.className === "macidm-slim-thumb");
  assert.ok(thumb, "thumb 应挂在容器父节点上");
  // scrollTop=500/800 progress -> top = 160 * 0.625 = 100; the thumb itself
  // is opacity-hidden (no visible class).
  assert.equal(thumb.style.display, "");
  assert.equal(thumb.style.top, "100px");
  assert.ok(!thumb._classSet.has("macidm-slim-thumb-visible"), "未滚动前 thumb 不显示");

  // Scrolled to the bottom: progress clamps to 1 -> top = rectTop(0) + (200 - 40) = 160.
  container.scrollTop = 900;
  container.dispatch("scroll");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(thumb._classSet.has("macidm-slim-thumb-visible"), "滚动时 thumb 应可见");
  assert.equal(thumb.style.top, "160px");
  await new Promise((resolve) => setTimeout(resolve, 1000));
  assert.ok(!thumb._classSet.has("macidm-slim-thumb-visible"), "停止滚动约 0.9s 后应淡出");

  // detach removes the thumb, listeners, and the container tag.
  detach();
  assert.equal(thumb.parentNode, null);
  assert.ok(!container._classSet.has("macidm-slim-scroll"));
  assert.equal((container.listeners.scroll ?? []).length, 0);
  assert.equal(globalListeners.filter(([type]) => type === "resize").length, 0);
});
