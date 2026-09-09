import test from "node:test";
import assert from "node:assert/strict";

import { SizeProbeScheduler } from "../../../BrowserExtension/chrome/src/background/size-probe-scheduler.js";

// 回归：开启 autoRetry 后，失败候选数超过 failureLedger 容量时，旧实现把重试次数只存在
// 可被 LRU 淘汰的账本里，淘汰后定时器仍触发再入队 → 计数从 1 重新开始 → 突破 maxRetryAttempts
// 且永不发布终态（复现：每项 11 次、published 0、retryTimerCount 5）。
// 修复后：重试预算随任务生命周期携带（独立于账本），#retryTimers 有容量上限，
// 淘汰/停止时收口发布终态 → 每项 <= 预算、全部到达终态、定时器有界并清零。
//
// 说明：调度器定时器源（setTimeout/Date.now）不可注入，改为可控时钟会扩大改动范围；
// 这里用确定性退避上下界 + 不变量断言（预算不被突破 / 终态可达 / 定时器有界）+ 充裕等待，
// 避免依赖精确时序，降低偶发性。

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitUntil(pred, timeoutMs = 1000, stepMs = 2) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    if (pred()) return true;
    await sleep(stepMs);
  }
  return pred();
}

function makeScheduler(overrides, onFetch) {
  const published = [];
  const scheduler = new SizeProbeScheduler({
    autoRetry: true,
    globalConcurrency: 8,
    perTabConcurrency: 4,
    maxRetryAttempts: 3,
    getGeneration: () => 1,
    pushResult: (tabId, payload) => published.push({ tabId, payload }),
    ...overrides,
    fetchProbe: onFetch,
  });
  return { scheduler, published };
}

test("Issue 2 [淘汰压力/确定性小容量]: 失败候选超过账本容量时，每项不突破生命周期预算且必达终态", async () => {
  const attempts = new Map();
  const { scheduler, published } = makeScheduler(
    { maxFailureEntries: 1, backoffBaseMs: 5, maxBackoffMs: 10 },
    async (url) => {
      attempts.set(url, (attempts.get(url) || 0) + 1);
      return { size: null, mime: "" }; // 持续失败
    },
  );

  const urls = [];
  for (let i = 0; i < 5; i++) {
    const url = `https://example.invalid/evict-${i}`;
    urls.push(url);
    scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
  }

  await new Promise((r) => setTimeout(r, 600));

  // 关键不变量：每项尝试次数不得超过配置的生命周期预算（修复前为 ~11）
  for (const url of urls) {
    const n = attempts.get(url) || 0;
    assert.ok(n >= 1 && n <= 3, `${url} 尝试次数 ${n} 必须在 [1,3] 内，不得突破预算`);
  }
  // 每个生命周期都必须收口到终态（修复前 published 为 0，永久卡在探测中）
  const terminal = published.filter((p) => p.payload.sizeProbeFailed === true);
  assert.equal(terminal.length, 5, "5 个候选都必须发布 sizeProbeFailed 终态");
  // 终态后定时器必须全部清理
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 0, "到达终态后不得残留重试定时器");

  scheduler.clearAll();
});

test("Issue 2 [定时器容量上限/小容量确定性]: #retryTimers 不得超过 maxRetryTimers，淘汰的生命周期收口发布终态", async () => {
  const attempts = new Map();
  const { scheduler, published } = makeScheduler(
    {
      maxRetryTimers: 2,
      maxFailureEntries: 1000,
      // 退避极大 → 定时器在断言窗口内不触发，从而稳定累积以检验容量上限
      backoffBaseMs: 100000,
      maxBackoffMs: 100000,
    },
    async (url) => {
      attempts.set(url, (attempts.get(url) || 0) + 1);
      return { size: null, mime: "" };
    },
  );

  // 5 个不同 Tab 各 1 个候选，全部失败一次并各自尝试安排重试
  for (let tab = 1; tab <= 5; tab++) {
    scheduler.enqueue({
      tabId: tab,
      candidate: { url: `https://example.invalid/cap-${tab}` },
      referer: "https://example.invalid/",
    });
  }

  await new Promise((r) => setTimeout(r, 120));

  const counts = scheduler.getActiveCounts();
  // 待重试定时器总量严格受限（修复前会累积到 5）
  assert.ok(counts.retryTimerCount <= 2, `retryTimerCount=${counts.retryTimerCount} 必须 <= maxRetryTimers(2)`);
  assert.equal(counts.retryTimerCount, 2, "容量为 2 时应恰好保留 2 个待重试定时器");
  // 每个候选只探测一次（定时器未触发）
  assert.equal([...attempts.values()].reduce((a, b) => a + b, 0), 5, "定时器未触发，每项应仅探测 1 次");
  // 被容量淘汰的 3 个生命周期必须收口发布终态（不能静默丢弃）
  const terminal = published.filter((p) => p.payload.sizeProbeFailed === true);
  assert.equal(terminal.length, 3, "5 - 2 = 3 个被淘汰的生命周期必须发布终态");

  scheduler.clearAll();
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 0, "clearAll 后定时器清零");
});

test("Issue 2 [默认参数小负载压力]: 全局/单 Tab 活跃并发与待重试总量有界，全部收口且预算不被突破（24 候选 < 默认 1000 容量，仅证默认参数下小负载有界性，不声称覆盖默认容量淘汰；容量淘汰由上面小容量确定性用例覆盖）", async () => {
  const attempts = new Map();
  const { scheduler, published } = makeScheduler(
    { backoffBaseMs: 2, maxBackoffMs: 8 }, // 默认 maxFailureEntries=1000, maxRetryTimers=1000
    async (url) => {
      attempts.set(url, (attempts.get(url) || 0) + 1);
      return { size: null, mime: "" };
    },
  );

  const N = 24;
  const urls = [];
  // 全部压在同一个 Tab 上，检验 perTabConcurrency 上界
  for (let i = 0; i < N; i++) {
    const url = `https://example.invalid/stress-${i}`;
    urls.push(url);
    scheduler.enqueue({ tabId: 1, candidate: { url }, referer: "https://example.invalid/" });
  }

  // 采样峰值并发与峰值待重试定时器总量
  let peakGlobal = 0;
  let peakRetryTimers = 0;
  const sampler = setInterval(() => {
    const c = scheduler.getActiveCounts();
    peakGlobal = Math.max(peakGlobal, c.global);
    peakRetryTimers = Math.max(peakRetryTimers, c.retryTimerCount);
  }, 1);

  await new Promise((r) => setTimeout(r, 2500));
  clearInterval(sampler);

  // 单 Tab 活跃并发受 perTabConcurrency(4) 约束（同一 Tab 上 global 不会超过 4）
  assert.ok(peakGlobal <= 4, `峰值活跃并发 ${peakGlobal} 必须 <= perTabConcurrency(4)`);
  // 待重试定时器总量受默认 maxRetryTimers(1000) 约束
  assert.ok(peakRetryTimers <= 1000, `峰值待重试定时器 ${peakRetryTimers} 必须 <= 1000`);
  // 每项不突破预算
  for (const url of urls) {
    const n = attempts.get(url) || 0;
    assert.ok(n <= 3, `${url} 尝试次数 ${n} 不得超过预算 3`);
  }
  // 全部收口到终态、定时器清零、无残留在途/队列
  const terminal = published.filter((p) => p.payload.sizeProbeFailed === true);
  assert.equal(terminal.length, N, `${N} 个候选都必须到达终态`);
  const finalCounts = scheduler.getActiveCounts();
  assert.equal(finalCounts.retryTimerCount, 0, "压力结束后待重试定时器必须清零");
  assert.equal(finalCounts.inFlightCount, 0, "无残留在途请求");
  assert.equal(finalCounts.queueLength, 0, "无残留队列");

  scheduler.clearAll();
});

test("Issue 2 [成功清理]: 重试期间恢复成功后清理重试定时器与失败账本，不再继续尝试", async () => {
  const attempts = new Map();
  const { scheduler, published } = makeScheduler(
    { maxFailureEntries: 1000, backoffBaseMs: 5, maxBackoffMs: 10 },
    async (url) => {
      const n = (attempts.get(url) || 0) + 1;
      attempts.set(url, n);
      if (n === 1) return { size: null, mime: "" }; // 第一次失败
      return { size: 2048, mime: "video/mp4" }; // 第二次成功
    },
  );

  scheduler.enqueue({
    tabId: 1,
    candidate: { url: "https://example.invalid/recover" },
    referer: "https://example.invalid/",
  });

  await new Promise((r) => setTimeout(r, 300));

  assert.equal(attempts.get("https://example.invalid/recover"), 2, "第二次重试成功后停止");
  const success = published.filter((p) => p.payload.size === 2048);
  assert.equal(success.length, 1, "必须发布一次成功结果");
  assert.equal(published.filter((p) => p.payload.sizeProbeFailed === true).length, 0, "成功后不得发布失败终态");
  const counts = scheduler.getActiveCounts();
  assert.equal(counts.retryTimerCount, 0, "成功后必须清理重试定时器");
  assert.equal(counts.failureSize, 0, "成功后必须清理失败账本");

  scheduler.clearAll();
});

test("Issue 2 [cancel/clear 无幽灵]: 待重试定时器在 cancelTab / clearAll 后不得再发起请求或发布结果", async () => {
  const attempts = new Map();
  const { scheduler, published } = makeScheduler(
    {
      maxFailureEntries: 1000,
      // 可负担、且会被最终等待真正越过的退避：若定时器未被取消，它们必在等待窗口内触发并再次探测，
      // 从而让“无幽灵请求”断言真正有证据力（原用 100000ms 退避配 150ms 等待，根本没越过退避时刻）。
      backoffBaseMs: 40,
      maxBackoffMs: 80,
    },
    async (url) => {
      attempts.set(url, (attempts.get(url) || 0) + 1);
      return { size: null, mime: "" };
    },
  );

  for (let tab = 1; tab <= 3; tab++) {
    scheduler.enqueue({
      tabId: tab,
      candidate: { url: `https://example.invalid/ghost-${tab}` },
      referer: "https://example.invalid/",
    });
  }

  // 等待三个上下文各失败一次并进入“待触发重试”，且赶在退避定时器触发前完成取消
  assert.ok(await waitUntil(() => scheduler.getActiveCounts().retryTimerCount >= 3, 300), "三个上下文都应进入待触发重试");
  const attemptsBefore = [...attempts.values()].reduce((a, b) => a + b, 0);
  assert.equal(attemptsBefore, 3, "取消前每项各探测一次");

  // 取消 tab 1 → 其待重试定时器与生命周期必须被清除
  const beforeCancel = scheduler.getActiveCounts().retryTimerCount;
  scheduler.cancelTab(1);
  assert.ok(scheduler.getActiveCounts().retryTimerCount < beforeCancel, "cancelTab 必须减少待重试定时器");

  // clearAll → 全部清除
  scheduler.clearAll();
  assert.equal(scheduler.getActiveCounts().retryTimerCount, 0, "clearAll 后待重试定时器清零");
  assert.equal(scheduler.getActiveCounts().retryLifecycleCount, 0, "clearAll 后重试生命周期清零");

  // 等待远超退避时刻（200ms > maxBackoffMs 80ms）：若定时器未被真正取消，此刻必已触发并再次探测
  await sleep(200);
  const attemptsAfter = [...attempts.values()].reduce((a, b) => a + b, 0);
  assert.equal(attemptsAfter, attemptsBefore, "cancel/clear 后不得再发起任何探测请求（退避窗口已被越过）");
  assert.equal(published.length, 0, "cancel/clear 后不得发布任何结果");
});
