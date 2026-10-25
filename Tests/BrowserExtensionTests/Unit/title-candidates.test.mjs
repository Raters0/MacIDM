import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// 语义判断候选收割器的纯函数边界（technical-spec §8.1 / chrome-extension-spec
// §7.1.1）：修剪、2–200 字符边界、全串去重、10 条上限与来源标注。DOM 收集
// 层是薄封装，真实页面证据由 Tests/Support/jev-title-eval 评测覆盖。

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/title-candidates.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({});
context.globalThis = context;
vm.runInContext(source, context);
const titleCandidates = context.MacIDMTitleCandidates;

test("normalizeCandidates 修剪空白、过滤 2–200 字符边界并全串去重", () => {
  const normalized = titleCandidates.normalizeCandidates([
    { text: "  标题一  ", source: "heading" },
    { text: "标题一", source: "img-alt" },
    { text: "", source: "heading" },
    { text: "a", source: "heading" },
    { text: "标".repeat(201), source: "heading" },
    { text: "标题二", source: "img-alt" },
  ]);
  // vm 跨 realm 数组与宿主原型不同，展开成宿主数组再比较。
  assert.deepEqual(
    [...normalized.map((candidate) => candidate.text)],
    ["标题一", "标题二"],
  );
});

test("normalizeCandidates 大小写不敏感去重并截断到 10 条且保持原顺序", () => {
  const entries = [];
  for (let index = 0; index < 12; index += 1) {
    entries.push({ text: `Title ${index}`, source: "heading" });
  }
  entries.push({ text: "title 0", source: "img-alt" });
  const normalized = titleCandidates.normalizeCandidates(entries);
  assert.equal(normalized.length, 10);
  assert.equal(normalized[0].text, "Title 0");
  assert.equal(normalized.at(-1).text, "Title 9");
});

test("normalizeCandidates 保留来源标注与卡片/页面作用域", () => {
  const normalized = titleCandidates.normalizeCandidates([
    { text: "标题三", source: "img-alt", scope: "card" },
    { text: "标题四", source: "document.title" },
  ]);
  assert.equal(normalized[0].source, "img-alt");
  assert.equal(normalized[0].scope, "card");
  assert.equal(normalized[1].scope, "page", "缺省作用域必须归为 page");
});
