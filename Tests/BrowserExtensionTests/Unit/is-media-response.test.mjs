import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/background/service-worker.js", import.meta.url),
  "utf8",
);

const match = source.match(/function isMediaResponse\([\s\S]*?\n\}/);
assert.ok(match, "isMediaResponse function not found in service-worker.js");
const context = vm.createContext({});
vm.runInContext(match[0], context);
const isMediaResponse = context.isMediaResponse;

test("isMediaResponse matches URL with media extension", () => {
  assert.equal(isMediaResponse("https://cdn.example/video.mp4", ""), true);
  assert.equal(isMediaResponse("https://cdn.example/stream.m3u8", ""), true);
  assert.equal(isMediaResponse("https://cdn.example/manifest.mpd", ""), true);
  assert.equal(isMediaResponse("https://cdn.example/audio.mp3", ""), true);
});

test("isMediaResponse matches video/audio Content-Type", () => {
  assert.equal(isMediaResponse("https://cdn.example/stream", "video/mp4"), true);
  assert.equal(isMediaResponse("https://cdn.example/stream", "audio/mpeg"), true);
  assert.equal(isMediaResponse("https://cdn.example/stream", "application/vnd.apple.mpegurl"), true);
  assert.equal(isMediaResponse("https://cdn.example/stream", "application/dash+xml"), true);
});

test("isMediaResponse matches Content-Range header for CDN video", () => {
  assert.equal(
    isMediaResponse("https://cdn.example/stream", "application/octet-stream", "bytes 0-1023/12345678"),
    true,
  );
  assert.equal(
    isMediaResponse("https://cdn.example/video?id=1", "", "bytes 1048576-2097151/12345678"),
    true,
  );
});

test("isMediaResponse matches Content-Disposition with media filename", () => {
  assert.equal(
    isMediaResponse("https://cdn.example/dl", "application/octet-stream", "", 'attachment; filename="video.mp4"'),
    true,
  );
  assert.equal(
    isMediaResponse("https://cdn.example/dl", "", "", "attachment; filename=movie.webm"),
    true,
  );
});

test("isMediaResponse rejects non-media responses", () => {
  assert.equal(isMediaResponse("https://cdn.example/data", "application/json"), false);
  assert.equal(isMediaResponse("https://cdn.example/page", "text/html"), false);
  assert.equal(isMediaResponse("https://cdn.example/file", "application/octet-stream"), false);
  assert.equal(isMediaResponse("https://cdn.example/file", "", "", 'attachment; filename="doc.pdf"'), false);
});

test("isMediaResponse ignores media extensions embedded in query strings", () => {
  // B 站实测：data.bilibili.com/log/web 埋点把 CDN m4s 地址整段抄进 query，
  // webRequest 响应头观察据此把每条日志都记成候选（「M4S · 2 B」随播放
  // 持续累积）。扩展名判定只看路径（首个 ?/# 之前）。
  const beacon = "https://data.bilibili.com/log/web?0011|Default:Ugc:0|https://cn-hbyc-ct-01-05.bilivideo.com/upgcxcode/82/76/40214857682/40214857682-1-30011.m4s?e=abc&deadline=123";
  assert.equal(isMediaResponse(beacon, ""), false);
  assert.equal(isMediaResponse(beacon, "text/plain"), false);
  assert.equal(isMediaResponse("https://example.com/collect?payload=.mp4", ""), false);
  assert.equal(isMediaResponse("https://example.com/page#https://cdn.example/v.mp4", ""), false);
  // Real media: the extension is on the path, so the signed-query CDN URL is
  // still recognized.
  assert.equal(
    isMediaResponse(
      "https://cn-hbyc-ct-01-05.bilivideo.com/upgcxcode/82/76/40214857682/40214857682-1-30011.m4s?e=abc&deadline=123",
      "video/mp4",
    ),
    true,
  );
});
