import test from "node:test";
import assert from "node:assert/strict";

import {
  SizeProbeScheduler,
  PROBE_PRIORITY,
} from "../../../BrowserExtension/chrome/src/background/size-probe-scheduler.js";

// 回归：merge-fix-recheck-handoff.md「2026-09-06 复核结果」中的 R1/R2/R3。
// 三者都是开启 autoRetry 后重试生命周期的边界缺陷。每项均为 Before-Fail / After-Pass：
//   R1 修复前：取消最后一次在途尝试仍发布 sizeProbeFailed（publishedTerminal=1）；修复后=0。
//   R2 修复前：重试定时器转入队列后被 HIGH 淘汰，生命周期无声丢失（aTerminalCount=0）；修复后=1。
//   R3 修复前：失败账本淘汰 + 重复外部更新使每项重试达 ~10 次（突破预算 3）；修复后每项=3。
// 全部无网络：fetchProbe 由本地函数替换，示例 URL 不会被访问。用等待条件而非固定 sleep 断言状态迁移。

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitUntil(pred, timeoutMs = 1500, stepMs = 2) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (pred()) return true;
    await sleep(stepMs);
  }
  return pred();
}

// 第三次尝试保持 pending，直到 signal.abort 才返回未知，用于精确取消"在途的最后一次尝试"。
function makeThirdAttemptPendingProbe(counter) {
  return (url, opts) => {
    counter.n += 1;
    if (counter.n < 3) return Promise.resolve({ size: null, mime: "" });
    return new Promise((resolve) => {
      if (opts && opts.signal) {
        opts.signal.addEventListener("abort", () => resolve({ size: null, mime: "" }));
      }
    });
  };
}

test("R1: cancelTab 取消达到预算的最后一次在途尝试，不得发布失败终态、不得再重试", async () => {
  const published = [];
  const counter = { n: 0 };
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 3,
    backoffBaseMs: 5,
    maxBackoffMs: 10,
    getGeneration: () => 1,
    fetchProbe: makeThirdAttemptPendingProbe(counter),
    pushResult: (_, payload) => published.push(payload),
  });

  scheduler.enqueue({ tabId: 1, candidate: { url: "https://example.invalid/r1" }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => counter.n >= 3, 1000), "第三次尝试应真正进入 fetch");

  scheduler.cancelTab(1); // generation 不变，仅取消
  await sleep(80);

  assert.equal(published.filter((p) => p.sizeProbeFailed === true).length, 0, "取消不得被当作探测失败发布终态");
  assert.equal(published.length, 0, "取消后不得有任何发布");
  assert.equal(counter.n, 3, "取消后不得再发起新的探测");
  const counts = scheduler.getActiveCounts();
  assert.equal(counts.retryTimerCount, 0, "取消后无残留定时器");
  assert.equal(counts.retryLifecycleCount, 0, "取消后无残留重试生命周期");
  scheduler.clearAll();
});

test("R1: clearAll 取消达到预算的最后一次在途尝试，不得发布失败终态", async () => {
  const published = [];
  const counter = { n: 0 };
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 3,
    backoffBaseMs: 5,
    maxBackoffMs: 10,
    getGeneration: () => 1,
    fetchProbe: makeThirdAttemptPendingProbe(counter),
    pushResult: (_, payload) => published.push(payload),
  });

  scheduler.enqueue({ tabId: 1, candidate: { url: "https://example.invalid/r1b" }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => counter.n >= 3, 1000), "第三次尝试应真正进入 fetch");

  scheduler.clearAll();
  await sleep(80);

  assert.equal(published.length, 0, "clearAll 取消后不得发布任何结果");
  assert.equal(counter.n, 3, "clearAll 后不得再发起新的探测");
});

test("R2: 自动重试转入队列后被 HIGH 候选淘汰，必须有界终止并收口发布终态（不静默丢失）", async () => {
  const published = [];
  const requests = [];
  let releaseB = null;
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    globalConcurrency: 1,
    perTabConcurrency: 1,
    maxQueueEntries: 1,
    maxRetryAttempts: 3,
    backoffBaseMs: 20,
    maxBackoffMs: 40,
    getGeneration: () => 1,
    fetchProbe: (url) => {
      requests.push(url.slice(url.lastIndexOf("/") + 1));
      if (url.endsWith("/A")) return Promise.resolve({ size: null, mime: "" });
      if (url.endsWith("/B")) {
        return new Promise((resolve) => {
          releaseB = () => resolve({ size: 100, mime: "video/mp4" });
        });
      }
      if (url.endsWith("/C")) return Promise.resolve({ size: 300, mime: "video/mp4" });
      return Promise.resolve({ size: null, mime: "" });
    },
    pushResult: (_, payload) => published.push(payload),
  });

  // A(LOW) 先失败一次 → 进入重试生命周期（退避定时器）
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://example.invalid/A" }, referer: "https://example.invalid/", priority: PROBE_PRIORITY.LOW });
  assert.ok(await waitUntil(() => scheduler.getActiveCounts().retryLifecycleCount >= 1, 500), "A 失败后应进入重试生命周期");

  // B 占住唯一执行槽并挂起
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://example.invalid/B" }, referer: "https://example.invalid/", priority: PROBE_PRIORITY.NORMAL });
  assert.ok(await waitUntil(() => releaseB !== null, 500), "B 应占住唯一执行槽");

  // A 的定时器触发 → A 的重试转入等待队列（此时执行槽被 B 占用）
  assert.ok(await waitUntil(() => scheduler.getActiveCounts().queueLength >= 1, 500), "A 的重试应转入等待队列");

  // C(HIGH) 入队 → 队列已满，淘汰 LOW 的 A（A 正处于重试生命周期）
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://example.invalid/C" }, referer: "https://example.invalid/", priority: PROBE_PRIORITY.HIGH });
  await sleep(10);

  // 释放 B，让 C 完成
  if (releaseB) releaseB();
  assert.ok(await waitUntil(() => published.some((p) => p.url && p.url.endsWith("/C")), 800), "C 应成功发布");
  await sleep(50);

  const aTerminal = published.filter((p) => p.url && p.url.endsWith("/A"));
  assert.equal(aTerminal.length, 1, "A 被淘汰时必须恰好收到一次终态，不得静默丢失");
  assert.equal(aTerminal[0].sizeProbeFailed, true, "A 被淘汰应收口为失败终态");
  assert.equal(requests.filter((r) => r === "A").length, 1, "A 的重试在被淘汰前未再实际派发");

  const counts = scheduler.getActiveCounts();
  assert.equal(counts.queueLength, 0, "无残留队列");
  assert.equal(counts.inFlightCount, 0, "无残留在途");
  assert.equal(counts.retryTimerCount, 0, "无残留定时器");
  assert.equal(counts.retryLifecycleCount, 0, "被淘汰的生命周期已收口清理");
  scheduler.clearAll();
});

test("R3: 失败账本淘汰 + 等待期间重复外部更新，同一生命周期不突破预算并最终收口", async () => {
  const count = new Map();
  const published = [];
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 3,
    maxFailureEntries: 1, // 强制账本淘汰，触发算法边界（默认容量 1000 下同一逻辑，只是门槛更高）
    backoffBaseMs: 40,
    maxBackoffMs: 80,
    getGeneration: () => 1,
    fetchProbe: async (url) => {
      count.set(url, (count.get(url) || 0) + 1);
      return { size: null, mime: "" };
    },
    pushResult: (_, payload) => published.push(payload),
  });

  const urls = [0, 1, 2, 3, 4].map((i) => `https://example.invalid/${i}`);
  const enqueueAll = () => {
    for (const url of urls) {
      scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
    }
  };

  enqueueAll();
  const updates = setInterval(enqueueAll, 20); // 重试等待期间持续重复外部更新
  await sleep(160);
  clearInterval(updates);
  await sleep(300);

  for (const url of urls) {
    const n = count.get(url) || 0;
    assert.ok(n >= 1 && n <= 3, `${url} 尝试 ${n} 次：重复更新不得重置未结束生命周期而突破预算 3`);
  }
  assert.equal(
    published.filter((p) => p.sizeProbeFailed === true).length,
    urls.length,
    "每个上下文最终都必须收口发布失败终态",
  );
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 0, "收口后无残留定时器");
  scheduler.clearAll();
});

test("R4: 自动重试入队不得绕过 maxQueueEntries（执行槽占满 + 队列满 + 多个重试到期）", async () => {
  let releaseBlock = null;
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    globalConcurrency: 1,
    perTabConcurrency: 1,
    maxQueueEntries: 1,
    maxRetryAttempts: 3,
    backoffBaseMs: 30,
    maxBackoffMs: 60,
    getGeneration: () => 1,
    fetchProbe: (url, opts) => {
      if (url.endsWith("/block")) {
        return new Promise((resolve) => {
          releaseBlock = () => resolve({ size: null, mime: "" });
          if (opts && opts.signal) opts.signal.addEventListener("abort", () => resolve({ size: null, mime: "" }), { once: true });
        });
      }
      return Promise.resolve({ size: null, mime: "" });
    },
    pushResult: () => {},
  });
  const put = (name) => scheduler.enqueue({ tabId: 1, candidate: { url: `https://example.invalid/${name}` }, referer: "https://example.invalid/" });

  let peakQueue = 0;
  const sampler = setInterval(() => { peakQueue = Math.max(peakQueue, scheduler.getActiveCounts().queueLength); }, 1);
  try {
    put("a"); await sleep(0);   // a 失败一次 → 重试生命周期
    put("b"); await sleep(0);   // b 失败一次 → 重试生命周期
    put("block");               // 占住唯一执行槽（挂起）
    put("queued");              // 填满唯一队列槽
    assert.ok(await waitUntil(() => releaseBlock !== null, 500), "block 应占住执行槽");
    // 等待 a、b 的重试定时器到期并尝试入队（此时队列已满、执行槽被占）
    await sleep(200);
    assert.ok(peakQueue <= 1, `任意时刻 queueLength(${peakQueue}) 不得超过 maxQueueEntries(1)`);
    assert.ok(scheduler.getActiveCounts().queueLength <= 1, "最终 queueLength 不得超过上限");
  } finally {
    clearInterval(sampler);
    if (releaseBlock) releaseBlock();
    scheduler.clearAll();
  }
  assert.equal(scheduler.getActiveCounts().retryLifecycleCount, 0, "clearAll 后无悬空生命周期");
  assert.equal(scheduler.getActiveCounts().queueLength, 0, "clearAll 后无残留队列");
});

test("R5: maxRetryAttempts=1 直接终态时，exhausted 记录不得绕过 maxRetryTimers 上限", async () => {
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 1,
    maxRetryTimers: 2,
    maxFailureEntries: 2,
    getGeneration: () => 1,
    fetchProbe: async () => ({ size: null, mime: "" }),
    pushResult: () => {},
  });
  let peak = 0;
  const sampler = setInterval(() => { peak = Math.max(peak, scheduler.getActiveCounts().retryLifecycleCount); }, 1);
  try {
    for (let i = 0; i < 10; i++) {
      scheduler.enqueue({ tabId: 1, candidate: { url: `https://example.invalid/${i}` }, referer: "https://example.invalid/" });
      await sleep(0);
    }
    await sleep(20);
    assert.ok(peak <= 2, `retryLifecycleCount 峰值(${peak}) 不得超过 maxRetryTimers(2)`);
    assert.ok(scheduler.getActiveCounts().retryLifecycleCount <= 2, "最终 retryLifecycleCount 不得超过上限");
  } finally {
    clearInterval(sampler);
    scheduler.clearAll();
  }
});

test("R5: exhausted 负缓存标记过期后允许同一上下文重新探测（不依赖容量压力才释放）", async () => {
  const count = new Map();
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 1,
    failureTtlMs: 1000,
    getGeneration: () => 1,
    fetchProbe: async (url) => { count.set(url, (count.get(url) || 0) + 1); return { size: null, mime: "" }; },
    pushResult: () => {},
  });
  const url = "https://example.invalid/expire";
  scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => (count.get(url) || 0) >= 1, 300), "首次探测应发生");
  assert.equal(scheduler.getActiveCounts().retryLifecycleCount, 1, "终态后保留 exhausted 负缓存标记");

  // 有效期内重复提交被拒绝（不重新探测）
  scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
  await sleep(20);
  assert.equal(count.get(url), 1, "有效期内不得重新探测");

  // 超过 failureTtlMs 后标记过期，允许重新探测
  await sleep(1050);
  scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => (count.get(url) || 0) >= 2, 300), "过期后应允许同一上下文重新探测");
  scheduler.clearAll();
});

test("R5: cancelTab / clearAll 清理 exhausted 终态记录（不同 Tab 隔离）", async () => {
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    maxRetryAttempts: 1,
    getGeneration: () => 1,
    fetchProbe: async () => ({ size: null, mime: "" }),
    pushResult: () => {},
  });
  scheduler.enqueue({ tabId: 7, candidate: { url: "https://example.invalid/x" }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => scheduler.getActiveCounts().retryLifecycleCount >= 1, 300), "tab7 应留下 exhausted 记录");
  scheduler.cancelTab(7);
  assert.equal(scheduler.getActiveCounts().retryLifecycleCount, 0, "cancelTab 应清理该 Tab 的 exhausted 记录");

  scheduler.enqueue({ tabId: 8, candidate: { url: "https://example.invalid/y" }, referer: "https://example.invalid/" });
  assert.ok(await waitUntil(() => scheduler.getActiveCounts().retryLifecycleCount >= 1, 300), "tab8 应留下 exhausted 记录");
  scheduler.clearAll();
  assert.equal(scheduler.getActiveCounts().retryLifecycleCount, 0, "clearAll 应清理所有 exhausted 记录");
});
