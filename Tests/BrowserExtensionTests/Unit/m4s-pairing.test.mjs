import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

import {
  applyM4sPairing,
  extractM4sInfo,
  isBilibiliPageURL,
} from "../../../BrowserExtension/chrome/src/background/m4s-pairing.js";

function makeCandidate(url, overrides = {}) {
  return {
    url,
    mime: "",
    format: "video",
    supported: true,
    displayName: url.split("/").pop() ?? "媒体资源",
    displayURL: url,
    size: null,
    filenameHint: "track.mp4",
    ...overrides,
  };
}

test("extractM4sInfo returns null for non-m4s URLs", () => {
  assert.equal(extractM4sInfo("https://cdn.example/video.mp4"), null);
  assert.equal(extractM4sInfo("blob:https://example.com/id"), null);
  assert.equal(extractM4sInfo("not-a-url"), null);
});

test("extractM4sInfo classifies 302xx as audio and others as video", () => {
  assert.deepEqual(
    extractM4sInfo("https://upgz.bilivideo.com/1550776785-1-100022.m4s"),
    { cid: "1550776785", formatId: 100022, kind: "video" },
  );
  assert.deepEqual(
    extractM4sInfo("https://upgz.bilivideo.com/1550776785-1-30280.m4s"),
    { cid: "1550776785", formatId: 30280, kind: "audio" },
  );
});

test("applyM4sPairing turns a cid with video+audio into a single paired candidate", () => {
  const videoUrl = "https://upgz.bilivideo.com/1550776785-1-100022.m4s";
  const audioUrl = "https://upgz.bilivideo.com/1550776785-1-30280.m4s";
  const payload = {
    // Neutral page: Bilibili pages deterministically synthesize the adapter
    // and return it first, so the pairing mechanism itself is verified on a
    // neutral page.
    pageUrl: "https://example.com/watch",
    title: "测试视频",
    candidates: [makeCandidate(videoUrl), makeCandidate(audioUrl)],
  };

  const result = applyM4sPairing(payload);

  assert.equal(result.candidates.length, 1);
  const paired = result.candidates[0];
  assert.equal(paired.pairKind, "m4s-pair");
  assert.equal(paired.pairVideoUrl, videoUrl);
  assert.equal(paired.pairAudioUrl, audioUrl);
  assert.equal(paired.pairCid, "1550776785");
  assert.equal(paired.pairNote, "含音视频，需 FFmpeg 合并");
  assert.equal(paired.collapsed, false);
  assert.equal(paired.url, videoUrl);
  assert.equal(paired.format, "video");
  // displayName uses the page title; filenameHint uses the page title + .mp4
  assert.equal(paired.displayName, "测试视频");
  assert.equal(paired.filenameHint, "测试视频.mp4");
});

test("applyM4sPairing falls back to 视频（cid） when page title is empty", () => {
  const videoUrl = "https://upgz.bilivideo.com/1550776785-1-100022.m4s";
  const audioUrl = "https://upgz.bilivideo.com/1550776785-1-30280.m4s";
  const payload = {
    pageUrl: "https://example.com/watch",
    title: "",
    candidates: [makeCandidate(videoUrl), makeCandidate(audioUrl)],
  };

  const result = applyM4sPairing(payload);
  const paired = result.candidates[0];
  assert.equal(paired.displayName, "视频（1550776785）");
  assert.equal(paired.filenameHint, "视频（1550776785）.mp4");
});

test("applyM4sPairing picks the highest format_id when multiple qualities exist", () => {
  const lowVideo = "https://upgz.bilivideo.com/1550776785-1-100022.m4s";
  const highVideo = "https://upgz.bilivideo.com/1550776785-1-100116.m4s";
  const lowAudio = "https://upgz.bilivideo.com/1550776785-1-30216.m4s";
  const highAudio = "https://upgz.bilivideo.com/1550776785-1-30280.m4s";
  const payload = {
    pageUrl: "https://example.com/watch",
    title: "T",
    candidates: [
      makeCandidate(lowVideo),
      makeCandidate(highVideo),
      makeCandidate(lowAudio),
      makeCandidate(highAudio),
    ],
  };

  const result = applyM4sPairing(payload);
  const paired = result.candidates[0];
  assert.equal(paired.pairVideoUrl, highVideo);
  assert.equal(paired.pairAudioUrl, highAudio);
});

test("applyM4sPairing prefers the Bilibili adapter over a video-only m4s fragment", () => {
  const videoUrl = "https://upgz.bilivideo.com/1550776785-1-100022.m4s";
  const payload = {
    pageUrl: "https://www.bilibili.com/video/BV1234",
    title: "T",
    candidates: [makeCandidate(videoUrl)],
  };

  const result = applyM4sPairing(payload);
  assert.equal(result.candidates.length, 1);
  assert.equal(result.candidates[0].siteAdapter, "bilibili");
});

test("applyM4sPairing keeps non-m4s candidates in front and fragments at the end", () => {
  const mp4 = makeCandidate("https://cdn.example/movie.mp4");
  const videoM4s = makeCandidate("https://upgz.bilivideo.com/111-1-100022.m4s");
  const audioM4s = makeCandidate("https://upgz.bilivideo.com/222-1-30280.m4s");
  const payload = {
    pageUrl: "https://example.com",
    title: "T",
    candidates: [mp4, videoM4s, audioM4s],
  };

  const result = applyM4sPairing(payload);
  assert.equal(result.candidates.length, 3);
  // non-m4s first
  assert.equal(result.candidates[0].url, "https://cdn.example/movie.mp4");
  // Paired candidates (same cid with both video+audio) come next — here each
  // of the two cids has only one track kind, so both count as fragments and
  // sort last
  assert.equal(result.candidates[1].pairKind, "m4s-fragment");
  assert.equal(result.candidates[2].pairKind, "m4s-fragment");
});

test("applyM4sPairing groups multiple cids independently", () => {
  const v1 = "https://upgz.bilivideo.com/111-1-100022.m4s";
  const a1 = "https://upgz.bilivideo.com/111-1-30280.m4s";
  const v2 = "https://upgz.bilivideo.com/222-1-100116.m4s";
  const a2 = "https://upgz.bilivideo.com/222-1-30216.m4s";
  const payload = {
    pageUrl: "https://example.com",
    title: "T",
    candidates: [makeCandidate(v1), makeCandidate(a1), makeCandidate(v2), makeCandidate(a2)],
  };

  const result = applyM4sPairing(payload);
  assert.equal(result.candidates.length, 2);
  assert.notEqual(result.candidates[0].pairCid, result.candidates[1].pairCid);
  assert.equal(result.candidates[0].pairKind, "m4s-pair");
  assert.equal(result.candidates[1].pairKind, "m4s-pair");
});

test("applyM4sPairing leaves non-m4s candidates untouched", () => {
  const mp4 = makeCandidate("https://cdn.example/movie.mp4");
  const payload = {
    pageUrl: "https://example.com",
    title: "T",
    candidates: [mp4],
  };

  const result = applyM4sPairing(payload);
  assert.equal(result.candidates.length, 1);
  assert.equal(result.candidates[0].url, "https://cdn.example/movie.mp4");
  assert.equal(result.candidates[0].pairKind, undefined);
  assert.equal(result.candidates[0].collapsed, undefined);
});

test("applyM4sPairing folds X-style HLS segment traffic behind its manifest", () => {
  const pageUrl = "https://x.com/user/status/123";
  const manifest = makeCandidate(
    "https://video.twimg.com/amplify/playlist.m3u8",
    { format: "hls", mime: "application/vnd.apple.mpegurl", fileExtension: "m3u8" },
  );
  const segment = makeCandidate(
    "https://video.twimg.com/amplify/seg-1.m4s",
    { size: 47_000, fileExtension: "m4s" },
  );
  const tinyMp4 = makeCandidate(
    "https://video.twimg.com/amplify/bootstrap.mp4",
    { size: 904, fileExtension: "mp4" },
  );

  const result = applyM4sPairing({
    pageUrl,
    title: "X 帖子",
    candidates: [manifest, segment, tinyMp4],
  });

  assert.equal(result.candidates.length, 2);
  assert.equal(result.candidates[0].format, "hls");
  assert.equal(result.candidates[0].fileExtension, "m3u8");
  assert.equal(result.candidates[1].pairKind, "stream-segment");
  assert.equal(result.candidates[1].supported, false);
  assert.equal(result.candidates[1].segmentCount, 2);
});

test("applyM4sPairing removes player sounds and exact duplicates while preserving manifest query identity", () => {
  const pageUrl = "https://www.youtube.com/watch?v=123";
  const result = applyM4sPairing({
    pageUrl,
    title: "YouTube 测试视频",
    candidates: [
      makeCandidate("https://www.youtube.com/s/player/abc/failure.mp3", {
        format: "audio",
        fileExtension: "mp3",
      }),
      makeCandidate("https://video.example/playlist.m3u8?tag=14", {
        format: "hls",
        mime: "application/vnd.apple.mpegurl",
        fileExtension: "m3u8",
      }),
      makeCandidate("https://video.example/playlist.m3u8?tag=14#same", {
        format: "hls", mime: "application/vnd.apple.mpegurl", fileExtension: "m3u8",
      }),
      makeCandidate("https://video.example/playlist.m3u8?tag=15", {
        format: "hls",
        mime: "application/vnd.apple.mpegurl",
        fileExtension: "m3u8",
      }),
      makeCandidate("https://rr.example.googlevideo.com/videoplayback?mime=video%2Fmp4&itag=18", {
        fileExtension: "mp4",
      }),
    ],
  });

  assert.equal(result.candidates.length, 3);
  assert.equal(result.candidates.filter((candidate) => candidate.format === "hls").length, 2);
  assert.equal(result.candidates.filter((candidate) => candidate.fileExtension === "mp4").length, 1);
});

test("applyM4sPairing creates a Bilibili page adapter when only CDN noise is observed", () => {
  const pageUrl = "https://www.bilibili.com/video/BV1234";
  const result = applyM4sPairing({
    pageUrl,
    title: "B 站标题",
    candidates: [
      makeCandidate(
        "https://upos-sz-mirror08c.bilivideo.com/123/web.mp4",
        { mime: "video/mp4", size: 2, fileExtension: "mp4" },
      ),
    ],
  });

  assert.equal(result.candidates.length, 1);
  assert.equal(result.candidates[0].siteAdapter, "bilibili");
  assert.equal(result.candidates[0].fileExtension, "mp4");
});

test("applyM4sPairing handles empty / malformed input gracefully", () => {
  assert.deepEqual(applyM4sPairing(null), null);
  assert.deepEqual(applyM4sPairing({}), {});
  assert.deepEqual(applyM4sPairing({ candidates: [] }), { candidates: [] });
});

test("applyM4sPairing adds the Bilibili adapter on the watchlater list page", () => {
  // The watchlater list page embeds the same player; the identity lives in
  // the bvid/oid query parameters and must collapse into the site-resolution
  // candidate exactly like a /video/ page, instead of handing the user
  // dozens of m4s fragments.
  const pageUrl =
    "https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9&oid=117229555292053&vd_source=tracking";
  const result = applyM4sPairing({
    pageUrl,
    title: "稍后再看标题",
    candidates: [
      makeCandidate("https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", {
        mime: "video/mp4",
        size: 2,
        fileExtension: "mp4",
      }),
      makeCandidate("https://upgz.bilivideo.com/1550776785-1-100022.m4s"),
    ],
  });

  assert.equal(result.candidates.length, 1);
  assert.equal(result.candidates[0].siteAdapter, "bilibili");
  assert.equal(result.candidates[0].url, pageUrl);
});

test("applyM4sPairing keeps a watchlater page without video identity unadapted", () => {
  const result = applyM4sPairing({
    pageUrl: "https://www.bilibili.com/list/watchlater/",
    title: "T",
    candidates: [makeCandidate("https://cdn.example/movie.mp4", { fileExtension: "mp4" })],
  });

  assert.ok(result.candidates.every((candidate) => candidate.siteAdapter !== "bilibili"));
});

test("background and page-world Bilibili page detection stay in sync", async () => {
  // The service worker and the page world each hold their own
  // isBilibiliPageURL (modules cannot be shared at runtime); the two
  // implementations must reach identical verdicts on the same URLs, otherwise
  // Popup and overlay candidates drift apart.
  const source = await readFile(
    new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
    "utf8",
  );
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(source, context);
  const pageWorld = context.MacIDMMediaUtils.isBilibiliPageURL;

  const urls = [
    "",
    "not-a-url",
    "https://www.bilibili.com/video/BV1B6bN6HEX9/",
    "https://bilibili.com/video/av12345?p=2",
    "https://www.bilibili.com/bangumi/play/ep123456",
    "https://www.bilibili.com/bangumi/play/ss123456",
    "https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9&oid=117229555292053",
    "https://www.bilibili.com/list/watchlater/?oid=117229555292053",
    "https://www.bilibili.com/list/watchlater/?avid=117229555292053",
    "https://m.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9",
    "https://www.bilibili.com/list/watchlater/",
    "https://www.bilibili.com/list/watchlater/?bvid=not-a-bvid",
    "https://www.bilibili.com/list/watchlater/?oid=abc",
    "https://www.bilibili.com/list/ml/?bvid=BV1B6bN6HEX9",
    "https://www.bilibili.com/space/1",
    "https://example.com/list/watchlater/?bvid=BV1B6bN6HEX9",
    "https://notbilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9",
  ];
  for (const url of urls) {
    assert.equal(isBilibiliPageURL(url), pageWorld(url), `两份实现对 ${url || "(空)"} 结论不一致`);
  }
  assert.equal(isBilibiliPageURL("https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9"), true);
  assert.equal(isBilibiliPageURL("https://www.bilibili.com/list/watchlater/"), false);
});

test("both worlds collapse strays identically once pair/adapter evidence exists", async () => {
  // Collapse and finalize behavior must stay consistent across worlds;
  // otherwise the Popup and the overlay again disagree — one showing the
  // adapter, the other a pair plus a duplicated highlighted row.
  const source = await readFile(
    new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
    "utf8",
  );
  const context = vm.createContext({ URL });
  context.globalThis = context;
  vm.runInContext(source, context);
  const pageWorld = context.MacIDMMediaUtils;

  // Same-cid video/audio tracks on edge CDN hosts (not bilivideo.com):
  // recognizable only via the m4s filename, exactly what site-agnostic
  // collapsing must cover.
  const edgeVideo = makeCandidate("https://svx42w.edge.mountaintoys.cn:4483/upgcxcode/93/86/41667068693/41667068693-1-100024.m4s?e=x");
  const edgeAudio = makeCandidate("https://svx42w.edge.mountaintoys.cn:4483/upgcxcode/93/86/41667068693/41667068693-1-30232.m4s?e=x");
  const nextCidVideo = makeCandidate("https://cn-gddg-ct-01-10.bilivideo.com/upgcxcode/99/99/88888888888/88888888888-1-100024.m4s?e=x");
  const strayMp4 = makeCandidate("https://upos-sz-mirror08c.bilivideo.com/123/web.mp4", {
    mime: "video/mp4",
    size: 2,
    fileExtension: "mp4",
  });
  // Note: page-world arrays are vm-realm objects; .map would return a
  // vm-realm Array whose prototype breaks deepStrictEqual, so build the
  // comparison structure manually in the test realm.
  const shape = (list) => {
    const out = [];
    for (const c of list) out.push([c.url, c.siteAdapter ?? "", c.pairKind ?? ""]);
    return out;
  };

  // Scenario 1: watchlater page (identity resolvable) -> both worlds keep
  // only the adapter.
  const watchlater = "https://www.bilibili.com/list/watchlater/?bvid=BV1B6bN6HEX9&oid=117229555292053";
  const pageOne = pageWorld.coalesceMediaCandidates(
    [edgeVideo, edgeAudio, nextCidVideo, strayMp4],
    "T",
    watchlater,
  );
  const bgOne = applyM4sPairing({
    pageUrl: watchlater,
    title: "T",
    candidates: [edgeVideo, edgeAudio, nextCidVideo, strayMp4],
  }).candidates;
  assert.ok(pageOne.some(c => c.siteAdapter === "bilibili"));
  assert.ok(pageOne.some(c => c.pairKind === "m4s-pair"));
  assert.equal(pageOne[0].siteAdapter, "bilibili");
  assert.deepEqual(shape(bgOne), shape(pageOne), "两世界收尾不一致");

  // Scenario 2: non-Bilibili page but a full pair observed -> both worlds
  // keep only the pair; fragments do not flood the list.
  const otherPage = "https://example.com/watch";
  const pageTwo = pageWorld.coalesceMediaCandidates([edgeVideo, edgeAudio, nextCidVideo], "T", otherPage);
  const bgTwo = applyM4sPairing({
    pageUrl: otherPage,
    title: "T",
    candidates: [edgeVideo, edgeAudio, nextCidVideo],
  }).candidates;
  assert.ok(pageTwo.some(c => c.pairKind === "m4s-pair"));
  assert.ok(pageTwo.some(c => c.pairKind !== "m4s-pair"), "unrelated CID remains discoverable");
  assert.equal(pageTwo[0].pairKind, "m4s-pair");
  assert.deepEqual(shape(bgTwo), shape(pageTwo), "两世界收尾不一致");

  // Scenario 3: no evidence at all -> fragments are the only clue, both
  // worlds keep them unchanged.
  const pageThree = pageWorld.coalesceMediaCandidates([nextCidVideo, strayMp4], "T", otherPage);
  const bgThree = applyM4sPairing({
    pageUrl: otherPage,
    title: "T",
    candidates: [nextCidVideo, strayMp4],
  }).candidates;
  assert.equal(pageThree.length, 2);
  assert.ok(pageThree.some((c) => c.pairKind === "m4s-fragment"));
  assert.deepEqual(shape(bgThree), shape(pageThree), "两世界收尾不一致");
});

test("pairing preserves unrelated MP4 and HLS downloads", () => {
  const independent = [makeCandidate("https://other.example/lecture.mp4"), makeCandidate("https://other.example/live.m3u8", { format: "hls" })];
  const candidates = [...independent, makeCandidate("https://cdn.example/42-1-100022.m4s"), makeCandidate("https://cdn.example/42-1-30280.m4s")];
  const result = applyM4sPairing({ pageUrl: "https://example.com/watch", candidates });
  for (const item of independent) assert.ok(result.candidates.some(c => c.url === item.url));
});
