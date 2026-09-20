import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
  new URL("../../../BrowserExtension/chrome/src/shared/media-metadata-probe.js", import.meta.url),
  "utf8",
);

// Fake <video> that reports metadata on the next tick once src is assigned.
function makeVideo() {
  const handlers = {};
  const video = {
    preload: "",
    muted: false,
    playsInline: false,
    duration: 13.5,
    videoWidth: 640,
    videoHeight: 360,
    addEventListener(type, fn) {
      (handlers[type] ||= []).push(fn);
    },
    removeAttribute() {},
    load() {},
    pause() {},
  };
  Object.defineProperty(video, "src", {
    get() { return video._src ?? ""; },
    set(value) {
      video._src = value;
      setTimeout(() => (handlers.loadedmetadata || []).forEach((fn) => fn()), 0);
    },
  });
  return video;
}

function makeContext() {
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    Promise,
    console,
    document: { createElement: (tag) => (tag === "video" ? makeVideo() : {}) },
  });
  context.globalThis = context;
  vm.runInContext(source, context);
  return context;
}

test("direct-media probe reads duration and resolution from loadedmetadata", async () => {
  const { MacIDMMediaMetadataProbe: probe } = makeContext();
  const candidate = { url: "https://cdn.example.com/video.mp4", format: "video", supported: true };
  assert.equal(probe.needsProbe(candidate), true);

  const results = await probe.probeCandidates([candidate]);
  assert.equal(results.length, 1);
  const meta = results[0].meta;
  assert.equal(meta.duration, 13.5);
  assert.equal(meta.width, 640);
  assert.equal(meta.height, 360);

  // Cached: a second needsProbe call reports no work remaining.
  assert.ok(probe.cached(candidate.url));
  assert.equal(probe.needsProbe(candidate), false);
});

test("probe skips unsupported, blob, and DASH candidates", () => {
  const { MacIDMMediaMetadataProbe: probe } = makeContext();
  assert.equal(probe.needsProbe({ url: "blob:https://x/y", format: "blob", supported: false }), false);
  assert.equal(probe.needsProbe({ url: "https://x/y.mpd", format: "dash", supported: true }), false);
  assert.equal(probe.needsProbe({ url: "https://x/y.mp4", format: "video", supported: true, duration: 5, width: 1, height: 1 }), false);
});

test("HLS probe degrades to null when hls.js is absent", async () => {
  const { MacIDMMediaMetadataProbe: probe } = makeContext();
  const candidate = { url: "https://cdn.example.com/master.m3u8", format: "hls", supported: true };
  const results = await probe.probeCandidates([candidate]);
  assert.equal(results.length, 1);
  assert.equal(results[0].meta, null);
});

test("metadata probes skip images, parser pages and already paired tracks", async () => {
  const { MacIDMMediaMetadataProbe: probe } = makeContext();
  for (const extra of [{format:"image"},{mime:"image/webp"},{siteAdapter:"bilibili"},{pairKind:"m4s-pair"}]) {
    assert.equal(probe.needsProbe({url:"https://example.com/media",format:"video",...extra}),false);
  }
  const events = [];
  await probe.probeCandidates([{url:"https://example.com/a.mp4",format:"video"}], {onResult: result=>events.push(result.url)});
  assert.deepEqual(events,["https://example.com/a.mp4"]);
});

function controlledProbes() {
  const videos = [];
  const context = vm.createContext({ URL, setTimeout, clearTimeout, AbortController,
    document: { createElement() {
      const handlers = {};
      const video = { duration: 10, videoWidth: 640, videoHeight: 360,
        addEventListener(type, fn) { handlers[type] = fn; },
        removeAttribute() { this.released = true; }, load() {},
        complete() { handlers.loadedmetadata(); },
      };
      videos.push(video); return video;
    } },
  });
  vm.runInContext(source, context);
  return { probe: context.MacIDMMediaMetadataProbe, videos };
}

test("overlapping batches share capacity and release stops active and queued probes", async () => {
  const { probe, videos } = controlledProbes();
  const candidates = prefix => Array.from({length:4}, (_,i) => ({url:`https://cdn.test/${prefix}${i}.mp4`}));
  const a = probe.probeCandidates(candidates('a'));
  const b = probe.probeCandidates(candidates('b'));
  await Promise.resolve();
  try {
    assert.ok(videos.length > 0);
    assert.ok(videos.length <= 4, `started ${videos.length} probes`);
  } finally { probe.releaseAll(); }
  await Promise.all([a,b]);
  assert.ok(videos.every(v => v.released));
});

test("interactive work uses reserved capacity and shared subscribers cancel independently", async () => {
  const { probe, videos } = controlledProbes();
  const bg = probe.probeCandidates(Array.from({length:5}, (_,i)=>({url:`https://cdn.test/bg${i}.mp4`})));
  await Promise.resolve();
  assert.equal(videos.length, 3);
  const first = new AbortController();
  const second = new AbortController();
  const candidate = {url:'https://cdn.test/focused.mp4'};
  const a = probe.probeCandidates([candidate], {priority:'interactive', signal:first.signal});
  const b = probe.probeCandidates([candidate], {priority:'interactive', signal:second.signal});
  await Promise.resolve();
  assert.equal(videos.length, 4);
  assert.equal(videos[3].src, candidate.url);
  first.abort();
  assert.ok(!videos[3].released);
  videos[3].complete();
  assert.equal((await a)[0].meta, null);
  assert.equal((await b)[0].meta.duration, 10);
  probe.releaseAll();
  await bg;
});

test("a result is delivered before the other requests in its batch finish", async () => {
  const {probe,videos} = controlledProbes();
  const received=[];
  const work=probe.probeCandidates([{url:'https://cdn.test/fast.mp4'},{url:'https://cdn.test/slow.mp4'}],
    {onResult:r=>received.push(r)});
  await Promise.resolve();
  videos[0].complete();
  for(let i=0;i<8;i++) await Promise.resolve();
  assert.equal(received.length,1);
  assert.equal(received[0].meta.duration,10);
  probe.releaseAll(); await work;
});
