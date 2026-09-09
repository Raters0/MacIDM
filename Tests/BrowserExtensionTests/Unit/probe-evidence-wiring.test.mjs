import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

import { ProbeEvidenceLedger } from "../../../BrowserExtension/chrome/src/background/probe-policy.js";

const source = fs.readFileSync(
  new URL(
    "../../../BrowserExtension/chrome/src/background/service-worker.js",
    import.meta.url,
  ),
  "utf8",
);

const match = source.match(
  /chrome\.webRequest\.onResponseStarted\.addListener\(\s*\(details\) => \{([\s\S]*?)\n  \},/,
);
assert.ok(match, "onResponseStarted listener not found in service-worker.js");

const VIDEO = "https://cdn.example.com/video.mp4";

function loadListener({ declinedOnTabs = [] } = {}) {
  const recorded = [];
  const peers = [];
  const rescheduled = [];
  const mediaUrls = new Set([VIDEO]);
  const candidates = [{ url: VIDEO, format: "video" }];
  // A real ledger: the evidence event consults the same per-document decline
  // bookkeeping the service worker runs against.
  const ledger = new ProbeEvidenceLedger();
  for (const tabId of declinedOnTabs) ledger.markDeclined(VIDEO, { tabId });
  const context = {
    isMediaResponse: (url) => mediaUrls.has(url),
    probeEvidence: {
      record: (entry) => {
        recorded.push(entry);
        return ledger.record(entry);
      },
      observePeer: (entry) => {
        peers.push(entry);
        return ledger.observePeer(entry);
      },
      wasDeclined: (url, options) => ledger.wasDeclined(url, options),
    },
    mediaCandidatesByTab: new Map([[4, { pageUrl: "https://player.example.com/watch", candidates }]]),
    scheduleSizeProbes: (tabId, list) => {
      rescheduled.push({ tabId, urls: list.map((candidate) => candidate.url) });
    },
    Number,
  };
  vm.createContext(context);
  const fn = vm.runInContext(`(details) => {${match[1]}}`, context);
  return { fn, recorded, peers, rescheduled, context, ledger };
}

const mediaResponse = {
  tabId: 4,
  frameId: 0,
  url: VIDEO,
  ip: "93.184.216.34",
  documentId: "doc-1",
  responseHeaders: [{ name: "Content-Type", value: "video/mp4" }],
};

test("only the response event that reports the peer address records evidence", () => {
  // `ip` is documented on onResponseStarted/onBeforeRedirect/onCompleted/
  // onErrorOccurred — not on onHeadersReceived. Recording evidence where `ip`
  // is undefined would make every cross-origin probe fail closed.
  const calls = source.match(/probeEvidence\.record\(/g) ?? [];
  assert.equal(calls.length, 1, "evidence must be recorded from exactly one event");
  const headersBlock = source.match(
    /chrome\.webRequest\.onHeadersReceived\.addListener\([\s\S]*?\n\);/,
  );
  assert.ok(headersBlock, "onHeadersReceived listener not found");
  assert.equal(headersBlock[0].includes("probeEvidence.record("), false);
});

test("the peer summary has exactly one producer and runs before the media gate", () => {
  const calls = source.match(/probeEvidence\.observePeer\(/g) ?? [];
  assert.equal(calls.length, 1, "the peer summary must come from one response event");
  const body = match[1];
  assert.ok(
    body.indexOf("observePeer(") < body.indexOf("isMediaResponse("),
    "a proxy is only detectable from the page document, so the summary may not " +
      "wait for the media filter",
  );
});

test("a media response records the observed address for its own tab", () => {
  const { fn, recorded } = loadListener();
  fn(mediaResponse);
  assert.equal(recorded.length, 1);
  // Spread first: the entry was constructed inside the vm realm, so a strict
  // deep-equal would fail on prototypes rather than on content.
  assert.deepEqual({ ...recorded[0] }, {
    tabId: 4,
    url: VIDEO,
    ip: "93.184.216.34",
    frameId: 0,
    documentId: "doc-1",
  });
});

test("non-media responses and tab-less requests record nothing", () => {
  const { fn, recorded, peers } = loadListener();
  fn({
    tabId: 4,
    url: "https://cdn.example.com/app.js",
    ip: "93.184.216.34",
    responseHeaders: [{ name: "Content-Type", value: "application/javascript" }],
  });
  fn({
    tabId: -1,
    url: VIDEO,
    ip: "93.184.216.34",
    responseHeaders: [{ name: "Content-Type", value: "video/mp4" }],
  });
  assert.deepEqual(recorded, []);
  // The non-media response still counts for the peer summary; the tab-less one
  // cannot be attributed to any tab at all.
  assert.deepEqual(peers.map((entry) => entry.url), ["https://cdn.example.com/app.js"]);
});

test("an IPv6 peer address is preserved verbatim for the policy to judge", () => {
  const { fn, recorded } = loadListener();
  fn({
    tabId: 4,
    frameId: 2,
    url: VIDEO,
    ip: "2606:2800:220:1:248:1893:25c8:1946",
    responseHeaders: [{ name: "Content-Type", value: "video/mp4" }],
  });
  assert.equal(recorded.length, 1);
  assert.equal(recorded[0].frameId, 2);
  assert.equal(recorded[0].ip, "2606:2800:220:1:248:1893:25c8:1946");
});

test("a candidate declined for lack of evidence is reconsidered when it lands", () => {
  // Response-started normally arrives after the content script already reported
  // the candidate, so without this the refusal would stand for the whole load.
  const { fn, rescheduled } = loadListener({ declinedOnTabs: [4] });
  fn(mediaResponse);
  assert.equal(rescheduled.length, 1);
  assert.deepEqual(rescheduled[0], { tabId: 4, urls: [VIDEO] });
});

test("an already accepted candidate is not re-probed by the evidence event", () => {
  const { fn, rescheduled } = loadListener();
  fn(mediaResponse);
  assert.deepEqual(rescheduled, []);
});

test("a decline recorded by another tab does not reconsider this tab", () => {
  const { fn, rescheduled } = loadListener({ declinedOnTabs: [9] });
  fn(mediaResponse);
  assert.deepEqual(rescheduled, [], "another tab's refusal reached this document");
});

test("only the declined URL of that tab is reconsidered", () => {
  const { fn, rescheduled, context } = loadListener({ declinedOnTabs: [4] });
  context.mediaCandidatesByTab.set(4, {
    pageUrl: "https://player.example.com/watch",
    candidates: [
      { url: VIDEO },
      { url: "https://other.example.com/clip.mp4" },
    ],
  });
  fn(mediaResponse);
  assert.deepEqual(rescheduled, [{ tabId: 4, urls: [VIDEO] }]);
});
