import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// chrome-extension-spec §5.8: the style contract for expanding full
// candidate titles. The collapsed state keeps a single ellipsized line (no
// list-density regression); the expanded state switches to full multi-line
// wrapping, and both entry points must keep the expansion selector so the
// render branch preserves the expanded state.

const popupCss = await readFile(
  new URL("../../../BrowserExtension/chrome/src/popup/popup.css", import.meta.url),
  "utf8",
);
const overlaySource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/content/overlay.js", import.meta.url),
  "utf8",
);

function ruleBlock(source, selector) {
  const index = source.indexOf(selector);
  assert.notEqual(index, -1, `缺少选择器 ${selector}`);
  const open = source.indexOf("{", index);
  const close = source.indexOf("}", open);
  return source.slice(open + 1, close);
}

test("Popup 折叠标题保持单行省略", () => {
  const block = ruleBlock(popupCss, ".media-content strong {");
  assert.match(block, /white-space:\s*nowrap/u);
  assert.match(block, /text-overflow:\s*ellipsis/u);
});

test("Popup 展开标题完整换行显示", () => {
  const block = ruleBlock(popupCss, ".media-row.open .media-content strong");
  assert.match(block, /white-space:\s*normal/u);
  assert.match(block, /overflow-wrap:\s*anywhere/u);
  assert.doesNotMatch(block, /text-overflow:\s*ellipsis/u);
});

test("悬浮窗折叠标题保持单行省略", () => {
  const block = ruleBlock(overlaySource, ".name {");
  assert.match(block, /white-space:\s*nowrap/u);
  assert.match(block, /text-overflow:\s*ellipsis/u);
});

test("悬浮窗展开标题完整换行显示", () => {
  const block = ruleBlock(overlaySource, ".item.open .name");
  assert.match(block, /white-space:\s*normal/u);
  assert.match(block, /overflow-wrap:\s*anywhere/u);
});
