import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

import { applyM4sPairing } from "../../../BrowserExtension/chrome/src/background/m4s-pairing.js";
import {
  alignMediaTabStateWithLiveURL,
  isHttpURL,
  takeBackgroundCandidates,
} from "../../../BrowserExtension/chrome/src/background/media-observation.js";

// Resolve every production path from this file's own location, NOT from
// process.cwd(): `npm test` runs with cwd = BrowserExtension/chrome while an
// ad-hoc `node --test` may run from the repo root, and a cwd-relative resolve
// silently pointed at chrome/BrowserExtension/chrome/... under npm test.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const chromeRoot = path.resolve(repoRoot, "BrowserExtension/chrome");

const serviceWorkerPath = path.resolve(
  chromeRoot,
  "src/background/service-worker.js",
);
const serviceWorkerSource = fs.readFileSync(serviceWorkerPath, "utf8");

// ============================================================================
// 1. Static import and module wiring integrity verification
// ============================================================================

test("Service Worker 接线: 生产 service-worker.js 必须正确导入 applyM4sPairing 及全部依赖", () => {
  // Parse all import statements
  const importStatements = [];
  const importRegex = /import\s+(?:\{([^}]+)\}|(\w+)|\*\s+as\s+(\w+))\s+from\s+["']([^"']+)["'];?/g;
  let match;
  while ((match = importRegex.exec(serviceWorkerSource)) !== null) {
    const symbols = [];
    if (match[1]) {
      match[1].split(",").forEach((s) => {
        const parts = s.trim().split(/\s+as\s+/);
        const name = parts[parts.length - 1].trim();
        if (name) symbols.push(name);
      });
    } else if (match[2]) {
      symbols.push(match[2].trim());
    } else if (match[3]) {
      symbols.push(match[3].trim());
    }
    importStatements.push({ symbols, sourcePath: match[4] });
  }

  // 1. Verify applyM4sPairing must be imported from ./m4s-pairing.js
  const m4sImport = importStatements.find((stmt) => stmt.sourcePath === "./m4s-pairing.js");
  assert.ok(m4sImport, "service-worker.js 必须包含 import from \x27./m4s-pairing.js\x27");
  assert.ok(
    m4sImport.symbols.includes("applyM4sPairing"),
    "service-worker.js 必须从 ./m4s-pairing.js 导入 applyM4sPairing",
  );

  // 2. Verify every relative-path imported module file really exists and
  // exports the referenced symbols
  const swDir = path.dirname(serviceWorkerPath);
  for (const stmt of importStatements) {
    if (stmt.sourcePath.startsWith(".")) {
      const resolvedPath = path.resolve(swDir, stmt.sourcePath);
      assert.ok(
        fs.existsSync(resolvedPath),
        `Import 模块文件不存在: ${stmt.sourcePath} (${resolvedPath})`,
      );

      // Verify the target file really exports the imported symbols
      const targetSource = fs.readFileSync(resolvedPath, "utf8");
      for (const symbol of stmt.symbols) {
        const exportRegex = new RegExp(`\\bexport\\s+(?:(?:const|let|var|(?:async\\s+)?function|class)\\s+${symbol}\\b|\\{[^}]*\\b${symbol}\\b[^}]*\\})`);
        assert.ok(
          exportRegex.test(targetSource),
          `模块 ${stmt.sourcePath} 未导出被引用的符号 \x27${symbol}\x27`,
        );
      }
    }
  }

  // 3. Verify the core components added in Phase C are all imported
  const importedAllSymbols = new Set(importStatements.flatMap((s) => s.symbols));
  assert.ok(importedAllSymbols.has("SizeProbeScheduler"), "必须导入 SizeProbeScheduler");
  assert.ok(importedAllSymbols.has("SniffBudgetCoordinator"), "必须导入 SniffBudgetCoordinator");
  assert.ok(importedAllSymbols.has("isProbeContextValid"), "必须导入 isProbeContextValid");
  assert.ok(importedAllSymbols.has("fetchProbeDirect"), "必须导入 fetchProbeDirect");
});

// ============================================================================
// 2. Production popup.mediaCandidates message-path smoke test
// ============================================================================

test("Service Worker 生产链路烟测: popup.mediaCandidates 正确分发并调用 applyM4sPairing", async () => {
  // Extract the getPopupMediaCandidates function body from service-worker.js
  const getPopupMatch = serviceWorkerSource.match(/async function getPopupMediaCandidates\([\s\S]*?\n\}/);
  assert.ok(getPopupMatch, "未能在 service-worker.js 中找到 getPopupMediaCandidates 函数");

  const mediaCandidatesByTab = new Map();
  const testTabId = 42;
  // Neutral page: Bilibili pages deterministically synthesize the adapter
  // and return it first; what is verified here is the pairing path itself.
  const pageURL = "https://example.com/watch";

  // Build candidate data containing Bilibili split video/audio streams (m4s)
  const videoUrl = "https://upgz.bilivideo.com/1550776785-1-100022.m4s";
  const audioUrl = "https://upgz.bilivideo.com/1550776785-1-30280.m4s";
  mediaCandidatesByTab.set(testTabId, {
    pageUrl: pageURL,
    title: "测试视频标题",
    titleSource: "card",
    candidates: [
      { url: videoUrl, mime: "video/mp4", format: "video", supported: true, displayName: "视频轨", displayURL: videoUrl },
      { url: audioUrl, mime: "audio/mp4", format: "audio", supported: true, displayName: "音频轨", displayURL: audioUrl },
    ],
    filteredSummary: { diagnosticAudio: 0, streamSegments: 0 },
  });

  const chromeMock = {
    tabs: {
      get: async (tabId) => ({ id: tabId, url: pageURL, title: "测试视频标题" }),
      sendMessage: async () => ({ ok: false }),
    },
    runtime: {
      onMessage: {
        addListener: () => {},
      },
    },
  };

  const sandbox = {
    chrome: chromeMock,
    mediaCandidatesByTab,
    backgroundMediaCandidatesByOrigin: new Map(),
    alignMediaTabStateWithLiveURL,
    isHttpURL,
    takeBackgroundCandidates,
    applyM4sPairing, // the production-imported applyM4sPairing
    ensureContentScript: async () => {},
    rememberMediaCandidates: () => {},
    mainFrameOptions: {},
    recordSafeError: async () => {},
    safeDiagnostic: (err) => ({ message: err?.message || String(err) }),
    t: (key) => key,
    console,
    Number,
    Array,
    Map,
    Set,
  };

  vm.createContext(sandbox);

  // Run the extracted getPopupMediaCandidates
  vm.runInContext(getPopupMatch[0], sandbox);

  // Execute getPopupMediaCandidates inside the sandbox
  const result = await sandbox.getPopupMediaCandidates(testTabId);

  assert.equal(result.ok, true, "popup.mediaCandidates 必须返回 ok: true");
  assert.equal(result.candidates.length, 1, "m4s 视频轨与音频轨必须被成功配对合并为 1 个候选");
  assert.equal(result.candidates[0].pairKind, "m4s-pair");
  assert.equal(result.candidates[0].pairVideoUrl, videoUrl);
  assert.equal(result.candidates[0].pairAudioUrl, audioUrl);
  // titleSource "card" 的画廊语义：卡片级标题不得命名页面级 m4s 对行
  // （否则单卡标题会盖到每一行），配对行回落到 视频（cid） 命名。
  assert.equal(result.candidates[0].displayName, "视频（1550776785）");
  // 画廊卡片级标题来源必须随响应返回并回写缓存：丢失后 Popup 会把
  // 单卡标题当页面级标题盖到每一行（全部同名回归）。
  assert.equal(result.titleSource, "card", "popup 响应必须透传 titleSource");
  assert.equal(mediaCandidatesByTab.get(testTabId).titleSource, "card", "对齐后的回写缓存必须保留 titleSource");
});

// ============================================================================
// 3. Counterfactual failure verification and root-cause explanation
// ============================================================================

test("Service Worker 根因反事实验证: 缺失 applyM4sPairing 时必须捕获 ReferenceError", async () => {
  const getPopupMatch = serviceWorkerSource.match(/async function getPopupMediaCandidates\([\s\S]*?\n\}/);
  assert.ok(getPopupMatch);

  const mediaCandidatesByTab = new Map([[1, {
    pageUrl: "https://example.com",
    title: "Example",
    candidates: [{ url: "https://example.com/v.mp4" }],
    filteredSummary: { diagnosticAudio: 0, streamSegments: 0 },
  }]]);

  // Build a sandbox without applyM4sPairing (simulating a wrongly deleted import)
  const brokenSandbox = {
    chrome: {
      tabs: {
        get: async () => ({ id: 1, url: "https://example.com", title: "Example" }),
      },
    },
    mediaCandidatesByTab,
    backgroundMediaCandidatesByOrigin: new Map(),
    alignMediaTabStateWithLiveURL,
    isHttpURL,
    takeBackgroundCandidates,
    // applyM4sPairing: deliberately missing
    ensureContentScript: async () => {},
    rememberMediaCandidates: () => {},
    mainFrameOptions: {},
    recordSafeError: async () => {},
    safeDiagnostic: (err) => ({ message: err?.message || String(err) }),
    t: (key) => key,
    console,
    Number,
    Array,
    Map,
    Set,
  };

  vm.createContext(brokenSandbox);
  vm.runInContext(getPopupMatch[0], brokenSandbox);

  // Execution must throw ReferenceError: applyM4sPairing is not defined
  await assert.rejects(
    async () => {
      await brokenSandbox.getPopupMediaCandidates(1);
    },
    (err) => {
      assert.equal(err.name, "ReferenceError");
      assert.ok(err.message.includes("applyM4sPairing is not defined"));
      return true;
    },
    "缺失 applyM4sPairing 时必须产生 ReferenceError",
  );
});

test("cold JIT injection loads the presentation dependency used by overlay", async () => {
  const match = serviceWorkerSource.match(/async function ensureContentScript\(tabId\) \{[\s\S]*?\n\}/);
  assert.ok(match);
  let injected;
  const injections = [];
  const worker = vm.createContext({ chrome: { scripting: { executeScript: async (options) => { injections.push(options); injected = options.files; } } } });
  vm.runInContext(match[0], worker);
  await worker.ensureContentScript(42);
  assert.equal(injections[0].world, "MAIN");
  assert.deepEqual(Array.from(injections[0].files), ["src/content/media-source-observer.js"]);
  assert.ok(injected.indexOf("src/content/media-element-scope.js") < injected.indexOf("src/content/overlay.js"));
  const page = vm.createContext({ URL, console });
  for (const file of injected) {
    if (file === "src/content/overlay.js") break;
    // The DOM observers are covered by their own browser harness. Load the
    // actual shared dependencies from the production JIT list into a cold VM.
    if (["src/shared/media-utils.js", "src/shared/youtube-format-utils.js", "src/shared/media-presentation.js", "src/content/media-element-scope.js"].includes(file)) {
      vm.runInContext(fs.readFileSync(path.resolve(chromeRoot, file), "utf8"), page);
    }
  }
  assert.equal(typeof page.MacIDMMediaElementScope.filterCandidates, "function");
  const overlay = fs.readFileSync(path.resolve(chromeRoot, "src/content/overlay.js"), "utf8");
  const candidateKey = overlay.match(/function candidateKey\(candidate\) \{[\s\S]*?\n  \}/);
  assert.ok(candidateKey);
  vm.runInContext(candidateKey[0], page);
  assert.equal(page.candidateKey({ url: "https://example.test/movie.mp4" }), "https://example.test/movie.mp4");
});

// ============================================================================
// 4. Quit-intent wake path: popup.openApp must use the user-initiated
//    app.activate gesture, never the background ping.
// ============================================================================

test("Service Worker 接线: popup.openApp 必须走 app.activate（用户主动唤醒）而非后台 ping", () => {
  const openAppMatch = serviceWorkerSource.match(
    /if \(message\?\.type === "popup\.openApp"\) \{[\s\S]*?return true;\s*\}/,
  );
  assert.ok(openAppMatch, "未能定位 popup.openApp 分支");
  const branch = openAppMatch[0];
  assert.ok(
    branch.includes("nativeClient") && branch.includes(".activate("),
    "popup.openApp 必须调用 nativeClient.activate：app.activate 是用户主动唤醒，可重启已退出的 App",
  );
  assert.ok(
    !/\.ping\(/.test(branch),
    "popup.openApp 不得再用后台 ping：ping 在退出标记存在时不唤醒 App，会让『打开 MacIDM』按钮失效",
  );
});

// ============================================================================
// 5. User-gesture inspection and App-not-running status: media.inspect must
//    carry userInitiated so the Host may wake a deliberately quit App, and a
//    mere "App is not up" state must not surface as an error toast.
// ============================================================================

test("Service Worker 接线: media.inspect 必须透传 userInitiated（否则退出后的 App 无法被『解析画质』唤醒）", () => {
  const inspectMatch = serviceWorkerSource.match(
    /if \(message\?\.type === "media\.inspect"\) \{[\s\S]*?return true;\s*\}/,
  );
  assert.ok(inspectMatch, "未能定位 media.inspect 分支");
  assert.match(
    inspectMatch[0],
    /userInitiated:\s*message\.userInitiated === true/,
    "media.inspect 分支必须把内容页/Popup 的用户手势标记透传给 Host：BridgeLaunchIntent 依赖该字段决定是否唤醒已退出的 App",
  );
});

test("Service Worker 接线: YouTube 兜底解析必须标记 userInitiated（ensure/retry 只来自用户打开的 Popup 与浮窗）", () => {
  const appInspector = serviceWorkerSource.match(
    /appInspector: async \(\{ tabId, url \}\) => \{[\s\S]*?return \{ ok: true, variants:/,
  );
  assert.ok(appInspector, "未能定位 youTubeInspectionCoordinator 的 appInspector");
  assert.match(
    appInspector[0],
    /userInitiated: true/,
    "yt-dlp 兜底解析同样源自用户手势，缺少该标记会让 YouTube 画质解析在 App 退出后直接失败",
  );
});

test("Service Worker 接线: popupStatus 必须把连接健康类错误转成 unreachableReason，而不是当作 lastError 弹错误提示", () => {
  const statusMatch = serviceWorkerSource.match(/async function popupStatus\(\) \{[\s\S]*?\n\}/);
  assert.ok(statusMatch, "未能定位 popupStatus");
  const body = statusMatch[0];
  assert.match(
    body,
    /CONNECTION_HEALTH_ERROR_CODES\.has\(diagnostic\.code\)/,
    "必须用共享的连接健康错误码集合判定『App 只是没在运行』",
  );
  assert.match(body, /unreachableReason:/, "必须回传 unreachableReason 供 Popup 渲染可操作的状态点");
  assert.match(
    body,
    /lastError: healthCode \? null : diagnostic/,
    "健康类失败不得再作为 lastError 返回：否则每次打开 Popup 都会弹『MacIDM 启动超时，Chrome 下载将继续』",
  );
});

test("浮窗与 Popup 发出的 media.inspect 必须携带 userInitiated: true", () => {
  for (const file of ["src/content/overlay.js", "src/popup/popup.js"]) {
    const source = fs.readFileSync(path.resolve(chromeRoot, file), "utf8");
    const blocks = [...source.matchAll(/type: "media\.inspect",[\s\S]*?\}\)/g)].map((m) => m[0]);
    assert.ok(blocks.length > 0, `${file} 未发现 media.inspect 请求`);
    for (const block of blocks) {
      assert.match(
        block,
        /userInitiated: true/,
        `${file} 的 media.inspect 必须标记用户手势：两个界面都由用户点开，Host 据此才允许唤醒已退出的 App`,
      );
    }
  }
});

test("Popup 接线: 状态点必须按 unreachableReason 给出可操作文案，而不是笼统的『未连接』", () => {
  const source = fs.readFileSync(
    path.resolve(chromeRoot, "src/popup/popup.js"),
    "utf8",
  );
  const refresh = source.match(/async function refreshStatus\(\) \{[\s\S]*?\n\}/);
  assert.ok(refresh, "未能定位 popup.js 的 refreshStatus");
  assert.match(
    refresh[0],
    /popup\.appNotRunning/,
    "App 仅未运行时必须告诉用户去哪里启动（⋯ → 打开 MacIDM）",
  );
  assert.match(
    refresh[0],
    /popup\.hostNotInstalled/,
    "本地 Host 缺失时必须与『App 未运行』区分开，两者的修复动作不同",
  );
});
