import { STORAGE_PENDING_KEY, INTERACTIVE_TIMEOUT_MS } from "../shared/constants.js";
import { createRequest, ProtocolError } from "../shared/protocol.js";
import { filenameFromDownload, isHttpURL } from "../shared/validation.js";
import { t } from "../shared/i18n-access.js";
import { shouldTakeover } from "./rules.js";

// Minimum interval between two user-facing notifications for the same
// reason code. Without this a ChatGPT-style page that fires many blob:
// downloads in a row (or a site whose every download is POST-triggered)
// would toast on every single item. The controller keeps the timestamps
// in SW memory: after an SW restart the user gets one fresh notification
// per reason, which is the desired behaviour.
const SKIP_NOTIFICATION_THROTTLE_MS = 5 * 60 * 1_000;

// Map a bridge/protocol error code to a user-actionable reason key.
// Rationale: a generic "takeover failed; the browser download was kept"
// notification does not tell the user WHY MacIDM did not take the
// download, so connection-health failures (host missing, App not
// running, protocol mismatch) look identical to a real App bug.
// Distinguishing them lets the user act (install the host, launch the
// App, rebuild the extension) instead of just shrugging.
function reasonKeyForError(error) {
  const code = String(error?.code || "");
  switch (code) {
    case "NATIVE_HOST_NOT_FOUND":
      return "takeover.reasonHostMissing";
    case "APP_START_TIMEOUT":
    case "APP_UNAVAILABLE":
    case "PING_TIMEOUT":
      return "takeover.reasonAppNotRunning";
    case "PROTOCOL_VERSION_MISMATCH":
      return "takeover.reasonVersionMismatch";
    case "TAKEOVER_TIMEOUT":
    case "ENQUEUE_TIMEOUT":
    case "ACK_TIMEOUT":
    case "ABANDON_TIMEOUT":
    case "INSPECT_TIMEOUT":
    case "ACTIVATE_TIMEOUT":
    case "SCAN_TIMEOUT":
    case "REQUEST_TIMEOUT":
      return "takeover.reasonTimeout";
    case "INVALID_MESSAGE":
      return "takeover.reasonInvalidMessage";
    case "CONTEXT_UNSUPPORTED":
      return "takeover.reasonNeedsLogin";
    default:
      return null;
  }
}

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
    ...options
  }) {
    this.downloads = downloads;
    this.storage = storage;
    this.nativeClient = nativeClient;
    this.settingsProvider = settingsProvider;
    this.profileIDProvider = profileIDProvider ?? (async () => "test-profile");
    this.requestContextProvider = requestContextProvider ?? (async () => null);
    // provider that returns the current Set/Map of URLs observed via
    // non-GET requests. When a download's URL is present, takeover is skipped
    // because the App would replay the URL with GET and lose the POST body.
    this.nonGetURLProvider = nonGetURLProvider ?? (() => new Set());
    // Optional user-facing toast ("Handed over to MacIDM"); tests omit it.
    this.notifier = notifier ?? null;
    this.active = new Set();
    this.pendingMutation = Promise.resolve();
    // reasonCode -> last Date.now() a notification was fired for that code.
    // Bounded by the throttle window; entries are pruned lazily on read.
    this.skipNotificationAt = new Map();
    this.clock = options?.clock ?? (() => Date.now());
  }

  async handleCreated(item, explicit = false, recovery = false) {
    if (!item) return;
    if (this.active.has(item.id)) return;
    if (item.state && item.state !== "in_progress") return;
    const downloadURL = item.finalUrl || item.url;
    if (!isHttpURL(downloadURL)) {
      // blob:/data:/filesystem: URLs are renderer-local; the SW cannot
      // hand them to the App for a GET replay, so takeover is
      // structurally impossible. Surface a throttled one-shot diagnostic
      // so the user is not left wondering why clicking "Download" did
      // nothing on the MacIDM side. Skipped on the recovery path (SW
      // restart replaying old markers) and on explicit user-initiated
      // enqueues (which validate the scheme upstream and throw).
      if (!explicit && !recovery) {
        this.notifySkipped(item, "unsupported-scheme");
      }
      return;
    }
    // a POST-triggered download cannot be replayed with GET. If the
    // download URL was observed in a non-GET request, leave the browser
    // download running instead of pausing and losing the POST context.
    if (!explicit) {
      const nonGetURLs = this.nonGetURLProvider();
      if (nonGetURLs && typeof nonGetURLs.has === "function" && nonGetURLs.has(downloadURL)) {
        if (!recovery) {
          this.notifySkipped(item, "non-get-url");
        }
        if (recovery) {
          await this.recoverAbandoned(recovery, item);
        }
        return;
      }
    }
    const decision = shouldTakeover(item, await this.settingsProvider(), explicit);
    if (!decision.takeOver) {
      // User-configured filters (takeoverEnabled=false, site blocked,
      // file-type/size below threshold). These are the extension working
      // as configured, not a fault — do NOT toast here or every filtered
      // download would spam the user.
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
      // The user dismissed the MacIDM confirmation choosing to also cancel the
      // paused browser download: cancel + erase it here instead of resuming.
      if (error?.code === "TAKEOVER_USER_CANCELLED_BROWSER") {
        keepRecoveryMarker = true;
        await this.markPhase(item.id, "userCancelPending");
        try {
          await this.completeUserCancellation(item.id);
          keepRecoveryMarker = false;
        } catch {
          this.notifyTakeoverResult(false, item,
            new ProtocolError("TAKEOVER_FAILED", t("takeover.cancelFailed"), true));
        }
        return;
      }
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
        return;
      }
      // User-initiated cancel is a deliberate action; the confirmation
      // window already gave feedback. Do not double-toast here.
      if (error?.code === "TAKEOVER_USER_CANCELLED_BROWSER") return;
      let reason;
      if (error?.code === "APP_ACK_PENDING" && typeof error.message === "string") {
        // Recovery-specific message ("Chrome cancelled; the MacIDM receipt
        // is pending recovery") is already user-actionable.
        reason = error.message;
      } else if (String(error?.code || "") === "TAKEOVER_FAILED" && typeof error?.message === "string") {
        // pause/cancel failures carry specific localized messages.
        reason = error.message;
      } else {
        const reasonKey = reasonKeyForError(error);
        reason = reasonKey ? t(reasonKey) : t("takeover.reasonKept");
      }
      this.notifier(t("takeover.notComplete"), t("takeover.notCompleteBody", { name, reason }));
    } catch {
      // Notifications are best-effort; never break the takeover flow.
    }
  }

  /// One-shot diagnostic when handleCreated bails out before touching the
  /// App (unsupported URL scheme, POST-triggered download). Throttled per
  /// reason code so a page that fires many such downloads in a row does
  /// not spam the user. Deliberately distinct from notifyTakeoverResult:
  /// this covers silent-skip paths where no bridge traffic happened.
  notifySkipped(item, reasonCode) {
    if (!this.notifier) return;
    const reasonKey = reasonCode === "unsupported-scheme"
      ? "takeover.skippedUnsupportedScheme"
      : reasonCode === "non-get-url"
        ? "takeover.skippedNonGetURL"
        : null;
    if (!reasonKey) return;
    const now = this.clock();
    // Lazy prune so the Map stays bounded across a long-lived SW.
    for (const [code, at] of this.skipNotificationAt) {
      if (now - at >= SKIP_NOTIFICATION_THROTTLE_MS) this.skipNotificationAt.delete(code);
    }
    const last = this.skipNotificationAt.get(reasonCode);
    if (typeof last === "number" && now - last < SKIP_NOTIFICATION_THROTTLE_MS) return;
    this.skipNotificationAt.set(reasonCode, now);
    try {
      const name = displayBasename(item).slice(0, 120);
      this.notifier(
        t("takeover.notComplete"),
        t("takeover.notCompleteBody", { name, reason: t(reasonKey) }),
      );
    } catch {
      // Best-effort; never break the takeover flow.
    }
  }

  async waitForInteractiveConfirmation(downloadId, idempotencyKey, payload) {
    const deadline = Date.now() + INTERACTIVE_TIMEOUT_MS;
    await this.markPhase(downloadId, "interactiveWaiting");
    // Only the first enqueue is a genuine user action; the 1s retries are
    // background polls and must not be allowed to wake an App the user just
    // quit (otherwise quitting mid-confirmation zombie-restarts the App).
    let first = true;
    while (Date.now() < deadline) {
      const response = await this.nativeClient.send(createRequest(
        "download.enqueue", idempotencyKey,
        { ...payload, interactive: true, ...(first ? {} : { poll: true }) },
      ));
      first = false;
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
      if (entry.phase === "userCancelPending") {
        await this.completeUserCancellation(entry.downloadId).catch(() => {
          this.notifyTakeoverResult(false, item ?? {},
            new ProtocolError("TAKEOVER_FAILED", t("takeover.cancelFailed"), true));
        });
        continue;
      }
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

  // A user's cancellation is durable until Chrome confirms the item is gone.
  // Recovery must never resume or create an App task for this intent.
  async completeUserCancellation(downloadId) {
    const [item] = await this.downloads.search({ id: downloadId });
    if (item) {
      if (item.state === "in_progress") {
        try {
          await this.downloads.cancel(downloadId);
        } catch (error) {
          const [current] = await this.downloads.search({ id: downloadId });
          if (current?.state === "in_progress") throw error;
        }
      }
      try {
        await this.downloads.erase({ id: downloadId });
      } catch (error) {
        const [remaining] = await this.downloads.search({ id: downloadId });
        if (remaining) throw error;
      }
    }
    await this.forget(downloadId);
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
      // Chrome resolved this name for the download item itself (honouring
      // Content-Disposition); it is authoritative in the App's naming trust
      // model (technical spec §8.1).
      filenameHintSource: "browserResolved",
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
