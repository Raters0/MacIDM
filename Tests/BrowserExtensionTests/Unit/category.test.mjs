import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/category.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(source, context);
const category = context.MacIDMCategory;

test("extensions map onto the same seven categories as the App", () => {
  const cases = [
    ["backup.zip", "archive"],
    ["release.tar.gz", "archive"],
    ["archive.tgz", "archive"],
    ["paper.pdf", "document"],
    ["notes.md", "document"],
    ["book.epub", "document"],
    ["photo.webp", "image"],
    ["shot.bmp", "image"],
    ["song.flac", "audio"],
    ["voice.opus", "audio"],
    ["movie.mkv", "video"],
    ["clip.flv", "video"],
    ["installer.dmg", "application"],
    ["app.apk", "application"],
    ["tool.msi", "application"],
    ["disk.iso", "application"],
    ["Obsidian-1.14.16.AppImage", "application"],
    ["editor.flatpak", "application"],
    ["tool.snap", "application"],
    ["mystery.bin", "other"],
    ["no-extension", "other"],
  ];
  for (const [filename, expected] of cases) {
    assert.equal(category.categoryFor(filename), expected, filename);
  }
});

test("broadened market formats classify the same way as the App", () => {
  const cases = [
    ["rootfs.tar.zst", "archive"],
    ["image.wim", "archive"],
    ["简历.pages", "document"],
    ["book.azw3", "document"],
    ["scan.djvu", "document"],
    ["config.yaml", "document"],
    ["photo.cr2", "image"],
    ["shot.avif", "image"],
    ["design.psd", "image"],
    ["track.ape", "audio"],
    ["book.m4b", "audio"],
    ["segment.ts", "video"],
    ["cam.m2ts", "video"],
    ["movie.rmvb", "video"],
    ["app.aab", "application"],
    ["signed.ipa", "application"],
    ["modern.msix", "application"],
    ["extension.crx", "application"],
    ["install.sh", "other"],
    ["run.bat", "other"],
  ];
  for (const [filename, expected] of cases) {
    assert.equal(category.categoryFor(filename), expected, filename);
  }
});

test("URL query strings do not hide the extension", () => {
  assert.equal(
    category.categoryFor("https://cdn.example.com/files/setup.exe?token=abc&expires=9"),
    "application",
  );
  assert.equal(
    category.categoryFor("https://cdn.example.com/seg/7f3a9b21", "image/png"),
    "image",
  );
});

test("MIME decides when the extension is unrecognized or missing", () => {
  assert.equal(category.categoryFor("data", "application/zip"), "archive");
  assert.equal(category.categoryFor("stream", "video/mp2t"), "video");
  assert.equal(category.categoryFor("track", "audio/mpeg"), "audio");
  assert.equal(category.categoryFor("blob", "application/octet-stream"), "other");
  assert.equal(category.categoryFor("file", "text/csv; charset=utf-8"), "document");
});

test("streaming candidates are always video regardless of filename or MIME", () => {
  assert.equal(category.categoryForCandidate({ url: "https://x.com/master.m3u8", format: "hls" }), "video");
  assert.equal(category.categoryForCandidate({ url: "https://x.com/a.mpd", format: "dash" }), "video");
  assert.equal(
    category.categoryForCandidate({ url: "https://bilibili.com/video/BV1", siteAdapter: "bilibili" }),
    "video",
  );
});

test("direct candidates classify from filename hint first", () => {
  assert.equal(
    category.categoryForCandidate({ url: "https://x.com/blob", filenameHint: "讲义.pdf", mime: "application/pdf" }),
    "document",
  );
  assert.equal(category.categoryForCandidate(null), "other");
});

test("every category has an icon and a label key", () => {
  for (const name of category.CATEGORIES) {
    const svg = category.categoryIconSVG(name);
    assert.match(svg, /^<svg /, name);
    assert.match(svg, /<\/svg>$/u, name);
    assert.match(svg, /fill="none"/u, name);
    assert.match(svg, /stroke="currentColor"/u, name);
    assert.equal(category.categoryLabelKey(name), `common.category.${name}`);
  }
  // Unknown names fall back to the "other" bucket instead of throwing.
  assert.equal(category.categoryLabelKey("nonsense"), "common.category.other");
  assert.match(category.categoryIconSVG("nonsense"), /<svg /);
});

test("popup.css does not override line-stroke SVG fill with currentColor", async () => {
  const popupCss = await readFile(
    new URL("../../../BrowserExtension/chrome/src/popup/popup.css", import.meta.url),
    "utf8",
  );
  const selector = ".media-meta .meta-icon svg";
  const index = popupCss.indexOf(selector);
  assert.notEqual(index, -1, `缺少选择器 ${selector}`);
  const open = popupCss.indexOf("{", index);
  const close = popupCss.indexOf("}", open);
  const block = popupCss.slice(open + 1, close);
  assert.doesNotMatch(
    block,
    /fill:\s*currentColor/iu,
    "Popup CSS 不得对线框分类 SVG 强行覆盖 fill currentColor",
  );
});
