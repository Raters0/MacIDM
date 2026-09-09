import test from "node:test";
import assert from "node:assert/strict";
import {
  SizeProbeScheduler,
  PROBE_PRIORITY,
} from "../../../BrowserExtension/chrome/src/background/size-probe-scheduler.js";
import { isProbeContextValid } from "../../../BrowserExtension/chrome/src/background/probe-policy.js";

test("SizeProbeScheduler: 真实 LRU 缓存机制 (get 刷新顺序与超容淘汰最旧项)", () => {
  const pushes = [];
  const scheduler = new SizeProbeScheduler({
    maxCacheEntries: 3,
    fetchProbe: async (url) => ({ size: 1000, mime: "video/mp4" }),
    pushResult: (tabId, payload) => pushes.push({ tabId, payload }),
    getGeneration: () => 1,
  });

  const tabId = 1;
  const referer = "https://example.com";

  // 入队 3 个不同 URL
  scheduler.enqueue({ tabId, candidate: { url: "https://example.com/1" }, referer });
  scheduler.enqueue({ tabId, candidate: { url: "https://example.com/2" }, referer });
  scheduler.enqueue({ tabId, candidate: { url: "https://example.com/3" }, referer });

  // 等待微任务完成
  return new Promise((resolve) => setTimeout(resolve, 50)).then(() => {
    assert.equal(scheduler.getActiveCounts().cacheSize, 3);

    // 访问第 1 项，使其成为最新访问项（LRU 刷新）
    scheduler.enqueue({ tabId, candidate: { url: "https://example.com/1" }, referer });

    // 插入第 4 项，应该淘汰最久未访问的第 2 项 (https://example.com/2)
    scheduler.enqueue({ tabId, candidate: { url: "https://example.com/4" }, referer });

    return new Promise((resolve) => setTimeout(resolve, 50)).then(() => {
      assert.equal(scheduler.getActiveCounts().cacheSize, 3);
      // 验证第 2 项已被淘汰，第 1 项仍保留
      const counts = scheduler.getActiveCounts();
      assert.equal(counts.cacheSize, 3);
    });
  });
});

test("SizeProbeScheduler: 安全上下文隔离 (同一 Tab/Referer/URL 改变 generation 必须重新发起 probe，严禁跨代复用缓存)", async () => {
  let probeCallCount = 0;
  let currentGeneration = 1;
  const published = [];

  const scheduler = new SizeProbeScheduler({
    fetchProbe: async (url, opts) => {
      probeCallCount++;
      return { size: 5000, mime: "video/mp4" };
    },
    pushResult: (tabId, res) => published.push({ tabId, res, gen: currentGeneration }),
    getGeneration: (tabId) => currentGeneration,
  });

  const tabId = 10;
  const referer = "https://example.com/watch?v=123";
  const url = "https://cdn.example.com/stream.m4s";

  // 1. Generation 1 探测
  scheduler.enqueue({ tabId, candidate: { url }, referer });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(probeCallCount, 1, "第 1 代必须发起网络探测");
  assert.equal(published.length, 1);

  // 2. Generation 1 再次 enqueue 同一 URL -> 命中第 1 代缓存
  scheduler.enqueue({ tabId, candidate: { url }, referer });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(probeCallCount, 1, "同代内允许命中缓存");
  assert.equal(published.length, 2);

  // 3. 切换到 Generation 2 (同一 Tab/Referer/URL) -> 必须重新发起探测，严禁命中第 1 代缓存
  currentGeneration = 2;
  scheduler.enqueue({ tabId, candidate: { url }, referer });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(probeCallCount, 2, "代际变化后必须重新发起探测，禁止跨代复用缓存");
  assert.equal(published.length, 3);
  assert.equal(published[2].gen, 2);
});

test("SizeProbeScheduler: 真实 Aging 算法 (低优先级因等待时间增加被提权调度)", async () => {
  let activeSlots = 0;
  let slotRelease = null;
  const dispatchedOrder = [];

  const scheduler = new SizeProbeScheduler({
    globalConcurrency: 1, // 仅 1 个并发槽位
    perTabConcurrency: 1,
    agingIntervalMs: 50,  // 每 50ms 提权一次
    fetchProbe: async (url) => {
      dispatchedOrder.push(url);
      if (url === "hold_slot") {
        await new Promise((resolve) => {
          slotRelease = resolve;
        });
      }
      return { size: 100, mime: "video/mp4" };
    },
    getGeneration: () => 1,
  });

  // 1. 占满唯一的全局并发槽位
  scheduler.enqueue({
    tabId: 1,
    candidate: { url: "hold_slot" },
    priority: PROBE_PRIORITY.HIGH,
  });

  // 2. 入队 LOW 任务
  scheduler.enqueue({
    tabId: 2,
    candidate: { url: "low_task" },
    priority: PROBE_PRIORITY.LOW,
  });

  // 3. 推进时间，让 LOW 任务在队列中 aging 提权 (等待 120ms > 2 个 aging interval)
  await new Promise((r) => setTimeout(r, 120));

  // 4. 新入队一个 NORMAL 任务
  scheduler.enqueue({
    tabId: 3,
    candidate: { url: "normal_task" },
    priority: PROBE_PRIORITY.NORMAL,
  });

  // 5. 释放持有槽位的任务
  slotRelease();
  await new Promise((r) => setTimeout(r, 80));

  // 验证：因 LOW 任务经过 120ms aging 累计加权，其综合评分超越了刚入队的 NORMAL 任务
  assert.equal(dispatchedOrder[0], "hold_slot");
  assert.equal(dispatchedOrder[1], "low_task", "Aging 加权后的 LOW 任务必须先于新入队的 NORMAL 任务被调度");
  assert.equal(dispatchedOrder[2], "normal_task");
});

test("SizeProbeScheduler: Tab 间 Round-Robin 公平轮转调度", async () => {
  let slotResolvers = [];
  const dispatchedTabs = [];

  const scheduler = new SizeProbeScheduler({
    globalConcurrency: 1, // 串行调度以严格观察出队顺序
    perTabConcurrency: 1,
    fetchProbe: async (url) => {
      dispatchedTabs.push(url);
      await new Promise((resolve) => {
        slotResolvers.push(resolve);
      });
      return { size: 100, mime: "video/mp4" };
    },
    getGeneration: () => 1,
  });

  // Tab 1 连续入队 2 个任务
  scheduler.enqueue({ tabId: 1, candidate: { url: "t1_job1" }, priority: PROBE_PRIORITY.NORMAL });
  scheduler.enqueue({ tabId: 1, candidate: { url: "t1_job2" }, priority: PROBE_PRIORITY.NORMAL });

  // Tab 2 入队 1 个任务
  scheduler.enqueue({ tabId: 2, candidate: { url: "t2_job1" }, priority: PROBE_PRIORITY.NORMAL });

  // 释放第 1 个任务 (t1_job1 完成)
  await new Promise((r) => setTimeout(r, 20));
  slotResolvers.shift()();

  // 释放第 2 个任务
  await new Promise((r) => setTimeout(r, 20));
  slotResolvers.shift()();

  // 释放第 3 个任务
  await new Promise((r) => setTimeout(r, 20));
  slotResolvers.shift()();

  await new Promise((r) => setTimeout(r, 50));

  // 验证：t1_job1 完成后，调度器优先轮转到 Tab 2 (t2_job1)，而不是继续霸占 Tab 1 (t1_job2)
  assert.equal(dispatchedTabs[0], "t1_job1");
  assert.equal(dispatchedTabs[1], "t2_job1", "必须优先调度 Tab 2，实现 Round-Robin 公平性");
  assert.equal(dispatchedTabs[2], "t1_job2");
});

test("SizeProbeScheduler: 双重复核门控 (canDispatch 与 canPublish)", async () => {
  let networkFetches = 0;
  const published = [];

  const scheduler = new SizeProbeScheduler({
    fetchProbe: async (url) => {
      networkFetches++;
      return { size: 2048, mime: "video/mp4" };
    },
    pushResult: (tabId, res) => published.push({ tabId, res }),
    getGeneration: () => 1,
    canDispatch: (task) => task.candidate.url !== "https://forbidden-dispatch.com",
    canPublish: (sub, result) => sub.candidate.url !== "https://forbidden-publish.com",
  });

  // 1. 被 canDispatch 拒绝的任务：出队时直接废弃，不发起网络请求
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://forbidden-dispatch.com" } });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(networkFetches, 0, "canDispatch 拒绝时不应发起网络请求");

  // 2. 被 canPublish 拒绝的任务：发起网络探测但结果不写回
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://forbidden-publish.com" } });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(networkFetches, 1, "允许发起网络探测");
  assert.equal(published.length, 0, "canPublish 拒绝时不应写回结果");

  // 3. 正常任务：全流程通过
  scheduler.enqueue({ tabId: 1, candidate: { url: "https://allowed.com" } });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(networkFetches, 2);
  assert.equal(published.length, 1);
});

test("SizeProbeScheduler: 策略拒绝时不产生可复用缓存 (被拒绝任务后续必须重新发起网络请求)", async () => {
  let networkFetches = 0;
  let allowPublish = false;
  const published = [];

  const scheduler = new SizeProbeScheduler({
    fetchProbe: async () => {
      networkFetches++;
      return { size: 4096, mime: "video/mp4" };
    },
    pushResult: (tabId, res) => published.push(res),
    getGeneration: () => 1,
    canPublish: () => allowPublish,
  });

  const tabId = 1;
  const candidate = { url: "https://policy-denied.com/video.mp4" };

  // 1. 发起探测，但 canPublish 拒绝 -> 结果未发布，且绝不写入正向缓存
  scheduler.enqueue({ tabId, candidate });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(networkFetches, 1);
  assert.equal(published.length, 0);
  assert.equal(scheduler.getActiveCounts().cacheSize, 0, "被拒绝的结果绝对不得写入缓存");

  // 2. 策略放行后再次 enqueue -> 必须重新发起网络探测（因为没有缓存）
  allowPublish = true;
  scheduler.enqueue({ tabId, candidate });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(networkFetches, 2, "无缓存时必须重新发起网络探测");
  assert.equal(published.length, 1);
  assert.equal(scheduler.getActiveCounts().cacheSize, 1, "放行后才允许写入缓存");
});

test("SizeProbeScheduler: 导航清理触发旧在途 AbortSignal 并彻底清空队列", async () => {
  let signalAborted = false;
  let probeResolvers = [];

  const scheduler = new SizeProbeScheduler({
    perTabConcurrency: 1,
    fetchProbe: async (url, { signal }) => {
      signal.addEventListener("abort", () => {
        signalAborted = true;
      });
      return new Promise((resolve) => {
        probeResolvers.push(resolve);
      });
    },
    getGeneration: () => 1,
  });

  const tabId = 1;
  // 入队 2 个任务：1 个在途，1 个排队
  scheduler.enqueue({ tabId, candidate: { url: "https://site.com/v1" } });
  scheduler.enqueue({ tabId, candidate: { url: "https://site.com/v2" } });

  await new Promise((r) => setTimeout(r, 20));
  assert.equal(scheduler.getActiveCounts().inFlightCount, 1);
  assert.equal(scheduler.getActiveCounts().queueLength, 1);

  // 导航触发 cancelTab
  scheduler.cancelTab(tabId);

  assert.equal(signalAborted, true, "在途请求的 AbortSignal 必须被触发");
  assert.equal(scheduler.getActiveCounts().queueLength, 0, "排队队列必须被彻底清空");
});

test("SizeProbeScheduler: 有界指数退避与重试上限", async () => {
  let attempts = 0;
  const scheduler = new SizeProbeScheduler({
    maxRetryAttempts: 3,
    backoffBaseMs: 50, // 50ms, 100ms, 200ms
    fetchProbe: async () => {
      attempts++;
      return { size: null, mime: "" }; // 模拟失败
    },
    getGeneration: () => 1,
  });

  const tabId = 1;
  const candidate = { url: "https://fail.com/video.mp4" };

  // 第 1 次尝试 -> 失败，记录第 1 次退避 (50ms)
  scheduler.enqueue({ tabId, candidate });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 1);

  // 立即重试 -> 处于退避期，被拒绝
  const rejected1 = scheduler.enqueue({ tabId, candidate });
  assert.equal(rejected1, false);
  assert.equal(attempts, 1);

  // 等待 60ms 突破第 1 次退避 -> 允许第 2 次尝试
  await new Promise((r) => setTimeout(r, 60));
  const allowed2 = scheduler.enqueue({ tabId, candidate });
  assert.equal(allowed2, true);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 2);

  // 等待 120ms 突破第 2 次退避 (100ms) -> 允许第 3 次尝试
  await new Promise((r) => setTimeout(r, 120));
  const allowed3 = scheduler.enqueue({ tabId, candidate });
  assert.equal(allowed3, true);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 3);

  // 达到最大重试次数 (3 次) -> 后续重试永久拒绝
  await new Promise((r) => setTimeout(r, 300));
  const rejectedFinal = scheduler.enqueue({ tabId, candidate });
  assert.equal(rejectedFinal, false);
  assert.equal(attempts, 3);
});

test("SizeProbeScheduler: generation 不变但 pageUrl 改变时，旧 Referer 任务被门控拦截 (不 dispatch / 不 publish)", async () => {
  let networkFetches = 0;
  const published = [];
  let currentPageUrl = "https://example.com/pageA";
  let finishSlot;

  // 1. 测试 canDispatch 门控拦截排队任务
  const dispatchScheduler = new SizeProbeScheduler({
    globalConcurrency: 1, // 串行调度以使后续任务在队列中等待
    perTabConcurrency: 1,
    fetchProbe: async (url) => {
      networkFetches++;
      if (url === "hold_slot") {
        await new Promise((resolve) => {
          finishSlot = resolve;
        });
      }
      return { size: 2048, mime: "video/mp4" };
    },
    pushResult: (tabId, res) => published.push({ tabId, res }),
    getGeneration: () => 1,
    canDispatch: (task) => task.referer === currentPageUrl,
    canPublish: () => true,
  });

  // 占满并发槽位
  dispatchScheduler.enqueue({ tabId: 1, candidate: { url: "hold_slot" }, referer: "https://example.com/pageA" });
  // 入队待调度任务，Referer 为 pageA (排队等待)
  dispatchScheduler.enqueue({ tabId: 1, candidate: { url: "https://example.com/stream1.m4s" }, referer: "https://example.com/pageA" });

  // 在出队前页面切换至 pageB
  currentPageUrl = "https://example.com/pageB";

  // 释放槽位，触发 pump() 调度 stream1.m4s
  finishSlot();
  await new Promise((r) => setTimeout(r, 40));

  assert.equal(networkFetches, 1, "pageUrl 改变后，排队的旧 Referer 任务不得 dispatch (仅 hold_slot 发起 1 次)");
  assert.equal(published.length, 1);
  assert.equal(published[0].res.url, "hold_slot");

  // 2. 测试 canPublish 门控拦截网络在途中 pageUrl 发生变化的任务
  currentPageUrl = "https://example.com/pageB";
  let finishProbe;
  const publishScheduler = new SizeProbeScheduler({
    fetchProbe: async () => {
      networkFetches++;
      return new Promise((resolve) => {
        finishProbe = resolve;
      });
    },
    pushResult: (tabId, res) => published.push({ tabId, res }),
    getGeneration: () => 1,
    canDispatch: (task) => task.referer === currentPageUrl,
    canPublish: (sub) => sub.referer === currentPageUrl,
  });

  publishScheduler.enqueue({ tabId: 1, candidate: { url: "https://example.com/stream2.m4s" }, referer: "https://example.com/pageB" });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(networkFetches, 2, "通过 canDispatch 发起网络请求");

  // 网络在途中页面切换为 pageC
  currentPageUrl = "https://example.com/pageC";
  finishProbe({ size: 4096, mime: "video/mp4" });
  await new Promise((r) => setTimeout(r, 40));

  assert.equal(published.length, 1, "网络返回时由于 referer 与当前 pageUrl 不匹配，canPublish 必须拒绝写回");
  assert.equal(publishScheduler.getActiveCounts().cacheSize, 0, "被拒绝的结果不得写入缓存");
});

test("SizeProbeScheduler [生产接线]: 结合 isProbeContextValid 验证空 Referer、不同 Referer 和相同 Referer 的 Fail-Closed 门控", async () => {
  let networkFetches = 0;
  const published = [];
  let currentPageUrl = "https://example.com/watch?v=123";
  let currentGen = 1;

  // 使用与 service-worker.js 完全一致的生产接线方式
  const scheduler = new SizeProbeScheduler({
    fetchProbe: async (url) => {
      networkFetches++;
      return { size: 1024 * 1024, mime: "video/mp4" };
    },
    pushResult: (tabId, payload) => published.push({ tabId, payload }),
    getGeneration: () => currentGen,
    canDispatch: (task) =>
      isProbeContextValid({
        currentGen,
        taskGen: task.generation,
        pageUrl: currentPageUrl,
        referer: task.referer,
      }),
    canPublish: (sub, result) =>
      isProbeContextValid({
        currentGen,
        taskGen: sub.generation,
        pageUrl: currentPageUrl,
        referer: sub.referer,
      }),
  });

  const tabId = 1;

  // 1. 空 Referer 任务 (必须 Fail-Closed，绝不发起网络请求)
  scheduler.enqueue({
    tabId,
    candidate: { url: "https://cdn.example.com/empty_ref.mp4" },
    referer: "",
  });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(networkFetches, 0, "空 Referer 任务必须在 canDispatch 阶段被拦截，不得发起网络探测");

  // 2. 不同 Referer 任务 (必须 Fail-Closed，绝不发起网络请求)
  scheduler.enqueue({
    tabId,
    candidate: { url: "https://cdn.example.com/diff_ref.mp4" },
    referer: "https://example.com/other_page",
  });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(networkFetches, 0, "不同 Referer 任务必须在 canDispatch 阶段被拦截，不得发起网络探测");

  // 3. 相同且合法的 Referer 任务 (放行并成功发布)
  scheduler.enqueue({
    tabId,
    candidate: { url: "https://cdn.example.com/valid_ref.mp4" },
    referer: "https://example.com/watch?v=123",
  });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(networkFetches, 1, "相同合法 Referer 任务必须正常放行并完成探测");
  assert.equal(published.length, 1);
  assert.equal(published[0].payload.size, 1024 * 1024);
});
