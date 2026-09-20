import {
  DEFAULT_SETTINGS,
  MENU_DOWNLOAD_ALL,
  MENU_DOWNLOAD_LINK,
  STORAGE_LAST_ERROR_KEY,
  STORAGE_PROFILE_ID_KEY,
  STORAGE_SETTINGS_KEY,
} from "../shared/constants.js";
// Side-effect import: installs globalThis.MacIDMSniffGovernance (classic
// script with no export statements, shared with content scripts).
import "../shared/sniff-governance.js";
import { t, i18n } from "../shared/i18n-access.js";
import { createRequest } from "../shared/protocol.js";
import {
  CONNECTION_HEALTH_ERROR_CODES,
  filterRecentSafeError,
  safeDiagnostic,
} from "../shared/redaction.js";
import { filenameFromDownload } from "../shared/validation.js";
import { NativeClient } from "./native-client.js";
import { ExplicitEnqueueClient } from "./explicit-enqueue.js";
import { buildRequestContext } from "./request-context.js";
import {
  isOriginAuthorized,
  normalizeHttpOrigin,
} from "../shared/cookie-authorization.js";
import { TakeoverController } from "./takeover-controller.js";
import { applyM4sPairing } from "./m4s-pairing.js";
import { isProbeableCandidate, fetchProbeDirect } from "./size-probe.js";
import { SizeProbeScheduler, PROBE_PRIORITY } from "./size-probe-scheduler.js";
import { SniffBudgetCoordinator } from "./sniff-budget-coordinator.js";
import { YouTubeInspectionCoordinator } from "./youtube-inspection-coordinator.js";
import {
  ProbeEvidenceLedger,
  decideAutoProbe,
  isProbeContextValid,
} from "./probe-policy.js";
import {
  alignMediaTabStateWithLiveURL,
  isHttpURL,
  mergeTabMediaCache,
  pruneBackgroundCandidates,
  rememberBackgroundCandidate,
  takeBackgroundCandidates,
} from "./media-observation.js";
import { isBodyCarryingMethod } from "./rules.js";

const nativeClient = new NativeClient();
const MAX_DOWNLOAD_ALL_LINKS = 1_000;
const DOWNLOAD_ALL_SCAN_TTL_MS = 10 * 60 * 1_000;
const downloadAllSubmissions = new Set();
// chrome-extension-spec §5.5: Download-All scan results contain full URLs
// (including query strings with signed-URL tokens). They live in a SW
// in-memory Map mirrored into chrome.storage.session — a pure in-memory
// store that evaporates when the browser closes and never touches disk.
// The mirror exists because MV3 evicts an idle SW after ~30s, which used to
// wipe the scan while the user was still picking links. Entries carry a TTL
// and are deleted on submit/expiry.
const downloadAllScans = new Map();
const downloadAllScanTabs = new Map();
const DOWNLOAD_ALL_SCAN_SESSION_PREFIX = "downloadAllScan.";
async function sessionScanKey(scanID) {
  return DOWNLOAD_ALL_SCAN_SESSION_PREFIX + scanID;
}
async function mirrorScanToSession(scanID, scan) {
  try {
    if (!chrome.storage?.session) return;
    await chrome.storage.session.set({
      [await sessionScanKey(scanID)]: scan,
    });
  } catch {
    // Session storage is best-effort resilience; the in-memory Map remains
    // the source of truth while the SW is alive.
  }
}
async function deleteScanFromSession(scanID) {
  try {
    if (!chrome.storage?.session) return;
    await chrome.storage.session.remove(await sessionScanKey(scanID));
  } catch {
    // Same best-effort contract as the mirror write.
  }
}
// POST-triggered downloads cannot be replayed with GET — the request
// body (form data, signed payload) is lost. Record non-GET request URLs so
// the takeover controller can skip them and leave the browser download
// intact. Entries expire after 5 minutes to bound memory.
const NON_GET_URL_TTL_MS = 5 * 60 * 1_000;
const nonGetRequestURLs = new Map();
// Overlay authorize windows: source tabId -> authorize windowId, used to
// close the window when authorize.done arrives.
const pendingAuthorizeWindows = new Map();
const mediaCandidatesByTab = new Map();
// Chrome reports downloads initiated by service workers with tabId=-1. Keep
// those candidates under the request initiator origin until the Popup asks for
// the matching page; never attach them to whichever tab happens to be active.
const backgroundMediaCandidatesByOrigin = new Map();
const probeEvidence = new ProbeEvidenceLedger();
const sniffBudgetCoordinator = new SniffBudgetCoordinator({
  maxPageBudget: 2 * 1024 * 1024,
});

function recheckProbePolicy({ tabId, generation, candidate, referer }) {
  if (!candidate || typeof candidate.url !== "string") return false;
  if (!Number.isInteger(tabId) || tabId < 0) return false;
  const currentGen = probeEvidence.generationOf(tabId);
  if (currentGen !== generation) return false;

  const currentEntry = mediaCandidatesByTab.get(tabId);
  if (!currentEntry) return false;

  // Strict fail-closed Referer gate and context validation (covers empty
  // referer, mismatched referer, and invalid pageUrl).
  if (
    !isProbeContextValid({
      currentGen,
      taskGen: generation,
      pageUrl: currentEntry.pageUrl,
      referer,
    })
  ) {
    return false;
  }

  const peerAddressInformative = probeEvidence.peerAddressIsInformative(tabId);
  const decision = decideAutoProbe({
    candidate,
    evidence: probeEvidence.evidenceFor(candidate.url, { tabId }),
    pageURL: currentEntry.pageUrl,
    probeable: isProbeableCandidate(candidate),
    peerAddressInformative,
  });

  return decision.allowed === true;
}

const sizeProbeScheduler = new SizeProbeScheduler({
  globalConcurrency: 8,
  perTabConcurrency: 4,
  autoRetry: true,
  getGeneration: (tabId) => probeEvidence.generationOf(tabId),
  fetchProbe: (url, opts) => fetchProbeDirect(url, opts),
  canDispatch: (task) => recheckProbePolicy(task),
  canPublish: (sub, result) => recheckProbePolicy(sub),
  pushResult: (tabId, payload) => {
    if (Number.isSafeInteger(payload?.size)) {
      probeEvidence.clearFailures(payload.url, { tabId });
      const current = mediaCandidatesByTab.get(tabId);
      if (current) {
        const target = current.candidates.find((item) => item.url === payload.url);
        if (target && !Number.isSafeInteger(target.size)) {
          target.size = payload.size;
          if (payload.mime && !target.mime) target.mime = payload.mime;
        }
        // Display-only server filename (Content-Disposition). Never promoted
        // to filenameHint/filenameHintSource on the wire: the bridge validator
        // accepts only browserResolved/titleDerived/urlPath.
        if (target && payload.cdFilename) target.serverFilename = payload.cdFilename;
      }
    }
    pushProbeResultToPage(tabId, payload);
  },
});
const settingsProvider = async () => {
  const stored = await chrome.storage.local.get(STORAGE_SETTINGS_KEY);
  const raw = stored[STORAGE_SETTINGS_KEY] ?? DEFAULT_SETTINGS;
  // sniffGovernance field-by-field validation migration (read-time
  // migration path): never trust old chrome.storage values directly.
  return {
    ...raw,
    sniffGovernance: globalThis.MacIDMSniffGovernance
      ? globalThis.MacIDMSniffGovernance.normalizeSniffGovernance(raw?.sniffGovernance)
      : DEFAULT_SETTINGS.sniffGovernance,
  };
};
// Wraps buildRequestContext to surface the secure cookie diagnostics
// (booleans/counts/bytes only — never cookie names or values) in the
// service-worker console, answering whether cookies were authorized,
// queried, partition-filtered, dropped for size, or attached
// (see the public extension specification).
const provideRequestContext = async (item) => {
  const { context, cookieDiagnostics } = await buildRequestContext(item);
  if (cookieDiagnostics) {
    console.debug("[MacIDM] requestContext cookieDiagnostics", cookieDiagnostics);
  }
  return context;
};
const controller = new TakeoverController({
  downloads: chrome.downloads,
  storage: chrome.storage,
  nativeClient,
  settingsProvider,
  profileIDProvider: getProfileID,
  requestContextProvider: provideRequestContext,
  nonGetURLProvider: () => pruneAndReturnNonGetURLs(),
  notifier: (title, message) => {
    chrome.notifications
      .create({
        type: "basic",
        iconUrl: chrome.runtime.getURL("icons/icon-128.png"),
        title,
        message,
      })
      .catch(() => {});
  },
});
const explicitEnqueue = new ExplicitEnqueueClient({
  nativeClient,
  profileIDProvider: getProfileID,
  requestContextProvider: provideRequestContext,
});

// YouTube in-page inspection coordinator: the
// Popup and the overlay share one inspection and one stage snapshot; page
// data comes from the content script (MAIN world bridge), and App/yt-dlp
// runs only as one shared fallback.
const youTubeInspectionCoordinator = new YouTubeInspectionCoordinator({
  requestPageQualities: (tabId, message) =>
    chrome.tabs.sendMessage(tabId, message, { frameId: 0 }),
  appInspector: async ({ tabId, url }) => {
    try {
      const context = await mediaTabContext(tabId, {});
      const payload = await explicitEnqueue.inspect({
        url,
        referrer: context.referrer,
        tabId: context.tabId,
        mediaKind: "youtube",
        // ensure/retry only arrive from the Popup or the overlay panel, both
        // of which the user opened; the yt-dlp fallback may therefore wake a
        // quit App instead of reporting a launch timeout.
        userInitiated: true,
      });
      return { ok: true, variants: payload?.variants ?? [] };
    } catch (error) {
      // Structured error categories stay distinct (§5.4): timeout /
      // channel-unreachable / rejected are independent; the presentation
      // layer merges them safely later and never disguises them all as
      // network/proxy errors. The App's stable MEDIA_* inspection categories
      // (including MEDIA_CLEANUP_FAILED) are kept
      // as-is.
      const code = String(error?.code ?? "");
      let errorCategory = "unknown";
      if (code.endsWith("_TIMEOUT")) errorCategory = "timeout";
      else if (code === "NATIVE_HOST_NOT_FOUND") errorCategory = "appUnreachable";
      else if (code === "APP_REJECTED") errorCategory = "appRejected";
      else if (code.startsWith("MEDIA_")) errorCategory = code;
      return {
        ok: false,
        message: safeDiagnostic(error).message,
        errorCategory,
      };
    }
  },
  publish: (tabId, snapshot) => {
    const update = { type: "macidm.youTubeInspectionUpdate", snapshot };
    // The overlay (content script) and the Popup (runtime context) subscribe
    // to the same snapshot stream.
    chrome.tabs.sendMessage(tabId, update, { frameId: 0 }).catch(() => {});
    chrome.runtime.sendMessage(update).catch(() => {});
  },
});

// Keep Chrome's built-in download bubble/shelf enabled so a takeover
// failure or a silent skip (blob/data URL, POST-triggered download,
// blocked site, unreachable host, version mismatch) still leaves the user
// with visible download progress instead of "nothing happened". A
// successful takeover pauses → cancels → erases the browser download, so
// the shelf entry disappears naturally in the happy path.
// Guarded for forward compatibility — setUiOptions may not exist in all
// Chrome versions.
if (typeof chrome.downloads.setUiOptions === "function") {
  chrome.downloads.setUiOptions({ enabled: true }).catch(() => {});
}

function refreshContextMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_DOWNLOAD_LINK,
      title: t("serviceWorker.menuDownloadLink"),
      contexts: ["link"],
    });
    chrome.contextMenus.create({
      id: MENU_DOWNLOAD_ALL,
      title: t("serviceWorker.menuDownloadAll"),
      contexts: ["page"],
    });
  });
}

// Load the persisted language choice as soon as the worker wakes; context
// menus are rebuilt whenever the resolved language changes.
i18n.init().catch(() => {});
i18n.onChange(() => refreshContextMenus());

chrome.runtime.onInstalled.addListener(async () => {
  refreshContextMenus();
  const stored = await chrome.storage.local.get(STORAGE_SETTINGS_KEY);
  if (!stored[STORAGE_SETTINGS_KEY]) {
    await chrome.storage.local.set({ [STORAGE_SETTINGS_KEY]: DEFAULT_SETTINGS });
  }
});

let recoveryPromise;
chrome.runtime.onStartup.addListener(() => recoverPendingOnce());
recoverPendingOnce();

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "download-all-selection") return;
  port.onDisconnect.addListener(() => {});
});

chrome.tabs.onRemoved.addListener((tabId) => {
  mediaCandidatesByTab.delete(tabId);
  probeEvidence.handleTabRemoved(tabId);
  youTubeInspectionCoordinator.handleTabRemoved(tabId);
  sizeProbeScheduler.cancelTab(tabId);
  sniffBudgetCoordinator.clearTab(tabId);
  const abandonedScanID = downloadAllScanTabs.get(tabId);
  if (abandonedScanID !== undefined) {
    downloadAllScanTabs.delete(tabId);
    // chrome-extension-spec §5.5: the selection page was closed without submitting; the
    // signed-URL list must not outlive it.
    removeDownloadAllScan(abandonedScanID).catch(() => {});
  }
});

// Sniff governance settings changed: clear every tab's candidate cache. The
// cache merge is a URL union, so without clearing, stale ungoverned
// candidates would survive a "disable → enable" toggle; content scripts
// listen to the same storage change and republish governed snapshots under
// the new settings, rebuilding the cache right away.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  const change = changes?.[STORAGE_SETTINGS_KEY];
  if (!change) return;
  const normalize = globalThis.MacIDMSniffGovernance?.normalizeSniffGovernance;
  if (!normalize) return;
  const before = JSON.stringify(normalize(change.oldValue?.sniffGovernance));
  const after = JSON.stringify(normalize(change.newValue?.sniffGovernance));
  if (before === after) return;
  mediaCandidatesByTab.clear();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" || typeof changeInfo.url === "string") {
    mediaCandidatesByTab.delete(tabId);
    // Cancel all in-flight and queued tasks for this tab (triggers the
    // AbortSignal and fully stops old requests).
    sizeProbeScheduler.cancelTab(tabId);
    // Clear all of the tab's old page budget ledgers.
    sniffBudgetCoordinator.clearTab(tabId);
    // Bump the generation, invalidating every probe and sniff authorization
    // of the old document.
    probeEvidence.handleTabNavigated(tabId);
    // SPA navigation bumps the generation: inspection records for the old
    // videoId are dropped, never handing video A's variants to video B
    // (see the public extension specification).
    youTubeInspectionCoordinator.handleTabNavigated(tabId, changeInfo.url);
    // tabId < 0 observations are keyed by origin because Chrome does not
    // provide their originating tab. Drop the current origin on navigation so
    // a same-origin page cannot inherit another page's short-lived media.
    const changedURL = changeInfo.url;
    if (isHttpURL(changedURL)) {
      backgroundMediaCandidatesByOrigin.delete(new URL(changedURL).origin);
    } else {
      chrome.tabs.get(tabId).then((tab) => {
        if (isHttpURL(tab?.url)) {
          backgroundMediaCandidatesByOrigin.delete(new URL(tab.url).origin);
        }
      }).catch(() => {});
    }
    pruneBackgroundCandidates(backgroundMediaCandidatesByOrigin);
  }
});

chrome.downloads.onCreated.addListener((item) => {
  controller.handleCreated(item).catch(recordSafeError);
});

chrome.downloads.onChanged.addListener((changeInfo) => {
  controller.handleChanged(changeInfo.id, changeInfo).catch(recordSafeError);
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === MENU_DOWNLOAD_LINK && info.linkUrl) {
      await explicitEnqueue.enqueue({
        url: info.linkUrl,
        referrer: info.pageUrl,
        tabId: tab?.id,
        pageTitle: tab?.title,
      });
    } else if (info.menuItemId === MENU_DOWNLOAD_ALL && tab?.id != null) {
      await startDownloadAll(tab.id);
    }
  } catch (error) {
    await recordSafeError(error);
  }
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "popup.status") {
    popupStatus()
      .then(sendResponse)
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "popup.mediaCandidates") {
    getPopupMediaCandidates(message.tabId)
      .then(sendResponse)
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "popup.setTakeover") {
    setTakeover(message.enabled === true)
      .then(sendResponse)
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "popup.setSniffGovernance") {
    setSniffGovernance(
      typeof message.enabled === "boolean" ? message.enabled : undefined,
      message.thresholds,
    )
      .then(sendResponse)
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "popup.openApp") {
    // Dedicated user gesture to open the App. Unlike the background status
    // ping, app.activate is authorized to relaunch an App the user
    // previously quit (the Host clears the quit-intent marker for it), so
    // the toolbar "Open MacIDM" button keeps working after a manual quit.
    nativeClient
      .activate(createRequest)
      .then(() => sendResponse({ ok: true }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, error: safeDiagnostic(error) });
      });
    return true;
  }
  if (message?.type === "popup.downloadAll") {
    startDownloadAll(message.tabId)
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "media.candidatesUpdated") {
    if (Number.isInteger(sender.tab?.id) && sender.tab.id >= 0) {
      rememberMediaCandidates(sender.tab.id, message, sender.frameId);
    }
    return false;
  }
  if (message?.type === "overlay.tabTitle") {
    const tabId = sender?.tab?.id;
    if (Number.isInteger(tabId) && tabId >= 0) {
      chrome.tabs
        .get(tabId)
        .then((tab) => sendResponse({
          ok: true,
          tabId,
          title: tab?.title ?? "",
          url: isHttpURL(tab?.url) ? tab.url : "",
        }))
        .catch(() => sendResponse({ ok: false, title: "", url: "" }));
    } else {
      sendResponse({ ok: false, title: "", url: "" });
    }
    return true;
  }
  if (message?.type === "overlay.permissionState") {
    // Content scripts cannot call chrome.permissions; site-level grants are
    // read from the chrome.storage ledger (permissions.contains' origins
    // argument is made meaningless by global host_permissions).
    const origin = normalizeHttpOrigin(sender?.tab?.url);
    if (!origin) {
      sendResponse({ ok: true, cookieGranted: false });
      return false;
    }
    isOriginAuthorized(chrome, origin)
      .then((granted) => sendResponse({ ok: true, cookieGranted: granted === true }))
      .catch(() => sendResponse({ ok: true, cookieGranted: false }));
    return true;
  }
  if (message?.type === "overlay.openPopup" || message?.type === "overlay.authorizeCookies") {
    // The overlay's authorize entry point: prefer waking the extension
    // popup (its title bar has one-click authorize); when openPopup is
    // unavailable or rejected (version/gesture limits), fall back to the
    // small authorize window.
    const tabId = sender?.tab?.id;
    let origin = null;
    try {
      origin = isHttpURL(sender?.tab?.url) ? new URL(sender.tab.url).origin : null;
    } catch {
      origin = null;
    }
    if (!origin || !Number.isInteger(tabId) || tabId < 0) {
      sendResponse({ ok: false });
      return false;
    }
    const openSmallAuthorizeWindow = async () => {
      const authorizeURL = chrome.runtime.getURL("src/authorize/authorize.html")
        + `?origin=${encodeURIComponent(origin)}&tabId=${tabId}`;
      const win = await chrome.windows.create({
        url: authorizeURL,
        type: "popup",
        width: 400,
        height: 240,
        focused: true,
      });
      if (win && Number.isInteger(win.id)) pendingAuthorizeWindows.set(tabId, win.id);
    };
    const openPopupFirst = async () => {
      if (typeof chrome.action?.openPopup !== "function") {
        throw new Error("chrome.action.openPopup unavailable");
      }
      await chrome.action.openPopup();
    };
    openPopupFirst()
      .catch(() => openSmallAuthorizeWindow())
      .then(() => sendResponse({ ok: true }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false });
      });
    return true;
  }
  if (message?.type === "authorize.done") {
    const tabId = Number.isInteger(message.tabId) ? message.tabId : null;
    const granted = message.granted === true;
    if (tabId != null) {
      const windowId = pendingAuthorizeWindows.get(tabId);
      pendingAuthorizeWindows.delete(tabId);
      // Auto-close the window only on a successful grant; on rejection keep
      // it so the user can read the notice and close it manually.
      if (granted && Number.isInteger(windowId)) chrome.windows.remove(windowId).catch(() => {});
      // Notify the source tab's overlay to refresh its authorization state
      // and (if granted) clear the cache and re-inspect.
      chrome.tabs
        .sendMessage(tabId, { type: "macidm.cookieAuthorized", granted })
        .catch(() => {});
    }
    sendResponse({ ok: true });
    return false;
  }
  if (message?.type === "downloadAll.getScan") {
    getDownloadAllScan(message.scanID)
      .then((scan) => sendResponse(scan ? { ok: true, ...scan } : { ok: false, message: t("serviceWorker.scanExpired") }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: t("serviceWorker.scanUnavailable") });
      });
    return true;
  }
  if (message?.type === "downloadAll.releaseScan") {
    // Sent by the selection page's pagehide; works across SW restarts
    // because the message itself wakes the worker.
    if (typeof message.scanID === "string") {
      if (Number.isInteger(sender.tab?.id)) {
        downloadAllScanTabs.delete(sender.tab.id);
      }
      removeDownloadAllScan(message.scanID).catch(() => {});
    }
    sendResponse({ ok: true });
    return false;
  }
  if (message?.type === "downloadAll.submit") {
    submitDownloadAll(message.scanID, message.urls)
      .then(sendResponse)
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "media.download") {
    mediaTabContext(message.tabId, sender)
      .then((context) =>
        explicitEnqueue.enqueue({
          url: message.url,
          referrer: context.referrer,
          tabId: context.tabId,
          mediaKind: message.mediaKind,
          mime: message.mime,
          filenameHint: message.filenameHint,
          filenameHintSource: message.filenameHintSource,
          pageTitle: message.pageTitle,
          interactive: true,
          pairVideoUrl: message.pairVideoUrl,
          pairAudioUrl: message.pairAudioUrl,
          pairCid: message.pairCid,
          pairNote: message.pairNote,
          duration: message.duration,
          estimatedSize: message.estimatedSize,
        }),
      )
      .then((payload) => sendResponse({ ok: true, ...payload }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "media.inspect") {
    mediaTabContext(message.tabId, sender)
      .then((context) =>
        explicitEnqueue.inspect({
          url: message.url,
          referrer: context.referrer,
          tabId: context.tabId,
          mediaKind: message.mediaKind,
          // Both senders (Popup, overlay panel) are surfaces the user opened,
          // so the inspection may wake an App the user quit earlier.
          userInitiated: message.userInitiated === true,
        }),
      )
      .then((payload) => sendResponse({ ok: true, ...payload }))
      .catch(async (error) => {
        await recordSafeError(error);
        sendResponse({ ok: false, message: safeDiagnostic(error).message });
      });
    return true;
  }
  if (message?.type === "youtube.ensureInspection") {
    // Shared inspection entry: only one in-flight page inspection per
    // tabId + videoId; opening/closing the Popup does not cancel it, and a
    // reopen reads the latest snapshot (§5.1).
    const tabId = Number.isInteger(message.tabId) && message.tabId >= 0
      ? message.tabId
      : sender?.tab?.id;
    const snapshot = youTubeInspectionCoordinator.ensure({
      tabId,
      url: message.url,
      force: message.force === true,
    });
    sendResponse(snapshot ? { ok: true, snapshot } : { ok: false });
    return false;
  }
  if (message?.type === "youtube.retryInspection") {
    const tabId = Number.isInteger(message.tabId) && message.tabId >= 0
      ? message.tabId
      : sender?.tab?.id;
    const snapshot = youTubeInspectionCoordinator.retry({ tabId, url: message.url });
    sendResponse(snapshot ? { ok: true, snapshot } : { ok: false });
    return false;
  }
  if (message?.type === "macidm.sniff.acquireLease") {
    const tabId = sender?.tab?.id;
    const generation = probeEvidence.generationOf(tabId);
    const result = sniffBudgetCoordinator.acquireLease({
      tabId,
      generation,
      requestedBytes: message.requestedBytes,
      tier: message.tier,
    });
    sendResponse(result);
    return false;
  }
  if (message?.type === "macidm.sniff.settleLease") {
    const tabId = sender?.tab?.id;
    const generation = probeEvidence.generationOf(tabId);
    const result = sniffBudgetCoordinator.settleLease({
      tabId,
      generation,
      leaseId: message.leaseId,
      actualBytes: message.actualBytes,
    });
    sendResponse(result);
    return false;
  }
  if (message?.type === "macidm.sniff.releaseLease") {
    const tabId = sender?.tab?.id;
    const generation = probeEvidence.generationOf(tabId);
    const result = sniffBudgetCoordinator.releaseLease({
      tabId,
      generation,
      leaseId: message.leaseId,
      reason: message.reason,
    });
    sendResponse(result);
    return false;
  }
  return false;
});

chrome.webRequest.onBeforeRequest.addListener(
  (details) => {
    // POST/PUT/PATCH/DELETE-triggered downloads cannot be replayed with GET
    // — the request body (form data, signed payload, CSRF token) is lost.
    // Record body-carrying request URLs so the takeover controller can skip
    // them. HEAD/OPTIONS are bodyless probes that players (e.g. jwplayer) fire
    // before the real GET download of the SAME url; recording them wrongly
    // suppressed takeover of that later GET download (the hanime1.me case).
    if (isBodyCarryingMethod(details.method)) {
      if (typeof details.url === "string" && isHttpURL(details.url)) {
        nonGetRequestURLs.set(details.url, Date.now());
        // Prune inline: previously only the takeover path pruned, so
        // POST-heavy pages (login flows, telemetry) grew this map without
        // bound for the whole SW lifetime.
        const now = Date.now();
        for (const [url, ts] of nonGetRequestURLs) {
          if (now - ts > NON_GET_URL_TTL_MS) nonGetRequestURLs.delete(url);
        }
      }
    }
  },
  { urls: ["http://*/*", "https://*/*"] },
);

function pruneAndReturnNonGetURLs() {
  const now = Date.now();
  for (const [url, ts] of nonGetRequestURLs) {
    if (now - ts > NON_GET_URL_TTL_MS) nonGetRequestURLs.delete(url);
  }
  return nonGetRequestURLs;
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    const headerValue = (name) =>
      details.responseHeaders?.find((header) => header.name.toLowerCase() === name)?.value;
    const contentType = headerValue("content-type") ?? "";
    const contentRange = headerValue("content-range") ?? "";
    const contentDisposition = headerValue("content-disposition") ?? "";
    if (!isMediaResponse(details.url, contentType, contentRange, contentDisposition)) return;
    const contentLength = Number.parseInt(headerValue("content-length") ?? "", 10);
    let size = Number.isSafeInteger(contentLength) && contentLength >= 0 ? contentLength : null;
    if (contentRange) {
      const match = contentRange.match(/\/(\d+)/);
      if (match) {
        const rangeTotal = Number.parseInt(match[1], 10);
        if (Number.isSafeInteger(rangeTotal) && rangeTotal >= 0) {
          size = rangeTotal;
        }
      }
    }
    const candidate = {
      url: details.url,
      mime: contentType.slice(0, 256),
      size,
    };
    if (details.tabId < 0) {
      // The target may be a CDN. The initiator is the only safe association
      // key, and an absent/opaque initiator is intentionally discarded.
      rememberBackgroundCandidate(backgroundMediaCandidatesByOrigin, details.initiator, candidate);
      return;
    }
    const frameId = Number.isInteger(details.frameId) && details.frameId >= 0
      ? details.frameId
      : 0;
    // Evidence for the probe policy is recorded by onResponseStarted below:
    // `onHeadersReceived` carries no `ip`, and without the observed peer
    // address a cross-origin target cannot be proven public.
    // Route a response-header observation to the frame that made the request.
    // Broadcasting to every content-script frame lets an ad iframe inject its
    // media into the top page and makes the source/page association ambiguous.
    chrome.tabs
      .sendMessage(
        details.tabId,
        {
          type: "macidm.addMediaCandidate",
          candidate,
        },
        { frameId },
      )
      .catch(() => {});
  },
  { urls: ["http://*/*", "https://*/*"] },
  ["responseHeaders"],
);

// This is the only place automatic-probe evidence is recorded: `ip` — the server
// address the request actually went to — is documented on onResponseStarted (and
// onBeforeRedirect/onCompleted/onErrorOccurred), not on onHeadersReceived. It is
// what lets a hostname target be proven public instead of merely well-named.
chrome.webRequest.onResponseStarted.addListener(
  (details) => {
    if (!Number.isInteger(details.tabId) || details.tabId < 0) return;
    // Peer bookkeeping sees every response rather than only media ones: the page
    // document is what proves whether this browser connects directly or hands
    // everything to a local proxy.
    probeEvidence.observePeer({
      tabId: details.tabId,
      url: details.url,
      ip: details.ip,
    });
    const headerValue = (name) =>
      details.responseHeaders?.find((header) => header.name.toLowerCase() === name)?.value;
    if (!isMediaResponse(
      details.url,
      headerValue("content-type") ?? "",
      headerValue("content-range") ?? "",
      headerValue("content-disposition") ?? "",
    )) return;
    const frameId = Number.isInteger(details.frameId) && details.frameId >= 0
      ? details.frameId
      : 0;
    const recorded = probeEvidence.record({
      tabId: details.tabId,
      url: details.url,
      ip: details.ip,
      frameId,
      documentId: details.documentId,
    });
    // Response-started normally lands after the candidate was first scheduled,
    // so a refusal caused by missing evidence has to be revisited here.
    if (recorded && probeEvidence.wasDeclined(details.url, { tabId: details.tabId })) {
      const candidates = mediaCandidatesByTab.get(details.tabId)?.candidates ?? [];
      scheduleSizeProbes(
        details.tabId,
        candidates.filter((candidate) => candidate.url === details.url),
      );
    }
  },
  { urls: ["http://*/*", "https://*/*"] },
  ["responseHeaders"],
);

async function getRecentSafeError(options = { isConnected: true }) {
  try {
    const stored = await chrome.storage.local.get(STORAGE_LAST_ERROR_KEY);
    const raw = stored[STORAGE_LAST_ERROR_KEY];
    const { keep, error } = filterRecentSafeError(raw, Date.now(), options.isConnected);
    if (!keep) {
      if (raw) {
        await chrome.storage.local.remove(STORAGE_LAST_ERROR_KEY);
      }
      return null;
    }
    return error;
  } catch {
    return null;
  }
}

async function popupStatus() {
  const settings = await settingsProvider();
  // The Popup threshold inputs need the full governance settings (including
  // the three threshold fields); the enabled boolean is kept for legacy
  // consumers of the old field.
  const governance = {
    sniffGovernanceEnabled: settings.sniffGovernance?.enabled === true,
    sniffGovernance: settings.sniffGovernance,
  };
  // If there are active non-ping requests (e.g. media.inspect or download.enqueue)
  // in flight on the single serial port, skip ping to avoid adding a 3s blocked request to the queue.
  if (nativeClient.hasPendingNonPingRequests()) {
    const storedError = await getRecentSafeError({ isConnected: true });
    return {
      connected: true,
      takeoverEnabled: settings.takeoverEnabled,
      ...governance,
      lastError: storedError,
    };
  }
  try {
    await nativeClient.ping(createRequest);
    const storedError = await getRecentSafeError({ isConnected: true });
    return {
      connected: true,
      takeoverEnabled: settings.takeoverEnabled,
      ...governance,
      lastError: storedError,
    };
  } catch (error) {
    const diagnostic = safeDiagnostic(error);
    // Connection-health codes mean "the App is not up right now", not a fault
    // the user has to act on. Reporting them as `lastError` made the Popup
    // toast "launch timed out; the Chrome download will continue" every time
    // it opened while the App was simply quit. Return a reason instead so the
    // Popup can render an actionable status dot and stay silent.
    const healthCode = CONNECTION_HEALTH_ERROR_CODES.has(diagnostic.code) ? diagnostic.code : null;
    return {
      connected: false,
      unreachableReason: healthCode === "NATIVE_HOST_NOT_FOUND"
        ? "hostMissing"
        : healthCode
          ? "appNotRunning"
          : null,
      takeoverEnabled: settings.takeoverEnabled,
      ...governance,
      lastError: healthCode ? null : diagnostic,
    };
  }
}

async function setTakeover(enabled) {
  const settings = { ...(await settingsProvider()), takeoverEnabled: enabled };
  await chrome.storage.local.set({ [STORAGE_SETTINGS_KEY]: settings });
  return { ok: true, takeoverEnabled: enabled };
}

// Popup's high-frequency "filter noisy candidates" toggle and threshold
// inputs: enabled and the three threshold fields
// (minimumMediaBytes / audioMinimumBytes / segmentMaximumBytes, in bytes)
// are all optional writes; fields not provided keep the settingsProvider's
// normalized result; thresholds are validated field-by-field by
// normalizeSniffGovernance (0–64 MiB safe integers).
async function setSniffGovernance(enabled, thresholds) {
  const settings = await settingsProvider();
  const normalized = globalThis.MacIDMSniffGovernance
    ? globalThis.MacIDMSniffGovernance.normalizeSniffGovernance(settings.sniffGovernance)
    : settings.sniffGovernance;
  const sniffGovernance = { ...normalized };
  if (typeof enabled === "boolean") sniffGovernance.enabled = enabled;
  if (thresholds && typeof thresholds === "object" && !Array.isArray(thresholds)) {
    for (const field of ["minimumMediaBytes", "audioMinimumBytes", "segmentMaximumBytes"]) {
      const value = thresholds[field];
      if (Number.isSafeInteger(value) && value >= 0 && value <= 64 * 1024 * 1024) {
        sniffGovernance[field] = value;
      }
    }
  }
  await chrome.storage.local.set({ [STORAGE_SETTINGS_KEY]: { ...settings, sniffGovernance } });
  return { ok: true, sniffGovernanceEnabled: sniffGovernance.enabled, sniffGovernance };
}

async function ensureContentScript(tabId) {
  if (!Number.isInteger(tabId) || tabId < 0) throw new Error(t("serviceWorker.pageUnavailable"));
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    world: "MAIN",
    files: ["src/content/media-source-observer.js"],
  });
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    files: [
      "src/shared/media-utils.js",
      "src/shared/youtube-format-utils.js",
      "src/shared/media-presentation.js",
      "src/shared/sniff-governance.js",
      "src/shared/category.js",
      "src/shared/i18n.js",
      "src/shared/locale-zh-cn.js",
      "src/shared/locale-en.js",
      "src/shared/panel-ui.js",
      "src/content/discovery.js",
      "src/content/content-script.js",
      "src/content/media-element-scope.js",
      "src/content/overlay.js",
    ],
  });
}

async function startDownloadAll(tabId) {
  await ensureContentScript(tabId);
  // Collect links from the main frame only: with all_frames content scripts,
  // a broadcast without frameId resolves with the first responder, which on
  // pages with ad iframes is often the iframe's nav links rather than the
  // page's own download links.
  const scan = await chrome.tabs.sendMessage(
    tabId,
    { type: "macidm.scanLinks" },
    { frameId: 0 },
  );
  if (!Array.isArray(scan?.links)) throw new Error(t("serviceWorker.linksUnreadable"));
  const scanID = crypto.randomUUID();
  await purgeExpiredScans();
  await saveDownloadAllScan(scanID, {
    pageUrl: scan.pageUrl,
    title: scan.title,
    links: scan.links.slice(0, MAX_DOWNLOAD_ALL_LINKS),
    expiresAt: Date.now() + DOWNLOAD_ALL_SCAN_TTL_MS,
  });
  const selectionTab = await chrome.tabs.create({
    url: chrome.runtime.getURL(`src/download-all/download-all.html?scan=${scanID}`),
  });
  // chrome-extension-spec §5.5: closing the selection page must delete the scan immediately.
  if (Number.isInteger(selectionTab?.id)) {
    downloadAllScanTabs.set(selectionTab.id, scanID);
  }
  return { count: scan.links.length };
}

async function submitDownloadAll(scanID, requestedURLs) {
  if (downloadAllSubmissions.has(scanID)) {
    return { ok: false, message: t("serviceWorker.scanSubmitting") };
  }
  downloadAllSubmissions.add(scanID);
  try {
    const scan = await getDownloadAllScan(scanID);
    if (!scan || scan.expiresAt <= Date.now()) {
      return { ok: false, message: t("serviceWorker.scanExpiredRescan") };
    }
    const allowed = new Map(scan.links.map((item) => [item.url, item]));
    const links = Array.isArray(requestedURLs)
      ? [...new Set(requestedURLs)]
          .map((url) => allowed.get(url))
          .filter(Boolean)
          .slice(0, MAX_DOWNLOAD_ALL_LINKS)
      : [];
    let accepted = 0;
    for (const [index, link] of links.entries()) {
      try {
        const anchorText = typeof link.text === "string" ? link.text.trim() : "";
        await explicitEnqueue.enqueue({
          url: link.url,
          referrer: scan.pageUrl,
          // The anchor label is the most useful filename signal for
          // Download-All. Fall back to the page title only when the link has
          // no usable text; the URL-derived name remains the final fallback.
          pageTitle: anchorText || scan.title,
          filenameHint: filenameFromDownload({ url: link.url, filename: anchorText }),
          // An anchor-text hint is a semantic name; a URL-tail hint is not
          // (technical spec §8.1 naming trust model).
          filenameHintSource: anchorText ? "titleDerived" : "urlPath",
          operationID: `${scanID}-${index}`,
        });
        accepted += 1;
      } catch (error) {
        await recordSafeError(error);
      }
    }
    await removeDownloadAllScan(scanID);
    return { ok: true, accepted };
  } finally {
    downloadAllSubmissions.delete(scanID);
  }
}

function isMediaResponse(url, contentType, contentRange = "", contentDisposition = "") {
  // Extension detection looks at the path only (before the first ?/#):
  // telemetry-style requests copy whole media URLs into query parameters
  // (e.g. Bilibili log/web beacons embedding CDN m4s URLs), so an
  // extension inside the parameters is not candidate evidence — this keeps
  // response-header observation from flagging beacon logs as media.
  const path = String(url ?? "").split(/[?#]/u, 1)[0];
  if (
    /\.(?:m3u8|mpd|mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mp2t|mkv|avi|wmv|flv|opus|wav|jpg|jpeg|png|gif|webp|avif|bmp|tiff|heic|heif)(?:$|[?#])/iu.test(path) ||
    /^(?:video|audio|image)\//iu.test(contentType) ||
    /(?:mpegurl|dash\+xml)/iu.test(contentType)
  ) {
    return true;
  }
  // A Content-Range header almost always indicates media streaming (browsers
  // use Range requests for <video>/<audio>). CDNs that serve video without a
  // media extension or with application/octet-stream still send Content-Range.
  if (contentRange && /^bytes\s+\d+-\d+\/\d+/iu.test(contentRange)) {
    return true;
  }
  // Content-Disposition may carry the original filename with a media extension,
  // even when the URL and Content-Type are generic (e.g. CDN download links).
  if (contentDisposition) {
    const filenameMatch = contentDisposition.match(/filename\s*=\s*"?([^";]+)/iu);
    if (filenameMatch) {
      const filename = filenameMatch[1].trim().toLowerCase();
      if (/\.(?:mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mkv|avi|wmv|flv|opus|wav|m3u8|mpd)(?:$|[?#])/u.test(filename)) {
        return true;
      }
    }
  }
  return false;
}

async function recoverPendingOnce() {
  if (!recoveryPromise) {
    recoveryPromise = controller
      .recoverPending()
      .catch(recordSafeError)
      .finally(() => {
        recoveryPromise = undefined;
      });
  }
  return recoveryPromise;
}

async function saveDownloadAllScan(scanID, scan) {
  downloadAllScans.set(scanID, scan);
  await mirrorScanToSession(scanID, scan);
}

async function getDownloadAllScan(scanID) {
  if (typeof scanID !== "string" || !scanID) return null;
  let scan = downloadAllScans.get(scanID);
  if (!scan && chrome.storage?.session) {
    try {
      const stored = await chrome.storage.session.get(await sessionScanKey(scanID));
      scan = stored[await sessionScanKey(scanID)];
      // Survived an SW eviction: repopulate the in-memory Map so the next
      // read (and purge) sees it without another session round-trip.
      if (scan) downloadAllScans.set(scanID, scan);
    } catch {
      scan = undefined;
    }
  }
  if (!scan || scan.expiresAt <= Date.now()) {
    if (scan) await removeDownloadAllScan(scanID);
    return null;
  }
  return scan;
}

async function removeDownloadAllScan(scanID) {
  downloadAllScans.delete(scanID);
  await deleteScanFromSession(scanID);
}

async function purgeExpiredScans() {
  const now = Date.now();
  for (const [scanID, scan] of downloadAllScans) {
    if (!scan || scan.expiresAt <= now) {
      downloadAllScans.delete(scanID);
      await deleteScanFromSession(scanID);
    }
  }
  // Orphan backstop: a scan whose selection tab vanished while the SW was
  // evicted has no in-memory entry and nobody reading it — its session copy
  // must still age out (chrome-extension-spec §5.5) instead of living until browser exit.
  try {
    if (!chrome.storage?.session) return;
    const stored = await chrome.storage.session.get(null);
    const stale = Object.entries(stored)
      .filter(([key, value]) => {
        if (!key.startsWith(DOWNLOAD_ALL_SCAN_SESSION_PREFIX)) return false;
        return !value || typeof value.expiresAt !== "number" || value.expiresAt <= now;
      })
      .map(([key]) => key);
    if (stale.length) await chrome.storage.session.remove(stale);
  } catch {
    // Best-effort TTL sweep.
  }
}

// Fire-and-forget on every SW start (cold boot and eviction wake): keeps
// orphaned session scans bounded without waiting for a new scan to trigger
// purgeExpiredScans.
purgeExpiredScans().catch(() => {});

async function getProfileID() {
  const stored = await chrome.storage.local.get(STORAGE_PROFILE_ID_KEY);
  if (typeof stored[STORAGE_PROFILE_ID_KEY] === "string") {
    return stored[STORAGE_PROFILE_ID_KEY];
  }
  const value = `chrome-profile:${crypto.randomUUID()}`;
  await chrome.storage.local.set({ [STORAGE_PROFILE_ID_KEY]: value });
  return value;
}

async function recordSafeError(error) {
  try {
    await chrome.storage.local.set({ [STORAGE_LAST_ERROR_KEY]: safeDiagnostic(error) });
  } catch {
    // Diagnostics must never prevent the original message from receiving a
    // response or turn a recoverable service-worker error into an unhandled
    // rejection.
  }
}

async function getPopupMediaCandidates(tabId) {
  if (!Number.isInteger(tabId) || tabId < 0) {
    return { ok: false, message: t("serviceWorker.sniffUnsupported") };
  }
  let tab = null;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    // The tab can close between Popup open and this read.
  }
  const pageURL = isHttpURL(tab?.url) ? tab.url : mediaCandidatesByTab.get(tabId)?.pageUrl;
  const backgroundCandidates = takeBackgroundCandidates(
    backgroundMediaCandidatesByOrigin,
    pageURL,
  );
  if (backgroundCandidates.length > 0) {
    const isYouTube = Boolean(
      globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(pageURL),
    );
    rememberMediaCandidates(
      tabId,
      {
        pageUrl: pageURL,
        title: isYouTube ? "" : tab?.title,
        // A browser tab title is always page-level provenance; it must not
        // inherit (or be inherited as) a gallery card's scoped title.
        titleSource: "document",
        candidates: backgroundCandidates,
      },
      0,
    );
  }
  // Target the main frame (frameId 0) explicitly: chrome.tabs.sendMessage
  // without a frameId resolves with the first responding frame, which on
  // pages with ad iframes is often the iframe — yielding empty or
  // irrelevant candidates while the main page's media goes unreported.
  const mainFrameOptions = { frameId: 0 };
  try {
    const response = await chrome.tabs.sendMessage(
      tabId,
      { type: "macidm.getMediaCandidates" },
      mainFrameOptions,
    );
    if (response?.ok) {
      rememberMediaCandidates(tabId, response, 0);
    }
  } catch {
    // The page may be a browser-internal URL, or this tab may have been open
    // before the extension was loaded. Try one just-in-time injection so the
    // Popup still shows the current page without a separate "start sniffing"
    // action; unsupported pages fall through to the cached/empty result.
    try {
      await ensureContentScript(tabId);
      const response = await chrome.tabs.sendMessage(
        tabId,
        { type: "macidm.getMediaCandidates" },
        mainFrameOptions,
      );
      if (response?.ok) {
        rememberMediaCandidates(tabId, response, 0);
      }
    } catch {
      // Browser-internal pages and restricted frames cannot be injected.
    }
  }
  const cached = mediaCandidatesByTab.get(tabId);
  const aligned = alignMediaTabStateWithLiveURL(cached, pageURL);
  if (aligned && isHttpURL(aligned.pageUrl)) {
    mediaCandidatesByTab.set(tabId, {
      pageUrl: aligned.pageUrl,
      title: aligned.title,
      titleSource: aligned.titleSource,
      candidates: aligned.candidates,
      filteredSummary: aligned.filteredSummary,
    });
  }
  return {
    ok: true,
    filteredSummary: aligned.filteredSummary ?? { diagnosticAudio: 0, streamSegments: 0 },
    ...applyM4sPairing(aligned),
  };
}

function rememberMediaCandidates(tabId, value, frameId) {
  if (!Number.isInteger(tabId) || tabId < 0 || !Array.isArray(value?.candidates)) return;
  const existing = mediaCandidatesByTab.get(tabId);
  const updated = mergeTabMediaCache(existing, value, frameId);
  if (!updated) return;
  mediaCandidatesByTab.set(tabId, updated);
  scheduleSizeProbes(tabId, updated.candidates);
}

// IDM-style active size probing: candidates observed without Content-Length
// (chunked streaming responses) get a HEAD / one-byte Range probe in the
// background. Results are written back into the tab's candidate cache, so
// Popup, overlay, and download-all all see the size on their next refresh.

function scheduleSizeProbes(tabId, candidates, { priority = PROBE_PRIORITY.NORMAL } = {}) {
  const entry = mediaCandidatesByTab.get(tabId);
  const referer = entry?.pageUrl || undefined;
  // False for a tab whose peers were all loopback: a local proxy is in the path,
  // so the recorded peer address cannot prove the target's location.
  const peerAddressInformative = probeEvidence.peerAddressIsInformative(tabId);
  for (const candidate of candidates) {
    if (candidate.siteAdapter || candidate.pairKind || candidate.supported === false) continue;
    // Only the candidate's own size may skip work. A URL probed for a previous
    // document has to be served again: navigation drops the tab cache along with
    // the size it carried, and probeResourceSize() answers from its own cache
    // without a request until that entry expires.
    if (Number.isSafeInteger(candidate.size)) continue;
    // Failed probes retry on later candidate updates up to three times;
    // Referer-dependent CDNs often 403 the first attempt, so giving up
    // permanently on one failure would leave sizes unknown forever. The budget
    // belongs to this tab and document, so another tab cannot exhaust it.
    if (probeEvidence.failureCount(candidate.url, { tabId }) >= 3) continue;
    const decision = decideAutoProbe({
      candidate,
      evidence: probeEvidence.evidenceFor(candidate.url, { tabId }),
      pageURL: entry?.pageUrl,
      probeable: isProbeableCandidate(candidate),
      peerAddressInformative,
    });
    if (!decision.allowed) {
      // A page-supplied URL that no request ever produced is not evidence of a
      // real resource. Report "size unknown" once and move on.
      if (
        isProbeableCandidate(candidate)
        && !probeEvidence.wasDeclined(candidate.url, { tabId })
      ) {
        probeEvidence.markDeclined(candidate.url, { tabId });
        pushProbeResultToPage(tabId, { url: candidate.url, sizeProbeFailed: true });
      }
      continue;
    }
    // Evidence may arrive after an earlier refusal (the page only just
    // requested the URL). Forgetting the refusal keeps it probeable.
    probeEvidence.clearDeclined(candidate.url, { tabId });

    sizeProbeScheduler.enqueue({
      tabId,
      candidate,
      referer,
      priority,
    });
  }
}

// Delivers an active size-probe result to the tab's content script, whose
// snapshot feeds the overlay. Best-effort: unsupported tabs simply ignore it.
function pushProbeResultToPage(tabId, candidate) {
  chrome.tabs
    .sendMessage(tabId, { type: "macidm.addMediaCandidate", candidate, updateOnly: true }, { frameId: 0 })
    .catch(() => {});
}

async function mediaTabContext(tabId, sender) {
  const senderTab = sender?.tab;
  const resolvedTabID = Number.isInteger(tabId) && tabId >= 0 ? tabId : senderTab?.id;
  if (!Number.isInteger(resolvedTabID) || resolvedTabID < 0) {
    return { tabId: undefined, referrer: undefined };
  }
  const tab = senderTab?.id === resolvedTabID ? senderTab : await chrome.tabs.get(resolvedTabID);
  return {
    tabId: resolvedTabID,
    referrer: isHttpURL(tab?.url) ? tab.url : undefined,
    pageTitle: typeof tab?.title === "string" ? tab.title.slice(0, 300) : undefined,
  };
}
