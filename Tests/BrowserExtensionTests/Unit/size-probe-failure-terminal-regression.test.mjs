import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

import {
  SizeProbeScheduler,
  PROBE_PRIORITY,
} from "../../../BrowserExtension/chrome/src/background/size-probe-scheduler.js";
import {
  ProbeEvidenceLedger,
  decideAutoProbe,
} from "../../../BrowserExtension/chrome/src/background/probe-policy.js";
import { isProbeableCandidate } from "../../../BrowserExtension/chrome/src/background/size-probe.js";

test("Issue 4: 静态页面单次提交且持续失败，必须自动退避重试并最终到达终态 (sizeProbeFailed: true)", async () => {
  let attempts = 0;
  const published = [];
  const scheduler = new SizeProbeScheduler({
    backoffBaseMs: 10,
    maxBackoffMs: 20,
    maxRetryAttempts: 3,
    autoRetry: true,
    getGeneration: () => 1,
    fetchProbe: async () => {
      attempts++;
      return { size: null, mime: "" }; // keeps failing
    },
    pushResult: (tabId, result) => published.push({ tabId, result }),
  });

  scheduler.enqueue({
    tabId: 1,
    candidate: { url: "https://example.invalid/static_video.mp4" },
    referer: "https://example.invalid/",
  });

  // Wait for the automatic backoff retries to finish (10ms + 20ms + execution time)
  await new Promise((resolve) => setTimeout(resolve, 200));

  assert.equal(attempts, 3, "必须自动完成 3 次尝试");
  assert.equal(published.length, 1, "第 3 次失败后必须向订阅者发布终态");
  assert.equal(published[0].result.sizeProbeFailed, true, "终态载荷必须包含 sizeProbeFailed: true");
  assert.equal(published[0].result.url, "https://example.invalid/static_video.mp4");

  // Verify retries stop after the terminal state, with no busy loop
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(attempts, 3, "到达终态后不得继续无限制重试");

  scheduler.clearAll();
});

test("Issue 4: 退避重试过程中恢复成功，必须发布成功结果且停止后续重试", async () => {
  let attempts = 0;
  const published = [];
  const scheduler = new SizeProbeScheduler({
    backoffBaseMs: 10,
    maxBackoffMs: 20,
    maxRetryAttempts: 3,
    autoRetry: true,
    getGeneration: () => 1,
    fetchProbe: async () => {
      attempts++;
      if (attempts === 1) {
        return { size: null, mime: "" }; // first attempt fails
      }
      return { size: 1048576, mime: "video/mp4" }; // second attempt recovers
    },
    pushResult: (tabId, result) => published.push({ tabId, result }),
  });

  scheduler.enqueue({
    tabId: 1,
    candidate: { url: "https://example.invalid/recover.mp4" },
    referer: "https://example.invalid/",
  });

  await new Promise((resolve) => setTimeout(resolve, 150));

  assert.equal(attempts, 2, "第二次重试时恢复成功");
  assert.equal(published.length, 1, "必须发布成功结果");
  assert.equal(published[0].result.size, 1048576);
  assert.equal(published[0].result.sizeProbeFailed, undefined);

  // Verify no third attempt fires after success
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(attempts, 2, "成功后定时器必须被清理，不得继续重试");

  scheduler.clearAll();
});

test("Issue 4: Tab 关闭或 cancelTab 必须清理重试定时器，旧定时器不得触发", async () => {
  let attempts = 0;
  const published = [];
  const scheduler = new SizeProbeScheduler({
    backoffBaseMs: 50,
    maxBackoffMs: 100,
    maxRetryAttempts: 3,
    autoRetry: true,
    getGeneration: () => 1,
    fetchProbe: async () => {
      attempts++;
      return { size: null, mime: "" };
    },
    pushResult: (tabId, result) => published.push({ tabId, result }),
  });

  scheduler.enqueue({
    tabId: 5,
    candidate: { url: "https://example.invalid/cancel.mp4" },
    referer: "https://example.invalid/",
  });

  // Wait for the first failure to complete and enter the backoff wait
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(attempts, 1);
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 1);

  // Cancel the tab
  scheduler.cancelTab(5);
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 0, "cancelTab 必须清除重试定时器");

  // Wait past the backoff window
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(attempts, 1, "已被取消的 Tab 定时器不得再发起网络请求");
  assert.equal(published.length, 0, "不得发布任何结果");

  scheduler.clearAll();
});

test("Issue 4: Generation 变化（页面导航）使代际失效，旧代重试不得重新发起或发布", async () => {
  let attempts = 0;
  const published = [];
  let currentGen = 1;

  const scheduler = new SizeProbeScheduler({
    backoffBaseMs: 30,
    maxBackoffMs: 60,
    maxRetryAttempts: 3,
    autoRetry: true,
    getGeneration: (tabId) => currentGen,
    fetchProbe: async () => {
      attempts++;
      return { size: null, mime: "" };
    },
    pushResult: (tabId, result) => published.push({ tabId, result }),
  });

  scheduler.enqueue({
    tabId: 1,
    candidate: { url: "https://example.invalid/nav.mp4" },
    referer: "https://example.invalid/",
  });

  // First failure completes
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(attempts, 1);

  // The page performs an SPA navigation; the generation increments
  currentGen = 2;

  // Wait for the backoff timer to fire
  await new Promise((resolve) => setTimeout(resolve, 60));

  // Generation mismatch: no retry may execute
  assert.equal(attempts, 1, "代际变化后重试定时器必须短路放弃，不得发起请求");
  assert.equal(published.length, 0, "不得向旧页面发布结果");

  scheduler.clearAll();
});

test("Issue 4 [生产调用方]: service-worker scheduleSizeProbes 单次调用后通过内部调度器自动退避到终态", async () => {
  const source = fs.readFileSync(
    new URL("../../../BrowserExtension/chrome/src/background/service-worker.js", import.meta.url),
    "utf8"
  );
  const match = source.match(/function scheduleSizeProbes\([\s\S]*?\n\}/);
  assert.ok(match, "scheduleSizeProbes 函数未找到");

  const ledger = new ProbeEvidenceLedger();
  const candidatesByTab = new Map();
  const published = [];
  let fetchAttempts = 0;

  const tabId = 42;
  const pageUrl = "https://example.com/watch";
  const mediaUrl = "https://cdn.example.com/video.mp4";

  // Register valid evidence so the candidate is probeable
  ledger.record({
    tabId,
    url: mediaUrl,
    ip: "93.184.216.34",
    frameId: 0,
    documentId: "doc-1",
  });

  const scheduler = new SizeProbeScheduler({
    backoffBaseMs: 10,
    maxBackoffMs: 20,
    maxRetryAttempts: 3,
    autoRetry: true,
    getGeneration: (tId) => ledger.generationOf(tId),
    fetchProbe: async () => {
      fetchAttempts++;
      return { size: null, mime: "" }; // simulate a probe failure
    },
    pushResult: (tId, payload) => {
      published.push({ tabId: tId, payload });
    },
  });

  candidatesByTab.set(tabId, {
    pageUrl,
    candidates: [{ url: mediaUrl, mime: "" }],
  });

  const context = {
    isProbeableCandidate,
    decideAutoProbe,
    PROBE_PRIORITY,
    sizeProbeScheduler: scheduler,
    probeEvidence: ledger,
    mediaCandidatesByTab: candidatesByTab,
    pushProbeResultToPage: (tId, payload) => published.push({ tabId: tId, payload }),
  };

  vm.createContext(context);
  vm.runInContext(match[0], context);

  // The production caller triggers scheduleSizeProbes once; no further
  // candidate changes happen afterwards
  context.scheduleSizeProbes(tabId, candidatesByTab.get(tabId).candidates);

  // Wait for the backoff retries to reach the terminal state
  await new Promise((resolve) => setTimeout(resolve, 200));

  assert.equal(fetchAttempts, 3, "生产调用方接线下必须自动完成 3 次退避尝试");
  assert.equal(published.length, 1, "必须向页面发布 1 次失败终态");
  assert.equal(published[0].payload.sizeProbeFailed, true);
  assert.equal(published[0].payload.url, mediaUrl);

  scheduler.clearAll();
});
