// Takeover E2E suite — automates the local E2E case list in
// docs/specifications/chrome-extension-spec.md §10.2.
//
// One Edge (or other Chromium-family) instance loads the unpacked MacIDM
// extension with a stub native messaging host standing in for the App, and a
// controlled 127.0.0.1 origin serves the trigger pages. Real-App evidence
// (GUI confirmation window, installed bundle) is a separate tier and is NOT
// claimed here.
//
// Run:  node --test Tests/BrowserExtensionTests/E2E/*.test.mjs
// Env:  MACIDM_E2E_BROWSER_PATH=<binary>  override the browser executable
//       MACIDM_E2E_HEADED=1               run the browser headed

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { before, after, test } from "node:test";
import { TakeoverHarness } from "./helpers/takeover-harness.mjs";
import { defaultBrowserPath, waitFor } from "./helpers/cdp.mjs";
import { E2E_SECRET_TOKEN } from "../../Support/takeover-origin-server.mjs";

const TAKEOVER_FILE = "/files/e2e-takeover.bin";
const TAKEOVER_BYTES = 64 * 1024;

const browserExecutable = defaultBrowserPath("chrome-for-testing");
const browserMissing = existsSync(browserExecutable)
  ? false
  : `E2E browser not found at ${browserExecutable} (set MACIDM_E2E_BROWSER_PATH)`;

let harness;

before(async () => {
  if (browserMissing) return;
  harness = await TakeoverHarness.start({});
});

after(async () => {
  await harness?.close().catch(() => {});
  harness = null;
});

const e2e = (name, options, fn) => test(name, { skip: browserMissing, ...options }, fn);

function messagesOfType(type) {
  return harness.readMessages().filter((entry) => entry.type === type);
}

/// The stub records only inbound requests; "no takeover traffic" is asserted
/// as a quiet window, and response-based assertions use inbound side effects
/// instead.
async function assertNoTakeoverTraffic({ quietMs = 3_000 } = {}) {
  const deadline = Date.now() + quietMs;
  while (Date.now() < deadline) {
    const messages = harness.readMessages();
    if (messages.length > 0) {
      assert.fail(`expected no host traffic, got: ${messages.map((m) => m.type).join(",")}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

async function assertDownloadCompleted(urlPart, { timeout = 15_000 } = {}) {
  const item = await harness.waitForDownload({
    urlPart,
    predicate: (candidate) => candidate.state === "complete",
    timeout,
  });
  assert.ok(item, `expected a completed browser download for ${urlPart}`);
  return item;
}

async function assertDownloadGone(urlPart, { timeout = 15_000 } = {}) {
  const gone = await waitFor(
    async () => {
      const items = await harness.downloadsSnapshot();
      return items.every((item) => !(item.finalUrl || item.url || "").includes(urlPart));
    },
    { timeout, interval: 250, description: `download ${urlPart} to be erased after takeover` },
  );
  assert.ok(gone);
}

// §10.2 cases 3 (plain GET) + 12 (duplicate events → one task); case 1 (host
// online) is a side effect of the full round trip.
e2e("plain GET download is taken over exactly once", {}, async () => {
  await harness.resetForTest();
  await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });

  const create = await harness.waitForMessage("download.create", { timeout: 10_000 });
  assert.equal(create.request.payload.url, harness.originURL(TAKEOVER_FILE));
  assert.equal(create.request.payload.totalBytes, TAKEOVER_BYTES);
  assert.equal(create.request.payload.filenameHint, "e2e-takeover.bin");
  assert.equal(create.request.payload.filenameHintSource, "browserResolved");
  // Programmatically clicked anchors can lose the tab association (tabId -1);
  // when the page title IS available it must be the real page title.
  const pageTitle = create.request.payload.pageTitle;
  if (pageTitle !== undefined) assert.equal(pageTitle, "anchor");
  assert.ok(create.request.payload.referrer?.endsWith("/anchor-page.html"));
  assert.equal(typeof create.request.payload.browserDownloadId, "number");
  assert.ok(create.request.idempotencyKey.includes(":download-"));

  // onCreated plus any handleChanged redispatch must produce one App task.
  assert.equal(messagesOfType("download.create").length, 1);
  await harness.waitForMessage("download.browserCancelled", { timeout: 10_000 });
  await assertDownloadGone(TAKEOVER_FILE);
});

// §10.2 case 4: the App must see the post-redirect URL, not the trigger URL.
e2e("redirected GET reports the final URL to the App", {}, async () => {
  await harness.resetForTest();
  await harness.runTriggerPage("/redirect-page.html", { timeout: 30_000 });
  const create = await harness.waitForMessage("download.create", { timeout: 10_000 });
  assert.ok(create.request.payload.url.endsWith(TAKEOVER_FILE), `final URL: ${create.request.payload.url}`);
  assert.ok(!create.request.payload.url.includes("/redirect"));
  await assertDownloadGone(TAKEOVER_FILE);
});

// §10.2 case 17: signed URLs travel to the App by design, but must never leak
// into extension storage or console output.
e2e("signed URL tokens stay out of extension storage and console", {}, async () => {
  await harness.resetForTest();
  await harness.runTriggerPage("/signed-page.html", { timeout: 30_000 });
  const create = await harness.waitForMessage("download.create", { timeout: 10_000 });
  assert.ok(create.request.payload.url.includes(`token=${E2E_SECRET_TOKEN}`), "App receives the full signed URL (by design)");

  const storageDump = await harness.session.evaluateInServiceWorker(
    `(async () => JSON.stringify(await chrome.storage.local.get(null)))()`,
  );
  assert.ok(!storageDump.includes(E2E_SECRET_TOKEN), "token leaked into chrome.storage.local");
  for (const entry of harness.session.consoleLog) {
    assert.ok(!entry.text.includes(E2E_SECRET_TOKEN), `token leaked into console: ${entry.text}`);
  }
  await assertDownloadGone(TAKEOVER_FILE);
});

// §10.2 case 5 (partial): without the optional cookies permission the request
// context must never contain cookies. The authorized-site path needs a user
// gesture to grant the permission and stays covered by unit tests + manual
// browser evidence.
e2e("site cookies are withheld unless the site is authorized", {}, async () => {
  await harness.resetForTest();
  await harness.runTriggerPage("/cookie-page.html", { timeout: 30_000 });
  const create = await harness.waitForMessage("download.create", { timeout: 10_000 });
  const context = create.request.payload.requestContext;
  if (context) {
    assert.equal(context.cookie, undefined, "cookie attached without per-site authorization");
  }
  await assertDownloadGone(TAKEOVER_FILE);
});

// §10.2 case 6: a site that is not allowed must not be taken over.
e2e("unauthorized site is left to the browser", {}, async () => {
  await harness.resetForTest({
    settings: { takeoverAllDownloads: false, allowedSites: ["example.invalid"], extensions: ["bin"] },
  });
  const settled = await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

// §10.2 case 7: unknown size stays with the browser unless explicitly enabled.
e2e("unknown-size download is skipped when takeoverUnknownSize is false", {}, async () => {
  await harness.resetForTest({ settings: { takeoverAllDownloads: false } });
  const settled = await harness.runTriggerPage("/unknown-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

// §10.2 case 8: below the configured size threshold stays with the browser.
e2e("below-threshold download is skipped", {}, async () => {
  await harness.resetForTest({ settings: { takeoverAllDownloads: false } });
  const settled = await harness.runTriggerPage("/small-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

e2e("blocked site is never taken over", {}, async () => {
  await harness.resetForTest({ settings: { blockedSites: ["127.0.0.1"] } });
  const settled = await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

// blob:/data: URLs are renderer-local; the App cannot GET-replay them, so the
// extension must skip them and keep the browser download running.
e2e("blob download is skipped with the browser keeping the file", {}, async () => {
  await harness.resetForTest();
  const settled = await harness.runTriggerPage("/blob-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

// A URL the page POSTed to cannot be replayed as GET: takeover must skip it.
e2e("POST-observed URL is skipped to preserve the request body", {}, async () => {
  await harness.resetForTest();
  const settled = await harness.runTriggerPage("/post-then-download-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
});

// §10.2 case 9: when pause() fails (download already finished), takeover is
// abandoned and the browser download survives.
e2e("pause failure keeps the completed browser download", {}, async () => {
  await harness.resetForTest();
  const settled = await harness.runTriggerPage("/instant-page.html", { timeout: 30_000 });
  await assertNoTakeoverTraffic();
  assert.equal(settled.items[0]?.state, "complete");
  assert.ok(!messagesOfType("download.browserCancelled").length);
});

// §10.2 case 2 (App unavailable): an App rejection abandons the partial task
// and resumes the browser download instead of silently losing it.
e2e("app-unavailable rejection resumes the browser download", {}, async () => {
  await harness.resetForTest();
  harness.setBehaviorRules({ "download.create": { mode: "error", errorCode: "APP_UNAVAILABLE" } });
  const settled = await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await harness.waitForMessage("download.create", { timeout: 10_000 });
  await harness.waitForMessage("download.abandon", { timeout: 10_000 });
  assert.ok(!messagesOfType("download.browserCancelled").length, "browser download must not be cancelled when the App is unavailable");
  assert.equal(settled.items[0]?.state, "complete");
});

// §10.2 case 10: an App that never answers create() must time out and resume
// the browser download (NATIVE_TIMEOUT_MS = 15 s).
e2e("app-create timeout resumes the browser download", { timeout: 60_000 }, async () => {
  await harness.resetForTest();
  harness.setBehaviorRules({ "download.create": { mode: "timeout" } });
  const settled = await harness.runTriggerPage("/anchor-page.html", { timeout: 45_000 });
  await harness.waitForMessage("download.create", { timeout: 10_000 });
  await harness.waitForMessage("download.abandon", { timeout: 10_000 });
  assert.equal(settled.items[0]?.state, "complete");
});

// §10.2 case 15 (host restart): losing the host after the browser download was
// cancelled must not drop the takeover — the retry loop reconnects to a fresh
// host process and the receipt lands (the second browserCancelled request).
e2e("host crash after browser-cancel recovers via a fresh host", {}, async () => {
  await harness.resetForTest();
  harness.setBehaviorRules({ "download.browserCancelled": { mode: "exit", times: 1 } });
  await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await assertDownloadGone(TAKEOVER_FILE);
  // The lifecycle file is truncated per test, so a host spawned before the
  // reset has no start record; a start AFTER a scripted exit proves a respawn.
  const lifecycle = await harness.readHostLifecycle();
  const scriptedExitIndex = lifecycle.findIndex((entry) => entry.event === "exit" && entry.reason === "scripted");
  const respawned = scriptedExitIndex >= 0
    && lifecycle.slice(scriptedExitIndex + 1).some((entry) => entry.event === "start");
  assert.ok(respawned, `expected a host respawn, lifecycle=${JSON.stringify(lifecycle)}`);
  assert.ok(messagesOfType("download.browserCancelled").length >= 2, "the receipt must be retried after the crash");
  assert.equal(messagesOfType("download.create").length, 1, "crash recovery must not duplicate the task");
});

// §10.2 case 16: reloading the extension mid-confirmation replays the pending
// takeover through the recovery marker instead of losing it.
e2e("extension reload mid-confirmation recovers the pending takeover", { timeout: 60_000 }, async () => {
  await harness.resetForTest({ settings: { takeoverInteractive: true } });
  harness.setBehaviorRules({ "download.enqueue": { mode: "pending" } });
  // Interactive mode parks the download paused on the confirmation window, so
  // there is nothing to "settle" — wait for the enqueue itself.
  const page = await harness.triggerPageOnly("/anchor-page.html");
  const first = await harness.waitForMessage("download.enqueue", { timeout: 15_000 });
  await page.close();

  // Defer the reload with a timer so this evaluation returns before the
  // worker is torn down underneath it.
  await harness.session.evaluateInServiceWorker(`setTimeout(() => chrome.runtime.reload(), 0); "scheduled"`);
  // The reload leaves a command-line extension DISABLED in current Chromium;
  // re-enable it (the user's equivalent of the chrome://extensions toggle),
  // after which the worker restarts and recoverPending() replays the marker.
  await harness.reenableExtension();
  // Make the App confirm the replayed enqueue so the flow completes.
  harness.setBehaviorRules({ "download.enqueue": { mode: "ready" } });
  await assertDownloadGone(TAKEOVER_FILE, { timeout: 30_000 });
  const enqueues = messagesOfType("download.enqueue");
  assert.ok(enqueues.length >= 2, "recovery must re-send the enqueue");
  assert.equal(new Set(enqueues.map((m) => m.request.idempotencyKey)).size, 1, "recovery reuses the idempotency key");
  assert.ok(enqueues[0].request.idempotencyKey === first.request.idempotencyKey);
  assert.ok(messagesOfType("download.browserCancelled").length >= 1);
});

// §10.2 case 14: a full browser restart with a pending takeover must leave no
// stuck marker and no duplicate task. Two recovery shapes are legitimate: if
// the interrupted download stays dead the recovery abandons the takeover; if
// Chrome auto-resumed it, recovery re-evaluates and re-enqueues with the same
// idempotency key. Either way: no duplicate task, no browser cancellation.
e2e("browser restart with a pending takeover recovers without duplicates", { timeout: 90_000 }, async () => {
  await harness.resetForTest({ settings: { takeoverInteractive: true } });
  harness.setBehaviorRules({ "download.enqueue": { mode: "pending" } });
  const page = await harness.triggerPageOnly("/anchor-page.html");
  const first = await harness.waitForMessage("download.enqueue", { timeout: 25_000 });
  await page.close();
  const createsBefore = messagesOfType("download.create").length;
  // Give the recovery marker's chrome.storage.local write time to reach disk
  // before the shutdown.
  await new Promise((resolve) => setTimeout(resolve, 3_000));

  await harness.restartBrowser({ graceful: true });
  harness.setBehaviorRules({});
  const recovery = await waitFor(
    () => {
      const messages = harness.readMessages();
      const abandon = messages.find((m) =>
        m.type === "download.abandon" && m.request.idempotencyKey === first.request.idempotencyKey);
      if (abandon) return { shape: "abandoned" };
      const replay = messages.find((m) =>
        m.type === "download.enqueue"
        && m.request.idempotencyKey === first.request.idempotencyKey
        && m.seq > messages.find((c) => c.type === "download.create" || c.type === "download.enqueue")?.seq
        && messages.indexOf(m) > messages.indexOf(first));
      return replay ? { shape: "re-enqueued" } : null;
    },
    { timeout: 30_000, description: "post-restart recovery (abandon or re-enqueue)" },
  );
  assert.ok(recovery);

  // No duplicate task may appear after the restart, and the paused browser
  // download must never have been cancelled blindly.
  assert.equal(messagesOfType("download.create").length, createsBefore);
  assert.ok(!messagesOfType("download.browserCancelled").length);
  const pending = await harness.session.evaluateInServiceWorker(
    `(async () => (await chrome.storage.local.get("pendingTakeovers")).pendingTakeovers ?? [])()`,
  );
  if (recovery.shape === "abandoned") {
    assert.equal(pending.length, 0, "recovery marker must be cleared after abandon");
  }
});

// §10.2 case 1 (host offline): a host that dies on first contact fails the
// takeover after the retry budget and the browser download survives.
e2e("host dying on first contact resumes the browser download", { timeout: 60_000 }, async () => {
  await harness.resetForTest();
  harness.setBehaviorRules({ "download.create": { mode: "exit", times: 9 } });
  const settled = await harness.runTriggerPage("/anchor-page.html", { timeout: 45_000 });
  assert.ok(messagesOfType("download.create").length >= 1);
  assert.ok(!messagesOfType("download.browserCancelled").length);
  assert.equal(settled.items[0]?.state, "complete");
});

// Two successive downloads create two independent App tasks with distinct
// idempotency keys (complements the same-item dedupe asserted in test 1).
e2e("two successive downloads create two distinct tasks", {}, async () => {
  await harness.resetForTest();
  await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await assertDownloadGone(TAKEOVER_FILE);
  await harness.runTriggerPage("/anchor-page.html", { timeout: 30_000 });
  await waitFor(
    async () => messagesOfType("download.create").length >= 2,
    { timeout: 15_000, description: "second takeover create" },
  );
  const creates = messagesOfType("download.create");
  assert.equal(creates.length, 2);
  assert.notEqual(creates[0].request.idempotencyKey, creates[1].request.idempotencyKey);
});
