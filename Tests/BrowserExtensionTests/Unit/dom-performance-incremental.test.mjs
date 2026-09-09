import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import "../../../BrowserExtension/chrome/src/content/discovery.js";
import "../../../BrowserExtension/chrome/src/shared/media-utils.js";

const discovery = globalThis.MacIDMDiscovery;
const mediaUtils = globalThis.MacIDMMediaUtils;
const contentScriptSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/content-script.js", import.meta.url),
  "utf8",
);

test("Incremental Discovery: extractDOMMutationCandidates 仅提取局部 addedNodes 与媒体属性变化", () => {
  // 1. Ordinary non-media node changes -> 0 candidates
  const nonMediaRecords = [
    {
      type: "childList",
      addedNodes: [
        {
          nodeType: 1,
          tagName: "DIV",
          getAttribute: () => null,
          querySelectorAll: () => [],
        },
      ],
    },
  ];
  const c1 = discovery.extractDOMMutationCandidates(nonMediaRecords, "https://example.com");
  assert.equal(c1.length, 0);

  // 2. A newly added subtree containing a video element
  const mediaRecords = [
    {
      type: "childList",
      addedNodes: [
        {
          nodeType: 1,
          tagName: "DIV",
          getAttribute: () => null,
          querySelectorAll: (sel) => {
            if (sel.includes("video")) {
              return [
                {
                  tagName: "VIDEO",
                  currentSrc: "https://example.com/stream.m3u8",
                  type: "application/x-mpegURL",
                  getAttribute: () => null,
                },
              ];
            }
            return [];
          },
        },
      ],
    },
  ];
  const c2 = discovery.extractDOMMutationCandidates(mediaRecords, "https://example.com");
  assert.equal(c2.length, 1);
  assert.equal(c2[0].url, "https://example.com/stream.m3u8");
  assert.equal(c2[0].confidence, "dom");
});

test("Incremental Discovery: extractPerformanceEntriesCandidates 流式增量消费新条目", () => {
  const entries = [
    { name: "https://example.com/style.css", initiatorType: "css" },
    { name: "https://example.com/segment_001.m4s", initiatorType: "video", transferSize: 500000 },
    { name: "https://api.example.com/json", initiatorType: "fetch" },
  ];

  const extracted = discovery.extractPerformanceEntriesCandidates(entries);
  assert.equal(extracted.length, 1);
  assert.equal(extracted[0].url, "https://example.com/segment_001.m4s");
  assert.equal(extracted[0].size, 500000);
  assert.equal(extracted[0].confidence, "extension");
});

test("Watermark Boundary & SPA A->B 隔离 (startTime 优先生产链路全覆盖)", () => {
  let observerCallback = null;
  const sentMessages = [];
  let performanceNowValue = 1000;

  const mockPerformance = {
    getEntriesByType(type) {
      return [];
    },
    now: () => performanceNowValue,
  };

  const context = {
    location: { href: "https://example.com/pageA" },
    document: {
      title: "Page A",
      querySelector: () => null,
      querySelectorAll: () => [],
      documentElement: {},
      addEventListener: () => {},
    },
    performance: mockPerformance,
    PerformanceObserver: class {
      constructor(callback) {
        observerCallback = callback;
      }
      observe() {}
      disconnect() {}
    },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    setTimeout: (fn) => setTimeout(fn, 10),
    clearTimeout: (h) => clearTimeout(h),
    addEventListener: () => {},
    postMessage: () => {},
    chrome: {
      runtime: {
        onMessage: { addListener: () => {} },
        sendMessage: (msg) => {
          sentMessages.push(msg);
          return Promise.resolve();
        },
      },
    },
    MacIDMDiscovery: discovery,
    MacIDMMediaUtils: mediaUtils,
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(contentScriptSource, context);

  assert.ok(observerCallback, "PerformanceObserver 回调必须已注册");

  // Simulate an SPA navigation to pageB; the watermark is now 1500
  performanceNowValue = 1500;
  context.location.href = "https://example.com/pageB";

  // Build 5 groups of key boundary Resource entries
  const entries = [
    // 1. Old request A: started at 1200ms but only ended at 1600ms (startTime <= 1500) -> must be rejected
    { name: "https://cdn.example.com/old_slow_start1200.m4s", startTime: 1200, responseEnd: 1600, initiatorType: "video" },
    // 2. New request B: started at 1500.1ms (startTime > 1500) -> must be accepted
    { name: "https://cdn.example.com/new_fast_start1500_1.m4s", startTime: 1500.1, responseEnd: 1600, initiatorType: "video" },
    // 3. Boundary time C: started at 1500.0ms (startTime <= 1500) -> must be rejected
    { name: "https://cdn.example.com/exact_watermark_start1500.m4s", startTime: 1500.0, responseEnd: 1600, initiatorType: "video" },
    // 4. Missing startTime D: startTime=0, responseEnd=1400 (<= 1500) -> degraded verdict rejects
    { name: "https://cdn.example.com/missing_start_end1400.m4s", startTime: 0, responseEnd: 1400, initiatorType: "video" },
    // 5. Missing startTime E: startTime=0, responseEnd=1600 (> 1500) -> degraded verdict accepts
    { name: "https://cdn.example.com/missing_start_end1600.m4s", startTime: 0, responseEnd: 1600, initiatorType: "video" },
  ];

  // Drive the real PerformanceObserver callback (it runs resetIfPageChanged
  // internally, which updates the watermark)
  observerCallback({
    getEntries: () => entries,
  });

  return new Promise((r) => setTimeout(r, 180)).then(() => {
    const lastUpdate = sentMessages.filter((m) => m.type === "media.candidatesUpdated").pop();
    assert.ok(lastUpdate, "必须发布媒体候选更新消息");
    const candidateUrls = lastUpdate.candidates.map((c) => c.url);

    assert.ok(!candidateUrls.includes("https://cdn.example.com/old_slow_start1200.m4s"), "旧慢请求 (start=1200, end=1600, wm=1500) 必须被拒绝");
    assert.ok(candidateUrls.includes("https://cdn.example.com/new_fast_start1500_1.m4s"), "新请求 (start=1500.1, end=1600, wm=1500) 必须被接受");
    assert.ok(!candidateUrls.includes("https://cdn.example.com/exact_watermark_start1500.m4s"), "临界请求 (start=1500.0, wm=1500) 必须被拒绝");
    assert.ok(!candidateUrls.includes("https://cdn.example.com/missing_start_end1400.m4s"), "startTime 缺失且 end=1400 <= 1500 必须被拒绝");
    assert.ok(candidateUrls.includes("https://cdn.example.com/missing_start_end1600.m4s"), "startTime 缺失且 end=1600 > 1500 必须被接受");
  });
});

test("content-script.js 生产脚本: PerformanceObserver 启动配置不包含 buffered: true", () => {
  let observedOptions = null;
  let observerCreated = 0;

  const mockPerformance = {
    getEntriesByType(type) {
      if (type === "resource") {
        return [
          { name: "https://example.com/initial_history.m4s", initiatorType: "video", responseEnd: 100 },
        ];
      }
      return [];
    },
    now: () => 200,
  };

  const sentMessages = [];
  const context = {
    location: { href: "https://example.com" },
    document: {
      title: "test",
      querySelector: () => null,
      querySelectorAll: () => [],
      documentElement: {},
      addEventListener: () => {},
    },
    performance: mockPerformance,
    PerformanceObserver: class {
      constructor(callback) {
        observerCreated++;
      }
      observe(options) {
        observedOptions = options;
      }
      disconnect() {}
    },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    setTimeout: (fn) => setTimeout(fn, 10),
    clearTimeout: (h) => clearTimeout(h),
    addEventListener: () => {},
    postMessage: () => {},
    chrome: {
      runtime: {
        onMessage: { addListener: () => {} },
        sendMessage: (msg) => {
          sentMessages.push(msg);
          return Promise.resolve();
        },
      },
    },
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(contentScriptSource, context);

  assert.ok(observedOptions, "必须启动 PerformanceObserver");
  assert.equal(observedOptions.buffered, undefined, "生产脚本 PerformanceObserver 严禁使用 buffered: true");
  assert.equal(observedOptions.type, "resource");
});
