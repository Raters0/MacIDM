// Unit tests for false-positive suppression (sniffGovernance). See the
// "false-positive suppression / noise threshold configuration" section of
// docs/specifications/chrome-extension-spec.md and
// docs/specifications/technical-spec.md §8.4.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

import { DEFAULT_SETTINGS } from "../../../BrowserExtension/chrome/src/shared/constants.js";

const governanceSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/sniff-governance.js", import.meta.url),
  "utf8",
);
const mediaUtilsSource = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const context = vm.createContext({ URL });
context.globalThis = context;
vm.runInContext(mediaUtilsSource, context);
vm.runInContext(governanceSource, context);
const governance = context.MacIDMSniffGovernance;
const mediaUtils = context.MacIDMMediaUtils;

const PAGE_URL = "https://www.example.com/watch";

function candidate(raw, baseURL = PAGE_URL) {
  return mediaUtils.normalizeMediaCandidate(raw, baseURL);
}

// Object prototypes in the vm realm differ from the host's; copy into the
// host realm before deepEqual.
function plainSummary(summary) {
  return { ...summary };
}

function run(input, settings) {
  const result = governance.applySniffGovernance(input, settings);
  return { candidates: result.candidates, filteredSummary: plainSummary(result.filteredSummary) };
}

function urls(result) {
  return [...result.candidates.map((item) => item.url)];
}

test("sniff-governance installs a frozen global API", () => {
  assert.ok(governance);
  assert.ok(Object.isFrozen(governance));
  assert.equal(typeof governance.normalizeSniffGovernance, "function");
  assert.equal(typeof governance.applySniffGovernance, "function");
});

test("defaults stay in parity with DEFAULT_SETTINGS.sniffGovernance", () => {
  assert.deepEqual(
    { ...governance.DEFAULT_SNIFF_GOVERNANCE },
    { ...DEFAULT_SETTINGS.sniffGovernance },
  );
});

test("normalizeSniffGovernance migrates missing fields to defaults", () => {
  assert.deepEqual({ ...governance.normalizeSniffGovernance(undefined) }, {
    enabled: true,
    minimumMediaBytes: 0,
    audioMinimumBytes: 64 * 1024,
    segmentMaximumBytes: 16 * 1024,
  });
  assert.deepEqual(
    { ...governance.normalizeSniffGovernance(null) },
    { ...governance.DEFAULT_SNIFF_GOVERNANCE },
  );
  assert.deepEqual(
    { ...governance.normalizeSniffGovernance("on") },
    { ...governance.DEFAULT_SNIFF_GOVERNANCE },
  );
  assert.deepEqual(
    { ...governance.normalizeSniffGovernance([1, 2]) },
    { ...governance.DEFAULT_SNIFF_GOVERNANCE },
  );
  // Field-by-field fallback: valid fields are kept, invalid ones fall back
  // to defaults.
  assert.deepEqual(
    { ...governance.normalizeSniffGovernance({ enabled: false }) },
    { enabled: false, minimumMediaBytes: 0, audioMinimumBytes: 64 * 1024, segmentMaximumBytes: 16 * 1024 },
  );
});

test("normalizeSniffGovernance rejects invalid threshold values", () => {
  const cases = [
    { minimumMediaBytes: -1 },
    { minimumMediaBytes: 0.5 },
    { minimumMediaBytes: "1024" },
    { minimumMediaBytes: 64 * 1024 * 1024 + 1 },
    { audioMinimumBytes: -1 },
    { audioMinimumBytes: 1.5 },
    { audioMinimumBytes: "65536" },
    { audioMinimumBytes: 64 * 1024 * 1024 + 1 },
    { segmentMaximumBytes: -1024 },
    { segmentMaximumBytes: Number.NaN },
    { segmentMaximumBytes: 64 * 1024 * 1024 + 1 },
  ];
  for (const override of cases) {
    assert.deepEqual(
      { ...governance.normalizeSniffGovernance(override) },
      { ...governance.DEFAULT_SNIFF_GOVERNANCE },
      `expected defaults for ${JSON.stringify(override)}`,
    );
  }
  // Boundary values are legal: 0 and 64 MiB.
  assert.equal(governance.normalizeSniffGovernance({ minimumMediaBytes: 0 }).minimumMediaBytes, 0);
  assert.equal(governance.normalizeSniffGovernance({ audioMinimumBytes: 0 }).audioMinimumBytes, 0);
  assert.equal(
    governance.normalizeSniffGovernance({ segmentMaximumBytes: 64 * 1024 * 1024 }).segmentMaximumBytes,
    64 * 1024 * 1024,
  );
});

test("disabled governance keeps everything and reports zero counts", () => {
  const input = [
    candidate({ url: "https://cdn.example.com/success.mp3", size: 2048 }),
    candidate({ url: "https://cdn.example.com/live/master.m3u8", mime: "application/vnd.apple.mpegurl" }),
    candidate({ url: "https://cdn.example.com/live/init.mp4", size: 700 }),
  ];
  const result = run(input, { enabled: false });
  assert.equal(result.candidates.length, 3);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
});

test("small known-size audio below the threshold is diagnostic noise", () => {
  const input = [
    candidate({ url: "https://cdn.example.com/success.mp3", size: 2048 }),
    candidate({ url: "https://cdn.example.com/open.mp3", size: 2048, duration: 8 }),
  ];
  const result = run(input, null);
  assert.deepEqual(urls(result), []);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 2, streamSegments: 0, smallResources: 0 });
});

test("audio with unknown size, long duration, or large size is never noise", () => {
  const input = [
    candidate({ url: "https://cdn.example.com/unknown.mp3" }),
    candidate({ url: "https://cdn.example.com/podcast.mp3", size: 2048, duration: 15 }),
    candidate({ url: "https://cdn.example.com/album.mp3", size: 500 * 1024 }),
  ];
  const result = run(input, null);
  assert.equal(result.candidates.length, 3);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
});

test("audio with duration over 10 seconds is kept even when tiny", () => {
  const input = [candidate({ url: "https://cdn.example.com/speech.mp3", size: 4096, duration: 10.5 })];
  const result = run(input, null);
  assert.equal(result.candidates.length, 1);
});

test("audio with exactly 10 seconds duration is treated as noise (rule is >10s)", () => {
  const input = [candidate({ url: "https://cdn.example.com/tone.mp3", size: 4096, duration: 10 })];
  const result = run(input, null);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 1, streamSegments: 0, smallResources: 0 });
});

test("site-adapter, m4s-pair, manifest, and blob candidates are never suppressed", () => {
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const siteAdapter = {
    ...candidate({ url: PAGE_URL, mime: "text/html" }),
    siteAdapter: "bilibili",
    size: 2048,
  };
  const m4sPair = {
    ...candidate({ url: "https://upos.example.bilivideo.com/1000-1-30080.m4s", size: 2048 }),
    pairKind: "m4s-pair",
  };
  const blob = candidate({ url: "blob:https://www.example.com/media" });
  const input = [
    candidate({ url: "https://cdn.example.com/success.mp3", size: 2048 }),
    manifest,
    siteAdapter,
    m4sPair,
    blob,
  ];
  const result = run(input, null);
  assert.equal(result.candidates.length, 4);
  assert.ok(result.candidates.includes(manifest));
  assert.ok(result.candidates.includes(siteAdapter));
  assert.ok(result.candidates.includes(m4sPair));
  assert.ok(result.candidates.includes(blob));
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 1, streamSegments: 0, smallResources: 0 });
});

test("init segments collapse only when a same-host manifest exists", () => {
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const sameHostInit = candidate({ url: "https://cdn.example.com/live/init.mp4", size: 700 });
  const crossHostInit = candidate({ url: "https://other.example.com/init.mp4", size: 700 });

  const withManifest = run([manifest, sameHostInit, crossHostInit], null);
  assert.deepEqual(urls(withManifest), [manifest.url, crossHostInit.url]);
  assert.deepEqual(withManifest.filteredSummary, { diagnosticAudio: 0, streamSegments: 1, smallResources: 0 });

  // Without manifest evidence: both cross-origin and same-origin init
  // segments stay visible (prefer keeping noise).
  const withoutManifest = run([sameHostInit, crossHostInit], null);
  assert.equal(withoutManifest.candidates.length, 2);
  assert.deepEqual(withoutManifest.filteredSummary, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
});

test("bootstrap-named segments follow the init rule but initial does not", () => {
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  // Sizes are all above the tiny-segment threshold; only the name rule can
  // trigger.
  const bootstrap = candidate({ url: "https://cdn.example.com/live/bootstrap.mp4", size: 100 * 1024 });
  const initial = candidate({ url: "https://cdn.example.com/live/initial.mp4", size: 100 * 1024 });
  const result = run([manifest, bootstrap, initial], null);
  assert.deepEqual(urls(result), [manifest.url, initial.url]);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 1, smallResources: 0 });
});

test("tiny stream segments after a same-host manifest collapse as noise", () => {
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const tinyTS = candidate({ url: "https://cdn.example.com/live/seg-001.ts", size: 4096 });
  const tinyMP4 = candidate({ url: "https://cdn.example.com/live/frag-1.mp4", size: 8192 });
  const result = run([manifest, tinyTS, tinyMP4], null);
  assert.deepEqual(urls(result), [manifest.url]);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 2, smallResources: 0 });
});

test("segments without manifest evidence stay visible", () => {
  const tinyTS = candidate({ url: "https://cdn.example.com/live/seg-001.ts", size: 4096 });
  const tinyMP4 = candidate({ url: "https://cdn.example.com/live/frag-1.mp4", size: 8192 });
  const result = run([tinyTS, tinyMP4], null);
  assert.equal(result.candidates.length, 2);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
});

test("large segments above the threshold are kept even with a manifest", () => {
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const largeTS = candidate({ url: "https://cdn.example.com/live/seg-001.ts", size: 1024 * 1024 });
  const result = run([manifest, largeTS], null);
  assert.deepEqual(urls(result), [manifest.url, largeTS.url]);
});

test("a standalone small direct video without a manifest is never suppressed", () => {
  const input = [candidate({ url: "https://files.example.com/clip.mp4", size: 8192 })];
  const result = run(input, null);
  assert.equal(result.candidates.length, 1);
  assert.deepEqual(result.filteredSummary, { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 });
});

test("Bilibili full-track m4s candidates are never suppressed (pair sources)", () => {
  const manifest = candidate({
    url: "https://upos.example.bilivideo.com/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const tinyTrack = candidate({
    url: "https://upos.example.bilivideo.com/123456-1-30280.m4s",
    size: 4096,
  });
  const result = run([manifest, tinyTrack], null);
  assert.deepEqual(urls(result), [manifest.url, tinyTrack.url]);
});

test("summary carries only the three desensitized count keys and caps at 100000", () => {
  const many = Array.from({ length: 100_005 }, (_, index) =>
    candidate({ url: `https://cdn.example.com/tone-${index}.mp3`, size: 2048 }));
  const result = run(many, null);
  assert.deepEqual([...Object.keys(result.filteredSummary).sort()], ["diagnosticAudio", "smallResources", "streamSegments"]);
  assert.equal(result.candidates.length, 0);
  assert.equal(result.filteredSummary.diagnosticAudio, 100_000);
});

test("custom thresholds are honored", () => {
  const input = [candidate({ url: "https://cdn.example.com/success.mp3", size: 100 * 1024 })];
  const defaultResult = run(input, null);
  assert.equal(defaultResult.candidates.length, 1);

  const raised = run(input, { enabled: true, audioMinimumBytes: 200 * 1024 });
  assert.equal(raised.candidates.length, 0);
  assert.equal(raised.filteredSummary.diagnosticAudio, 1);
});

test("minimumMediaBytes filters size-known small candidates and counts smallResources", () => {
  // Observed on Bilibili: page decoration images (avatars/thumbnails, small
  // with known sizes) flood the list. At a 16 KB threshold they are all
  // filtered as smallResources; the default 0 filters nothing.
  const input = [
    candidate({ url: "https://i2.hdslb.com/bfs/archive/cover.avif", size: 40 * 1024 }),
    candidate({ url: "https://i1.hdslb.com/bfs/face/avatar.webp", size: 2 * 1024 }),
    candidate({ url: "https://i0.hdslb.com/garb/item/badge.webp", size: 564 }),
  ];
  const defaultResult = run(input, null);
  assert.equal(defaultResult.candidates.length, 3);
  assert.equal(defaultResult.filteredSummary.smallResources, 0);

  const filtered = run(input, { enabled: true, minimumMediaBytes: 16 * 1024 });
  assert.deepEqual(urls(filtered), ["https://i2.hdslb.com/bfs/archive/cover.avif"]);
  assert.equal(filtered.filteredSummary.smallResources, 2);
});

test("minimumMediaBytes never filters size-unknown candidates", () => {
  // Most video streams cannot probe a total size (size null): size-unknown
  // candidates are never filtered by the generic threshold (prefer keeping
  // noise over killing direct links).
  const input = [
    candidate({ url: "https://cdn.example.com/stream.m3u8", mime: "application/vnd.apple.mpegurl" }),
    candidate({ url: "https://cdn.example.com/track.m4s" }),
    candidate({ url: "https://cdn.example.com/video.mp4" }),
  ];
  const result = run(input, { enabled: true, minimumMediaBytes: 64 * 1024 * 1024 });
  assert.equal(result.candidates.length, 3);
  assert.equal(result.filteredSummary.smallResources, 0);
});

test("minimumMediaBytes keeps whitelisted candidates even when small and size-known", () => {
  // Site adapters / paired m4s / manifests / blobs are never filtered by
  // the generic threshold.
  const siteAdapter = {
    ...candidate({ url: PAGE_URL, mime: "text/html" }),
    siteAdapter: "bilibili",
    size: 2048,
  };
  const m4sPair = {
    ...candidate({ url: "https://upos.example.bilivideo.com/1000-1-30080.m4s", size: 2048 }),
    pairKind: "m4s-pair",
  };
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
    size: 2048,
  });
  const blob = candidate({ url: "blob:https://www.example.com/media" });
  const result = run(
    [siteAdapter, m4sPair, manifest, blob],
    { enabled: true, minimumMediaBytes: 64 * 1024 },
  );
  assert.equal(result.candidates.length, 4);
  assert.equal(result.filteredSummary.smallResources, 0);
});

test("specific noise classes win over the generic small-resource bucket", () => {
  // Diagnostic audio and noise segments are classified first: one candidate
  // must not be double-counted into smallResources.
  const manifest = candidate({
    url: "https://cdn.example.com/live/master.m3u8",
    mime: "application/vnd.apple.mpegurl",
  });
  const tinyAudio = candidate({ url: "https://cdn.example.com/tone.mp3", size: 2048 });
  const tinySegment = candidate({ url: "https://cdn.example.com/live/seg-001.ts", size: 4096 });
  const tinyImage = candidate({ url: "https://cdn.example.com/avatar.webp", size: 2048 });
  const result = run(
    [manifest, tinyAudio, tinySegment, tinyImage],
    { enabled: true, minimumMediaBytes: 16 * 1024 },
  );
  assert.deepEqual(urls(result), [manifest.url]);
  assert.deepEqual(result.filteredSummary, {
    diagnosticAudio: 1,
    streamSegments: 1,
    smallResources: 1,
  });
});

test("governance composes with coalesceMediaCandidates as a pre-filter", () => {
  // content-script snapshot pipeline: govern first, then coalesce. Diagnostic
  // audio must not appear in the final Popup candidates; kept segments are
  // still folded into a segment group by coalesce.
  const raw = [
    candidate({ url: "https://cdn.example.com/success.mp3", size: 2048 }),
    candidate({ url: "https://cdn.example.com/live/master.m3u8", mime: "application/vnd.apple.mpegurl" }),
    candidate({ url: "https://cdn.example.com/live/seg-001.ts", size: 5 * 1024 * 1024 }),
    candidate({ url: "https://cdn.example.com/live/seg-002.ts", size: 5 * 1024 * 1024 }),
  ];
  const governed = governance.applySniffGovernance(raw, null);
  const coalesced = mediaUtils.coalesceMediaCandidates(governed.candidates, "页面标题", PAGE_URL);

  assert.equal(governed.filteredSummary.diagnosticAudio, 1);
  assert.ok(coalesced.every((item) => item.url !== "https://cdn.example.com/success.mp3"));
  const segmentGroup = coalesced.find((item) => item.pairKind === "stream-segment");
  assert.ok(segmentGroup, "kept segments still fold into a stream-segment group");
  assert.equal(segmentGroup.segmentCount, 2);
});
