import assert from "node:assert/strict";
import test from "node:test";

import {
  YouTubeInspectionCoordinator,
  YOUTUBE_INSPECTION_STAGES,
  safeCategoryFromAppResult,
} from "../../../BrowserExtension/chrome/src/background/youtube-inspection-coordinator.js";

// chrome-extension-spec §5.8 的自动化门禁：共享解析协调器必须保证
// 页内持续补全、稳定判定、单一 in-flight、SPA 隔离、部分结果保留。

const PAGE_URL = "https://www.youtube.com/watch?v=abc123";
const TAB_ID = 42;

function variant(height, itag) {
  return {
    url: `${PAGE_URL}#height=${height}&itag=${itag}`,
    itag,
    height,
    label: `${height}P`,
  };
}

// Fast harness: small budgets, ~5 ms simulated page round trips.
function makeHarness({ pageResults = [], appResult = null, deterministic = false } = {}) {
  let clock = 0;
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    ...(deterministic ? {
      now: () => clock,
      sleep: async (ms) => { clock += ms; await new Promise((resolve) => setTimeout(resolve, 0)); },
    } : {}),
    requestPageQualities: async () => {
      // 循环取结果：列表耗尽后继续轮换而不是钉死在最后一项，
      // 「永不稳定」场景才不会被意外误判为稳定。
      const index = pageResults.length > 0 ? calls.page % pageResults.length : 0;
      calls.page += 1;
      await new Promise((resolve) => setTimeout(resolve, 5));
      return pageResults.length > 0 ? pageResults[index] : null;
    },
    appInspector: async () => {
      calls.app += 1;
      await new Promise((resolve) => setTimeout(resolve, 5));
      if (appResult instanceof Error) throw appResult;
      return appResult;
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    limits: {
      pagePollMs: 10,
      pageBudgetMs: 120,
      stableGapMs: 20,
      terminalTtlMs: 60_000,
      staleInFlightMs: 30_000,
    },
  });
  return { coordinator, calls };
}

async function waitForStage(coordinator, stage, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const snapshot = coordinator.snapshotForURL(TAB_ID, PAGE_URL);
    if (snapshot?.stage === stage) return snapshot;
    if (Date.now() > deadline) {
      throw new Error(`stage never reached ${stage}, at ${snapshot?.stage}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

test("页内稳定信号达到后完成，且不启动 yt-dlp 回退", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137), variant(720, 136)] }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.source, "page");
  assert.equal(snapshot.variantCount, 2);
  assert.ok(snapshot.stableRounds >= 1, "稳定轮数应记录");
  assert.equal(calls.app, 0, "页内稳定完成时不得启动 yt-dlp");
});

test("初次 noPlayerData 后页内数据到达：就地补全，不启动 yt-dlp", async () => {
  const { coordinator, calls } = makeHarness({
    deterministic: true,
    pageResults: [
      { ok: false, reason: "noPlayerData" },
      { ok: false, reason: "noPlayerData" },
      { ok: true, variants: [variant(1080, 137)] },
    ],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.variantCount, 1);
  assert.equal(calls.app, 0, "页内数据随后出现时不得回退 yt-dlp");
});

test("部分变体持续增加时逐步发布并最终按稳定键去重", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [
      { ok: true, variants: [variant(1080, 137)] },
      { ok: true, variants: [variant(1080, 137), variant(720, 136)] },
      { ok: true, variants: [variant(1080, 137), variant(720, 136)] },
    ],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.variantCount, 2);
  assert.equal(calls.app, 0);
  // 阶段发布流中必须出现过 pagePartial（1 个画质的中间状态）。
  assert.ok(
    calls.published.some(
      ({ snapshot: s }) => s.stage === YOUTUBE_INSPECTION_STAGES.pagePartial && s.variantCount === 1,
    ),
    "部分结果应即时发布，用户可见持续补全",
  );
});

test("Popup 与悬浮窗同时打开只产生一个共享 in-flight 解析", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
  });
  const first = coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const second = coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  assert.ok(first && second, "两个入口都必须拿到快照");
  assert.equal(coordinator.records.size, 1, "同视频同代只允许一个记录");
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(calls.app, 0);
});

test("Popup 关闭再打开读取现有状态，不重复解析", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  const pageCallsAfterComplete = calls.page;

  const reopened = coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  assert.equal(reopened.stage, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(calls.page, pageCallsAfterComplete, "重新打开不得重新轮询页内数据");
});

test("页内预算耗尽后共享一次 yt-dlp 回退并按稳定键合并", async () => {
  // 每轮都引入新变体 → 合并后集合持续变化 → 永不稳定 → 预算耗尽进入回退。
  const growing = Array.from({ length: 40 }, (_, i) => ({
    ok: true,
    variants: [variant(240 + i, 900 + i)],
  }));
  const { coordinator, calls } = makeHarness({
    pageResults: growing,
    appResult: { ok: true, variants: [variant(2160, 313), variant(240, 900)] },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(calls.app, 1, "只允许一次共享回退");
  assert.equal(snapshot.source, "merged");
  // App 的新画质并入；与页内同键的 itag 900 合并后仍只出现一次。
  assert.ok(snapshot.variantCount >= 2);
  assert.ok(snapshot.variants.some((v) => v.itag === 313), "App 新画质应并入");
  assert.equal(
    snapshot.variants.filter((v) => v.itag === 900).length,
    1,
    "同键变体合并后不得重复",
  );
});

test("回退失败但已有页内结果：进入 partial 并保留画质，可重试", async () => {
  const growing = Array.from({ length: 40 }, (_, i) => ({
    ok: true,
    variants: [variant(240 + i, 900 + i)],
  }));
  const { coordinator } = makeHarness({
    pageResults: growing,
    appResult: { ok: false, timedOut: true, message: "timed out" },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.partial);
  assert.ok(snapshot.variantCount >= 1, "部分完成必须保留已发现画质");
  assert.equal(snapshot.retryable, true);
  assert.equal(snapshot.safeReason, "timeout");
});

test("回退失败且无结果：进入 failed，错误类别保持区分", async () => {
  const { coordinator } = makeHarness({
    pageResults: [{ ok: false, reason: "noPlayerData" }],
    appResult: { ok: false, errorCategory: "appUnreachable", message: "host not found" },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);
  assert.equal(snapshot.retryable, true);
  assert.equal(snapshot.safeReason, "appUnreachable");
});

test("页内明确识别的被拦截直播直接短路，不触发长回退", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: false, reason: "liveUnsupported", livePhase: "currentlyLive" }],
    appResult: { ok: true, variants: [variant(1080, 137)] },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.unsupported);
  assert.equal(snapshot.retryable, false);
  assert.equal(calls.app, 0, "直播拦截不得触发 30–60 秒回退");
});

test("SPA 导航丢弃旧 videoId 记录，新视频不串页", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: false, reason: "noPlayerData" }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(coordinator.records.size, 1);

  coordinator.handleTabNavigated(TAB_ID, "https://www.youtube.com/watch?v=newvideo1");
  assert.equal(coordinator.records.size, 0, "旧视频的解析记录必须被丢弃");
  assert.equal(coordinator.snapshotForURL(TAB_ID, PAGE_URL), null);

  // 旧循环被 generation 拦截后不得再发布旧视频的状态。
  const publishedAfter = calls.published.length;
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.ok(
    calls.published
      .slice(publishedAfter)
      .every(({ snapshot }) => snapshot.videoId !== "abc123"),
    "导航后不得再发布旧视频的状态",
  );
});

test("retry 强制重启失败的解析并最终完成", async () => {
  let appOutcome = { ok: false, errorCategory: "unknown", message: "boom" };
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    appInspector: async () => {
      calls.app += 1;
      return appOutcome;
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    limits: { pagePollMs: 5, pageBudgetMs: 30, stableGapMs: 10 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);

  appOutcome = { ok: true, variants: [variant(1080, 137)] };
  coordinator.retry({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.source, "app-ytdlp");
  assert.equal(calls.app, 2);
});

// ---- §2：同视频仅参数变化时的状态键一致性（chrome-extension-spec §5.8）----

test("同 videoId 仅参数变化：终态快照可被新 URL 消费，且不重启 yt-dlp", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137), variant(720, 136)] }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  const pageCallsAfter = calls.page;
  const appCallsAfter = calls.app;

  // service worker 经 tabs.onUpdated 通知导航：仅追加 &t=60s，videoId 不变。
  const paramURL = `${PAGE_URL}&t=60s`;
  coordinator.handleTabNavigated(TAB_ID, paramURL);

  const snapshot = coordinator.ensure({ tabId: TAB_ID, url: paramURL });
  assert.equal(snapshot?.stage, YOUTUBE_INSPECTION_STAGES.complete, "终态结果必须可被当前请求消费");
  assert.equal(snapshot.pageUrl, paramURL, "快照 pageUrl 必须反映当前请求 URL");
  assert.equal(snapshot.variantCount, 2);
  assert.equal(snapshot.mayComplete, false);
  assert.equal(calls.page, pageCallsAfter, "不得重新轮询页内数据");
  assert.equal(calls.app, appCallsAfter, "不得重新启动 yt-dlp");
});

test("同视频参数变化不得留下「保留但失活」的 generation 失配记录", async () => {
  const { coordinator, calls } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  // 页内循环运行中发生同视频参数变化。
  const paramURL = `${PAGE_URL}&t=60s`;
  coordinator.handleTabNavigated(TAB_ID, paramURL);
  assert.equal(coordinator.records.size, 1, "同视频记录必须被保留");
  assert.ok(coordinator.snapshotForURL(TAB_ID, paramURL), "新 URL 必须能读到记录");
  const record = coordinator.records.get(coordinator.key(TAB_ID, "abc123"));
  assert.equal(coordinator.alive(record), true, "保留的记录不得处于 alive == false 状态");

  // 同步 generation 后旧循环继续收敛为终态，且不回退 yt-dlp。
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.variantCount, 1);
  assert.equal(calls.app, 0);
});

test("同视频参数变化后换到不同 videoId：旧结果仍被丢弃", async () => {
  const { coordinator } = makeHarness({
    pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);

  coordinator.handleTabNavigated(TAB_ID, `${PAGE_URL}&t=60s`);
  assert.equal(coordinator.records.size, 1, "同视频参数变化保留记录");
  coordinator.handleTabNavigated(TAB_ID, "https://www.youtube.com/watch?v=newvideo1");
  assert.equal(coordinator.records.size, 0, "A→B 仍必须丢弃 A 的记录");
  assert.equal(coordinator.snapshotForURL(TAB_ID, PAGE_URL), null);
});

test("safeCategoryFromAppResult keeps timeout/category distinctions", () => {
  assert.equal(safeCategoryFromAppResult({ timedOut: true }), "timeout");
  assert.equal(
    safeCategoryFromAppResult({ ok: false, errorCategory: "appUnreachable" }),
    "appUnreachable",
  );
  assert.equal(safeCategoryFromAppResult(null), "unknown");
});

// ---- §3：轮询节奏与快照去重（可控时钟）----

function makeFakeClock() {
  let t = 1_000;
  const sleeps = [];
  return {
    now: () => t,
    sleep: async (ms) => {
      sleeps.push(ms);
      t += ms;
    },
    sleeps,
  };
}

test("页内轮询按 pagePollMs 节奏运行，不忙等", async () => {
  const clock = makeFakeClock();
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    appInspector: async () => {
      calls.app += 1;
      return { ok: false, errorCategory: "timeout" };
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    now: clock.now,
    sleep: clock.sleep,
    limits: { pagePollMs: 1_500, pageBudgetMs: 9_000, stableGapMs: 1_200 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);

  // 预算 9 s / 轮询 1.5 s → 观察轮数被节奏限制在个位数，绝不数千次忙轮询。
  assert.ok(calls.page >= 3, "应多轮观察");
  assert.ok(calls.page <= 8, `轮询次数超出节奏上限: ${calls.page}`);
  const slept = clock.sleeps.reduce((a, b) => a + b, 0);
  assert.ok(slept >= 7_500, `轮询间隔必须真实等待: ${slept}ms`);
  assert.ok(clock.sleeps.every((ms) => ms <= 1_500), "单次等待不得超过轮询间隔");
  assert.equal(calls.app, 1, "预算耗尽后仅一次共享回退");
});

test("相同语义快照不重复发布", async () => {
  const clock = makeFakeClock();
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    appInspector: async () => {
      calls.app += 1;
      return { ok: true, variants: [variant(1080, 137)] };
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    now: clock.now,
    sleep: clock.sleep,
    limits: { pagePollMs: 1_500, pageBudgetMs: 9_000, stableGapMs: 1_200 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);

  // 多轮 noPlayerData 只发布一次等待阶段；阶段/集合不变时不得重绘 UI。
  const waiting = calls.published.filter(
    ({ snapshot }) => snapshot.stage === YOUTUBE_INSPECTION_STAGES.pageWaitingForStableData,
  );
  assert.equal(waiting.length, 1, "相同等待状态只能发布一次");
  assert.ok(calls.page >= 3, "观察轮次不受发布去重影响");
});

test("稳定信号尊重 stableGapMs：连续两次相同集合且间隔达标", async () => {
  const clock = makeFakeClock();
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: true, variants: [variant(1080, 137)] };
    },
    appInspector: async () => {
      calls.app += 1;
      return null;
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    now: clock.now,
    sleep: clock.sleep,
    limits: { pagePollMs: 1_500, pageBudgetMs: 9_000, stableGapMs: 1_200 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.complete);
  assert.equal(snapshot.source, "page");
  assert.equal(calls.page, 2, "两轮相同集合即完成");
  assert.equal(calls.app, 0);
});

test("SPA 导航立即中止节奏等待，不再发布或回退", async () => {
  const clock = makeFakeClock();
  const calls = { page: 0, app: 0, published: [] };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    appInspector: async () => {
      calls.app += 1;
      return { ok: true, variants: [variant(1080, 137)] };
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    now: clock.now,
    sleep: clock.sleep,
    limits: { pagePollMs: 1_500, pageBudgetMs: 9_000, stableGapMs: 1_200 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  // 导航与首轮观察竞争：换代后旧循环必须在下一个检查点停止。
  coordinator.handleTabNavigated(TAB_ID, "https://www.youtube.com/watch?v=newvideo1");
  // 给异步循环足够的推进机会（伪时钟下若忙轮询会立刻积累大量调用）。
  for (let i = 0; i < 50; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  assert.ok(calls.page <= 1, "换代后不得继续轮询旧页面");
  assert.equal(calls.app, 0, "换代后不得为旧视频启动回退");
  assert.ok(
    calls.published.every(({ snapshot }) => snapshot.videoId === "abc123"),
    "不得为新视频发布旧状态",
  );
});

// ---- §9：终态语义与未预期异常收敛 ----

test("所有终态快照的 mayComplete 必须为 false", async () => {
  const cases = [
    {
      name: "complete",
      pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
      appResult: null,
    },
    {
      name: "unsupported",
      pageResults: [{ ok: false, reason: "liveUnsupported" }],
      appResult: null,
    },
    {
      name: "failed",
      pageResults: [{ ok: false, reason: "noPlayerData" }],
      appResult: { ok: false, errorCategory: "unknown", message: "boom" },
    },
  ];
  for (const scenario of cases) {
    const { coordinator, calls } = makeHarness({
      pageResults: scenario.pageResults,
      appResult: scenario.appResult,
    });
    coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
    await waitForStage(coordinator, scenario.name);
    const terminalSnapshots = calls.published.filter(
      ({ snapshot }) => snapshot.stage === scenario.name,
    );
    assert.ok(terminalSnapshots.length > 0, `${scenario.name} 终态必须被发布`);
    assert.ok(
      terminalSnapshots.every(({ snapshot }) => snapshot.mayComplete === false),
      `${scenario.name} 终态快照不得仍带 mayComplete: true`,
    );
  }
});

const TERMINAL_STAGE_SET = new Set([
  YOUTUBE_INSPECTION_STAGES.complete,
  YOUTUBE_INSPECTION_STAGES.partial,
  YOUTUBE_INSPECTION_STAGES.failed,
  YOUTUBE_INSPECTION_STAGES.unsupported,
]);

/// 把共享合并器替换为抛异常的实现，模拟内部逻辑的未预期异常；
/// `throwAfter` 控制前几次合并正常、之后抛异常。用例结束恢复原实现。
/// 注意：MacIDMYouTubeFormats 整体被 Object.freeze，必须替换整个对象。
async function withThrowingMerge(throwAfter, body) {
  const original = globalThis.MacIDMYouTubeFormats;
  const originalMerge = original.mergeVariantLists;
  let mergeCalls = 0;
  globalThis.MacIDMYouTubeFormats = {
    ...original,
    mergeVariantLists: (...args) => {
      mergeCalls += 1;
      if (mergeCalls > throwAfter) {
        throw new Error("SECRET_INTERNAL_BOOM url=https://signed.example/token");
      }
      return originalMerge(...args);
    },
  };
  try {
    return await body();
  } finally {
    globalThis.MacIDMYouTubeFormats = original;
  }
}

test("未预期异常无结果时收敛为 failed，不透传异常原文", async () => {
  await withThrowingMerge(0, async () => {
    const { coordinator, calls } = makeHarness({
      pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
    });
    coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
    const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);
    assert.equal(snapshot.safeReason, "internalError", "使用安全内部类别");
    assert.equal(snapshot.message, null, "不得透传异常原文");
    assert.equal(snapshot.mayComplete, false);
    const serialized = JSON.stringify(calls.published);
    assert.ok(!serialized.includes("SECRET_INTERNAL_BOOM"), "异常原文不得进入发布流");
  });
});

test("未预期异常但已有页内结果时收敛为 partial 并保留画质", async () => {
  await withThrowingMerge(1, async () => {
    const { coordinator } = makeHarness({
      pageResults: [
        { ok: true, variants: [variant(1080, 137)] },
        { ok: true, variants: [variant(1080, 137), variant(720, 136)] },
      ],
    });
    coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
    const snapshot = await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.partial);
    assert.equal(snapshot.variantCount, 1, "已发现画质必须保留");
    assert.equal(snapshot.safeReason, "internalError");
    assert.equal(snapshot.mayComplete, false);
    assert.equal(snapshot.retryable, true);
  });
});

test("SPA 换代后旧记录的未预期异常结果不得发布", async () => {
  await withThrowingMerge(0, async () => {
    const { coordinator, calls } = makeHarness({
      pageResults: [{ ok: true, variants: [variant(1080, 137)] }],
    });
    coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
    // 异常在首轮合并时抛出；换代必须拦住收敛终态的发布。
    coordinator.handleTabNavigated(TAB_ID, "https://www.youtube.com/watch?v=newvideo1");
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.ok(
      calls.published.every(({ snapshot }) => !TERMINAL_STAGE_SET.has(snapshot.stage)),
      "换代后不得发布旧视频的异常终态",
    );
  });
});

test("发布去重签名覆盖 message：同阶段不同文案必须重发", async () => {
  const clock = makeFakeClock();
  const calls = { page: 0, app: 0, published: [] };
  let appOutcome = { ok: false, errorCategory: "timeout", message: "first" };
  const coordinator = new YouTubeInspectionCoordinator({
    requestPageQualities: async () => {
      calls.page += 1;
      return { ok: false, reason: "noPlayerData" };
    },
    appInspector: async () => {
      calls.app += 1;
      return appOutcome;
    },
    publish: (tabId, snapshot) => calls.published.push({ tabId, snapshot }),
    now: clock.now,
    sleep: clock.sleep,
    limits: { pagePollMs: 500, pageBudgetMs: 600, stableGapMs: 400, terminalTtlMs: 0 },
  });
  coordinator.ensure({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);
  const failedWithFirst = calls.published.filter(
    ({ snapshot }) =>
      snapshot.stage === YOUTUBE_INSPECTION_STAGES.failed && snapshot.message === "first",
  );
  assert.ok(failedWithFirst.length > 0);

  // 重试时 App 文案变化（同阶段）：签名必须感知 message 并重发。
  appOutcome = { ok: false, errorCategory: "timeout", message: "second" };
  coordinator.retry({ tabId: TAB_ID, url: PAGE_URL });
  await waitForStage(coordinator, YOUTUBE_INSPECTION_STAGES.failed);
  assert.ok(
    calls.published.some(
      ({ snapshot }) =>
        snapshot.stage === YOUTUBE_INSPECTION_STAGES.failed && snapshot.message === "second",
    ),
    "message 变化必须触发重新发布，不得在签名外无声变化",
  );
});
