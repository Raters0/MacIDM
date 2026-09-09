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
