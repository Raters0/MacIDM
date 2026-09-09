import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const mediaUtilsSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/media-utils.js", import.meta.url),
  "utf8",
);
const youtubeFormatUtilsSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/youtube-format-utils.js", import.meta.url),
  "utf8",
);
const mediaPresentationSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/shared/media-presentation.js", import.meta.url),
  "utf8",
);

function createEnvironment() {
  const context = vm.createContext({
    URL,
    Number,
    Array,
    String,
    Boolean,
    Object,
    Map,
    Set,
  });
  context.globalThis = context;
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(youtubeFormatUtilsSource, context);
  vm.runInContext(mediaPresentationSource, context);
  return context.MacIDMMediaPresentation;
}

test("candidateKey: resolves youtube state keys for youtube candidates and raw url for others", () => {
  const presentation = createEnvironment();

  assert.equal(
    presentation.candidateKey({ url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", siteAdapter: "youtube" }),
    "youtube:dQw4w9WgXcQ",
  );
  assert.equal(
    presentation.candidateKey({ url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", siteAdapter: "youtube" }),
    "youtube:dQw4w9WgXcQ",
  );
  assert.equal(
    presentation.candidateKey({ url: "https://example.com/video.mp4" }),
    "https://example.com/video.mp4",
  );
  assert.equal(presentation.candidateKey(null), "");
  assert.equal(presentation.candidateKey(undefined), "");
});

test("snapshotKey: prefers videoId prefix and falls back to pageUrl", () => {
  const presentation = createEnvironment();

  assert.equal(presentation.snapshotKey({ videoId: "dQw4w9WgXcQ", pageUrl: "https://example.com" }), "youtube:dQw4w9WgXcQ");
  assert.equal(presentation.snapshotKey({ pageUrl: "https://example.com/item" }), "https://example.com/item");
  assert.equal(presentation.snapshotKey(null), "");
});

test("videoIdOf: extracts video id from supported YouTube page formats", () => {
  const presentation = createEnvironment();

  assert.equal(presentation.videoIdOf("https://www.youtube.com/watch?v=abc12345"), "abc12345");
  assert.equal(presentation.videoIdOf("https://www.youtube.com/shorts/abc12345"), "abc12345");
  assert.equal(presentation.videoIdOf("https://example.com/video"), "");
});

test("youTubeStageText: maps in-flight stages to i18n keys and suppresses terminal stages", () => {
  const presentation = createEnvironment();
  const dummyT = (key) => `[${key}]`;

  assert.equal(
    presentation.youTubeStageText({ mayComplete: true, stage: "discovered" }, dummyT),
    "[youtube.stagePageInspecting]",
  );
  assert.equal(
    presentation.youTubeStageText({ mayComplete: true, stage: "pageInspecting" }, dummyT),
    "[youtube.stagePageInspecting]",
  );
  assert.equal(
    presentation.youTubeStageText({ mayComplete: true, stage: "pageWaitingForStableData" }, dummyT),
    "[youtube.stageWaiting]",
  );
  assert.equal(
    presentation.youTubeStageText({ mayComplete: true, stage: "pagePartial" }, dummyT),
    "[youtube.stageCollecting]",
  );
  assert.equal(
    presentation.youTubeStageText({ mayComplete: true, stage: "fallbackInspecting" }, dummyT),
    "[youtube.stageFallback]",
  );

  // Terminal or mayComplete=false should return null
  assert.equal(presentation.youTubeStageText({ mayComplete: false, stage: "complete" }, dummyT), null);
  assert.equal(presentation.youTubeStageText({ mayComplete: true, stage: "complete" }, dummyT), null);
  assert.equal(presentation.youTubeStageText({ mayComplete: false, stage: "failed" }, dummyT), null);
  assert.equal(presentation.youTubeStageText(null, dummyT), null);
});

test("formatBytes and formatDuration: delegates to media-utils invariants", () => {
  const presentation = createEnvironment();

  assert.equal(presentation.formatBytes(0), "0 B");
  assert.equal(presentation.formatBytes(1024), "1 KB");
  assert.equal(presentation.formatBytes(1048576), "1 MB");
  assert.equal(presentation.formatBytes(-50), null);
  assert.equal(presentation.formatBytes(null), null);

  assert.equal(presentation.formatDuration(0), null);
  assert.equal(presentation.formatDuration(65), "01:05");
  assert.equal(presentation.formatDuration(3665), "1:01:05");
  assert.equal(presentation.formatDuration(-1), null);
  assert.equal(presentation.formatDuration(null), null);
});

test("estimateCandidateSize: returns null when no meaningful variant matches (no fallback to variants[0])", () => {
  const presentation = createEnvironment();

  // Variant with no label, height, resolution or format info
  const emptyVariant = { estimatedSize: 10485760 };
  const candidateWithoutMeaningfulVariants = {
    url: "https://example.com/stream.m3u8",
    variants: [emptyVariant],
  };

  // Predicate returns false for emptyVariant
  const customPredicate = (v) => Boolean(v.label || v.height);

  assert.equal(
    presentation.estimateCandidateSize(candidateWithoutMeaningfulVariants, null, customPredicate),
    null,
    "Must return null when no variant matches predicate; must NOT fall back to variants[0]",
  );
});

test("estimateCandidateSize: respects custom predicates from Popup and Overlay", () => {
  const presentation = createEnvironment();

  const candidate = {
    url: "https://example.com/video.mp4",
    variants: [
      { label: "自动画质", estimatedSize: 5000000 },
      { label: "1080P 高清", height: 1080, estimatedSize: 15000000 },
      { label: "720P", height: 720, estimatedSize: 8000000 },
    ],
  };

  // Popup predicate filtering out the auto-quality label
  const popupPredicate = (v) => v.label !== "自动画质" && Boolean(v.height);
  assert.equal(
    presentation.estimateCandidateSize(candidate, null, popupPredicate),
    15000000,
    "Should pick the first meaningful non-auto variant",
  );

  // Overlay predicate
  const overlayPredicate = (v) => Boolean(v.height && v.height >= 720);
  assert.equal(
    presentation.estimateCandidateSize(candidate, null, overlayPredicate),
    15000000,
  );
});

test("estimateCandidateSize: prioritizes YouTube inspection snapshots", () => {
  const presentation = createEnvironment();

  const ytCandidate = {
    url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    siteAdapter: "youtube",
    variants: [{ label: "360p", height: 360, estimatedSize: 2000000 }],
  };

  const inspections = new Map();
  inspections.set("youtube:dQw4w9WgXcQ", {
    videoId: "dQw4w9WgXcQ",
    pageUrl: ytCandidate.url,
    variants: [
      { label: "1080p", height: 1080, estimatedSize: 12000000 },
      { label: "720p", height: 720, estimatedSize: 6000000 },
    ],
  });

  assert.equal(
    presentation.estimateCandidateSize(ytCandidate, inspections),
    12000000,
    "Should use snapshot variants when available",
  );
});

test("Counterfactual wiring test: calling key helpers without media-presentation fails fast", () => {
  const context = vm.createContext({
    URL,
    Number,
    Array,
    String,
    Boolean,
    Object,
    Map,
    Set,
  });
  context.globalThis = context;
  // Intentionally omit mediaPresentationSource
  vm.runInContext(mediaUtilsSource, context);
  vm.runInContext(youtubeFormatUtilsSource, context);

  // Define thin helper matching popup/overlay direct delegation
  vm.runInContext(`
    function testCandidateKey(candidate) {
      return globalThis.MacIDMMediaPresentation.candidateKey(candidate);
    }
  `, context);

  assert.throws(
    () => {
      context.testCandidateKey({ url: "https://example.com" });
    },
    /TypeError|Cannot read properties of undefined|undefined is not an object/,
    "Direct delegation must fail fast if media-presentation.js is not loaded",
  );
});
