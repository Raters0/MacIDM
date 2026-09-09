import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";

import { applyM4sPairing } from "../../../BrowserExtension/chrome/src/background/m4s-pairing.js";
import {
  alignMediaTabStateWithLiveURL,
  isHttpURL,
  takeBackgroundCandidates,
} from "../../../BrowserExtension/chrome/src/background/media-observation.js";

const serviceWorkerPath = path.resolve(
  process.cwd(),
  "BrowserExtension/chrome/src/background/service-worker.js",
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
  assert.equal(result.candidates[0].displayName, "测试视频标题");
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
  const worker = vm.createContext({ chrome: { scripting: { executeScript: async (options) => { injected = options.files; } } } });
  vm.runInContext(match[0], worker);
  await worker.ensureContentScript(42);
  const page = vm.createContext({ URL, console });
  for (const file of injected) {
    if (file === "src/content/overlay.js") break;
    // The DOM observers are covered by their own browser harness. Load the
    // actual shared dependencies from the production JIT list into a cold VM.
    if (["src/shared/media-utils.js", "src/shared/youtube-format-utils.js", "src/shared/media-presentation.js"].includes(file)) {
      vm.runInContext(fs.readFileSync(path.resolve("BrowserExtension/chrome", file), "utf8"), page);
    }
  }
  const overlay = fs.readFileSync(path.resolve("BrowserExtension/chrome/src/content/overlay.js"), "utf8");
  const candidateKey = overlay.match(/function candidateKey\(candidate\) \{[\s\S]*?\n  \}/);
  assert.ok(candidateKey);
  vm.runInContext(candidateKey[0], page);
  assert.equal(page.candidateKey({ url: "https://example.test/movie.mp4" }), "https://example.test/movie.mp4");
});
