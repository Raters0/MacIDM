// Orchestrator for the takeover E2E suite (chrome-extension-spec §10.2).
//
// One harness instance per test file: it resolves a sandboxed native-messaging
// registration for the stub host, launches the browser with the unpacked
// extension, starts the controlled origin server, and exposes per-test reset +
// observation helpers. Nothing here talks to the real MacIDM App or the real
// "com.macidm.host" registration.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startOriginServer } from "../../../Support/takeover-origin-server.mjs";
import { BrowserSession, waitFor } from "./cdp.mjs";
import {
  STUB_HOST_NAME,
  PROBE_HOST_NAME,
  extensionRoot,
  computeExtensionID,
  installStubHostManifest,
  uninstallStubHostManifest,
  userDataDirNMHDir,
} from "./nmh-install.mjs";

export class E2ESetupError extends Error {}

/// Evaluate a native-messaging probe for `hostName` inside the extension's
/// service worker: connect, send one ping, resolve "message" when a reply
/// arrives, and always disconnect afterwards so no stub process lingers.
const probeExpression = (hostName) => `new Promise((resolve) => {
  try {
    const port = chrome.runtime.connectNative(${JSON.stringify(hostName)});
    let settled = false;
    port.onMessage.addListener(() => {
      settled = true;
      try { port.disconnect(); } catch {}
      resolve("message");
    });
    port.onDisconnect.addListener(() => {
      if (!settled) resolve("disconnect:" + (chrome.runtime.lastError?.message ?? "unknown"));
    });
    port.postMessage({protocolVersion: 1, requestId: "probe", idempotencyKey: "probe", type: "ping", payload: {}});
  } catch (error) {
    resolve("throw:" + error.message);
  }
})`;

export class TakeoverHarness {
  constructor({ browser, headless, rootDir, userDataDir, controlDir, origin, session, extensionID }) {
    this.browser = browser;
    this.headless = headless;
    this.rootDir = rootDir;
    this.userDataDir = userDataDir;
    this.controlDir = controlDir;
    this.origin = origin;
    this.session = session;
    this.extensionID = extensionID;
    this.nmhManifestDir = null;
    this.installedNames = [];
  }

  /// Launch the harness: verify a sandboxed native-messaging strategy, install
  /// the stub, start the origin server, launch the browser. Throws
  /// E2ESetupError with actionable text when no sandboxed strategy exists.
  ///
  /// Two verifications run before any takeover case:
  ///  1. availability — a manifest with a name that exists nowhere else is
  ///     installed only inside the test profile dir; a successful connect
  ///     proves the browser consults --user-data-dir.
  ///  2. shadowing — a stub manifest under the REAL host name is installed in
  ///     the profile dir and the connect must reach OUR stub. Global/fixed
  ///     native-messaging directories take precedence in some browsers
  ///     (observed on Edge), which would silently route takeover flows to the
  ///     user's real host and App. This check makes that a hard setup failure.
  ///
  /// Defaults to Chrome for Testing: unbranded (still accepts
  /// --load-extension, which branded Chrome ≥137 ignores) and its global NMH
  /// directory normally carries no real host registration.
  static async start({ browser = "chrome-for-testing", headless = true } = {}) {
    const extensionID = await computeExtensionID();
    const rootDir = mkdtempSync(join(tmpdir(), "macidm-takeover-e2e-"));
    const userDataDir = join(rootDir, "profile");
    const controlDir = join(rootDir, "host-control");
    // The stub host appends its record files here the moment Chrome spawns it;
    // create it up front so the first message never hits ENOENT.
    mkdirSync(controlDir, { recursive: true });
    writeFileSync(join(controlDir, "behavior.json"), "{}\n");
    const messagesPath = join(controlDir, "messages.jsonl");
    const origin = await startOriginServer();

    const recordedPing = () => {
      if (!existsSync(messagesPath)) return false;
      return readFileSync(messagesPath, "utf8").includes('"type":"ping"');
    };

    let session = null;
    try {
      const nmhDir = userDataDirNMHDir(userDataDir);

      // Both manifests MUST be installed before the browser launches:
      // Chromium-family browsers resolve native hosts against the manifest
      // snapshot taken at startup, so a manifest written after launch is
      // invisible and the lookup falls through to the user's global
      // registration of the real host (observed: real-App downloads).
      await installStubHostManifest({ name: PROBE_HOST_NAME, manifestDir: nmhDir, controlDir });
      await installStubHostManifest({ name: STUB_HOST_NAME, manifestDir: nmhDir, controlDir });
      session = await BrowserSession.launch({
        browser,
        userDataDir,
        extensionID,
        extensionPath: extensionRoot(),
        headless,
      });

      // Step 1: availability of profile-local native messaging.
      const probeOutcome = await session.evaluateInServiceWorker(probeExpression(PROBE_HOST_NAME));
      uninstallStubHostManifest({ name: PROBE_HOST_NAME, manifestDir: nmhDir });
      writeFileSync(messagesPath, "");
      if (probeOutcome !== "message") {
        throw new E2ESetupError(
          [
            `this browser does not read native-messaging manifests from --user-data-dir (${probeOutcome}).`,
            "Run the suite with a Chromium build that supports profile-local NMH manifests",
            "(e.g. Chrome for Testing) via MACIDM_E2E_BROWSER_PATH=<path>.",
          ].join(" "),
        );
      }

      // Step 2: the real host name must resolve to OUR stub, never to a
      // global registration of the real host.
      const shadowOutcome = await session.evaluateInServiceWorker(probeExpression(STUB_HOST_NAME));
      const shadowRecorded = recordedPing();
      writeFileSync(messagesPath, "");
      if (shadowOutcome !== "message" || !shadowRecorded) {
        throw new E2ESetupError(
          [
            `connectNative("${STUB_HOST_NAME}") did not reach the profile-local stub ` +
              `(outcome: ${shadowOutcome}, reachedStub: ${shadowRecorded}) — a global native-messaging ` +
              "registration takes precedence over --user-data-dir.",
            "Run the suite with a browser that has no global",
            `"${STUB_HOST_NAME}" registration (e.g. Chrome for Testing) via MACIDM_E2E_BROWSER_PATH=<path>,`,
            "so tests can never contact the real host and App.",
          ].join(" "),
        );
      }

      const harness = new TakeoverHarness({ browser, headless, rootDir, userDataDir, controlDir, origin, session, extensionID });
      harness.nmhManifestDir = nmhDir;
      harness.installedNames = [STUB_HOST_NAME];
      return harness;
    } catch (error) {
      await origin.close();
      if (session) await session.close().catch(() => {});
      rmSync(rootDir, { recursive: true, force: true });
      throw error;
    }
  }

  originURL(path = "") {
    return `${this.origin.url}${path}`;
  }

  // --- Per-test lifecycle ----------------------------------------------------

  /// Wait out flows from the previous test: cancel/erase every download and
  /// wait until the host message file has been quiet for a moment, so stale
  /// in-flight takeovers cannot pollute the next case's message assertions.
  async quiesce({ quietMs = 1_500, timeout = 20_000 } = {}) {
    await this.eraseAllDownloads();
    await waitFor(
      () => {
        const count = this.readMessages().length;
        if (count !== this.quiesceLastCount) {
          this.quiesceLastCount = count;
          this.quiesceLastChange = Date.now();
        }
        return Date.now() - this.quiesceLastChange >= quietMs;
      },
      { timeout, interval: 250, description: "host traffic to quiesce" },
    );
    this.quiesceLastCount = -1;
    this.quiesceLastChange = Date.now();
  }

  async resetForTest({ settings = {} } = {}) {
    await this.quiesce();
    // Write-empty rather than truncate: on the first test no message file
    // exists yet (the NMH probe consumed and removed its own).
    writeFileSync(join(this.controlDir, "messages.jsonl"), "");
    rmSync(join(this.controlDir, "host-lifecycle.jsonl"), { force: true });
    this.setBehaviorRules({});
    this.session.consoleLog.length = 0;
    // A fresh profile per test removes any pending recovery markers and
    // leftover downloads from earlier cases.
    await this.session.evaluateInServiceWorker(
      `chrome.storage.local.clear().then(() => chrome.storage.local.set({settings: ${JSON.stringify({
        takeoverInteractive: false,
        ...settings,
      })}}))`,
    );
    await this.eraseAllDownloads();
  }

  async eraseAllDownloads() {
    await this.session.evaluateInServiceWorker(
      `(async () => {
        const items = await chrome.downloads.search({});
        for (const item of items) {
          if (item.state === "in_progress") { try { await chrome.downloads.cancel(item.id); } catch {} }
          try { await chrome.downloads.erase({id: item.id}); } catch {}
        }
        return (await chrome.downloads.search({})).length;
      })()`,
    );
  }

  setBehaviorRules(rules) {
    writeFileSync(join(this.controlDir, "behavior.json"), `${JSON.stringify({ rules }, null, 2)}\n`);
  }

  // --- Observation -------------------------------------------------------------

  readMessages() {
    const file = join(this.controlDir, "messages.jsonl");
    if (!existsSync(file)) return [];
    return readFileSync(file, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .map((line) => JSON.parse(line))
      .filter((entry) => entry.type !== "e2e.hostStarted");
  }

  waitForMessage(type, { timeout = 10_000, where = null } = {}) {
    return waitFor(
      () => {
        const entry = this.readMessages().find(
          (candidate) => candidate.type === type && (!where || where(candidate)),
        );
        return entry ?? null;
      },
      { timeout, description: `${type} message${where ? " matching predicate" : ""}` },
    );
  }

  async readHostLifecycle() {
    const file = join(this.controlDir, "host-lifecycle.jsonl");
    if (!existsSync(file)) return [];
    return readFileSync(file, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .map((line) => JSON.parse(line));
  }

  async downloadsSnapshot() {
    return this.session.evaluateInServiceWorker(`chrome.downloads.search({})`);
  }

  waitForDownload({ urlPart, predicate, timeout = 15_000 } = {}) {
    return waitFor(
      async () => {
        const items = await this.downloadsSnapshot();
        return items.find((item) => {
          const url = item.finalUrl || item.url;
          return (!urlPart || (typeof url === "string" && url.includes(urlPart)))
            && (!predicate || predicate(item));
        }) ?? null;
      },
      { timeout, description: `download ${urlPart ?? ""} ${predicate ? "matching predicate" : ""}`.trim() },
    );
  }

  /// Open a trigger page without waiting for settlement — for flows that are
  /// expected to park on the App confirmation window (interactive mode), where
  /// the download stays paused until the user (or stub) decides.
  async triggerPageOnly(pagePath) {
    const targetId = await this.session.openPage(this.originURL(pagePath));
    return { targetId, close: () => this.session.closePage(targetId) };
  }

  /// Re-enable the extension via the chrome://extensions WebUI. A
  /// chrome.runtime.reload() of a command-line-loaded unpacked extension ends
  /// with the extension DISABLED in current Chromium builds; the §10.2
  /// "extension reload" recovery case needs it enabled again for the recovery
  /// pass to run.
  async reenableExtension() {
    // Let the reload's teardown settle first: enabling while the old context
    // is still being torn down races and the enable is lost.
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const { targetId } = await this.session.client.send("Target.createTarget", {
        url: "chrome://extensions/",
      });
      try {
        const webuiSession = await waitFor(
          () => {
            for (const [id, info] of this.session.sessions) {
              if (info.type === "page" && info.url.includes("extensions")) return id;
            }
            return null;
          },
          { timeout: 15_000, description: "chrome://extensions WebUI to attach" },
        );
        await this.session.client.send(
          "Runtime.evaluate",
          {
            expression: `chrome.management.setEnabled(${JSON.stringify(this.extensionID)}, true)
              .then(() => "enabled").catch((e) => "error:" + e.message)`,
            awaitPromise: true,
            returnByValue: true,
          },
          webuiSession,
        );
      } finally {
        await this.session.closePage(targetId);
      }
      if (await this.session.findReadyServiceWorkerSession()) return;
      await new Promise((resolve) => setTimeout(resolve, 2_000));
    }
    throw new Error("extension did not come back ready after re-enable");
  }

  /// Hard-kill (or gracefully close) the browser and relaunch it against the
  /// same profile dir. Used by the §10.2 restart-recovery cases: NMH manifests
  /// and the control dir live outside the profile so recovery flows survive.
  async restartBrowser({ graceful = false } = {}) {
    if (graceful) {
      await this.session.close();
    } else {
      await this.session.forceKill();
    }
    // The stale endpoint file would make the relaunch connect to the dead
    // browser's port before the new instance rewrites it.
    rmSync(join(this.userDataDir, "DevToolsActivePort"), { force: true });
    const { BrowserSession } = await import("./cdp.mjs");
    this.session = await BrowserSession.launch({
      browser: this.browser,
      userDataDir: this.userDataDir,
      extensionID: this.extensionID,
      extensionPath: extensionRoot(),
      headless: this.headless,
    });
  }

  /// Open a trigger page and wait for its download to settle (browser download
  /// completed, or takeover erased the item). Returns the settled snapshot.
  async runTriggerPage(pagePath, { timeout = 20_000 } = {}) {
    const before = new Set((await this.downloadsSnapshot()).map((item) => item.id));
    const targetId = await this.session.openPage(this.originURL(pagePath));
    try {
      return await waitFor(
        async () => {
          const items = await this.downloadsSnapshot();
          const relevant = items.filter((item) => !before.has(item.id));
          const settled = relevant.every((item) => item.state !== "in_progress");
          const anyRelevant = relevant.length > 0;
          // Takeover success erases the item: no relevant item is also settled
          // once at least one takeover message arrived.
          const takeoverStarted = this.readMessages().some((entry) =>
            entry.type === "download.create" || entry.type === "download.enqueue");
          if ((anyRelevant && settled) || (!anyRelevant && takeoverStarted)) {
            return { items: relevant, erasedWithoutTrace: !anyRelevant && takeoverStarted };
          }
          return null;
        },
        { timeout, interval: 250, description: `trigger page ${pagePath} to settle` },
      );
    } finally {
      await this.session.closePage(targetId);
    }
  }

  // --- Teardown --------------------------------------------------------------------

  async close() {
    await this.session?.close().catch(() => {});
    for (const name of this.installedNames) {
      uninstallStubHostManifest({ name, manifestDir: this.nmhManifestDir });
    }
    await this.origin.close();
    // A host process killed as the browser dies can append its lifecycle exit
    // record while the removal is running; retry the rmtree briefly.
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        rmSync(this.rootDir, { recursive: true, force: true });
        return;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
    }
  }
}
