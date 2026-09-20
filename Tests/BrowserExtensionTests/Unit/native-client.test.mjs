import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import { NativeClient } from "../../../BrowserExtension/chrome/src/background/native-client.js";
import { ProtocolError } from "../../../BrowserExtension/chrome/src/shared/protocol.js";

globalThis.crypto ??= webcrypto;

test("late native responses after timeout are ignored and cannot settle a new request", async () => {
  const messageListeners = [];
  const posted = [];
  const port = {
    onMessage: { addListener(listener) { messageListeners.push(listener); } },
    onDisconnect: { addListener() {} },
    postMessage(request) { posted.push(request); },
  };
  const client = new NativeClient({ connectNative: () => port });
  const request = {
    protocolVersion: 1,
    requestId: crypto.randomUUID(),
    idempotencyKey: "test:late-response",
    type: "download.create",
    payload: {},
  };

  await assert.rejects(client.send(request, 5), (error) => {
    assert.ok(error instanceof ProtocolError);
    assert.equal(error.code, "TAKEOVER_TIMEOUT");
    return true;
  });
  assert.equal(client.pending.size, 0);
  assert.equal(posted.length, 1);

  messageListeners[0]({
    protocolVersion: 1,
    requestId: request.requestId,
    status: "ok",
    type: "download.readyForTakeover",
    payload: { taskId: crypto.randomUUID(), takeoverToken: "late-token" },
  });
  assert.equal(client.pending.size, 0);
});

test("accurately classifies timeout error codes per request type", async () => {
  const messageListeners = [];
  const port = {
    onMessage: { addListener(listener) { messageListeners.push(listener); } },
    onDisconnect: { addListener() {} },
    postMessage() {},
  };
  const client = new NativeClient({ connectNative: () => port });

  const testCases = [
    { type: "ping", expectedCode: "PING_TIMEOUT" },
    { type: "app.activate", expectedCode: "ACTIVATE_TIMEOUT" },
    { type: "media.inspect", expectedCode: "INSPECT_TIMEOUT" },
    { type: "download.enqueue", expectedCode: "ENQUEUE_TIMEOUT" },
    { type: "download.create", expectedCode: "TAKEOVER_TIMEOUT" },
    { type: "download.abandon", expectedCode: "ABANDON_TIMEOUT" },
    { type: "download.browserCancelled", expectedCode: "ACK_TIMEOUT" },
    { type: "download.browserCancelFailed", expectedCode: "ACK_TIMEOUT" },
    { type: "downloadAll.scan", expectedCode: "SCAN_TIMEOUT" },
    { type: "unknown.type", expectedCode: "REQUEST_TIMEOUT" },
  ];

  for (const { type, expectedCode } of testCases) {
    const req = {
      protocolVersion: 1,
      requestId: crypto.randomUUID(),
      type,
      payload: {},
    };
    await assert.rejects(client.send(req, 5), (error) => {
      assert.ok(error instanceof ProtocolError);
      assert.equal(error.code, expectedCode);
      return true;
    });
  }
});

test("handles concurrent requests with independent completions and timeouts", async () => {
  let messageListener = null;
  const posted = [];
  const port = {
    onMessage: { addListener(listener) { messageListener = listener; } },
    onDisconnect: { addListener() {} },
    postMessage(req) { posted.push(req); },
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();

  const reqFast = {
    protocolVersion: 1,
    requestId: "req-fast",
    type: "media.inspect",
    payload: {},
  };
  const reqSlow = {
    protocolVersion: 1,
    requestId: "req-slow",
    type: "download.enqueue",
    payload: {},
  };

  const pFast = client.send(reqFast, 500);
  const slowPromise = assert.rejects(client.send(reqSlow, 10), (error) => {
    assert.ok(error instanceof ProtocolError);
    assert.equal(error.code, "ENQUEUE_TIMEOUT");
    return true;
  });

  // Fast response arrives before timeout
  messageListener({
    protocolVersion: 1,
    requestId: "req-fast",
    status: "ok",
    type: "media.inspected",
    payload: { variants: [{ label: "1080P" }] },
  });

  const resFast = await pFast;
  assert.equal(resFast.requestId, "req-fast");
  assert.equal(resFast.type, "media.inspected");

  await slowPromise;
  assert.equal(client.pending.size, 0);
});

test("port disconnect rejects all pending requests and resets client state", async () => {
  let disconnectListener = null;
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener(listener) { disconnectListener = listener; } },
    postMessage() {},
  };
  const client = new NativeClient({
    connectNative: () => port,
    lastError: { message: "Native host died" },
  });

  await client.connect();

  const req1 = { protocolVersion: 1, requestId: "req-1", type: "ping", payload: {} };
  const req2 = { protocolVersion: 1, requestId: "req-2", type: "media.inspect", payload: {} };

  const p1 = client.send(req1, 5000);
  const p2 = client.send(req2, 5000);

  assert.equal(client.pending.size, 2);
  assert.equal(client.state, "connected");

  disconnectListener();

  await assert.rejects(p1, (error) => {
    assert.ok(error instanceof ProtocolError);
    assert.equal(error.code, "NATIVE_HOST_NOT_FOUND");
    return true;
  });
  await assert.rejects(p2, (error) => {
    assert.ok(error instanceof ProtocolError);
    assert.equal(error.code, "NATIVE_HOST_NOT_FOUND");
    return true;
  });

  assert.equal(client.pending.size, 0);
  assert.equal(client.state, "disconnected");
  assert.equal(client.port, null);
});

test("hasPendingNonPingRequests accurately tracks in-flight non-ping operations", async () => {
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener() {} },
    postMessage() {},
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();

  assert.equal(client.hasPendingNonPingRequests(), false);

  const pPing = client.send({ protocolVersion: 1, requestId: "ping-1", type: "ping", payload: {} }, 500);
  // Only ping is pending
  assert.equal(client.hasPendingNonPingRequests(), false);

  const pInspect = client.send({ protocolVersion: 1, requestId: "inspect-1", type: "media.inspect", payload: {} }, 500);
  // media.inspect is pending
  assert.equal(client.hasPendingNonPingRequests(), true);

  // Clean up
  client.receive({ protocolVersion: 1, requestId: "inspect-1", status: "ok", type: "media.inspected", payload: { variants: [] } });
  await pInspect;
  assert.equal(client.hasPendingNonPingRequests(), false);

  client.receive({ protocolVersion: 1, requestId: "ping-1", status: "ok", type: "pong", payload: {} });
  await pPing;
  assert.equal(client.hasPendingNonPingRequests(), false);
});

test("非 ping 请求调用方超时后仍保持 busy，迟到响应只清 busy 不二次 settle 且不污染新请求", async () => {
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener() {} },
    postMessage() {},
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();

  // Send a media.inspect request with a 50ms timeout
  const pInspect = client.send({ protocolVersion: 1, requestId: "inspect-late", type: "media.inspect", payload: {} }, 50);

  // The caller's promise is rejected on timeout
  await assert.rejects(pInspect, (err) => {
    assert.equal(err.code, "INSPECT_TIMEOUT");
    return true;
  });

  // The caller's promise is gone after the timeout, but the native host may
  // still be processing, so isHostBusy must be true!
  assert.equal(client.isHostBusy(), true, "调用方超时后，原生主机仍处于 in-flight 忙碌状态");
  assert.equal(client.hasPendingNonPingRequests(), true);

  // Now the late response arrives (the App finished processing and replied)
  assert.doesNotThrow(() => {
    client.receive({
      protocolVersion: 1,
      requestId: "inspect-late",
      status: "ok",
      type: "media.inspected",
      payload: { variants: [{ label: "1080P" }] },
    });
  }, "迟到响应绝不能抛出异常或二次 settle 已超时的 promise");

  // 迟到响应到达后，忙碌状态立即被清除
  assert.equal(client.isHostBusy(), false, "迟到响应到达后，主机忙碌状态必须解除");

  // 发送新请求，确认管道未被旧请求状态污染
  const pNext = client.send({ protocolVersion: 1, requestId: "inspect-next", type: "media.inspect", payload: {} }, 500);
  assert.equal(client.isHostBusy(), true);
  client.receive({
    protocolVersion: 1,
    requestId: "inspect-next",
    status: "ok",
    type: "media.inspected",
    payload: { variants: [{ label: "720P" }] },
  });
  const res = await pNext;
  assert.equal(res.payload.variants[0].label, "720P");
  assert.equal(client.isHostBusy(), false);
});

test("Port disconnect 必须清空 in-flight 忙碌状态", async () => {
  let disconnectListener = null;
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener(l) { disconnectListener = l; } },
    postMessage() {},
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();

  const pInspect = client.send({ protocolVersion: 1, requestId: "inspect-disc", type: "media.inspect", payload: {} }, 5000);
  assert.equal(client.isHostBusy(), true);

  disconnectListener();

  await assert.rejects(pInspect, (err) => {
    assert.equal(err.code, "NATIVE_HOST_NOT_FOUND");
    return true;
  });

  assert.equal(client.isHostBusy(), false, "断开连接后必须清除所有 in-flight 忙碌标记");
});

test("硬上限清理：超过最大保留时限的 in-flight 请求自动过期清理", async () => {
  let currentTime = 1_000_000;
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener() {} },
    postMessage() {},
  };
  const client = new NativeClient({
    connectNative: () => port,
    clock: () => currentTime,
    hardInFlightTimeoutMs: 5000,
  });
  await client.connect();

  const pInspect = client.send({ protocolVersion: 1, requestId: "inspect-hard", type: "media.inspect", payload: {} }, 50);
  await assert.rejects(pInspect);

  // After 4 seconds, still under the 5-second hard cap
  currentTime += 4000;
  assert.equal(client.isHostBusy(), true);

  // After 6 seconds, past the 5-second hard cap; must be evicted automatically
  currentTime += 2000;
  assert.equal(client.isHostBusy(), false, "超过硬上限后自动淘汰丢弃的 in-flight 记录");
});

test("纯 ping 超时绝不能使主机判定为 busy", async () => {
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: { addListener() {} },
    postMessage() {},
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();

  const pPing = client.send({ protocolVersion: 1, requestId: "ping-fail", type: "ping", payload: {} }, 50);
  assert.equal(client.isHostBusy(), false, "发送 ping 时绝不能将主机标记为 busy");

  await assert.rejects(pPing, (err) => {
    assert.equal(err.code, "PING_TIMEOUT");
    return true;
  });

  assert.equal(client.isHostBusy(), false, "ping 超时后绝不能将主机判定为 busy");
});

test("activate() 发送 app.activate 用户主动唤醒请求并在响应到达时 resolve", async () => {
  let messageListener = null;
  const posted = [];
  const port = {
    onMessage: { addListener(listener) { messageListener = listener; } },
    onDisconnect: { addListener() {} },
    postMessage(req) { posted.push(req); },
  };
  const client = new NativeClient({ connectNative: () => port });
  await client.connect();
  const createRequest = (type, idempotencyKey, payload) => ({
    protocolVersion: 1,
    requestId: crypto.randomUUID(),
    idempotencyKey,
    type,
    payload,
  });

  const pending = client.activate(createRequest);
  assert.equal(posted.length, 1);
  assert.equal(posted[0].type, "app.activate");
  assert.ok(
    posted[0].idempotencyKey.startsWith("activate:"),
    "app.activate 使用独立的幂等键前缀，区别于 ping",
  );

  messageListener({
    protocolVersion: 1,
    requestId: posted[0].requestId,
    status: "ok",
    type: "app.activated",
    payload: { appVersion: "1.0.0" },
  });

  const response = await pending;
  assert.equal(response.type, "app.activated");
});
