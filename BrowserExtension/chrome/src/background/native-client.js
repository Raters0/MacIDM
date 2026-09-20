import { HOST_NAME, NATIVE_TIMEOUT_MS } from "../shared/constants.js";
import { ProtocolError, validateResponse } from "../shared/protocol.js";
import { t } from "../shared/i18n-access.js";

// M11: Map request types to context-specific timeout codes so callers and
// diagnostics can distinguish a ping failure (app not running) from an
// enqueue failure (app busy) from a takeover acknowledgement timeout.
const TIMEOUT_CODE_BY_TYPE = {
  ping: "PING_TIMEOUT",
  "app.activate": "ACTIVATE_TIMEOUT",
  "media.inspect": "INSPECT_TIMEOUT",
  "download.enqueue": "ENQUEUE_TIMEOUT",
  "download.create": "TAKEOVER_TIMEOUT",
  "download.abandon": "ABANDON_TIMEOUT",
  "download.browserCancelled": "ACK_TIMEOUT",
  "download.browserCancelFailed": "ACK_TIMEOUT",
  "downloadAll.scan": "SCAN_TIMEOUT",
};
const DEFAULT_TIMEOUT_CODE = "REQUEST_TIMEOUT";

export const DEFAULT_HARD_IN_FLIGHT_TIMEOUT_MS = 180_000;

export class NativeClient {
  constructor(runtimeOrOptions = chrome.runtime, options = {}) {
    let runtime;
    let opts;

    if (runtimeOrOptions && typeof runtimeOrOptions.connectNative === "function") {
      runtime = runtimeOrOptions;
      opts = runtimeOrOptions.clock || runtimeOrOptions.hardInFlightTimeoutMs
        ? { ...runtimeOrOptions, ...options }
        : options;
    } else if (runtimeOrOptions && typeof runtimeOrOptions === "object") {
      runtime = runtimeOrOptions.runtime ?? chrome.runtime;
      opts = { ...runtimeOrOptions, ...options };
    } else {
      runtime = chrome.runtime;
      opts = options;
    }

    this.runtime = runtime;
    this.port = null;
    this.pending = new Map();
    this.inFlightRequests = new Map();
    this.hardInFlightTimeoutMs = opts?.hardInFlightTimeoutMs ?? DEFAULT_HARD_IN_FLIGHT_TIMEOUT_MS;
    this.clock = typeof opts?.clock === "function" ? opts.clock : () => Date.now();
    this.state = "disconnected";
    // Connection lock: when a connect() is in progress, concurrent
    // callers share the same promise instead of racing to create ports.
    this.connectingPromise = null;
  }

  async connect() {
    if (this.port) return;
    // If another connect() is already in flight, reuse its promise.
    if (this.connectingPromise) return this.connectingPromise;
    this.connectingPromise = this.doConnect();
    try {
      await this.connectingPromise;
    } finally {
      this.connectingPromise = null;
    }
  }

  async doConnect() {
    this.state = "connecting";
    // M11: limited exponential backoff (3 attempts) so a transient native
    // host registration race does not surface as a hard failure to the user.
    const maxAttempts = 3;
    let lastError;
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      try {
        const port = this.runtime.connectNative(HOST_NAME);
        this.port = port;
        port.onMessage.addListener((message) => this.receive(message));
        port.onDisconnect.addListener(() => {
          const lastError = this.runtime.lastError;
          const error = new ProtocolError(
            "NATIVE_HOST_NOT_FOUND",
            lastError?.message || t("native.hostDisconnected"),
            true,
          );
          this.state = "disconnected";
          this.port = null;
          this.inFlightRequests.clear();
          for (const { reject, timer } of this.pending.values()) {
            clearTimeout(timer);
            reject(error);
          }
          this.pending.clear();
        });
        this.state = "connected";
        return;
      } catch (error) {
        lastError = error;
        this.port = null;
        if (attempt + 1 < maxAttempts) {
          const delay = Math.min(2_000, 200 * 2 ** attempt);
          await new Promise((resolve) => setTimeout(resolve, delay));
        }
      }
    }
    this.state = "disconnected";
    throw lastError;
  }

  async send(request, timeoutMs = NATIVE_TIMEOUT_MS) {
    if (!this.port) {
      await this.connect();
    }
    const timeoutCode = TIMEOUT_CODE_BY_TYPE[request?.type] ?? DEFAULT_TIMEOUT_CODE;
    const isPing = request?.type === "ping";
    if (!isPing && request?.requestId) {
      this.inFlightRequests.set(request.requestId, {
        type: request.type,
        sentAt: this.clock(),
        hardTimeoutMs: this.hardInFlightTimeoutMs,
      });
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(request.requestId);
        // Intentionally NOT removing the in-flight entry here: the App may
        // still be processing the request, so isHostBusy() must stay true
        // until the late response arrives (or the hard timeout cleans it
        // up). Removing it early would let popupStatus report idle and let
        // callers re-send while the host is genuinely busy.
        reject(new ProtocolError(timeoutCode, t("native.responseTimeout"), true));
      }, timeoutMs);
      this.pending.set(request.requestId, { resolve, reject, timer, type: request?.type });
      try {
        this.port.postMessage(request);
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(request.requestId);
        if (request?.requestId) this.inFlightRequests.delete(request.requestId);
        reject(new ProtocolError("NATIVE_HOST_NOT_FOUND", error.message, true));
      }
    });
  }

  isHostBusy(now = this.clock()) {
    for (const [id, entry] of this.inFlightRequests.entries()) {
      const age = now - entry.sentAt;
      if (age < 0 || age >= entry.hardTimeoutMs) {
        this.inFlightRequests.delete(id);
      }
    }
    return this.inFlightRequests.size > 0;
  }

  hasPendingNonPingRequests(now = this.clock()) {
    return this.isHostBusy(now);
  }

  async ping(createRequest) {
    const request = createRequest("ping", `ping:${crypto.randomUUID()}`, {});
    const response = await this.send(request, 3000);
    return validateResponse(response, request.requestId);
  }

  // Dedicated "open the App" gesture. Unlike ping (background status
  // probing, which must never resurrect an App the user quit), app.activate
  // is user-initiated: the Host may relaunch a deliberately quit App and
  // clears the quit-intent marker for it. Uses the standard timeout because
  // a cold launch plus the bridge handshake can take a few seconds.
  async activate(createRequest) {
    const request = createRequest("app.activate", `activate:${crypto.randomUUID()}`, {});
    const response = await this.send(request, NATIVE_TIMEOUT_MS);
    return validateResponse(response, request.requestId);
  }

  receive(message) {
    const requestId = message?.requestId;
    if (requestId) {
      this.inFlightRequests.delete(requestId);
    }
    const pending = this.pending.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(requestId);
    try {
      pending.resolve(validateResponse(message, requestId));
    } catch (error) {
      pending.reject(error);
    }
  }
}
