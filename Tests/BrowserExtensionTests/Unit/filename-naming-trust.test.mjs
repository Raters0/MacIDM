import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// 命名可信度模型（技术规范 §8.1）：filenameHint 必须携带来源标注，
// 泛化占位词清单在扩展 JS 与 App Swift 两侧必须一致。

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(source, context);
const mediaUtils = context.MacIDMMediaUtils;

test("filenameHintSourceFor marks synthesized names as titleDerived", () => {
  assert.equal(mediaUtils.filenameHintSourceFor({ siteAdapter: "youtube" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ siteAdapter: "bilibili" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ pairKind: "m4s-pair" }), "titleDerived");
  assert.equal(mediaUtils.filenameHintSourceFor({ pairKind: "stream-segment" }), "titleDerived");
  assert.equal(
    mediaUtils.filenameHintSourceFor({ url: "https://example.com/a.mp4", filenameHint: "a.mp4" }),
    "urlPath",
  );
  assert.equal(mediaUtils.filenameHintSourceFor(null), "urlPath");
  assert.equal(mediaUtils.filenameHintSourceFor(undefined), "urlPath");
});

test("smartMediaName treats download/master placeholders as generic", () => {
  // "download" 与 "master" 都在泛化清单里：多候选时也不拼进显示名。
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "download.mp4" }, "课程标题", 2),
    "课程标题",
  );
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "master.mp4" }, "课程标题", 2),
    "课程标题",
  );
  // 非泛化 hint 在多候选时作为区分后缀保留。
  assert.equal(
    mediaUtils.smartMediaName({ filenameHint: "720p.mp4" }, "课程标题", 2),
    "课程标题 · 720p.mp4",
  );
});

test("generic placeholder word lists stay identical across JS and Swift", async () => {
  const expected = [
    "audio", "download", "index", "manifest", "master", "media", "playlist", "video",
  ];
  const overlaySource = await readFile(
    new URL("../../../BrowserExtension/chrome/src/content/overlay.js", import.meta.url),
    "utf8",
  );
  const swiftSource = await readFile(
    new URL("../../../Sources/MacIDMApp/Presentation/DownloadNaming.swift", import.meta.url),
    "utf8",
  );

  // 两份 JS 泛化正则（media-utils 的 smartMediaName 与 overlay 的降级副本）。
  for (const jsSource of [source, overlaySource]) {
    const match = jsSource.match(/\^\((download\|[^)]+)\)\\b\/i/);
    assert.ok(match, "JS 源码必须包含泛化名正则，且以 download 开头");
    assert.deepEqual(match[1].split("|").sort(), expected);
  }

  // Swift 侧 isGenericFilename 的基词数组。
  const swiftMatch = swiftSource.match(/return \[\s*([^\]]+)\]\.contains\(base\)/);
  assert.ok(swiftMatch, "Swift 源码必须包含泛化基词清单");
  const swiftWords = [...swiftMatch[1].matchAll(/"([a-z]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(swiftWords, expected);
});
