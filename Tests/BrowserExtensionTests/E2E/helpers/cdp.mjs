// Minimal zero-dependency CDP (Chrome DevTools Protocol) driver for the
// takeover E2E suite. Launches a Chromium-family browser with the unpacked
// MacIDM extension, attaches to its background service worker over the
// DevTools WebSocket, and exposes small helpers (evaluate, open page, console
// capture, restart) used by the §10.2 takeover cases.
//
// Node >= 22 is required for the global WebSocket client.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Chrome ≥137 gates --load-extension behind this feature; passing the flag is
// a no-op on builds that never had the gate.
const LOAD_EXTENSION_FEATURE_FLAG = "DisableLoadExtensionCommandLineSwitch";

const BROWSER_PATHS = {
  chrome: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  edge: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  brave: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
  chromium: "/Applications/Chromium.app/Contents/MacOS/Chromium",
};

/// Chrome for Testing is the preferred E2E browser: unbranded (still accepts
/// --load-extension) and its global native-messaging directory carries no real
/// "com.macidm.host" registration, so the profile-local stub wins resolution.
/// Puppeteer caches it under a versioned directory — resolve the newest.
function chromeForTestingPath() {
  const applicationsPath = "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
  if (existsSync(applicationsPath)) return applicationsPath;
  const cacheRoot = join(homedir(), ".cache", "puppeteer", "chrome");
  if (!existsSync(cacheRoot)) return applicationsPath;
  const candidates = readdirSync(cacheRoot)
    .filter((name) => /^mac(_arm)?-\d/.test(name))
    .sort()
    .reverse();
  for (const candidate of candidates) {
    const executable = join(
      cacheRoot,
      candidate,
      "chrome-mac-arm64",
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing",
    );
    if (existsSync(executable)) return executable;
  }
  return applicationsPath;
}

export function defaultBrowserPath(browser) {
  if (process.env.MACIDM_E2E_BROWSER_PATH) return process.env.MACIDM_E2E_BROWSER_PATH;
  if (browser === "chrome-for-testing") return chromeForTestingPath();
  return BROWSER_PATHS[browser] ?? BROWSER_PATHS.chrome;
}

export class CDPClient {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    ws.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id !== undefined) {
        const entry = this.pending.get(message.id);
        if (!entry) return;
        this.pending.delete(message.id);
        if (message.error) {
          entry.reject(new Error(`CDP ${entry.method}: ${message.error.message}`));
        } else {
          entry.resolve(message.result);
        }
        return;
      }
      for (const fn of this.listeners.get(message.method) ?? []) {
        fn(message.params, message.sessionId);
      }
    });
  }

  static connect(url) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.addEventListener("open", () => resolve(new CDPClient(ws)), { once: true });
      ws.addEventListener("error", () => reject(new Error(`CDP WebSocket connect failed: ${url}`)), { once: true });
    });
  }

  send(method, params = {}, sessionId, { timeoutMs = 30_000 } = {}) {
    const id = this.nextId++;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method}: no response within ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
        method,
      });
      this.ws.send(JSON.stringify(payload));
    });
  }

  on(method, fn) {
    if (!this.listeners.has(method)) this.listeners.set(method, new Set());
    this.listeners.get(method).add(fn);
    return () => this.listeners.get(method).delete(fn);
  }

  close() {
    try {
      this.ws.close();
    } catch {
      // Already closing.
    }
  }
}

export class BrowserSession {
  constructor({ child, client, userDataDir, extensionID, extensionPath }) {
    this.child = child;
    this.client = client;
    this.userDataDir = userDataDir;
    this.extensionID = extensionID;
    this.extensionPath = extensionPath;
    this.sessions = new Map(); // sessionId -> targetInfo
    this.sessionIdByTarget = new Map(); // targetId -> sessionId
    this.serviceWorkerSessionId = null;
    this.consoleLog = [];
    this.stderrTail = [];
  }

  wire() {
    this.client.on("Target.attachedToTarget", async ({ sessionId, targetInfo }) => {
      this.sessions.set(sessionId, targetInfo);
      this.sessionIdByTarget.set(targetInfo.targetId, sessionId);
      if (targetInfo.type === "service_worker" && targetInfo.url.includes(this.extensionID)) {
        this.serviceWorkerSessionId = sessionId;
      }
      try {
        await this.client.send("Runtime.enable", {}, sessionId);
      } catch {
        // Detached targets are fine.
      }
    });
    this.client.on("Target.detachedFromTarget", ({ sessionId }) => {
      if (sessionId === this.serviceWorkerSessionId) this.serviceWorkerSessionId = null;
      this.sessions.delete(sessionId);
      for (const [targetId, mapped] of this.sessionIdByTarget) {
        if (mapped === sessionId) this.sessionIdByTarget.delete(targetId);
      }
    });
    this.client.on("Runtime.consoleAPICalled", (params, sessionId) => {
      const text = (params.args ?? [])
        .map((arg) => (typeof arg.value === "string" ? arg.value : arg.description ?? ""))
        .join(" ");
      this.consoleLog.push({ sessionId, type: params.type, text, at: Date.now() });
    });
    this.child.stderr?.on("data", (chunk) => {
      this.stderrTail.push(String(chunk));
      if (this.stderrTail.length > 200) this.stderrTail.shift();
    });
  }

  static async launch({
    browser = "chrome",
    browserPath,
    userDataDir,
    extensionID,
    extensionPath,
    headless = true,
    skipServiceWorkerWait = false,
  }) {
    const executable = browserPath || defaultBrowserPath(browser);
    if (!existsSync(executable)) {
      throw new Error(`E2E browser not found: ${executable}`);
    }
    // Chromium gates command-line-loaded unpacked extensions behind the
    // profile's developer-mode switch: without it the extension registers as
    // ENABLED but its API bindings (chrome.runtime, chrome.*) are never
    // injected into extension contexts. Seed the flag into the fresh profile.
    const defaultPreferencesDir = join(userDataDir, "Default");
    if (!existsSync(join(defaultPreferencesDir, "Preferences"))) {
      mkdirSync(defaultPreferencesDir, { recursive: true });
      writeFileSync(
        join(defaultPreferencesDir, "Preferences"),
        JSON.stringify({ extensions: { ui: { developer_mode: true } } }),
      );
    }
    const args = [
      `--user-data-dir=${userDataDir}`,
      `--load-extension=${extensionPath}`,
      // NOTE: no --disable-extensions-except — branded Chrome ≥137 rejects it
      // outright ("not allowed in Google Chrome, ignoring") and the rejection
      // takes --load-extension down with it. A fresh --user-data-dir has no
      // other unpacked extensions to filter out.
      `--disable-features=${LOAD_EXTENSION_FEATURE_FLAG}`,
      "--remote-debugging-port=0",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-sync",
      "--disable-background-networking",
      "--disable-component-update",
      "--metrics-recording-only",
      "--disable-breakpad",
      "--window-size=1280,900",
    ];
    if (headless) args.push("--headless=new");
    args.push("about:blank");

    const child = spawn(executable, args, { stdio: ["ignore", "ignore", "pipe"] });
    const session = new BrowserSession({ child, client: null, userDataDir, extensionID, extensionPath });
    try {
      const devtools = await waitForDevToolsEndpoint(userDataDir, 20_000);
      session.client = await CDPClient.connect(`ws://127.0.0.1:${devtools.port}${devtools.path}`);
      session.wire();
      await session.client.send("Target.setAutoAttach", {
        autoAttach: true,
        waitForDebuggerOnStart: false,
        flatten: true,
      });
      // Without discover mode, service workers started before connect (the
      // MV3 install-time spin-up) can stay invisible to Target.getTargets.
      await session.client.send("Target.setDiscoverTargets", { discover: true }).catch(() => {});
      await session.client
        .send("Browser.setDownloadBehavior", {
          behavior: "allow",
          downloadPath: join(userDataDir, "Downloads"),
        })
        .catch(() => {});
      await session.attachExistingTargets();
      if (!skipServiceWorkerWait) await session.ensureServiceWorkerAwake();
      return session;
    } catch (error) {
      let targetDump = "";
      if (session.client) {
        try {
          const { targetInfos } = await session.client.send("Target.getTargets");
          targetDump = `\ntargets: ${targetInfos.map((t) => `${t.type}:${t.url.slice(0, 60)}`).join(" | ")}`;
        } catch {
          // Client never connected.
        }
      }
      await session.forceKill().catch(() => {});
      const stderr = session.stderrTail.slice(-20).join("");
      throw new Error(`browser launch failed: ${error.message}${targetDump}\n${stderr}`);
    }
  }

  async attachExistingTargets() {
    const { targetInfos } = await this.client.send("Target.getTargets");
    for (const targetInfo of targetInfos) {
      if (targetInfo.attached) continue;
      if (!["page", "service_worker", "shared_worker", "iframe", "background_page"].includes(targetInfo.type)) {
        continue;
      }
      try {
        const { sessionId } = await this.client.send("Target.attachToTarget", {
          targetId: targetInfo.targetId,
          flatten: true,
        });
        this.sessions.set(sessionId, targetInfo);
        this.sessionIdByTarget.set(targetInfo.targetId, sessionId);
        if (targetInfo.type === "service_worker" && targetInfo.url.includes(this.extensionID)) {
          this.serviceWorkerSessionId = sessionId;
        }
        await this.client.send("Runtime.enable", {}, sessionId).catch(() => {});
      } catch {
        // Target may have gone away.
      }
    }
  }

  /// Probe every live extension service worker target and return the first
  /// session whose runtime answers with our extension id. A reload leaves the
  /// dying worker listed for a while; probing (instead of trusting one cached
  /// session) keeps evaluations off zombie sessions.
  async findReadyServiceWorkerSession({ probeTimeoutMs = 3_000 } = {}) {
    const { targetInfos } = await this.client.send("Target.getTargets");
    const workers = targetInfos.filter(
      (info) => info.type === "service_worker" && info.url.includes(this.extensionID),
    );
    for (const worker of workers) {
      let sessionId = this.sessionIdByTarget.get(worker.targetId);
      if (!sessionId) {
        try {
          sessionId = (await this.client.send("Target.attachToTarget", {
            targetId: worker.targetId,
            flatten: true,
          })).sessionId;
          this.sessions.set(sessionId, worker);
          this.sessionIdByTarget.set(worker.targetId, sessionId);
          await this.client.send("Runtime.enable", {}, sessionId).catch(() => {});
        } catch {
          continue;
        }
      }
      try {
        const result = await this.client.send(
          "Runtime.evaluate",
          { expression: 'typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.id', returnByValue: true },
          sessionId,
          { timeoutMs: probeTimeoutMs },
        );
        if (result.result?.value === this.extensionID) {
          this.serviceWorkerSessionId = sessionId;
          return sessionId;
        }
      } catch {
        // Zombie or busy worker: try the next candidate.
      }
    }
    return null;
  }

  /// Ensure the extension service worker is running AND has its extension API
  /// bindings injected, returning a validated CDP session id. In MV3 an open
  /// extension page does NOT wake the worker by itself, so the wake path opens
  /// the popup page and forces a chrome.runtime connection from that context.
  async ensureServiceWorkerAwake() {
    const ready = await this.findReadyServiceWorkerSession();
    if (ready) return ready;
    const popupTargetId = await this.client.send("Target.createTarget", {
      url: `chrome-extension://${this.extensionID}/src/popup/popup.html`,
    });
    const popupSession = await waitFor(
      () => {
        for (const [id, info] of this.sessions) {
          if (info.type === "page" && info.url.includes(`${this.extensionID}/src/popup/popup.html`)) return id;
        }
        return null;
      },
      { timeout: 15_000, description: "extension popup page to attach" },
    );
    await this.client
      .send(
        "Runtime.evaluate",
        {
          expression: `(async () => {
            try {
              const port = chrome.runtime.connect();
              port.onDisconnect.addListener(() => {});
              setTimeout(() => { try { port.disconnect(); } catch {} }, 250);
            } catch {}
            try { chrome.runtime.sendMessage({ type: "e2e.wake" }).catch(() => {}); } catch {}
            return true;
          })()`,
          awaitPromise: true,
          returnByValue: true,
        },
        popupSession,
      )
      .catch(() => {});
    await this.closePage(popupTargetId);
    return waitFor(
      () => this.findReadyServiceWorkerSession(),
      { timeout: 20_000, interval: 250, description: "extension service worker with API bindings" },
    );
  }

  async evaluateInServiceWorker(expression) {
    const sessionId = await this.ensureServiceWorkerAwake();
    const result = await this.client.send(
      "Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true },
      sessionId,
    );
    if (result.exceptionDetails) {
      const text = result.exceptionDetails.exception?.description
        ?? result.exceptionDetails.text
        ?? "unknown evaluation failure";
      throw new Error(`service worker evaluation failed: ${text}`);
    }
    return result.result?.value;
  }

  async openPage(url) {
    const { targetId } = await this.client.send("Target.createTarget", { url });
    return targetId;
  }

  async closePage(targetId) {
    await this.client.send("Target.closeTarget", { targetId }).catch(() => {});
  }

  /// Chrome restart case: hard-kill the browser process (no graceful shutdown)
  /// and drop the client; the harness relaunches with the same user data dir.
  async forceKill() {
    this.client?.close();
    if (this.child?.exitCode === null && !this.child?.killed) {
      this.child.kill("SIGKILL");
    }
    await new Promise((resolve) => {
      if (!this.child) return resolve();
      this.child.once("exit", resolve);
      setTimeout(resolve, 5_000).unref?.();
    });
  }

  async close() {
    try {
      await this.client.send("Browser.close");
    } catch {
      // Fall through to a hard kill.
    }
    await this.forceKill().catch(() => {});
  }
}

async function waitForDevToolsEndpoint(userDataDir, timeoutMs) {
  const file = join(userDataDir, "DevToolsActivePort");
  return waitFor(
    () => {
      if (!existsSync(file)) return null;
      const [portLine, pathLine] = readFileSync(file, "utf8").split("\n");
      const port = Number.parseInt(portLine ?? "", 10);
      if (!Number.isInteger(port) || port <= 0 || !pathLine) return null;
      return { port, path: pathLine.trim() };
    },
    { timeout: timeoutMs, description: "DevToolsActivePort file" },
  );
}

export async function waitFor(fn, { timeout = 10_000, interval = 200, description = "condition" } = {}) {
  const deadline = Date.now() + timeout;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
  const detail = lastError ? ` (last error: ${lastError.message})` : "";
  throw new Error(`timed out after ${timeout}ms waiting for ${description}${detail}`);
}
