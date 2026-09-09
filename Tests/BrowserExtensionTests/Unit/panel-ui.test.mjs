import assert from "node:assert/strict";
import test from "node:test";

// Loading the classic script installs MacIDMPanelUI on globalThis, the same
// way the popup document and the content-script world load it.
import "../../../BrowserExtension/chrome/src/shared/panel-ui.js";

function makeContainer() {
  const children = [];
  const container = {
    children,
    ownerDocument: {
      createElement() {
        const element = {
          attributes: {},
          style: { cssText: "" },
          textContent: "",
          setAttribute(name, value) {
            element.attributes[name] = value;
          },
          remove() {
            const index = children.indexOf(element);
            if (index >= 0) children.splice(index, 1);
          },
        };
        return element;
      },
    },
    querySelector(selector) {
      if (selector !== "[data-macidm-toast]") return null;
      return children.find((child) => "data-macidm-toast" in child.attributes) ?? null;
    },
    append(element) {
      children.push(element);
    },
  };
  return container;
}

test("showToast renders the message with the panel surface fill", () => {
  const container = makeContainer();
  const toast = MacIDMPanelUI.showToast(container, "已打开 MacIDM 下载确认窗口。", { durationMs: 60_000 });
  assert.equal(toast.textContent, "已打开 MacIDM 下载确认窗口。");
  assert.equal(toast.attributes["data-macidm-toast"], "success");
  // Semantic color lives in the text only; the fill stays the panel surface.
  assert.match(toast.style.cssText, /color:light-dark\(#38ab78,#5ecb9a\)/u);
  assert.match(toast.style.cssText, /background:light-dark\(rgba\(255,255,255,0\.97\),rgba\(32,35,41,0\.97\)\)/u);
  // Top-center anchoring relative to the container.
  assert.match(toast.style.cssText, /position:absolute/u);
  assert.match(toast.style.cssText, /top:10px/u);
  assert.match(toast.style.cssText, /translateX\(-50%\)/u);
  assert.equal(container.children.length, 1);
  toast.remove();
});

test("showToast picks the error color for the error kind", () => {
  const container = makeContainer();
  const toast = MacIDMPanelUI.showToast(container, "提交媒体下载失败。", { kind: "error", durationMs: 60_000 });
  assert.equal(toast.attributes["data-macidm-toast"], "error");
  assert.match(toast.style.cssText, /color:light-dark\(#e05257,#f0868a\)/u);
  toast.remove();
});

test("showToast defaults to a percentage max-width for normal containers", () => {
  const container = makeContainer();
  const toast = MacIDMPanelUI.showToast(container, "已发送给 MacIDM", { durationMs: 60_000 });
  assert.match(toast.style.cssText, /max-width:90%/u);
  toast.remove();
});

test("showToast honors a pixel max-width for zero-sized anchor containers", () => {
  // The overlay's .wrap is a 0×0 anchor around the FAB: a percentage
  // max-width resolves to 0 there and collapses the toast to its padding
  // (a ~26px white speck with the message clipped away). The overlay must
  // pass a pixel width so the feedback stays readable.
  const container = makeContainer();
  const toast = MacIDMPanelUI.showToast(container, "已发送给 MacIDM", {
    durationMs: 60_000,
    maxWidth: "280px",
  });
  assert.match(toast.style.cssText, /max-width:280px/u);
  assert.doesNotMatch(toast.style.cssText, /max-width:90%/u);
  toast.remove();
});

test("a new toast replaces a still-visible one instead of stacking", () => {
  const container = makeContainer();
  const first = MacIDMPanelUI.showToast(container, "first", { durationMs: 60_000 });
  const second = MacIDMPanelUI.showToast(container, "second", { durationMs: 60_000 });
  assert.equal(container.children.length, 1);
  assert.equal(container.children[0], second);
  assert.notEqual(first, second);
  second.remove();
});

test("the toast removes itself after the duration elapses", async () => {
  const container = makeContainer();
  MacIDMPanelUI.showToast(container, "gone soon", { durationMs: 10 });
  assert.equal(container.children.length, 1);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(container.children.length, 0);
});

test("empty input shows nothing", () => {
  const container = makeContainer();
  assert.equal(MacIDMPanelUI.showToast(container, "", {}), null);
  assert.equal(MacIDMPanelUI.showToast(null, "message", {}), null);
  assert.equal(container.children.length, 0);
});
