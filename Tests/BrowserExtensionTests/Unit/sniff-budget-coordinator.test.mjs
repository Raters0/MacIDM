import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {
  SniffBudgetCoordinator,
  DEFAULT_PAGE_SNIFF_BUDGET,
} from "../../../BrowserExtension/chrome/src/background/sniff-budget-coordinator.js";
import "../../../BrowserExtension/chrome/src/content/fetch-interceptor.js";

const interceptor = globalThis.MacIDMFetchInterceptor;
const fetchInterceptorSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/fetch-interceptor.js", import.meta.url),
  "utf8",
);

function createFrameVM({ frameId, tabId = 101, generation = 1, coordinator }) {
  const messageListeners = [];
  const postedMessages = [];

  const context = {
    URL,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    setTimeout,
    clearTimeout,
    console,
    location: { href: `https://example.com/frame_${frameId}` },
    addEventListener: (event, fn) => {
      if (event === "message") messageListeners.push(fn);
    },
    removeEventListener: () => {},
    postMessage: (msg) => {
      postedMessages.push(msg);
      if (!msg || typeof msg !== "object") return;

      // 模拟 content-script 转发到 Background SniffBudgetCoordinator
      if (msg.type === "macidm.requestSniffLease") {
        const leaseResult = coordinator.acquireLease({
          tabId,
          generation,
          requestedBytes: msg.requestedBytes,
          tier: msg.tier,
        });

        // 模拟异步回发 GRANT_LEASE_TYPE 消息
        queueMicrotask(() => {
          for (const listener of messageListeners) {
            try {
              listener({
                data: {
                  type: "macidm.grantSniffLease",
                  requestId: msg.requestId,
                  leaseId: leaseResult.leaseId,
                  grantedBytes: leaseResult.grantedBytes,
                },
              });
            } catch {}
          }
        });
      } else if (msg.type === "macidm.settleSniffLease") {
        coordinator.settleLease({
          tabId,
          generation,
          leaseId: msg.leaseId,
          actualBytes: msg.actualBytes,
        });
      } else if (msg.type === "macidm.releaseSniffLease") {
        coordinator.releaseLease({
          tabId,
          generation,
          leaseId: msg.leaseId,
          reason: msg.reason,
        });
      }
    },
  };

  context.globalThis = context;
  context.window = context;
  vm.createContext(context);
  vm.runInContext(fetchInterceptorSource, context);

  return {
    context,
    interceptor: context.MacIDMFetchInterceptor,
    postedMessages,
  };
}

test("SniffBudgetCoordinator [真实生产接线]: 多个独立 VM Frame 共用同一 Coordinator 严格受限于 2MB", async () => {
  const coordinator = new SniffBudgetCoordinator({
    maxPageBudget: 2 * 1024 * 1024, // 2MB
  });

  const tabId = 101;
  const generation = 1;

  // 创建 3 个独立的 VM Frame
  const frame1 = createFrameVM({ frameId: 1, tabId, generation, coordinator });
  const frame2 = createFrameVM({ frameId: 2, tabId, generation, coordinator });
  const frame3 = createFrameVM({ frameId: 3, tabId, generation, coordinator });

  // Frame 1 申请 1MB
  const p1 = frame1.interceptor.requestSniffLease(1024 * 1024, "json");
  // Frame 2 申请 1MB
  const p2 = frame2.interceptor.requestSniffLease(1024 * 1024, "json");

  const [res1, res2] = await Promise.all([p1, p2]);
  assert.ok(res1.leaseId, "Frame 1 必须获得真实 leaseId");
  assert.equal(res1.grantedBytes, 1024 * 1024);
  assert.ok(res2.leaseId, "Frame 2 必须获得真实 leaseId");
  assert.equal(res2.grantedBytes, 1024 * 1024);

  // 此时总预留已达 2MB
  const snapshot1 = coordinator.getPageSnapshot(tabId, generation);
  assert.equal(snapshot1.reservedBytes, 2 * 1024 * 1024);
  assert.equal(snapshot1.remainingBudget, 0);

  // Frame 3 申请 512KB -> 必须被拒绝，授予 0 字节
  const res3 = await frame3.interceptor.requestSniffLease(512 * 1024, "manifest");
  assert.equal(res3.grantedBytes, 0, "预算耗尽时 Frame 3 必须获得 0 字节");
  assert.equal(res3.leaseId, null);

  // Frame 1 实际仅消费 64KB 并结算
  frame1.interceptor.settleSniffLease(res1.leaseId, 64 * 1024);
  await new Promise((r) => setTimeout(r, 10));

  const snapshot2 = coordinator.getPageSnapshot(tabId, generation);
  assert.equal(snapshot2.usedBytes, 64 * 1024);
  assert.equal(snapshot2.reservedBytes, 1024 * 1024); // 仅剩 Frame 2 的 1MB reserved
  assert.equal(snapshot2.remainingBudget, 2 * 1024 * 1024 - (64 * 1024 + 1024 * 1024));

  // Frame 3 再次申请 512KB -> 此时有释放的额度，成功获得授权
  const res3Retry = await frame3.interceptor.requestSniffLease(512 * 1024, "manifest");
  assert.ok(res3Retry.leaseId);
  assert.equal(res3Retry.grantedBytes, 512 * 1024);

  // Frame 2 释放
  frame2.interceptor.releaseSniffLease(res2.leaseId, "aborted");
  // Frame 3 结算 32KB
  frame3.interceptor.settleSniffLease(res3Retry.leaseId, 32 * 1024);
  await new Promise((r) => setTimeout(r, 10));

  const finalSnapshot = coordinator.getPageSnapshot(tabId, generation);
  assert.equal(finalSnapshot.usedBytes, 64 * 1024 + 32 * 1024);
  assert.equal(finalSnapshot.reservedBytes, 0);
  assert.equal(finalSnapshot.activeLeasesCount, 0);
});

test("SniffBudgetCoordinator: 容量超限保护 (活跃 Lease 与已消费账本绝不逐出，Fail-Closed)", () => {
  const coordinator = new SniffBudgetCoordinator({
    maxPages: 2, // 容量仅允许 2 个 Page
  });

  // Page 1 申请并持有 active lease
  const l1 = coordinator.acquireLease({ tabId: 1, generation: 1, requestedBytes: 10000 });
  assert.equal(l1.ok, true);

  // Page 2 申请并持有 active lease
  const l2 = coordinator.acquireLease({ tabId: 2, generation: 1, requestedBytes: 10000 });
  assert.equal(l2.ok, true);

  // Page 3 尝试申请 -> 由于现有 2 个 Page 均有 active lease，必须 Fail-Closed 拒绝
  const l3 = coordinator.acquireLease({ tabId: 3, generation: 1, requestedBytes: 10000 });
  assert.equal(l3.ok, false);
  assert.equal(l3.reason, "capacity_exhausted_all_active");

  // Page 1 消费 5000 字节并结算 (leases 归零但 usedBytes > 0)
  coordinator.settleLease({ tabId: 1, generation: 1, leaseId: l1.leaseId, actualBytes: 5000 });
  assert.equal(coordinator.getPageSnapshot(1, 1).usedBytes, 5000);
  assert.equal(coordinator.getPageSnapshot(1, 1).reservedBytes, 0);

  // Page 2 释放 lease 且未使用 (usedBytes === 0, reservedBytes === 0)
  coordinator.releaseLease({ tabId: 2, generation: 1, leaseId: l2.leaseId });
  assert.equal(coordinator.getPageSnapshot(2, 1).usedBytes, 0);

  // Page 3 再次申请 -> 仅允许逐出 usedBytes === 0 的 Page 2，Page 1 已消费账本绝不被逐出
  const l3Retry = coordinator.acquireLease({ tabId: 3, generation: 1, requestedBytes: 10000 });
  assert.equal(l3Retry.ok, true);
  assert.ok(l3Retry.leaseId);

  // 验证 Page 1 账本与剩余额度完好保留
  const p1Snapshot = coordinator.getPageSnapshot(1, 1);
  assert.equal(p1Snapshot.usedBytes, 5000, "Page 1 已消费额度绝不得被重置或逐出");
  assert.equal(p1Snapshot.remainingBudget, 2 * 1024 * 1024 - 5000);

  // Page 3 消费 8000 字节并结算 -> 此时 Page 1 和 Page 3 均有 usedBytes > 0
  coordinator.settleLease({ tabId: 3, generation: 1, leaseId: l3Retry.leaseId, actualBytes: 8000 });

  // Page 4 尝试申请 -> 现存页面均有已消费账本，无法逐出，必须 Fail-Closed
  const l4 = coordinator.acquireLease({ tabId: 4, generation: 1, requestedBytes: 10000 });
  assert.equal(l4.ok, false);
  assert.equal(l4.reason, "capacity_exhausted_all_active");
});

test("SniffBudgetCoordinator: Lease 超时保守计入 usedBytes (Fail-Closed) 且晚到 settle 幂等失败", async () => {
  const coordinator = new SniffBudgetCoordinator({
    leaseTtlMs: 50, // 50ms 超时
  });

  const tabId = 303;
  const gen = 1;

  const lease = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 500_000 });
  assert.equal(lease.grantedBytes, 500_000);
  assert.equal(coordinator.getPageSnapshot(tabId, gen).reservedBytes, 500_000);
  assert.equal(coordinator.getPageSnapshot(tabId, gen).usedBytes, 0);

  // 等待 70ms 超过 lease TTL
  await new Promise((r) => setTimeout(r, 70));

  // getPageSnapshot 自动收敛清理超时 lease，保守将 500_000 计入 usedBytes
  const snapshot = coordinator.getPageSnapshot(tabId, gen);
  assert.equal(snapshot.reservedBytes, 0, "超时的 lease 必须自动收敛扣减 reservedBytes");
  assert.equal(snapshot.usedBytes, 500_000, "超时的 lease 必须保守计入 usedBytes 防止超额消费");
  assert.equal(snapshot.activeLeasesCount, 0);
  assert.equal(coordinator.getMetrics().leaseTimeout, 1);

  // 晚到的 settleLease 必须幂等失败，且绝不再次增加 usedBytes
  const lateSettle = coordinator.settleLease({ tabId, generation: gen, leaseId: lease.leaseId, actualBytes: 500_000 });
  assert.equal(lateSettle.ok, false);
  assert.equal(lateSettle.reason, "lease_not_found_or_expired");
  assert.equal(coordinator.getPageSnapshot(tabId, gen).usedBytes, 500_000, "晚到结算不得二次计费");
});

test("SniffBudgetCoordinator: 导航或 Tab 关闭时彻底清理账本", () => {
  const coordinator = new SniffBudgetCoordinator();
  const tabId = 202;

  coordinator.acquireLease({ tabId, generation: 1, requestedBytes: 500_000, tier: "json" });
  coordinator.acquireLease({ tabId, generation: 2, requestedBytes: 300_000, tier: "json" });

  assert.equal(coordinator.getPageSnapshot(tabId, 1).reservedBytes, 500_000);
  assert.equal(coordinator.getPageSnapshot(tabId, 2).reservedBytes, 300_000);

  // 清理代际 1
  coordinator.clearTab(tabId, 1);
  assert.equal(coordinator.getPageSnapshot(tabId, 1).reservedBytes, 0);
  assert.equal(coordinator.getPageSnapshot(tabId, 2).reservedBytes, 300_000);

  // 彻底关闭 Tab
  coordinator.clearTab(tabId);
  assert.equal(coordinator.getPageSnapshot(tabId, 2).reservedBytes, 0);
});

test("fetch-interceptor: 纯函数魔数匹配与 JSON 深层扫描", () => {
  assert.equal(interceptor.sniffManifestMagic("#EXTM3U\n#EXT-X-VERSION:3"), "hls");
  assert.equal(interceptor.sniffManifestMagic("<?xml version='1.0'?><MPD xmlns='urn:mpeg:dash:schema:mpd:2011'>"), "dash");
  assert.equal(interceptor.sniffManifestMagic("plain text not media"), null);

  const deepJSON = {
    code: 0,
    data: {
      result: {
        stream: {
          items: [
            { url: "https://example.com/live/segment1.m3u8" },
            { url: "https://example.com/video/track.mp4" },
          ],
        },
      },
    },
  };

  const scanned = interceptor.scanJSONForMedia(deepJSON, "https://example.com/page");
  assert.equal(scanned.urls.length, 2);
  assert.ok(scanned.urls.includes("https://example.com/live/segment1.m3u8"));
  assert.ok(scanned.urls.includes("https://example.com/video/track.mp4"));
});

test("SniffBudgetCoordinator: Page TTL 绝不重置 usedBytes > 0 账本，空白账本按 TTL 正常逐出", async () => {
  const coordinator = new SniffBudgetCoordinator({
    pageTtlMs: 30, // 30ms 极小 Page TTL
    maxPageBudget: 2 * 1024 * 1024,
  });

  const tabId = 999;
  const gen = 1;

  // 1. 申请 100KB 并结算 100KB (usedBytes = 100KB, reservedBytes = 0, leases = 0)
  const l1 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 100 * 1024 });
  assert.equal(l1.ok, true);
  coordinator.settleLease({ tabId, generation: gen, leaseId: l1.leaseId, actualBytes: 100 * 1024 });

  let snap = coordinator.getPageSnapshot(tabId, gen);
  assert.equal(snap.usedBytes, 100 * 1024);
  assert.equal(snap.reservedBytes, 0);

  // 2. 等待 50ms 超过 pageTtlMs (30ms)
  await new Promise((r) => setTimeout(r, 50));

  // 3. 再次在同一 tabId + generation 下申请全额 2MB 预算
  const l2 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 2 * 1024 * 1024 });
  assert.equal(l2.ok, true);
  // 必须只能获得剩余的 2MB - 100KB，绝不能重置为全新的 2MB！
  assert.equal(l2.grantedBytes, 2 * 1024 * 1024 - 100 * 1024, "Page TTL 超期绝不能重置已消费的 usedBytes 账本");

  snap = coordinator.getPageSnapshot(tabId, gen);
  assert.equal(snap.usedBytes, 100 * 1024);
  assert.equal(snap.reservedBytes, 2 * 1024 * 1024 - 100 * 1024);
  assert.equal(snap.remainingBudget, 0);

  // 4. 对比反事实验证：未消费的空白账本 (usedBytes === 0, reservedBytes === 0) 超过 pageTtlMs 会被正常逐出
  const emptyTab = 888;
  const lEmpty = coordinator.acquireLease({ tabId: emptyTab, generation: 1, requestedBytes: 50 * 1024 });
  coordinator.releaseLease({ tabId: emptyTab, generation: 1, leaseId: lEmpty.leaseId }); // used = 0
  assert.equal(coordinator.getPageSnapshot(emptyTab, 1).usedBytes, 0);

  await new Promise((r) => setTimeout(r, 50));
  // 触发一次 acquireLease 以执行 #pruneExpiredPages
  coordinator.acquireLease({ tabId: 777, generation: 1, requestedBytes: 1024 });

  const emptySnap = coordinator.getPageSnapshot(emptyTab, 1);
  assert.equal(emptySnap.usedBytes, 0);
  assert.equal(emptySnap.remainingBudget, 2 * 1024 * 1024, "空白条目安全逐出后不留残留");
});

test("SniffBudgetCoordinator: settleLease 输入验证与 Fail-Closed 保守计费 (防 NaN/Infinity/负数/越界)", () => {
  const coordinator = new SniffBudgetCoordinator({
    maxPageBudget: 1024 * 1024, // 1MB
  });

  const tabId = 555;
  const gen = 1;

  // 测试用例 1: actualBytes 为 NaN
  const l1 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 64 * 1024 });
  const s1 = coordinator.settleLease({ tabId, generation: gen, leaseId: l1.leaseId, actualBytes: NaN });
  assert.equal(s1.ok, true);
  assert.equal(s1.usedBytes, 64 * 1024, "NaN 结算必须 Fail-Closed 保守计入 full grantedBytes (64KB)");
  assert.equal(s1.reservedBytes, 0);
  assert.equal(Number.isFinite(s1.usedBytes), true);

  // 测试用例 2: actualBytes 为 Infinity 与 -Infinity
  const l2 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 32 * 1024 });
  const s2 = coordinator.settleLease({ tabId, generation: gen, leaseId: l2.leaseId, actualBytes: Infinity });
  assert.equal(s2.ok, true);
  assert.equal(s2.usedBytes, 64 * 1024 + 32 * 1024, "Infinity 结算必须 Fail-Closed 保守计入 full grantedBytes");
  assert.equal(Number.isFinite(s2.usedBytes), true);

  // 测试用例 3: actualBytes 为负数
  const l3 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 16 * 1024 });
  const s3 = coordinator.settleLease({ tabId, generation: gen, leaseId: l3.leaseId, actualBytes: -500 });
  assert.equal(s3.ok, true);
  assert.equal(s3.usedBytes, 64 * 1024 + 32 * 1024 + 16 * 1024, "负数结算必须 Fail-Closed 保守计入 full grantedBytes");

  // 测试用例 4: actualBytes 为非整数字符串
  const l4 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 16 * 1024 });
  const s4 = coordinator.settleLease({ tabId, generation: gen, leaseId: l4.leaseId, actualBytes: "corrupted" });
  assert.equal(s4.ok, true);
  assert.equal(s4.usedBytes, 64 * 1024 + 32 * 1024 + 16 * 1024 + 16 * 1024, "字符串结算必须 Fail-Closed 计入 full grantedBytes");

  // 测试用例 5: actualBytes 为浮点数
  const l5 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 8 * 1024 });
  const s5 = coordinator.settleLease({ tabId, generation: gen, leaseId: l5.leaseId, actualBytes: 4096.5 });
  assert.equal(s5.ok, true);
  assert.equal(s5.usedBytes, 64 * 1024 + 32 * 1024 + 16 * 1024 + 16 * 1024 + 8 * 1024, "非安全整数浮点数结算必须 Fail-Closed");

  // 测试用例 6: actualBytes 超出 grantedBytes (granted 8KB, 传入 64KB) -> 严格截断为 granted 8KB
  const l6 = coordinator.acquireLease({ tabId, generation: gen, requestedBytes: 8 * 1024 });
  const s6 = coordinator.settleLease({ tabId, generation: gen, leaseId: l6.leaseId, actualBytes: 64 * 1024 });
  assert.equal(s6.ok, true);
  assert.equal(s6.usedBytes, 64 * 1024 + 32 * 1024 + 16 * 1024 + 16 * 1024 + 8 * 1024 + 8 * 1024, "超额结算必须严格以 grantedBytes 为上限");

  // 终态 snapshot 校验：所有字段均为非负有限整数且 used + reserved <= maxPageBudget
  const snap = coordinator.getPageSnapshot(tabId, gen);
  assert.equal(Number.isSafeInteger(snap.usedBytes), true);
  assert.equal(Number.isSafeInteger(snap.reservedBytes), true);
  assert.equal(Number.isSafeInteger(snap.remainingBudget), true);
  assert.equal(Number.isSafeInteger(snap.activeLeasesCount), true);
  assert.ok(snap.usedBytes >= 0);
  assert.ok(snap.reservedBytes >= 0);
  assert.ok(snap.remainingBudget >= 0);
  assert.ok(snap.usedBytes + snap.reservedBytes <= 1024 * 1024);
});
