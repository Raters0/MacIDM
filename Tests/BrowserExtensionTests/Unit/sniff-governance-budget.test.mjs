import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { SniffBudgetCoordinator } from "../../../BrowserExtension/chrome/src/background/sniff-budget-coordinator.js";

const fetchInterceptorSource = fs.readFileSync(
  new URL("../../../BrowserExtension/chrome/src/content/fetch-interceptor.js", import.meta.url),
  "utf8",
);

function makeInterceptorContext({ fetch = null, coordinator = null, grantModifier = null } = {}) {
  const messages = [];
  const messageListeners = [];
  const coord = coordinator || new SniffBudgetCoordinator({ maxPageBudget: 2 * 1024 * 1024 });

  const dispatchMessage = (data) => {
    for (const listener of messageListeners) {
      try {
        listener({ data });
      } catch (err) {
        console.error("dispatch error:", err);
      }
    }
  };

  const context = {
    URL,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    setTimeout,
    clearTimeout,
    console,
    fetch,
    location: { href: "https://example.com/watch" },
    addEventListener: (event, fn) => {
      if (event === "message") messageListeners.push(fn);
    },
    removeEventListener: (event, fn) => {
      if (event === "message") {
        const idx = messageListeners.indexOf(fn);
        if (idx >= 0) messageListeners.splice(idx, 1);
      }
    },
    postMessage: (msg) => {
      messages.push(msg);
      if (!msg || typeof msg !== "object") return;

      if (msg.type === "macidm.requestSniffLease") {
        let lease = coord.acquireLease({
          tabId: 1,
          generation: 1,
          requestedBytes: msg.requestedBytes,
          tier: msg.tier,
        });

        if (typeof grantModifier === "function") {
          lease = grantModifier(lease, msg, { dispatchMessage, context, coordinator: coord });
        }

        if (lease !== null) {
          queueMicrotask(() => {
            dispatchMessage({
              type: "macidm.grantSniffLease",
              requestId: msg.requestId,
              leaseId: lease.leaseId,
              grantedBytes: lease.grantedBytes,
            });
          });
        }
      } else if (msg.type === "macidm.settleSniffLease") {
        coord.settleLease({
          tabId: 1,
          generation: 1,
          leaseId: msg.leaseId,
          actualBytes: msg.actualBytes,
        });
      } else if (msg.type === "macidm.releaseSniffLease") {
        coord.releaseLease({
          tabId: 1,
          generation: 1,
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
    messages,
    messageListeners,
    dispatchMessage,
    coordinator: coord,
  };
}

test("Body Sniff: constants and tier budgets are defined", () => {
  const { interceptor } = makeInterceptorContext();
  assert.ok(interceptor);
  assert.equal(interceptor.MAX_FRAME_CONCURRENT_SNIFFS, 2);
  assert.equal(interceptor.MAX_PAGE_SNIFF_BUDGET, 2 * 1024 * 1024);
  assert.equal(interceptor.TIER_BUDGETS.MANIFEST.maxBytes, 64 * 1024);
  assert.equal(interceptor.TIER_BUDGETS.JSON.maxBytes, 512 * 1024);
});

test("Body Sniff: 单 Chunk 大于 Grant 严格截断为 GrantedBytes 且结算准确", async () => {
  // 单 chunk 64KB, Background 仅批准 16KB
  const bigChunk = new Uint8Array(64 * 1024);
  bigChunk.fill(65); // 'A'

  let cancelCalled = false;
  const mockFetch = async () => ({
    url: "https://api.example.com/big_chunk.json",
    headers: {
      get: (name) => {
        if (name.toLowerCase() === "content-type") return "application/json";
        if (name.toLowerCase() === "content-length") return String(bigChunk.length);
        return null;
      },
    },
    clone() {
      return {
        body: {
          getReader() {
            let readCount = 0;
            return {
              async read() {
                if (readCount === 0) {
                  readCount++;
                  return { done: false, value: bigChunk };
                }
                return { done: true, value: undefined };
              },
              async cancel() {
                cancelCalled = true;
              },
            };
          },
        },
      };
    },
  });

  const { context, interceptor, coordinator } = makeInterceptorContext({
    fetch: mockFetch,
    grantModifier: (lease) => ({
      leaseId: lease.leaseId,
      grantedBytes: 16 * 1024, // 严格限制只给 16KB
    }),
  });

  await context.fetch("https://api.example.com/big_chunk.json");
  await new Promise((r) => setTimeout(r, 30));

  const metrics = interceptor.getMetrics();
  assert.equal(metrics.bytesRead, 16 * 1024, "读取字节必须严格截断至 grantedBytes (16KB)");
  assert.equal(cancelCalled, true, "截断后必须调用 reader.cancel()");

  const snapshot = coordinator.getPageSnapshot(1, 1);
  assert.equal(snapshot.usedBytes, 16 * 1024, "Coordinator 结算字节必须严格等于 16KB");
  assert.equal(snapshot.reservedBytes, 0);
});

test("Body Sniff: Grant 小于 Tier 预算时严格以 Grant 为上限", async () => {
  const chunk1 = new Uint8Array(4 * 1024);
  const chunk2 = new Uint8Array(4 * 1024);
  const chunk3 = new Uint8Array(4 * 1024);

  const mockFetch = async () => ({
    url: "https://api.example.com/multi_chunk.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      return {
        body: {
          getReader() {
            let round = 0;
            return {
              async read() {
                round++;
                if (round === 1) return { done: false, value: chunk1 };
                if (round === 2) return { done: false, value: chunk2 };
                if (round === 3) return { done: false, value: chunk3 };
                return { done: true, value: undefined };
              },
              async cancel() {},
            };
          },
        },
      };
    },
  });

  const { context, interceptor, coordinator } = makeInterceptorContext({
    fetch: mockFetch,
    grantModifier: (lease) => ({
      leaseId: lease.leaseId,
      grantedBytes: 8 * 1024, // 只给 8KB (前两个 chunk)
    }),
  });

  await context.fetch("https://api.example.com/multi_chunk.json");
  await new Promise((r) => setTimeout(r, 30));

  const metrics = interceptor.getMetrics();
  assert.equal(metrics.bytesRead, 8 * 1024, "读取字节必须严格以 grant 8KB 为上限");

  const snapshot = coordinator.getPageSnapshot(1, 1);
  assert.equal(snapshot.usedBytes, 8 * 1024);
  assert.equal(snapshot.reservedBytes, 0);
});

test("Body Sniff [核心时序回归]: 页面立即消费原 Response 正文，生产 Interceptor 仍成功克隆并完成非零嗅探", async () => {
  // 模拟真实浏览器行为：原 Response 正文被页面立即消费，clone 拥有独立流
  const mediaJSON = JSON.stringify({
    url: "https://cdn.example.com/hls/master.m3u8",
    title: "Test Video",
  });
  const jsonBytes = new TextEncoder().encode(mediaJSON);

  // 构造可克隆的 Fetch Response
  const mockFetch = async () => {
    let originalConsumed = false;
    return {
      url: "https://api.example.com/get_media.json",
      headers: {
        get: (name) => {
          if (name.toLowerCase() === "content-type") return "application/json";
          if (name.toLowerCase() === "content-length") return String(jsonBytes.length);
          return null;
        },
      },
      // 原 Response 的消费方法
      async text() {
        if (originalConsumed) throw new TypeError("Failed to execute 'text' on 'Response': body stream already used");
        originalConsumed = true;
        return mediaJSON;
      },
      async json() {
        if (originalConsumed) throw new TypeError("Failed to execute 'json' on 'Response': body stream already used");
        originalConsumed = true;
        return JSON.parse(mediaJSON);
      },
      // 同步克隆支持
      clone() {
        if (originalConsumed) throw new TypeError("Failed to execute 'clone' on 'Response': Response body is already used");
        let cloneRead = false;
        return {
          body: {
            getReader() {
              return {
                async read() {
                  if (!cloneRead) {
                    cloneRead = true;
                    return { done: false, value: jsonBytes };
                  }
                  return { done: true, value: undefined };
                },
                async cancel() {},
              };
            },
          },
        };
      },
    };
  };

  const { context, interceptor, coordinator } = makeInterceptorContext({
    fetch: mockFetch,
  });

  // 页面调用 fetch 并立即消费正文 (await resp.json() / resp.text())
  const resp = await context.fetch("https://api.example.com/get_media.json");
  const data = await resp.json(); // 页面立即消费原正文
  assert.equal(data.title, "Test Video");

  // 等待拦截器异步嗅探与 Lease 结算完成
  await new Promise((r) => setTimeout(r, 50));

  const metrics = interceptor.getMetrics();
  assert.equal(metrics.cloneError, 0, "同步克隆机制下 cloneError 必须为 0");
  assert.ok(metrics.bytesRead > 0, "生产 Interceptor 必须成功读取正文字节 (bytesRead > 0)");
  assert.equal(metrics.bytesRead, jsonBytes.length);
  assert.equal(metrics.completed, 1);

  const snapshot = coordinator.getPageSnapshot(1, 1);
  assert.equal(snapshot.usedBytes, jsonBytes.length, "Coordinator 账本必须正确计入嗅探读取字节");
  assert.equal(snapshot.reservedBytes, 0);
});

test("Body Sniff: Grant = 0 时安全退出，不进行流读取且不泄漏配额", async () => {
  const mockFetch = async () => ({
    url: "https://api.example.com/zero_grant.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      return {
        body: {
          getReader() {
            throw new Error("should not get reader when grant is 0");
          },
          cancel() {},
        },
      };
    },
  });

  const { context, interceptor } = makeInterceptorContext({
    fetch: mockFetch,
    grantModifier: () => ({ leaseId: null, grantedBytes: 0 }),
  });

  await context.fetch("https://api.example.com/zero_grant.json");
  await new Promise((r) => setTimeout(r, 20));

  const metrics = interceptor.getMetrics();
  assert.equal(metrics.skippedByBudget, 1);
  assert.equal(metrics.bytesRead, 0);
});

test("Body Sniff: Clone-Hold 超时取消与晚到 Lease 立即释放 (真实 Background 生产消息闭环)", async () => {
  let cloneCancelled = false;
  let readerCreated = false;

  const mockFetch = async () => ({
    url: "https://api.example.com/slow_lease.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      return {
        body: {
          cancel() {
            cloneCancelled = true;
          },
          getReader() {
            readerCreated = true;
            return {
              async read() {
                return { done: true, value: undefined };
              },
              async cancel() {},
            };
          },
        },
      };
    },
  });

  const coordinator = new SniffBudgetCoordinator({ maxPageBudget: 2 * 1024 * 1024 });

  const { context, interceptor, messages, dispatchMessage } = makeInterceptorContext({
    fetch: mockFetch,
    coordinator,
    grantModifier: (realLease, msg) => {
      // 1. Background 已经成功 acquire 真实 lease (此时 reservedBytes > 0)
      assert.ok(realLease.leaseId, "Background 必须已分配真实 leaseId");
      assert.ok(realLease.grantedBytes > 0, "Background 必须已预留 grantedBytes");

      // 2. 延迟 140ms 发送真实 grant（超过 100ms hold deadline）
      setTimeout(() => {
        dispatchMessage({
          type: "macidm.grantSniffLease",
          requestId: msg.requestId,
          leaseId: realLease.leaseId,
          grantedBytes: realLease.grantedBytes,
        });
      }, 140);

      // 返回 null 阻止立即同步下发
      return null;
    },
  });

  // 触发 fetch 请求
  context.fetch("https://api.example.com/slow_lease.json");

  // 等待 110ms：超过 100ms hold deadline，但 140ms grant 尚未到达
  await new Promise((r) => setTimeout(r, 110));

  assert.equal(cloneCancelled, true, "100ms hold 超时后必须主动 cancel clone body 防 tee 积压");
  assert.equal(readerCreated, false, "hold 超时绝不能调用 getReader()");

  // 此时 coordinator 仍持有 reserved 额度（因为 grant 还在 IPC 路上）
  let snap = coordinator.getPageSnapshot(1, 1);
  assert.ok(snap.reservedBytes > 0, "此时 Background 仍处于 reserved 状态");
  assert.equal(snap.activeLeasesCount, 1);

  // 等待到 170ms：140ms 的 late grant 到达生产 interceptor
  await new Promise((r) => setTimeout(r, 60));

  // 生产 interceptor 收到 late grant 必须立即发出 macidm.releaseSniffLease
  const releaseMsg = messages.find((m) => m.type === "macidm.releaseSniffLease");
  assert.ok(releaseMsg, "收到迟到 grant 时生产 interceptor 必须发送 releaseSniffLease 消息");
  assert.equal(releaseMsg.reason, "late_after_timeout");

  // Coordinator 最终状态必须彻底收敛归零，绝不泄漏配额
  snap = coordinator.getPageSnapshot(1, 1);
  assert.equal(snap.reservedBytes, 0, "迟到 lease 释放后 reservedBytes 必须严格归零");
  assert.equal(snap.activeLeasesCount, 0, "activeLeasesCount 必须归零");
  assert.equal(snap.usedBytes, 0, "未读取正文，usedBytes 必须严格为 0");

  const metrics = interceptor.getMetrics();
  assert.equal(metrics.leaseTimeout, 1, "必须准确记录 1 次 leaseTimeout");
  assert.equal(metrics.bytesRead, 0);
});

test("Body Sniff: 慢速挂起 Stream Reader 触发超时并安全释放 Lease", async () => {
  let readerCancelled = false;
  const mockFetch = async () => ({
    url: "https://api.example.com/hanging_stream.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      return {
        body: {
          getReader() {
            return {
              read() {
                // 永久挂起不返回
                return new Promise(() => {});
              },
              async cancel() {
                readerCancelled = true;
              },
            };
          },
        },
      };
    },
  });

  const { context, interceptor, coordinator } = makeInterceptorContext({
    fetch: mockFetch,
  });

  context.fetch("https://api.example.com/hanging_stream.json");
  // 等待 1100ms 触发 chunk read timeout (1000ms race)
  await new Promise((r) => setTimeout(r, 1150));

  assert.equal(readerCancelled, true, "挂起的 reader 必须被 Promise.race 超时取消");
  const metrics = interceptor.getMetrics();
  assert.equal(metrics.readError, 1);
  assert.equal(metrics.activeFrameSniffCount, 0, "活跃计数必须真实归零");

  const snapshot = coordinator.getPageSnapshot(1, 1);
  assert.equal(snapshot.reservedBytes, 0, "挂起超时的 Lease 必须全额释放归零");
});

test("Body Sniff: Operation Token 竞态保护 (旧 reader pending -> reset -> 新 sniff 启动 -> 旧 finally 晚到)", async () => {
  let op1ReaderCancel = false;
  let op1ReadResolve = null;
  let op2ReadResolve = null;

  let requestCount = 0;
  let op2ReadCount = 0;
  const mockFetch = async () => {
    requestCount++;
    const currentReq = requestCount;
    return {
      url: `https://api.example.com/req_${currentReq}.json`,
      headers: {
        get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
      },
      clone() {
        return {
          body: {
            getReader() {
              return {
                read() {
                  if (currentReq === 1) {
                    return new Promise((resolve) => {
                      op1ReadResolve = resolve;
                    });
                  }
                  if (currentReq === 2) {
                    op2ReadCount++;
                    if (op2ReadCount === 1) {
                      return new Promise((resolve) => {
                        op2ReadResolve = resolve;
                      });
                    }
                    return Promise.resolve({ done: true, value: undefined });
                  }
                  return Promise.resolve({ done: true, value: undefined });
                },
                async cancel() {
                  if (currentReq === 1) op1ReaderCancel = true;
                },
              };
            },
          },
        };
      },
    };
  };

  const { context, interceptor, coordinator } = makeInterceptorContext({
    fetch: mockFetch,
  });

  // 1. 启动 Op 1 并使其挂在 reader.read()
  context.fetch("https://api.example.com/req_1.json");
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(interceptor.getMetrics().activeFrameSniffCount, 1);

  // 2. SPA 换代触发 cancelAllActiveReaders()
  interceptor.cancelAllActiveReaders();
  assert.equal(op1ReaderCancel, true, "Op 1 的 reader 必须被取消");

  // 3. 立即启动 Op 2 并使其也处于在途读取状态
  context.fetch("https://api.example.com/req_2.json");
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(interceptor.getMetrics().activeFrameSniffCount, 2, "Op 1 尚未走出 finally，Op 2 处于在途，计数真实反映 2 个活跃 token");

  // 4. 此时 Op 1 走出循环进入 finally 并退出
  if (op1ReadResolve) {
    op1ReadResolve({ done: true, value: undefined });
  }
  await new Promise((r) => setTimeout(r, 30));

  // 验证反事实保护：Op 1 的 finally 绝不能把 Op 2 的活跃计数误减为 0！
  assert.equal(interceptor.getMetrics().activeFrameSniffCount, 1, "Op 1 退出后，Op 2 依然保持 1 个活跃计数，绝不被误减归零");

  // 5. Op 2 完成退出
  if (op2ReadResolve) {
    op2ReadResolve({ done: false, value: new Uint8Array(1024) });
  }
  await new Promise((r) => setTimeout(r, 30));

  assert.equal(interceptor.getMetrics().activeFrameSniffCount, 0, "Op 2 随后完成，活跃计数最终真实归零");
  assert.ok(interceptor.getMetrics().activeFrameSniffCount <= 2, "任何时刻实际活跃计数严格不超过并发上限 2");
});

test("Body Sniff: Reset 竞态保护 (请求使 Coordinator reserved > 0 -> Reset -> 晚到 Grant 到达后立即释放)", async () => {
  let cloneCancelled = false;

  const mockFetch = async () => ({
    url: "https://api.example.com/reset_race.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      return {
        body: {
          cancel() {
            cloneCancelled = true;
          },
          getReader() {
            return {
              async read() {
                return { done: true, value: undefined };
              },
              async cancel() {},
            };
          },
        },
      };
    },
  });

  const coordinator = new SniffBudgetCoordinator({ maxPageBudget: 2 * 1024 * 1024 });
  let savedMsg = null;
  let savedLease = null;

  const { context, interceptor, messages, dispatchMessage } = makeInterceptorContext({
    fetch: mockFetch,
    coordinator,
    grantModifier: (realLease, msg) => {
      savedLease = realLease;
      savedMsg = msg;
      // 模拟延迟响应：不立即发送 grant
      return null;
    },
  });

  // 1. 发起 fetch 请求
  context.fetch("https://api.example.com/reset_race.json");
  await new Promise((r) => setTimeout(r, 20));

  assert.ok(savedLease, "Background 已成功分配 lease");
  assert.ok(coordinator.getPageSnapshot(1, 1).reservedBytes > 0, "Coordinator 必须已处于 reserved > 0 状态");

  // 2. 在 Grant 返回前发生 SPA 导航或 reset
  interceptor.cancelAllActiveReaders();

  // 确认 clone 立即被 cancel
  assert.equal(cloneCancelled, true, "Reset 发生后必须立即 cancel clone body");

  // 3. 随后 Background 的 Grant 晚到并到达 MAIN 拦截器
  dispatchMessage({
    type: "macidm.grantSniffLease",
    requestId: savedMsg.requestId,
    leaseId: savedLease.leaseId,
    grantedBytes: savedLease.grantedBytes,
  });

  await new Promise((r) => setTimeout(r, 20));

  // 4. 验证生产 interceptor 捕获了晚到 grant 并发出 releaseSniffLease 消息
  const releaseMsg = messages.find(
    (m) => m.type === "macidm.releaseSniffLease" && m.leaseId === savedLease.leaseId,
  );
  assert.ok(releaseMsg, "Reset 后晚到的 grant 必须被生产拦截器捕获并释放");
  assert.equal(releaseMsg.reason, "late_after_reset");

  // 5. Coordinator 状态必须立即归零，而无需等待 30s TTL
  const snap = coordinator.getPageSnapshot(1, 1);
  assert.equal(snap.reservedBytes, 0, "Coordinator reserved 必须立即归零");
  assert.equal(snap.activeLeasesCount, 0);
  assert.equal(snap.usedBytes, 0);
});

test("Body Sniff: stream.cancel() 返回 rejected Promise 时被安全吸收，不产生 unhandledRejection 且租约收敛", async () => {
  const unhandledRejections = [];
  const onUnhandled = (err) => {
    unhandledRejections.push(err);
  };
  process.on("unhandledRejection", onUnhandled);

  try {
    const mockFetch = async () => ({
      url: "https://api.example.com/reject_cancel.json",
      headers: {
        get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
      },
      clone() {
        return {
          body: {
            cancel() {
              return Promise.reject(new Error("clone body cancel rejected"));
            },
            getReader() {
              return {
                async read() {
                  return { done: true, value: undefined };
                },
                cancel() {
                  return Promise.reject(new Error("reader cancel rejected"));
                },
              };
            },
          },
        };
      },
    });

    const coordinator = new SniffBudgetCoordinator();
    const { context, interceptor } = makeInterceptorContext({
      fetch: mockFetch,
      coordinator,
    });

    await context.fetch("https://api.example.com/reject_cancel.json");
    await new Promise((r) => setTimeout(r, 40));

    // 触发 cancelAllActiveReaders
    interceptor.cancelAllActiveReaders();
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(
      unhandledRejections.length,
      0,
      "stream cancel 的异步拒绝必须被 safeCancelStream 吸收，绝不得产生 unhandledRejection",
    );

    const snap = coordinator.getPageSnapshot(1, 1);
    assert.equal(snap.reservedBytes, 0, "租约必须正常收敛释放");
    assert.equal(snap.activeLeasesCount, 0);
  } finally {
    process.removeListener("unhandledRejection", onUnhandled);
  }
});

test("Body Sniff: Metrics 准确性 (pending 阶段 activeReadersCount = 0，读取阶段 = 1，结束后 = 0)", async () => {
  let finishRead = null;
  const mockFetch = async () => ({
    url: "https://api.example.com/metrics_test.json",
    headers: {
      get: (name) => (name.toLowerCase() === "content-type" ? "application/json" : null),
    },
    clone() {
      let readCount = 0;
      return {
        body: {
          getReader() {
            return {
              async read() {
                readCount++;
                if (readCount === 1) {
                  await new Promise((resolve) => {
                    finishRead = resolve;
                  });
                  return { done: false, value: new Uint8Array(512) };
                }
                return { done: true, value: undefined };
              },
              async cancel() {},
            };
          },
        },
      };
    },
  });

  let savedMsg = null;
  let savedLease = null;
  const { context, interceptor, dispatchMessage } = makeInterceptorContext({
    fetch: mockFetch,
    grantModifier: (realLease, msg) => {
      savedLease = realLease;
      savedMsg = msg;
      return null; // 延迟 grant
    },
  });

  // 1. 发起 fetch 请求，此时处于 pending lease 阶段
  context.fetch("https://api.example.com/metrics_test.json");
  await new Promise((r) => setTimeout(r, 20));

  let m = interceptor.getMetrics();
  assert.equal(m.activeFrameSniffCount, 1, "处于在途 operation");
  assert.equal(m.pendingRequestsCount, 1, "正在申请 lease");
  assert.equal(m.activeReadersCount, 0, "尚未拿到 lease / 尚未创建 reader，activeReadersCount 必须为 0");

  // 2. 下发 grant 进入真正读取阶段
  dispatchMessage({
    type: "macidm.grantSniffLease",
    requestId: savedMsg.requestId,
    leaseId: savedLease.leaseId,
    grantedBytes: savedLease.grantedBytes,
  });
  await new Promise((r) => setTimeout(r, 20));

  m = interceptor.getMetrics();
  assert.equal(m.activeFrameSniffCount, 1);
  assert.equal(m.pendingRequestsCount, 0, "grant 已决议");
  assert.equal(m.activeReadersCount, 1, "真正持有 reader 正在读取，activeReadersCount 必须为 1");

  // 3. 完成读取
  if (finishRead) finishRead();
  await new Promise((r) => setTimeout(r, 30));

  m = interceptor.getMetrics();
  assert.equal(m.activeFrameSniffCount, 0);
  assert.equal(m.pendingRequestsCount, 0);
  assert.equal(m.activeReadersCount, 0, "读取完成后 activeReadersCount 必须真实归零");
});
