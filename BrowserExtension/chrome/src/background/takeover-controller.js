import { STORAGE_PENDING_KEY, INTERACTIVE_TIMEOUT_MS } from "../shared/constants.js";
import { createRequest, ProtocolError } from "../shared/protocol.js";
import { filenameFromDownload, isHttpURL } from "../shared/validation.js";
import { t } from "../shared/i18n-access.js";
import { shouldTakeover } from "./rules.js";

/// Extract a notification-safe basename from a download item.
/// When `item.filename` is missing, the previous code fell back to
/// `finalUrl.split(/[\\/]/).pop()`, which preserved the query string
/// (`file.zip?token=…`) and leaked signed-URL signatures into user-visible
/// notifications. This helper routes URL fallbacks through `new URL().pathname`
/// so the query and fragment are stripped before the basename is taken.
function displayBasename(item) {
  const filename = item?.filename;
  if (typeof filename === "string" && filename.trim()) {
    const base = filename.split(/[\\/]/).pop();
    if (base) return base;
  }
  const url = item?.finalUrl || item?.url;
  if (typeof url === "string" && isHttpURL(url)) {
    try {
      const pathname = new URL(url).pathname;
      const base = decodeURIComponent(pathname.split("/").pop() || "");
      if (base) return base;
    } catch {
      // fall through to the raw split below
    }
    // Non-HTTP or unparseable: still strip at the last path separator but
    // drop any query/fragment suffix so signatures do not leak.
    const stripped = url.split(/[?#]/)[0];
    const base = stripped.split(/[\\/]/).pop();
    if (base) return base;
  }
  return t("takeover.filenameFallback");
}

export class TakeoverController {
  constructor({
    downloads,
    storage,
    nativeClient,
    settingsProvider,
    profileIDProvider,
    requestContextProvider,
    nonGetURLProvider,
    notifier,
  }) {
    this.downloads = downloads;
    this.storage = storage;
    this.nativeClient = nativeClient;
    this.settingsProvider = settingsProvider;
    this.profileIDProvider = profileIDProvider ?? (async () => "test-profile");
    this.requestContextProvider = requestContextProvider ?? (async () => null);
    // M9: provider that returns the current Set/Map of URLs observed via
    // non-GET requests. When a download's URL is present, takeover is skipped
    // because the App would replay the URL with GET and lose the POST body.
    this.nonGetURLProvider = nonGetURLProvider ?? (() => new Set());
    // Optional user-facing toast ("Handed over to MacIDM"); tests omit it.
    this.notifier = notifier ?? null;
    this.active = new Set();
    this.pendingMutation = Promise.resolve();
  }

  async handleCreated(item, explicit = false, recovery = false) {
    if (
      !item ||
      this.active.has(item.id) ||
      (item.state && item.state !== "in_progress") ||
      !isHttpURL(item.finalUrl || item.url)
    ) return;
    // M9: a POST-triggered download cannot be replayed with GET. If the
    // download URL was observed in a non-GET request, leave the browser
    // download running instead of pausing and losing the POST context.
    if (!explicit) {
      const nonGetURLs = this.nonGetURLProvider();
      const downloadURL = item.finalUrl || item.url;
      if (nonGetURLs && typeof nonGetURLs.has === "function" && nonGetURLs.has(downloadURL)) {
        if (recovery) {
          await this.recoverAbandoned(recovery, item);
        }
        return;
      }
    }
    const decision = shouldTakeover(item, await this.settingsProvider(), explicit);
    if (!decision.takeOver) {
      if (recovery) {
        await this.recoverAbandoned(recovery, item);
      }
      return;
    }
    const settings = await this.settingsProvider();
    // The settings lookup above yields control. Re-check and reserve the
    // download only after it completes so two concurrent download events
    // cannot both pass the old has-then-add window.
    if (this.active.has(item.id)) return;

    this.active.add(item.id);
    let browserPaused = false;
    let taskCreated = false;
    let keepRecoveryMarker = false;
    let idempotencyKey;
    try {
      // Write the pending recovery marker before any App traffic so a SW
      // eviction mid-flow leaves a record the recovery pass understands.
      idempotencyKey = `${await this.profileIDProvider()}:download-${item.id}`;
      await this.remember(item.id, idempotencyKey);

      // Spec §5.2: freeze the download with pause() BEFORE any App traffic.
      // A paused download cannot complete while the user deliberates in the
      // confirmation window, and an App-side failure is compensated by a
      // plain resume() — the browser download is never destroyed before the
      // App task exists, which removes the recreate-and-loop failure class.
      try {
        await this.downloads.pause(item.id);
        browserPaused = true;
      } catch {
        if (item.paused !== true) {
          // Pause failed and this is not a download already paused in the
          // recovery path: do not take over (spec §5.2).
          this.notifyTakeoverResult(false, item, new ProtocolError("TAKEOVER_FAILED", t("takeover.pauseFailed"), false));
          await this.forget(item.id);
          return;
        }
        // Recovery after a SW restart: the previous attempt already paused
        // this download, so pause() failing on it is not a blocker.
        browserPaused = true;
      }

      const payload = await this.createPayload(item);
      const ready = settings.takeoverInteractive !== false
        ? await this.waitForInteractiveConfirmation(item.id, idempotencyKey, payload)
        : await this.nativeClient.send(createRequest("download.create", idempotencyKey, payload));
      if (
        ready.type !== "download.readyForTakeover" ||
        typeof ready.payload?.taskId !== "string" ||
        typeof ready.payload?.takeoverToken !== "string"
      ) {
        throw new ProtocolError("INVALID_MESSAGE", t("takeover.appNotReady"));
      }
      taskCreated = true;

      // Spec §5.2: cancel() runs after the App task exists, so a cancel
      // failure is reportable over the wire (download.browserCancelFailed)
      // instead of needing a silent recreate of the browser download.
      await this.markPhase(item.id, "cancellingBrowser");
      keepRecoveryMarker = true;
      try {
        await this.downloads.cancel(item.id);
      } catch (cancelError) {
        await this.reportCancellationFailure(item.id, ready.payload, `${idempotencyKey}:cancel`, cancelError);
        await this.markPhase(item.id, "abandonPending");
        await this.recoverAbandoned({ downloadId: item.id, idempotencyKey }, item);
        keepRecoveryMarker = false;
        this.notifyTakeoverResult(false, item, new ProtocolError("TAKEOVER_FAILED", t("takeover.cancelFailed"), false));
        return;
      }
      await this.markPhase(item.id, "browserCancelled");

      try {
        await this.sendWithRetry(() =>
          this.sendCancellationResult(
          "download.browserCancelled",
          item.id,
          ready.payload,
          `${idempotencyKey}:cancel`,
          ),
        );
        await this.downloads.erase({ id: item.id });
        keepRecoveryMarker = false;
        this.notifyTakeoverResult(true, item);
      } catch (error) {
        keepRecoveryMarker = true;
        throw new ProtocolError(
          "APP_ACK_PENDING",
          t("takeover.chromeCancelledPending"),
          true,
        );
      }
    } catch (error) {
      if (!taskCreated) {
        // The App did not acknowledge creating a task (timeout, disconnect,
        // or invalid response). Abandon any partial task the App may have
        // created before the timeout, then resume the download — it was only
        // ever paused, never cancelled, so nothing needs to be recreated.
        if (idempotencyKey) {
          await this.markPhase(item.id, "abandonPending").catch(() => {});
          try {
            await this.abandonTakeover(item.id, idempotencyKey);
          } catch {
            keepRecoveryMarker = true;
          }
        }
        if (browserPaused) {
          if (!await this.safeResume(item.id)) keepRecoveryMarker = true;
        }
      }
      // If taskCreated is true but browserCancelled ack failed, the
      // keepRecoveryMarker flag was already set inside the try block;
      // the recovery mechanism will retry the ack.
      this.notifyTakeoverResult(false, item, error);
      throw error;
    } finally {
      this.active.delete(item.id);
      if (!keepRecoveryMarker) await this.forget(item.id);
    }
  }

  notifyTakeoverResult(succeeded, item, error) {
    if (!this.notifier) return;
    try {
      const name = displayBasename(item).slice(0, 120);
      if (succeeded) {
        this.notifier(t("takeover.handedOver"), name);
      } else {
        let reason;
        if (error?.code === "APP_ACK_PENDING") {
          reason = error.message;
        } else if (String(error?.code || "") === "CONTEXT_UNSUPPORTED") {
          reason = t("takeover.reasonNeedsLogin");
        } else {
          reason = t("takeover.reasonKept");
        }
        this.notifier(t("takeover.notComplete"), t("takeover.notCompleteBody", { name, reason }));
      }
    } catch {
      // Notifications are best-effort; never break the takeover flow.
    }
  }

  async waitForInteractiveConfirmation(downloadId, idempotencyKey, payload) {
    const deadline = Date.now() + INTERACTIVE_TIMEOUT_MS;
    await this.markPhase(downloadId, "interactiveWaiting");
    while (Date.now() < deadline) {
      const response = await this.nativeClient.send(createRequest(
        "download.enqueue", idempotencyKey, { ...payload, interactive: true },
      ));
      if (response.type === "download.readyForTakeover") return response;
      if (response.type !== "download.confirmationPending") {
        throw new ProtocolError("INVALID_MESSAGE", t("takeover.unexpectedResponse"));
      }
      // Each native request finishes promptly. Polling survives normal MV3
      // suspension; a new worker replays the same non-secret identity.
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
    throw new ProtocolError("TAKEOVER_TIMEOUT", t("takeover.unexpectedResponse"), true);
  }

  /// Non-interactive path: the App task exists but Chrome refused (or could
  /// not) cancel its download. Report it so the App marks the task
  /// `takeoverConflict` instead of silently keeping a duplicate running
  /// download (spec §5.2; technical spec: on cancel failure the App enters
  /// takeoverConflict and must not start silently).
  async reportCancellationFailure(browserDownloadId, readyPayload, idempotencyKey, cancelError) {
    try {
      await this.sendWithRetry(() =>
        this.sendCancellationResult(
          "download.browserCancelFailed",
          browserDownloadId,
          readyPayload,
          idempotencyKey,
          cancelError?.code || "BROWSER_CANCEL_FAILED",
        ),
      );
    } catch {
      // The App never learned the cancel failed; the conflict stays local to
      // the notification. Nothing further can be done from the extension.
    }
  }

  async handleChanged(downloadId, changeInfo = {}) {
    if (!Number.isInteger(downloadId) || downloadId < 0) return;
    if (
      !["filename", "finalUrl", "totalBytes", "mime", "state"].some(
        (field) => Object.prototype.hasOwnProperty.call(changeInfo, field),
      )
    ) return;
    const [item] = await this.downloads.search({ id: downloadId });
    if (!item || item.state !== "in_progress") return;
    await this.handleCreated(item);
  }

  async recoverPending() {
    const stored = await this.storage.local.get(STORAGE_PENDING_KEY);
    const pending = Array.isArray(stored[STORAGE_PENDING_KEY]) ? stored[STORAGE_PENDING_KEY] : [];
    for (const entry of pending) {
      if (this.active.has(entry.downloadId)) continue;
      const [item] = await this.downloads.search({ id: entry.downloadId });
      if (["browserCancelled", "cancellingBrowser", "receiptUnavailable"].includes(entry.phase)) {
        if (!item) {
          // Without Chrome metadata we cannot safely replay create. Keep the
          // non-secret marker and expose the unrecoverable receipt explicitly.
          this.notifyTakeoverResult(false, {}, new ProtocolError("APP_ACK_PENDING", t("takeover.receiptUnrestorable"), true));
          try {
            await this.abandonTakeover(entry.downloadId, entry.idempotencyKey);
            await this.markPhase(entry.downloadId, "receiptUnavailable");
          } catch { /* Retain the marker for coordination after reconnection. */ }

        } else if (item.state === "interrupted" &&
          (entry.phase === "browserCancelled" || item.error === "USER_CANCELED")) {
          await this.recoverCancelled(entry, item).catch(() => {});
        } else if (item.state === "in_progress") {
          await this.handleCreated(item, false, entry).catch(() => {});
        } else {
          await this.recoverAbandoned(entry, item).catch(() => {});
        }
      } else if (entry.phase === "abandonPending") {
        await this.recoverAbandoned(entry, item).catch(() => {});
      } else if (item?.state === "in_progress") {
        // Re-evaluate current settings on restart. `explicit=true` would
        // silently bypass a user-disabled takeover or a newly blocked site.
        await this.handleCreated(item, false, entry).catch(() => {});
      } else {
        await this.recoverAbandoned(entry, item).catch(() => {});
      }
    }
  }

  async sendCancellationResult(type, browserDownloadId, readyPayload, idempotencyKey, errorCode) {
    const payload = {
      taskId: readyPayload.taskId,
      browserDownloadId,
      takeoverToken: readyPayload.takeoverToken,
    };
    if (errorCode) payload.errorCode = String(errorCode).slice(0, 128);
    const request = createRequest(type, idempotencyKey, payload);
    const response = await this.nativeClient.send(request);
    if (response.type !== "download.accepted") {
      throw new ProtocolError("INVALID_MESSAGE", t("takeover.unexpectedResponse"));
    }
    return response;
  }

  async recoverCancelled(entry, item) {
    const create = createRequest(
      "download.create",
      entry.idempotencyKey,
      await this.createPayload(item),
    );
    const ready = await this.nativeClient.send(create);
    if (
      ready.type !== "download.readyForTakeover" ||
      typeof ready.payload?.taskId !== "string" ||
      typeof ready.payload?.takeoverToken !== "string"
    ) {
      throw new ProtocolError("INVALID_MESSAGE", t("takeover.receiptUnrestorable"));
    }
    await this.sendWithRetry(() =>
      this.sendCancellationResult(
        "download.browserCancelled",
        item.id,
        ready.payload,
        `${entry.idempotencyKey}:cancel`,
      ),
    );
    await this.downloads.erase({ id: item.id });
    await this.forget(item.id);
  }

  async recoverAbandoned(entry, item) {
    await this.abandonTakeover(entry.downloadId, entry.idempotencyKey);
    if (item?.state === "in_progress" && item.paused === true) {
      if (!await this.safeResume(entry.downloadId)) {
        throw new ProtocolError("TAKEOVER_FAILED", t("takeover.pauseFailed"), true);
      }
    }
    await this.forget(entry.downloadId);
  }

  async abandonTakeover(downloadId, originalIdempotencyKey) {
    const baseKey = `${originalIdempotencyKey}:abandon`;
    return this.sendWithRetry((attempt) => {
      const request = createRequest(
        "download.abandon",
        attempt === 0 ? baseKey : `${baseKey}:r${attempt}`,
        {
          browserDownloadId: downloadId,
          originalIdempotencyKey,
        },
      );
      return this.nativeClient.send(request);
    });
  }

  async createPayload(item) {
    const payload = {
      browserDownloadId: item.id,
      url: item.finalUrl || item.url,
      filenameHint: filenameFromDownload(item),
    };
    if (Number.isInteger(item.tabId) && item.tabId >= 0) {
      try {
        const tab = await chrome.tabs.get(item.tabId);
        if (typeof tab?.title === "string" && tab.title.trim()) {
          payload.pageTitle = tab.title.trim().slice(0, 300);
        }
      } catch {
        // A download can outlive its source tab; URL and server filename are
        // still valid fallbacks.
      }
    }
    if (typeof item.mime === "string" && item.mime.length <= 4096) payload.mime = item.mime;
    // Chrome reports an unknown download size as 0 (and -1) in
    // DownloadItem.totalBytes. Forwarding 0 as if it were a real
    // Content-Length makes the App's confirmation window show a confident
    // "0 KB" for a size nobody knows. Mirrors rules.js, which already
    // treats 0 as unknown-size for the takeover threshold.
    if (Number.isSafeInteger(item.totalBytes) && item.totalBytes > 0) payload.totalBytes = item.totalBytes;
    if (isHttpURL(item.referrer)) payload.referrer = item.referrer;
    const requestContext = await this.requestContextProvider(item);
    if (requestContext && Object.keys(requestContext).length > 0) {
      payload.requestContext = requestContext;
    }
    return payload;
  }

  async sendWithRetry(operation, attempts = 3) {
    let lastError;
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      try {
        return await operation(attempt);
      } catch (error) {
        lastError = error;
        if (error?.retryable !== true) throw error;
        if (attempt + 1 < attempts) {
          await new Promise((resolve) => setTimeout(resolve, Math.min(1_000, 100 * 2 ** attempt)));
        }
      }
    }
    throw lastError;
  }

  async safeResume(downloadId) {
    try {
      const [item] = await this.downloads.search({ id: downloadId });
      if (item?.state === "in_progress" && item.paused === true) {
        await this.downloads.resume(downloadId);
      }
      return true;
    } catch {
      return false;
    }
  }

  mutatePending(transform) {
    const operation = this.pendingMutation.then(async () => {
      const stored = await this.storage.local.get(STORAGE_PENDING_KEY);
      const pending = Array.isArray(stored[STORAGE_PENDING_KEY]) ? stored[STORAGE_PENDING_KEY] : [];
      await this.storage.local.set({ [STORAGE_PENDING_KEY]: transform(pending) });
    });
    this.pendingMutation = operation.catch(() => {});
    return operation;
  }

  remember(downloadId, idempotencyKey) {
    return this.mutatePending((pending) => [
      ...pending.filter((entry) => entry.downloadId !== downloadId),
      { downloadId, idempotencyKey, phase: "observed" },
    ]);
  }

  markPhase(downloadId, phase) {
    return this.mutatePending((pending) => pending.map((entry) =>
      entry.downloadId === downloadId ? { ...entry, phase } : entry,
    ));
  }

  forget(downloadId) {
    return this.mutatePending((pending) => pending.filter((entry) => entry.downloadId !== downloadId));
  }
}
