import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

import { isProbeableCandidate } from "../../../BrowserExtension/chrome/src/background/size-probe.js";
import {
  SizeProbeScheduler,
  PROBE_PRIORITY,
} from "../../../BrowserExtension/chrome/src/background/size-probe-scheduler.js";
import {
  ProbeEvidenceLedger,
  decideAutoProbe,
} from "../../../BrowserExtension/chrome/src/background/probe-policy.js";

// scheduleSizeProbes is the glue that turns admission policy into "no request
// leaves the extension". It is exercised the same way as isMediaResponse:
// extracted from the service worker source and run against stubbed state, so a
// future refactor that drops the gate fails here rather than in a browser.
const source = fs.readFileSync(
  new URL(
    "../../../BrowserExtension/chrome/src/background/service-worker.js",
    import.meta.url,
  ),
  "utf8",
);

const match = source.match(/function scheduleSizeProbes\([\s\S]*?\n\}/);
assert.ok(match, "scheduleSizeProbes function not found in service-worker.js");

const OBSERVED = "https://cdn.example.com/video.mp4";
const FORGED = "https://victim.example.com/private.mp4";

function harness({ evidence = null, generation = 0, probeResponse = null } = {}) {
  const ledger = new ProbeEvidenceLedger();
  if (evidence) {
    ledger.record(evidence);
  }
  const requests = [];
  const pushes = [];
  const candidatesByTab = new Map();
  const pushProbeResultToPage = (tabId, candidate) => {
    pushes.push({ tabId, candidate });
  };
  const probeResourceSize = (url, opts) => {
    requests.push(url);
    if (typeof context.probeResourceSize === "function" && context.probeResourceSize !== probeResourceSize) {
      return context.probeResourceSize(url, opts);
    }
    return Promise.resolve(probeResponse);
  };
  const scheduler = new SizeProbeScheduler({
    globalConcurrency: 8,
    perTabConcurrency: 4,
    initialBackoffMs: 0,
    maxBackoffMs: 0,
    getGeneration: (tabId) => ledger.generationOf(tabId),
    fetchProbe: (url, opts) => probeResourceSize(url, opts),
    pushResult: (tabId, payload) => {
      if (Number.isSafeInteger(payload?.size)) {
        ledger.clearFailures(payload.url, { tabId });
        const current = candidatesByTab.get(tabId);
        if (current) {
          const target = current.candidates.find((item) => item.url === payload.url);
          if (target && !Number.isSafeInteger(target.size)) {
            target.size = payload.size;
            if (payload.mime && !target.mime) target.mime = payload.mime;
          }
        }
      }
      pushProbeResultToPage(tabId, payload);
    },
  });

  const origHandleNav = ledger.handleTabNavigated.bind(ledger);
  ledger.handleTabNavigated = (tabId) => {
    scheduler.cancelTab(tabId);
    origHandleNav(tabId);
  };
  const origHandleRem = ledger.handleTabRemoved.bind(ledger);
  ledger.handleTabRemoved = (tabId) => {
    origHandleRem(tabId);
    scheduler.cancelTab(tabId);
  };

  const context = {
    isProbeableCandidate,
    decideAutoProbe,
    PROBE_PRIORITY,
    sizeProbeScheduler: scheduler,
    probeEvidence: ledger,
    mediaCandidatesByTab: candidatesByTab,
    pushProbeResultToPage,
    probeResourceSize,
  };
  context.generation = generation;
  vm.createContext(context);
  vm.runInContext(match[0], context);
  return { context, requests, pushes, candidatesByTab, ledger, scheduler };
}

test("a candidate with no observed request never reaches fetch", async () => {
  const { context, requests, pushes } = harness();
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://evil.example/player", candidates: [] });
  context.scheduleSizeProbes(1, [{ url: FORGED, format: "video" }]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, [], "the extension issued a request for a page-supplied URL");
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].candidate.sizeProbeFailed, true, "the UI was left showing probing");
});

test("an observed public candidate is probed and its size is applied", async () => {
  const { context, requests, pushes, candidatesByTab } = harness({
    evidence: { tabId: 1, url: OBSERVED, ip: "93.184.216.34" },
    probeResponse: { size: 4096, mime: "video/mp4" },
  });
  const cached = { url: OBSERVED, format: "video", size: null, mime: "" };
  candidatesByTab.set(1, {
    pageUrl: "https://player.example.com/watch",
    candidates: [cached],
  });
  context.scheduleSizeProbes(1, [cached]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, [OBSERVED]);
  assert.equal(cached.size, 4096);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].candidate.size, 4096);
  assert.equal(pushes[0].candidate.sizeProbeFailed, undefined);
});

test("a result landing after navigation is discarded", async () => {
  const { context, candidatesByTab, ledger, pushes } = harness({
    evidence: { tabId: 1, url: OBSERVED, ip: "93.184.216.34" },
  });
  const cached = { url: OBSERVED, format: "video", size: null, mime: "" };
  candidatesByTab.set(1, {
    pageUrl: "https://player.example.com/watch",
    candidates: [cached],
  });
  let resolveProbe;
  context.probeResourceSize = () =>
    new Promise((resolve) => {
      resolveProbe = resolve;
    });
  context.scheduleSizeProbes(1, [cached]);
  // The user navigates while the probe is still in flight.
  ledger.handleTabNavigated(1);
  resolveProbe({ size: 4096, mime: "video/mp4" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(cached.size, null, "a retired document's probe result was applied");
  assert.deepEqual(pushes, []);
});

test("manifests and site adapters are refused without a probe request", async () => {
  const { context, requests, pushes } = harness();
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://player.example.com/", candidates: [] });
  context.scheduleSizeProbes(1, [
    { url: "https://cdn.example.com/index.m3u8", format: "hls" },
    { url: "https://www.youtube.com/watch?v=abc", siteAdapter: "youtube" },
  ]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, []);
  // Not probeable by shape, so they were never candidates for a probe: no
  // "size unknown" report either, which would mislabel an unprobeable stream.
  assert.deepEqual(pushes, []);
});

test("evidence recorded for another tab does not authorize this tab", async () => {
  const { context, requests } = harness({
    evidence: { tabId: 2, url: OBSERVED, ip: "93.184.216.34" },
  });
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://player.example.com/", candidates: [] });
  context.scheduleSizeProbes(1, [{ url: OBSERVED, format: "video" }]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, []);
});

test("an observed address that resolves privately is never probed", async () => {
  const { context, requests } = harness({
    evidence: { tabId: 1, url: "http://nas.example/large.bin", ip: "192.168.1.20" },
  });
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://player.example.com/", candidates: [] });
  context.scheduleSizeProbes(1, [{ url: "http://nas.example/large.bin", format: "video" }]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, []);
});

test("a tab behind a local proxy still gets its observed candidate probed", async () => {
  // Measured on Chromium: with a system HTTP proxy every peer address is
  // 127.0.0.1, so refusing there would leave every proxy user without sizes.
  const { context, requests, candidatesByTab } = harness({
    evidence: { tabId: 1, url: OBSERVED, ip: "127.0.0.1" },
    probeResponse: { size: 8192, mime: "video/mp4" },
  });
  const cached = { url: OBSERVED, format: "video", size: null, mime: "" };
  candidatesByTab.set(1, {
    pageUrl: "https://player.example.com/watch",
    candidates: [cached],
  });
  context.scheduleSizeProbes(1, [cached]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, [OBSERVED]);
  assert.equal(cached.size, 8192);
});

test("a public peer in the same tab makes a loopback peer a real refusal", async () => {
  // The tab connects directly, so `ip` is the target's address again.
  const { context, requests, ledger, candidatesByTab } = harness({
    evidence: { tabId: 1, url: OBSERVED, ip: "127.0.0.1" },
  });
  ledger.observePeer({
    tabId: 1,
    url: "https://player.example.com/watch",
    ip: "93.184.216.34",
  });
  const cached = { url: OBSERVED, format: "video", size: null, mime: "" };
  candidatesByTab.set(1, {
    pageUrl: "https://player.example.com/watch",
    candidates: [cached],
  });
  context.scheduleSizeProbes(1, [cached]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, [], "a genuinely local target was probed");
  assert.equal(cached.size, null);
});

test("a refusal is retracted once the URL is genuinely observed", async () => {
  const { context, requests, pushes, ledger } = harness();
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://player.example.com/", candidates: [] });
  const candidate = { url: OBSERVED, format: "video" };
  context.scheduleSizeProbes(1, [candidate]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(pushes.length, 1, "first pass should report size unknown");

  // The page now really requests it, so the same URL becomes probeable.
  ledger.record({ tabId: 1, url: OBSERVED, ip: "93.184.216.34" });
  context.scheduleSizeProbes(1, [candidate]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, [OBSERVED]);
  assert.equal(pushes.length, 1, "a re-resolved candidate must not be re-reported");
});

test("candidates that already carry a size are left alone", async () => {
  const { context, requests, pushes } = harness();
  context.mediaCandidatesByTab.set(1, { pageUrl: "https://player.example.com/", candidates: [] });
  context.scheduleSizeProbes(1, [{ url: OBSERVED, format: "video", size: 2048 }]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(requests, []);
  assert.deepEqual(pushes, []);
});

test("a reload does not strand a previously probed candidate without a size", async () => {
  // After a page reload (generation increments): the old generation's cache is
  // not reused across navigations, and the new generation re-issues the
  // controlled probe and successfully obtains the size.
  const { context, requests, pushes, ledger, candidatesByTab } = harness({
    probeResponse: { size: 4096, mime: "video/mp4" },
  });
  const first = { url: OBSERVED, format: "video", size: null };
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/watch", candidates: [first] });
  ledger.record({ tabId: 1, url: OBSERVED, ip: "93.184.216.34" });
  context.scheduleSizeProbes(1, [first]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(first.size, 4096);

  // Reload: the tab cache is dropped, evidence invalidated, generation
  // incremented; the page re-requests the same URL and reports a new object
  // without a size.
  ledger.handleTabNavigated(1);
  ledger.record({ tabId: 1, url: OBSERVED, ip: "93.184.216.34" });
  const reloaded = { url: OBSERVED, format: "video", size: null };
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/watch", candidates: [reloaded] });
  context.scheduleSizeProbes(1, [reloaded]);
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(reloaded.size, 4096, "刷新后同一候选成功重新获取大小");
  assert.equal(requests.length, 2, "代际严格隔离：刷新后重新发起受控探测，禁止跨代复用缓存");
  const sizePush = pushes.filter((entry) => Number.isSafeInteger(entry.candidate.size));
  assert.equal(sizePush.length, 2, "两次文档都要把大小回传给页面");
});

test("one tab's exhausted retries do not silence another tab", async () => {
  // Failure counts were once tracked per URL: one tab exhausting its three
  // attempts permanently skipped the same URL in another tab — no more
  // probing, no "size unknown" report, and the UI stuck at "probing".
  const { context, requests, pushes, ledger, candidatesByTab } = harness({
    probeResponse: null,
  });
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/a", candidates: [] });
  candidatesByTab.set(2, { pageUrl: "https://other.example.com/b", candidates: [] });
  ledger.record({ tabId: 1, url: OBSERVED, ip: "93.184.216.34" });
  ledger.record({ tabId: 2, url: OBSERVED, ip: "93.184.216.34" });

  for (let attempt = 0; attempt < 4; attempt += 1) {
    context.scheduleSizeProbes(1, [{ url: OBSERVED, format: "video", size: null }]);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.equal(requests.length, 3, "三次之后应当停止重试");

  context.scheduleSizeProbes(2, [{ url: OBSERVED, format: "video", size: null }]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(requests.length, 4, "另一个标签页被同 URL 的失败预算消音");
});

test("a refusal stays with the document that received it", async () => {
  const { context, pushes, candidatesByTab } = harness();
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/a", candidates: [] });
  candidatesByTab.set(2, { pageUrl: "https://other.example.com/b", candidates: [] });
  const forged = { url: FORGED, format: "video", size: null };

  context.scheduleSizeProbes(1, [forged]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  context.scheduleSizeProbes(2, [forged]);
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(pushes.length, 2, "每个文档都要各自落定，不能停在「探测中」");
  assert.deepEqual([...new Set(pushes.map((entry) => entry.tabId))].sort(), [1, 2]);
});

test("a new document gets a fresh retry budget", async () => {
  // A deliberate trade-off: a CDN that refused one page's probe may answer
  // the next page.
  const { context, requests, ledger, candidatesByTab } = harness({ probeResponse: null });
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/a", candidates: [] });
  const candidate = () => ({ url: OBSERVED, format: "video", size: null });
  const observe = () => ledger.record({ tabId: 1, url: OBSERVED, ip: "93.184.216.34" });

  observe();
  for (let attempt = 0; attempt < 4; attempt += 1) {
    context.scheduleSizeProbes(1, [candidate()]);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.equal(requests.length, 3);

  ledger.handleTabNavigated(1);
  observe();
  candidatesByTab.set(1, { pageUrl: "https://player.example.com/b", candidates: [] });
  context.scheduleSizeProbes(1, [candidate()]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(requests.length, 4, "换代后仍未重新获得尝试机会");
});
