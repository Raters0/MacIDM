import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import { DEFAULT_SETTINGS } from "../../../BrowserExtension/chrome/src/shared/constants.js";
import { ProtocolError } from "../../../BrowserExtension/chrome/src/shared/protocol.js";
import { TakeoverController } from "../../../BrowserExtension/chrome/src/background/takeover-controller.js";

globalThis.crypto ??= webcrypto;

function harness(nativeResponses, itemOverrides = {}, settings = { ...DEFAULT_SETTINGS, takeoverInteractive: false }) {
  const calls = [];
  const item = {
    id: 42,
    url: "https://example.com/archive.zip",
    filename: "/tmp/archive.zip",
    mime: "application/zip",
    totalBytes: 10 * 1024 * 1024,
    state: "in_progress",
    paused: false,
    ...itemOverrides,
  };
  let erased = false;
  const downloads = {
    async pause() {
      calls.push("pause");
      item.paused = true;
    },
    async search() {
      return erased ? [] : [item];
    },
    async cancel() {
      calls.push("cancel");
      item.state = "interrupted";
      item.error = "USER_CANCELED";
      item.paused = false;
    },
    async resume() {
      calls.push("resume");
      item.paused = false;
    },
    async erase() {
      calls.push("erase");
      erased = true;
    },
  };
  let session = {};
  const storage = {
    local: {
      async get(key) {
        return { [key]: session[key] };
      },
      async set(value) {
        session = { ...session, ...value };
      },
    },
  };
  const nativeClient = {
    async send(request) {
      calls.push(request.type);
      const next = nativeResponses.shift();
      if (next instanceof Error) throw next;
      return {
        protocolVersion: 1,
        requestId: request.requestId,
        status: "ok",
        ...next,
      };
    },
  };
  return {
    calls,
    controller: new TakeoverController({
      downloads,
      storage,
      nativeClient,
      settingsProvider: async () => settings,
    }),
    item,
    storage,
  };
}

test("download is paused first and only cancelled after the App task exists", async () => {
  const { calls, controller, item } = harness([
    {
      type: "download.readyForTakeover",
      payload: { taskId: crypto.randomUUID(), takeoverToken: "one-time-token" },
    },
    { type: "download.accepted", payload: {} },
  ]);

  await controller.handleCreated(item);

  // Spec §5.2 order: pause() freezes the download before any App traffic;
  // cancel() follows readyForTakeover; erase follows the successful ack.
  assert.deepEqual(calls, [
    "pause",
    "download.create",
    "cancel",
    "download.browserCancelled",
    "erase",
  ]);
});

test("create timeout resumes the paused download and abandons the partial task", async () => {
  const { calls, controller, item } = harness([
    new ProtocolError("TAKEOVER_TIMEOUT", "timeout", true),
  ]);

  await assert.rejects(controller.handleCreated(item), /timeout/u);

  // Spec §5.2: the browser download was only paused, never cancelled, so
  // the compensation is a plain resume — nothing needs to be recreated.
  assert.deepEqual(calls, [
    "pause",
    "download.create",
    "download.abandon",
    "resume",
  ]);
});

test("create timeout leaves an abandon marker when compensation also times out", async () => {
  const responses = [
    new ProtocolError("TAKEOVER_TIMEOUT", "timeout", true),
    new ProtocolError("ABANDON_TIMEOUT", "timeout", true),
    new ProtocolError("ABANDON_TIMEOUT", "timeout", true),
    new ProtocolError("ABANDON_TIMEOUT", "timeout", true),
  ];
  const { calls, controller, item, storage } = harness(responses);

  await assert.rejects(controller.handleCreated(item), /timeout/u);

  assert.deepEqual(calls, [
    "pause",
    "download.create",
    "download.abandon",
    "download.abandon",
    "download.abandon",
    "resume",
  ]);
  const stored = await storage.local.get("pendingTakeovers");
  assert.deepEqual(stored.pendingTakeovers, [
    {
      downloadId: 42,
      idempotencyKey: "test-profile:download-42",
      phase: "abandonPending",
    },
  ]);
});

test("recovery re-evaluates disabled takeover settings and resumes Chrome", async () => {
  const settings = { ...DEFAULT_SETTINGS, takeoverEnabled: false };
  const { calls, controller, item, storage } = harness([], { paused: true }, settings);
  await storage.local.set({
    pendingTakeovers: [
      { downloadId: 42, idempotencyKey: "test-profile:download-42", phase: "observed" },
    ],
  });

  await controller.recoverPending();

  assert.deepEqual(calls, ["download.abandon", "resume"]);
  const stored = await storage.local.get("pendingTakeovers");
  assert.deepEqual(stored.pendingTakeovers, []);
});

test("cancelled Chrome download keeps a non-secret recovery marker until App acknowledges", async () => {
  const responses = [
    {
      type: "download.readyForTakeover",
      payload: { taskId: crypto.randomUUID(), takeoverToken: "one-time-token" },
    },
    new ProtocolError("APP_START_TIMEOUT", "offline", true),
    new ProtocolError("APP_START_TIMEOUT", "offline", true),
    new ProtocolError("APP_START_TIMEOUT", "offline", true),
  ];
  const { calls, controller, item, storage } = harness(responses);

  await assert.rejects(controller.handleCreated(item), /等待恢复/u);

  const stored = await storage.local.get("pendingTakeovers");
  assert.deepEqual(stored.pendingTakeovers, [
    {
      downloadId: 42,
      idempotencyKey: "test-profile:download-42",
      phase: "browserCancelled",
    },
  ]);
  assert.equal(calls.includes("resume"), false);
  assert.equal(calls.filter((call) => call === "download.browserCancelled").length, 3);
  // Keep the interrupted Chrome record so recovery can replay the receipt.
  assert.deepEqual(calls.slice(0, 4), ["pause", "download.create", "cancel", "download.browserCancelled"]);
  assert.equal(calls.includes("erase"), false);
});

test("non-retryable App errors are not retried after Chrome cancellation", async () => {
  const { calls, controller, item, storage } = harness([
    {
      type: "download.readyForTakeover",
      payload: { taskId: crypto.randomUUID(), takeoverToken: "one-time-token" },
    },
    new ProtocolError("TAKEOVER_CONFLICT", "destination is reserved"),
  ]);

  await assert.rejects(controller.handleCreated(item), /等待恢复/u);

  assert.equal(calls.filter((call) => call === "download.browserCancelled").length, 1);
  assert.equal(calls.includes("resume"), false);
  assert.deepEqual(calls.slice(0, 4), ["pause", "download.create", "cancel", "download.browserCancelled"]);
  assert.equal(calls.includes("erase"), false);
  const stored = await storage.local.get("pendingTakeovers");
  assert.deepEqual(stored.pendingTakeovers, [
    {
      downloadId: 42,
      idempotencyKey: "test-profile:download-42",
      phase: "browserCancelled",
    },
  ]);
});

test("download metadata changes trigger a later takeover decision", async () => {
  // Disable takeoverAllDownloads so file-type/size checks are active; this
  // test verifies that an incomplete download item is deferred until its
  // filename and size become known.
  const settings = { ...DEFAULT_SETTINGS, takeoverAllDownloads: false, takeoverInteractive: false };
  const { calls, controller, item } = harness(
    [
      {
        type: "download.readyForTakeover",
        payload: { taskId: crypto.randomUUID(), takeoverToken: "one-time-token" },
      },
      { type: "download.accepted", payload: {} },
    ],
    { filename: "", totalBytes: -1 },
    settings,
  );

  await controller.handleCreated(item);
  assert.deepEqual(calls, []);

  item.filename = "/tmp/Docker.dmg";
  item.totalBytes = DEFAULT_SETTINGS.minimumBytes + 1;
  await controller.handleChanged(42, { filename: { current: item.filename }, totalBytes: { current: item.totalBytes } });

  assert.deepEqual(calls, [
    "pause",
    "download.create",
    "cancel",
    "download.browserCancelled",
    "erase",
  ]);
});

test("unknown Chrome size is not forwarded as a real Content-Length", async () => {
  const { controller, item } = harness([]);
  // Chrome reports 0 (and -1) while the size is still unknown; neither may
  // ride along as a real Content-Length or the App renders a confident
  // "0 KB" for a size nobody knows.
  for (const unknown of [0, -1]) {
    item.totalBytes = unknown;
    const payload = await controller.createPayload(item);
    assert.equal(payload.totalBytes, undefined);
  }
  // A real size still passes through untouched.
  item.totalBytes = 25 * 1024 * 1024;
  const payload = await controller.createPayload(item);
  assert.equal(payload.totalBytes, 25 * 1024 * 1024);
});

test("takeover payload marks the filename as browser-resolved", async () => {
  // 命名可信度模型（技术规范 §8.1）：接管链路的 filenameHint 来自 Chrome
  // 解析的下载项文件名（尊重 Content-Disposition），必须标注为权威来源，
  // App 侧才允许它压过标签页标题。
  const { controller, item } = harness([]);
  const payload = await controller.createPayload(item);
  assert.equal(payload.filenameHint, "archive.zip");
  assert.equal(payload.filenameHintSource, "browserResolved");
});

test("interactive takeover passes the browser's Content-Length to the confirmation window", async () => {
  const requests = [];
  const item = {
    id: 77,
    url: "https://cdn.example.com/report.pdf?sig=abc",
    finalUrl: "https://cdn.example.com/report.pdf?sig=abc",
    filename: "",
    mime: "application/pdf",
    totalBytes: 25 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const downloads = {
    async pause() { item.paused = true; },
    async search() { return [item]; },
    async cancel() { item.state = "interrupted"; item.paused = false; },
    async resume() { item.paused = false; },
    async erase() {},
  };
  let session = {};
  const storage = {
    local: {
      async get(key) { return { [key]: session[key] }; },
      async set(value) { session = { ...session, ...value }; },
    },
  };
  const nativeClient = {
    async send(request) {
      requests.push(request);
      if (request.type === "download.enqueue" && request.payload?.interactive) {
        return {
          protocolVersion: 1,
          requestId: request.requestId,
          status: "ok",
          type: "download.readyForTakeover",
          payload: { taskId: crypto.randomUUID(), takeoverToken: "confirmed-token" },
        };
      }
      return { protocolVersion: 1, requestId: request.requestId, status: "ok", type: "download.accepted", payload: {} };
    },
  };
  const controller = new TakeoverController({
    downloads,
    storage,
    nativeClient,
    settingsProvider: async () => DEFAULT_SETTINGS,
  });

  await controller.handleCreated(item);

  const enqueue = requests.find((request) => request.payload?.interactive === true);
  assert.ok(enqueue, "expected an interactive download.enqueue request");
  // The browser has received response headers, so totalBytes is the real
  // size: the confirmation window no longer shows "size unknown", and the
  // takeover payload must pass the value through.
  assert.equal(enqueue.payload.totalBytes, item.totalBytes);
});

// Shared harness for notification-focused scenarios: the downloads/storage
// stubs and controller wiring are identical across success and failure paths;
// only the nativeClient behavior and the item differ.
function makeNotificationScenario({ item, send }) {
  const notifications = [];
  const downloads = {
    async pause() { item.paused = true; },
    async search() { return [item]; },
    async cancel() { item.state = "interrupted"; item.paused = false; },
    async resume() { item.paused = false; },
    async erase() {},
  };
  let session = {};
  const storage = {
    local: {
      async get(key) { return { [key]: session[key] }; },
      async set(value) { session = { ...session, ...value }; },
    },
  };
  const controller = new TakeoverController({
    downloads,
    storage,
    nativeClient: { send },
    settingsProvider: async () => DEFAULT_SETTINGS,
    notifier: (title, message) => notifications.push({ title, message }),
  });
  return { controller, notifications };
}

test("takeover success notification strips signed-URL query from filename", async () => {
  const item = {
    id: 99,
    url: "https://cdn.example.com/file.zip?token=secret-token&expires=9999",
    finalUrl: "https://cdn.example.com/file.zip?token=secret-token&expires=9999",
    filename: "",
    mime: "application/zip",
    totalBytes: 10 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const { controller, notifications } = makeNotificationScenario({
    item,
    send: async (request) => {
      if (request.type === "download.enqueue" && request.payload?.interactive) {
        return {
          protocolVersion: 1,
          requestId: request.requestId,
          status: "ok",
          type: "download.readyForTakeover",
          payload: { taskId: crypto.randomUUID(), takeoverToken: "confirmed-token" },
        };
      }
      if (request.type === "download.create") {
        return {
          protocolVersion: 1,
          requestId: request.requestId,
          status: "ok",
          type: "download.readyForTakeover",
          payload: { taskId: crypto.randomUUID(), takeoverToken: "tok" },
        };
      }
      return { protocolVersion: 1, requestId: request.requestId, status: "ok", type: "download.accepted", payload: {} };
    },
  });

  await controller.handleCreated(item);

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].title, "已交给 MacIDM 下载");
  // The query string (including the signed token) must not appear in the
  // notification message — only the bare basename should be shown.
  assert.equal(notifications[0].message.includes("?"), false);
  assert.equal(notifications[0].message.includes("token"), false);
  assert.equal(notifications[0].message, "file.zip");
});

test("takeover failure notification also strips signed-URL query", async () => {
  const item = {
    id: 100,
    url: "https://cdn.example.com/report.pdf?sig=abc123",
    finalUrl: "https://cdn.example.com/report.pdf?sig=abc123",
    filename: "",
    mime: "application/pdf",
    totalBytes: 10 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const { controller, notifications } = makeNotificationScenario({
    item,
    send: async () => {
      throw new ProtocolError("TAKEOVER_TIMEOUT", "timeout", true);
    },
  });

  await assert.rejects(controller.handleCreated(item), /timeout/u);

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].message.includes("?"), false);
  assert.equal(notifications[0].message.includes("sig"), false);
  assert.ok(notifications[0].message.includes("report.pdf"));
});


test("cancel failure after task creation reports browserCancelFailed and keeps the download", async () => {
  const calls = [];
  const item = {
    id: 55,
    url: "https://example.com/tool.dmg",
    finalUrl: "https://example.com/tool.dmg",
    filename: "/tmp/tool.dmg",
    mime: "application/x-apple-diskimage",
    totalBytes: 8 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const storage = {
    local: {
      async get(key) { return {}; },
      async set() {},
    },
  };
  const controller = new TakeoverController({
    downloads: {
      async pause() { calls.push("pause"); item.paused = true; },
      async search() { return [item]; },
      async cancel() { calls.push("cancel"); throw new Error("download completed"); },
      async resume() { calls.push("resume"); },
      async erase() { calls.push("erase"); },
    },
    storage,
    nativeClient: {
      async send(request) {
        calls.push(request.type);
        if (request.type === "download.create") {
          return {
            protocolVersion: 1,
            requestId: request.requestId,
            status: "ok",
            type: "download.readyForTakeover",
            payload: { taskId: crypto.randomUUID(), takeoverToken: "tok-55" },
          };
        }
        return { protocolVersion: 1, requestId: request.requestId, status: "ok", type: "download.conflictRecorded", payload: {} };
      },
    },
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
  });

  // Chrome refused the cancel after the App task exists: the spec §5.2
  // response is download.browserCancelFailed (App marks takeoverConflict),
  // never a silent recreate of the browser download.
  await controller.handleCreated(item);

  assert.deepEqual(calls, [
    "pause",
    "download.create",
    "cancel",
    "download.browserCancelFailed",
    "download.abandon",
    "resume",
  ]);
  assert.equal(calls.includes("erase"), false, "erase must not run when cancel failed");
  assert.equal(calls.includes("resume"), true, "failed cancellation must resume the paused browser download");
});

test("browserCancelFailed carries the task identity and a stable error code", async () => {
  const requests = [];
  const item = {
    id: 56,
    url: "https://example.com/tool.dmg",
    finalUrl: "https://example.com/tool.dmg",
    filename: "/tmp/tool.dmg",
    mime: "application/x-apple-diskimage",
    totalBytes: 8 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const controller = new TakeoverController({
    downloads: {
      async pause() { item.paused = true; },
      async search() { return [item]; },
      async cancel() { throw new Error("download completed"); },
      async resume() {},
      async erase() {},
    },
    storage: { local: { async get() { return {}; }, async set() {} } },
    nativeClient: {
      async send(request) {
        requests.push(request);
        if (request.type === "download.create") {
          return {
            protocolVersion: 1,
            requestId: request.requestId,
            status: "ok",
            type: "download.readyForTakeover",
            payload: { taskId: "task-56", takeoverToken: "tok-56" },
          };
        }
        return { protocolVersion: 1, requestId: request.requestId, status: "ok", type: "download.conflictRecorded", payload: {} };
      },
    },
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
  });

  await controller.handleCreated(item);

  const failure = requests.find((request) => request.type === "download.browserCancelFailed");
  assert.ok(failure, "expected a download.browserCancelFailed request");
  assert.equal(failure.payload.taskId, "task-56");
  assert.equal(failure.payload.takeoverToken, "tok-56");
  assert.equal(failure.payload.browserDownloadId, 56);
  assert.ok(failure.payload.errorCode, "expected a stable error code");
});

test("worker restart recovers ACK using the retained interrupted Chrome record", async () => {
  const ready = { type: "download.readyForTakeover", payload: { taskId: crypto.randomUUID(), takeoverToken: "token" } };
  const responses = [ready, ...Array.from({ length: 3 }, () => new ProtocolError("OFFLINE", "offline", true))];
  const { controller, item, calls, storage } = harness(responses);
  await assert.rejects(controller.handleCreated(item));
  assert.equal((await controller.downloads.search({ id: item.id })).length, 1);
  responses.push(ready, { type: "download.accepted" });
  const restarted = new TakeoverController({
    downloads: controller.downloads, storage, nativeClient: controller.nativeClient,
    settingsProvider: controller.settingsProvider,
  });
  await restarted.recoverPending();
  assert.deepEqual(calls.slice(-3), ["download.create", "download.browserCancelled", "erase"]);
  assert.equal((await controller.downloads.search({ id: item.id })).length, 0);
  assert.deepEqual((await storage.local.get("pendingTakeovers")).pendingTakeovers, []);
});

test("cancel intent survives worker death before browserCancelled phase write", async () => {
  const ready = { type: "download.readyForTakeover", payload: { taskId: crypto.randomUUID(), takeoverToken: "token" } };
  const { controller, calls, storage } = harness([ready, { type: "download.accepted" }], {
    state: "interrupted", error: "USER_CANCELED",
  });
  await storage.local.set({ pendingTakeovers: [{ downloadId: 42, idempotencyKey: "test-profile:download-42", phase: "cancellingBrowser" }] });
  await controller.recoverPending();
  assert.deepEqual(calls, ["download.create", "download.browserCancelled", "erase"]);
});

test("missing cancelled item coordinates abandonment and retains explicit failure marker", async () => {
  const { controller, item, storage, calls } = harness([{ type: "download.abandoned" }]);
  await controller.downloads.erase({ id: item.id });
  await controller.remember(item.id, "test-profile:download-42");
  await controller.markPhase(item.id, "browserCancelled");
  const notices = [];
  controller.notifier = (...args) => notices.push(args);
  await controller.recoverPending();
  assert.equal(notices.length, 1);
  assert.ok(calls.includes("download.abandon"));
  assert.equal((await storage.local.get("pendingTakeovers")).pendingTakeovers[0].phase, "receiptUnavailable");
});

test("interactive draft receipt never cancels Chrome before confirmation", async () => {
  const responses = [
    { type: "download.confirmationPending" },
    { type: "download.readyForTakeover", payload: { taskId: crypto.randomUUID(), takeoverToken: "token" } },
    { type: "download.accepted" },
  ];
  const { controller, item, calls } = harness(responses, {}, DEFAULT_SETTINGS);
  const running = controller.handleCreated(item);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(item.paused, true);
  assert.equal(calls.includes("cancel"), false);
  await running;
  assert.deepEqual(calls, ["pause", "download.enqueue", "download.enqueue", "cancel", "download.browserCancelled", "erase"]);
});

test("interactive cancel or timeout resumes Chrome without silent create", async () => {
  for (const code of ["TAKEOVER_ABANDONED", "TAKEOVER_TIMEOUT"]) {
    const { controller, item, calls } = harness([new ProtocolError(code, "confirmation ended"), { type: "download.abandoned" }], {}, DEFAULT_SETTINGS);
    await assert.rejects(controller.handleCreated(item));
    assert.equal(calls.includes("download.create"), false);
    assert.equal(calls.includes("cancel"), false);
    assert.equal(item.paused, false);
  }
});

test("concurrent marker writes retain both downloads", async () => {
  const { controller, storage } = harness([]);
  await Promise.all([controller.remember(1, "key-1"), controller.remember(2, "key-2")]);
  await Promise.all([controller.markPhase(1, "browserCancelled"), controller.forget(2)]);
  assert.deepEqual((await storage.local.get("pendingTakeovers")).pendingTakeovers, [
    { downloadId: 1, idempotencyKey: "key-1", phase: "browserCancelled" },
  ]);
});

test("erase failure retries cleanup only after an idempotent ACK replay", async () => {
  const ready = { type: "download.readyForTakeover", payload: { taskId: crypto.randomUUID(), takeoverToken: "token" } };
  const { controller, item, calls, storage } = harness([ready, { type: "download.accepted" }, ready, { type: "download.accepted" }]);
  const erase = controller.downloads.erase;
  let fail = true;
  controller.downloads.erase = async (...args) => {
    if (fail) { fail = false; throw new Error("erase failed"); }
    return erase(...args);
  };
  await assert.rejects(controller.handleCreated(item));
  await controller.recoverPending();
  assert.equal(calls.filter((call) => call === "cancel").length, 1);
  assert.equal(calls.includes("resume"), false);
  assert.deepEqual((await storage.local.get("pendingTakeovers")).pendingTakeovers, []);
});

test("completed and unrelated interrupted items never receive a successful cancellation ACK", async () => {
  for (const state of ["complete", "interrupted"]) {
    const { controller, storage, calls } = harness([{ type: "download.abandoned" }], { state, error: "NETWORK_FAILED" });
    await controller.remember(42, "key");
    await controller.markPhase(42, "cancellingBrowser");
    await controller.recoverPending();
    assert.equal(calls.includes("download.browserCancelled"), false);
    assert.ok(calls.includes("download.abandon"));
    assert.deepEqual((await storage.local.get("pendingTakeovers")).pendingTakeovers, []);
  }
});

test("failed browser resume retains the compensation marker for another worker", async () => {
  const { controller, item, storage } = harness([new ProtocolError("OFFLINE", "offline"), { type: "download.abandoned" }]);
  const resume = controller.downloads.resume;
  controller.downloads.resume = async () => { throw new Error("resume failed"); };
  await assert.rejects(controller.handleCreated(item));
  assert.equal((await storage.local.get("pendingTakeovers")).pendingTakeovers[0].phase, "abandonPending");
  controller.downloads.resume = resume;
  await controller.recoverPending();
  assert.equal(item.paused, false);
  assert.deepEqual((await storage.local.get("pendingTakeovers")).pendingTakeovers, []);
});


test("user-cancel-with-browser-cancel cancels and erases instead of resuming", async () => {
  const { controller, item, calls } = harness([
    new ProtocolError("TAKEOVER_USER_CANCELLED_BROWSER", "user cancelled", false),
  ]);
  await assert.rejects(controller.handleCreated(item)).catch(() => {});
  // handleCreated returns (not throws) for this outcome.
  await controller.handleCreated(item).catch(() => {});
  assert.ok(calls.includes("cancel"), "browser download should be cancelled");
  assert.ok(calls.includes("erase"), "browser download record should be erased");
  assert.equal(calls.includes("resume"), false, "must not resume the browser download");
});

// ---------------------------------------------------------------------------
// Silent-skip diagnostics + connection-health reason mapping.
//
// Rationale: before these tests, handleCreated had three silent-return
// branches (non-http URL, non-GET URL, shouldTakeover=false) that never
// called the notifier, and notifyTakeoverResult collapsed every error code
// into a generic "takeover failed" reason. That made a chatgpt.com blob:
// download or a dead host look identical to a successful takeover from the
// user's perspective: nothing happened.
// ---------------------------------------------------------------------------

function makeSkipHarness({ url, finalUrl, nonGetURLs, clock }) {
  const notifications = [];
  const item = {
    id: 200,
    url,
    finalUrl: finalUrl ?? url,
    filename: "",
    mime: "application/octet-stream",
    totalBytes: 1024,
    state: "in_progress",
    paused: false,
  };
  const downloads = {
    async pause() { item.paused = true; },
    async search() { return [item]; },
    async cancel() {},
    async resume() {},
    async erase() {},
  };
  const storage = { local: { async get() { return {}; }, async set() {} } };
  const nativeClient = {
    async send() { throw new Error("native client must not be called on silent-skip paths"); },
  };
  const controller = new TakeoverController({
    downloads,
    storage,
    nativeClient,
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
    nonGetURLProvider: () => nonGetURLs ?? new Set(),
    notifier: (title, message) => notifications.push({ title, message }),
    clock: clock ?? (() => Date.now()),
  });
  return { controller, item, notifications };
}

test("blob: URL fires a one-shot unsupported-scheme diagnostic and never touches native", async () => {
  const { controller, item, notifications } = makeSkipHarness({
    url: "blob:https://chatgpt.com/1234-5678",
  });

  await controller.handleCreated(item);

  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].title, "MacIDM 接管未完成");
  assert.ok(
    notifications[0].message.includes("http(s)"),
    `expected unsupported-scheme copy, got: ${notifications[0].message}`,
  );
  assert.ok(
    notifications[0].message.includes("blob") || notifications[0].message.includes("浏览器内部资源"),
    `expected the copy to name the scheme class, got: ${notifications[0].message}`,
  );
});

test("data: URL is also treated as unsupported scheme", async () => {
  const { controller, item, notifications } = makeSkipHarness({
    url: "data:application/pdf;base64,JVBERi0xLjQK",
  });
  await controller.handleCreated(item);
  assert.equal(notifications.length, 1);
  assert.ok(notifications[0].message.includes("http(s)"));
});

test("POST-triggered download fires a non-GET diagnostic and skips takeover", async () => {
  const url = "https://chatgpt.com/backend-api/files/download";
  const { controller, item, notifications } = makeSkipHarness({
    url,
    nonGetURLs: new Set([url]),
  });

  await controller.handleCreated(item);

  assert.equal(notifications.length, 1);
  assert.ok(
    notifications[0].message.includes("POST"),
    `expected non-GET copy, got: ${notifications[0].message}`,
  );
  assert.ok(
    notifications[0].message.includes("请求体") || notifications[0].message.includes("body"),
    `expected the copy to name the lost-body rationale, got: ${notifications[0].message}`,
  );
});

test("skip notifications are throttled per reason code within 5 minutes", async () => {
  let now = 1_700_000_000_000;
  const { controller, notifications } = makeSkipHarness({
    url: "blob:https://chatgpt.com/a",
    clock: () => now,
  });

  // Two blob: downloads in quick succession → only one notification.
  await controller.handleCreated({ id: 1, url: "blob:https://chatgpt.com/a", state: "in_progress" });
  await controller.handleCreated({ id: 2, url: "blob:https://chatgpt.com/b", state: "in_progress" });
  assert.equal(notifications.length, 1, "second blob within the throttle window must not toast");

  // Advance past the throttle window → a fresh notification is allowed.
  now += 6 * 60 * 1_000;
  await controller.handleCreated({ id: 3, url: "blob:https://chatgpt.com/c", state: "in_progress" });
  assert.equal(notifications.length, 2, "after 5min the same reason may toast again");

  // A different reason code has its own bucket and is not throttled by
  // the previous unsupported-scheme notification.
  const postURL = "https://chatgpt.com/backend-api/files/download";
  controller.nonGetURLProvider = () => new Set([postURL]);
  await controller.handleCreated({ id: 4, url: postURL, state: "in_progress" });
  assert.equal(notifications.length, 3, "different reason code has an independent throttle bucket");
});

test("recovery replay does NOT re-emit silent-skip notifications", async () => {
  const url = "https://chatgpt.com/backend-api/files/download";
  const notifications = [];
  const item = {
    id: 300,
    url,
    finalUrl: url,
    filename: "",
    state: "in_progress",
    paused: true,
  };
  const controller = new TakeoverController({
    downloads: {
      async pause() {},
      async search() { return [item]; },
      async cancel() {},
      async resume() { item.paused = false; },
      async erase() {},
    },
    storage: { local: { async get() { return {}; }, async set() {} } },
    // Recovery path calls download.abandon; return a normal response so
    // sendWithRetry does not blow up.
    nativeClient: {
      async send(request) {
        return { protocolVersion: 1, requestId: request.requestId, status: "ok", type: "download.abandoned", payload: {} };
      },
    },
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
    nonGetURLProvider: () => new Set([url]),
    notifier: (title, message) => notifications.push({ title, message }),
  });
  // recovery=true simulates recoverPending() replaying a stale marker after
  // an SW restart. The user already saw (or missed) the original toast; we
  // must not spam them again on every restart.
  await controller.handleCreated(item, false, { downloadId: 300, idempotencyKey: "k", phase: "observed" });
  assert.equal(notifications.length, 0, "recovery path must stay silent");
});

test("explicit enqueue of a blob: URL stays silent (upstream validator handles it)", async () => {
  const { controller, notifications } = makeSkipHarness({
    url: "blob:https://chatgpt.com/x",
  });
  // explicit=true means the user actively chose "Download with MacIDM" from
  // the context menu or overlay; explicit-enqueue.js already throws
  // enqueue.httpOnly before reaching the controller, so we must not
  // double-report here.
  await controller.handleCreated({
    id: 400,
    url: "blob:https://chatgpt.com/x",
    finalUrl: "blob:https://chatgpt.com/x",
    state: "in_progress",
  }, true);
  assert.equal(notifications.length, 0);
});

// ---------------------------------------------------------------------------
// notifyTakeoverResult error-code → reason mapping
// ---------------------------------------------------------------------------

async function failureNotificationFor(error) {
  const notifications = [];
  const item = {
    id: 500,
    url: "https://example.com/file.zip",
    finalUrl: "https://example.com/file.zip",
    filename: "/tmp/file.zip",
    mime: "application/zip",
    totalBytes: 10 * 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const downloads = {
    async pause() { item.paused = true; },
    async search() { return [item]; },
    async cancel() { item.state = "interrupted"; item.paused = false; },
    async resume() { item.paused = false; },
    async erase() {},
  };
  const storage = { local: { async get() { return {}; }, async set() {} } };
  const controller = new TakeoverController({
    downloads,
    storage,
    nativeClient: { async send() { throw error; } },
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
    notifier: (title, message) => notifications.push({ title, message }),
  });
  await controller.handleCreated(item).catch(() => {});
  assert.equal(notifications.length, 1, `expected exactly one notification for ${error?.code}`);
  return notifications[0];
}

test("NATIVE_HOST_NOT_FOUND tells the user to reinstall the native host", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("NATIVE_HOST_NOT_FOUND", "host missing", true),
  );
  assert.ok(notification.message.includes("Native Host"), notification.message);
  assert.ok(
    notification.message.includes("install-debug-native-host") || notification.message.includes("安装脚本"),
    `expected remediation hint, got: ${notification.message}`,
  );
});

test("PROTOCOL_VERSION_MISMATCH tells the user to rebuild and reload the extension", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("PROTOCOL_VERSION_MISMATCH", "version mismatch", false),
  );
  assert.ok(notification.message.includes("版本"), notification.message);
  assert.ok(
    notification.message.includes("重新加载") || notification.message.includes("重新构建"),
    `expected reload hint, got: ${notification.message}`,
  );
});

test("APP_START_TIMEOUT tells the user MacIDM is not running", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("APP_START_TIMEOUT", "launch timed out", true),
  );
  assert.ok(notification.message.includes("MacIDM 未运行"), notification.message);
});

test("PING_TIMEOUT maps to the same 'App not running' reason", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("PING_TIMEOUT", "ping timed out", true),
  );
  assert.ok(notification.message.includes("MacIDM 未运行"), notification.message);
});

test("TAKEOVER_TIMEOUT maps to a timeout reason distinct from launch timeout", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("TAKEOVER_TIMEOUT", "timed out", true),
  );
  assert.ok(notification.message.includes("超时"), notification.message);
  assert.ok(notification.message.includes("繁忙") || notification.message.includes("挂起"), notification.message);
});

test("INVALID_MESSAGE points at a version mismatch as the likely cause", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("INVALID_MESSAGE", "bad response", false),
  );
  assert.ok(notification.message.includes("无效消息"), notification.message);
  assert.ok(notification.message.includes("版本"), notification.message);
});

test("CONTEXT_UNSUPPORTED keeps the existing 'needs login' reason", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("CONTEXT_UNSUPPORTED", "needs login", false),
  );
  assert.ok(notification.message.includes("登录态"), notification.message);
});

test("unknown error codes fall back to the generic 'takeover failed' reason", async () => {
  const notification = await failureNotificationFor(
    new ProtocolError("SOMETHING_NEW", "mystery", false),
  );
  assert.ok(notification.message.includes("接管失败"), notification.message);
});

test("TAKEOVER_USER_CANCELLED_BROWSER never toasts (user already knows)", async () => {
  const notifications = [];
  const item = {
    id: 600,
    url: "https://example.com/f.zip",
    finalUrl: "https://example.com/f.zip",
    filename: "/tmp/f.zip",
    totalBytes: 1024 * 1024,
    state: "in_progress",
    paused: false,
  };
  const controller = new TakeoverController({
    downloads: {
      async pause() { item.paused = true; },
      async search() { return [item]; },
      async cancel() {},
      async resume() {},
      async erase() {},
    },
    storage: { local: { async get() { return {}; }, async set() {} } },
    nativeClient: {
      async send() { throw new ProtocolError("TAKEOVER_USER_CANCELLED_BROWSER", "cancelled", false); },
    },
    settingsProvider: async () => ({ ...DEFAULT_SETTINGS, takeoverInteractive: false }),
    notifier: (title, message) => notifications.push({ title, message }),
  });
  await controller.handleCreated(item).catch(() => {});
  assert.equal(notifications.length, 0, "user-initiated cancel must not double-toast");
});


test("user cancellation failure preserves intent and recovery never resumes or recreates", async () => {
  const {controller,item,calls,storage} = harness([
    new ProtocolError("TAKEOVER_USER_CANCELLED_BROWSER", "cancel", false),
  ], {}, {...DEFAULT_SETTINGS, takeoverInteractive:true});
  const cancel = controller.downloads.cancel;
  controller.downloads.cancel = async () => { throw new Error('temporary failure'); };
  await controller.handleCreated(item);
  const pending = (await storage.local.get('pendingTakeovers')).pendingTakeovers;
  assert.equal(item.paused, true);
  assert.equal(pending.length, 1);
  assert.equal(pending[0].phase, 'userCancelPending');
  controller.downloads.cancel = cancel;
  await controller.recoverPending();
  assert.equal(item.state, 'interrupted');
  assert.equal((await storage.local.get('pendingTakeovers')).pendingTakeovers.length, 0);
  assert.equal(calls.filter(c => c === 'download.enqueue').length, 1);
  assert.ok(!calls.includes('resume'));
});

test("user cancel recovery retains an erase failure and finishes without an App request", async () => {
  const {controller,item,calls,storage} = harness([
    new ProtocolError("TAKEOVER_USER_CANCELLED_BROWSER", "cancel", false),
  ], {}, {...DEFAULT_SETTINGS, takeoverInteractive:true});
  const erase=controller.downloads.erase;
  controller.downloads.erase=async()=>{throw new Error('temporary failure')};
  await controller.handleCreated(item);
  assert.equal(item.state,'interrupted');
  assert.equal((await storage.local.get('pendingTakeovers')).pendingTakeovers[0].phase,'userCancelPending');
  controller.downloads.erase=erase;
  await controller.recoverPending();
  assert.equal((await storage.local.get('pendingTakeovers')).pendingTakeovers.length,0);
  assert.equal(calls.filter(c=>c==='cancel').length,1);
  assert.equal(calls.filter(c=>c.startsWith('download.')).length,1);
});
