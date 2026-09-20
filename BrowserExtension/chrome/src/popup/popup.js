import { addAuthorizedOrigin, isOriginAuthorized } from "../shared/cookie-authorization.js";
import { t, i18n, hydrateDocument } from "../shared/i18n-access.js";
import { STORAGE_SETTINGS_KEY } from "../shared/constants.js";

const hostStatus = document.querySelector("#host-status");
const takeoverToggle = document.querySelector("#takeover-toggle");
const governanceToggle = document.querySelector("#sniff-governance-toggle");
const previewToggle = document.querySelector("#preview-toggle");
const minSizeInput = document.querySelector("#min-size-input");
const audioMinInput = document.querySelector("#audio-min-input");
const segmentMaxInput = document.querySelector("#segment-max-input");
const downloadAll = document.querySelector("#download-all");
const openApp = document.querySelector("#open-app");
const menuButton = document.querySelector("#menu-button");
const menu = document.querySelector("#menu");
const cookieStatus = document.querySelector("#cookie-status");
const cookieRow = document.querySelector("#cookie-row");
const cookieShortcut = document.querySelector("#cookie-authorize-shortcut");
const mediaCount = document.querySelector("#media-count");
const mediaLoading = document.querySelector("#media-loading");
const filteredNote = document.querySelector("#filtered-note");
const mediaList = document.querySelector("#media-list");
const languageSelect = document.querySelector("#language-select");

// Translucent overlay scrollbar: takes no layout width, appears while
// scrolling and auto-hides after it stops.
globalThis.MacIDMSlimScrollbar?.attach?.(mediaList);
globalThis.MacIDMSlimScrollbar?.attach?.(menu);

let currentOrigin = null;
let currentTabID = null;
let currentMedia = { pageUrl: null, title: "", candidates: [], filteredSummary: { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 } };

// Gallery pages: the page-level title belongs to one hovered card only; rows
// without their own identity use their stamped card title (else their display
// name), never another card's caption.
function rowBaseTitle(candidate) {
  const ownTitle = String(candidate?.cardTitle ?? "").trim();
  if (ownTitle) return ownTitle;
  const isImage = candidate?.format === "image" || String(candidate?.mime ?? "").startsWith("image/");
  if (isImage) return "";
  if (currentMedia?.titleSource === "card") {
    const own = String(candidate?.cardTitle ?? "").trim();
    if (own) return own;
    const display = String(candidate?.displayName ?? "").trim();
    // The normalized placeholder is not an identity: drop it so the row
    // reads by its own URL-tail name instead of a repeated generic prefix.
    return display && display !== t("common.mediaResource") ? display : "";
  }
  return String(currentMedia?.title ?? "").trim();
}
// Sniffing progress for the header spinner. "Done" means: no site adapter
// is still parsing (inspecting), no http candidate waits on a size/metadata
// probe (resolved or explicitly failed), and the page produced at least one
// resource — an empty list only right after opening the Popup still counts
// as sniffing (the page may not have surfaced media yet).
const metadataPending = new Set();
const popupOpenedAt = Date.now();
const EMPTY_SNIFF_GRACE_MS = 8_000;
function updateSniffingIndicator(candidates) {
  const pendingProbe = candidates.some((candidate) =>
    candidate.inspecting === true
    || (
      candidate.supported !== false && !candidate.siteAdapter && !candidate.pairKind
      && !Number.isSafeInteger(candidate.size)
      && candidate.sizeProbeFailed !== true
      && /^https?:/iu.test(String(candidate.url ?? ""))
    ));
  const sniffing = candidates.some(c => metadataPending.has(c.url)) || pendingProbe
    || (candidates.length === 0 && Date.now() - popupOpenedAt < EMPTY_SNIFF_GRACE_MS);
  mediaLoading.hidden = !sniffing;
  if (sniffing) mediaLoading.title = t("popup.sniffing");
}
let mediaRefreshTimer;
let fragmentGroupExpanded = false;
let lastRenderFingerprint = "";
// Previous page's YouTube videoId: a same-video parameter change is not a
// transition (chrome-extension-spec §5.8).
let lastSyncedVideoID = "";
// Candidate URL whose quality accordion is expanded (one at a time).
let openAccordionUrl = null;
let openAppInFlight = false;
// Site cookie permission state: decides the menu row copy and whether
// clicking the row requests the permission or merely re-parses.
let cookieGranted = false;
let cookieRowInFlight = false;
// Inline media preview (opt-in): allocates a decoder per open preview, so it
// is off by default and gated behind the menu toggle.
let previewEnabled = false;
let previewVideo = null;
let previewHls = null;
const autoInspectedUrls = new Set();
// YouTube shared-inspection snapshots (chrome-extension-spec §5.8):
// candidate url -> snapshot. Snapshots come from the background
// coordinator; closing the Popup does not cancel the inspection, and
// reopening reads the latest state.
const youTubeInspections = new Map();

initialize();

// Unified YouTube page identity (chrome-extension-spec §5.8): the primary key for
// inspection snapshots, auto-inspection dedupe and expand state is the
// videoId, not the changeable full URL; non-YouTube candidates keep using
// the original URL key. Normalization is only for state association and
// never rewrites the URL submitted to the App.
function candidateKey(candidate) {
  return globalThis.MacIDMMediaPresentation.candidateKey(candidate);
}

function snapshotKey(snapshot) {
  return globalThis.MacIDMMediaPresentation.snapshotKey(snapshot);
}

function videoIdOf(url) {
  return globalThis.MacIDMMediaPresentation.videoIdOf(url);
}

async function initialize() {
  await i18n.init();
  hydrateDocument();
  populateLanguageSelect();
  // Re-render everything when the language changes (either from the local
  // select or from another extension context via storage.onChanged).
  i18n.onChange(() => {
    hydrateDocument();
    lastRenderFingerprint = "";
    refreshStatus();
    refreshPermission();
    renderMediaCandidates(currentMedia);
  });
  const urlParams = new URLSearchParams(globalThis.window?.location?.search ?? "");
  const paramTabId = urlParams.get("tabId");
  if (paramTabId && !Number.isNaN(Number(paramTabId))) {
    currentTabID = Number(paramTabId);
    try {
      const targetTab = await chrome.tabs.get(currentTabID);
      currentOrigin = httpOrigin(targetTab?.url);
    } catch {
      currentOrigin = null;
    }
  } else {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    currentTabID = tab?.id ?? null;
    currentOrigin = httpOrigin(tab?.url);
  }
  // Subscribe to the shared inspection snapshot stream: in-page
  // completion/stage switches/fallback results update in place without
  // restarting the inspection.
  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "macidm.youTubeInspectionUpdate") return;
    const snapshot = message.snapshot;
    if (!snapshot || snapshot.tabId !== currentTabID) return;
    applyYouTubeSnapshot(snapshot);
  });
  previewToggle.addEventListener("change", () => {
    previewEnabled = previewToggle.checked;
    chrome.storage.local
      .get(STORAGE_SETTINGS_KEY)
      .then((stored) => {
        const settings = { ...(stored?.[STORAGE_SETTINGS_KEY] || {}), previewEnabled };
        return chrome.storage.local.set({ [STORAGE_SETTINGS_KEY]: settings });
      })
      .catch(() => {});
    releasePreview();
    lastRenderFingerprint = "";
    renderMediaCandidates(currentMedia);
  });
  await Promise.allSettled([refreshPermission(), refreshStatus(), loadPreviewSetting(), refreshMediaCandidates()]);
  // Once hls.js is available, re-render so HLS candidates can be probed and
  // previewed (the first render happened before the lib finished loading).
  ensureHlsLib()
    .then((Hls) => {
      if (Hls) {
        lastRenderFingerprint = "";
        renderMediaCandidates(currentMedia);
      }
    })
    .catch(() => {});
  mediaRefreshTimer = window.setInterval(refreshMediaCandidates, 1_200);
}

function populateLanguageSelect() {
  const options = [
    { id: i18n.SYSTEM_CHOICE, label: t("popup.languageSystem") },
    ...i18n.supportedLanguages(),
  ];
  languageSelect.replaceChildren(
    ...options.map(({ id, label }) => {
      const option = document.createElement("option");
      option.value = id;
      option.textContent = label;
      return option;
    }),
  );
  languageSelect.value = i18n.languageChoice();
}

languageSelect.addEventListener("change", async () => {
  try {
    await i18n.setLanguage(languageSelect.value);
  } catch {
    showToast(t("popup.errorSaveTakeoverRetry"), "error");
  }
});

takeoverToggle.addEventListener("change", async () => {
  try {
    const result = await chrome.runtime.sendMessage({
      type: "popup.setTakeover",
      enabled: takeoverToggle.checked,
    });
    if (!result?.ok) showToast(t("popup.errorSaveTakeover"), "error");
  } catch {
    showToast(t("popup.errorSaveTakeoverRetry"), "error");
  }
});

// "Filter noise candidates" toggle + threshold inputs: the toggle only
// writes enabled; thresholds are optionally written per field (bytes), and
// fields not provided keep their stored values in the service worker.
governanceToggle.addEventListener("change", async () => {
  try {
    const result = await chrome.runtime.sendMessage({
      type: "popup.setSniffGovernance",
      enabled: governanceToggle.checked,
    });
    if (!result?.ok) showToast(t("popup.errorSaveGovernance"), "error");
    else applyGovernanceThresholds(result.sniffGovernance);
  } catch {
    showToast(t("popup.errorSaveGovernance"), "error");
  }
});

// Threshold inputs: commit on change (KB → bytes); invalid input falls
// back to the current stored value. Each input submits only its own field
// so concurrent edits cannot overwrite each other.
function bindThresholdInput(input, field) {
  input.addEventListener("change", async () => {
    const kb = Number.parseInt(input.value, 10);
    if (!Number.isSafeInteger(kb) || kb < 0 || kb > 64 * 1024) {
      showToast(t("popup.errorSaveGovernance"), "error");
      restoreThresholdInputs();
      return;
    }
    try {
      const result = await chrome.runtime.sendMessage({
        type: "popup.setSniffGovernance",
        thresholds: { [field]: kb * 1024 },
      });
      if (!result?.ok) {
        showToast(t("popup.errorSaveGovernance"), "error");
        restoreThresholdInputs();
      } else {
        applyGovernanceThresholds(result.sniffGovernance);
      }
    } catch {
      showToast(t("popup.errorSaveGovernance"), "error");
      restoreThresholdInputs();
    }
  });
}
bindThresholdInput(minSizeInput, "minimumMediaBytes");
bindThresholdInput(audioMinInput, "audioMinimumBytes");
bindThresholdInput(segmentMaxInput, "segmentMaximumBytes");

// Backfill the three inputs from the latest governance settings (bytes →
// KB, rounded) and sync the disabled state.
function applyGovernanceThresholds(sniffGovernance) {
  const toKB = (bytes) => String(Math.round(Number(bytes || 0) / 1024));
  minSizeInput.value = toKB(sniffGovernance?.minimumMediaBytes);
  audioMinInput.value = toKB(sniffGovernance?.audioMinimumBytes);
  segmentMaxInput.value = toKB(sniffGovernance?.segmentMaximumBytes);
  const enabled = sniffGovernance?.enabled !== false;
  minSizeInput.disabled = !enabled;
  audioMinInput.disabled = !enabled;
  segmentMaxInput.disabled = !enabled;
}

// Fallback on save failure: restore the displayed values from the most
// recent popup.status snapshot.
let lastGovernanceSnapshot = null;
function restoreThresholdInputs() {
  if (lastGovernanceSnapshot) applyGovernanceThresholds(lastGovernanceSnapshot);
}

downloadAll.addEventListener("click", async () => {
  downloadAll.disabled = true;
  try {
    const result = await chrome.runtime.sendMessage({
      type: "popup.downloadAll",
      tabId: currentTabID,
    });
    if (result?.ok) {
      showToast(t("popup.toastDownloadAll", { count: result.count ?? 0 }), "success");
    } else {
      showToast(result?.message ?? t("popup.pageUnreadable"), "error");
    }
  } catch {
    showToast(t("popup.pageUnreadableRetry"), "error");
  } finally {
    downloadAll.disabled = !currentOrigin;
  }
});

// "Open MacIDM" lives inside the ⋯ menu as a menu row (a div, not a
// button, so it inherits the flat row styling); keyboard activation keeps
// it reachable for tab navigation.
async function launchApp() {
  if (openAppInFlight) return;
  openAppInFlight = true;
  try {
    const result = await chrome.runtime.sendMessage({ type: "popup.openApp" });
    if (!result?.ok) showToast(result?.error?.message ?? t("popup.openAppFailed"), "error");
  } catch {
    showToast(t("popup.connectFailed"), "error");
  } finally {
    openAppInFlight = false;
  }
}

openApp.addEventListener("click", launchApp);
openApp.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    launchApp();
  }
});

// The menu row is the persistent entry for cookie authorization: the
// row-level "Authorize Cookie" button only appears on failed-inspection
// rows, while a silent guest-quality downgrade raises no error, leaving
// the user nowhere to click.
cookieRow.addEventListener("click", authorizeSiteCookiesAndReparse);
cookieRow.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    authorizeSiteCookiesAndReparse();
  }
});

// The shortcut next to the title shares the menu row's authorization
// logic; it only appears when unauthorized, avoiding noise on sites that
// are already authorized.
cookieShortcut?.addEventListener("click", authorizeSiteCookiesAndReparse);

menuButton.addEventListener("click", (event) => {
  event.stopPropagation();
  toggleMenu();
});

// Any click outside the menu closes it.
document.addEventListener("click", (event) => {
  if (!menu.hidden && !menu.contains(event.target)) menu.hidden = true;
});

function toggleMenu() {
  menu.hidden = !menu.hidden;
  if (menu.hidden) return;
  // Height guard: a short popup window would clip the menu. Cap it at the
  // space between its top edge and the window bottom and scroll inside
  // instead (window.innerHeight based, as specified by the design doc).
  menu.style.maxHeight = "";
  const menuRect = menu.getBoundingClientRect();
  const available = window.innerHeight - menuRect.top - 8;
  menu.style.maxHeight = `${Math.max(available, 60)}px`;
}

window.addEventListener("unload", () => {
  if (mediaRefreshTimer != null) window.clearInterval(mediaRefreshTimer);
});

async function refreshStatus() {
  try {
    const status = await chrome.runtime.sendMessage({ type: "popup.status" });
    const online = status?.connected === true;
    hostStatus.classList.toggle("online", online);
    hostStatus.classList.toggle("offline", !online);
    // An unreachable App is a state with a remedy, not a fault: name the
    // remedy in the dot's tooltip (launch the App vs. install the Host)
    // instead of the generic "not connected".
    hostStatus.title = online
      ? t("popup.hostConnected")
      : status?.unreachableReason === "hostMissing"
        ? t("popup.hostNotInstalled")
        : status?.unreachableReason === "appNotRunning"
          ? t("popup.appNotRunning")
          : t("popup.hostDisconnected");
    takeoverToggle.checked = status?.takeoverEnabled === true;
    governanceToggle.checked = status?.sniffGovernanceEnabled === true;
    // Threshold input backfill: popup.status carries the full governance
    // settings (including the three threshold fields).
    if (status?.sniffGovernance) {
      lastGovernanceSnapshot = status.sniffGovernance;
      applyGovernanceThresholds(status.sniffGovernance);
    }
    if (status?.lastError?.message) {
      // Background errors (e.g. a takeover failure while the popup was
      // closed) surface once per recorded instance. Without the dedup the
      // same stale entry would toast on every single popup open.
      const shown = await chrome.storage.local.get("lastSafeErrorShownAt");
      if (shown.lastSafeErrorShownAt !== status.lastError.at) {
        showToast(status.lastError.message, "error");
        await chrome.storage.local.set({ lastSafeErrorShownAt: status.lastError.at });
      }
    }
  } catch {
    hostStatus.classList.remove("online");
    hostStatus.classList.add("offline");
    hostStatus.title = t("popup.hostDisconnected");
  }
}

async function refreshMediaCandidates() {
  if (currentTabID == null) {
    renderMediaCandidates({ pageUrl: null, title: "", candidates: [] });
    return;
  }
  try {
    const result = await chrome.runtime.sendMessage({
      type: "popup.mediaCandidates",
      tabId: currentTabID,
    });
    if (result?.ok) {
      mergeMediaCandidates(result);
    } else {
      renderMediaCandidates({ pageUrl: null, title: "", candidates: [] });
      mediaCount.textContent = result?.message ?? t("popup.pageUnavailable");
    }
  } catch {
    mediaCount.textContent = t("popup.temporarilyUnreadable");
  }
}

function mergeMediaCandidates(payload) {
  const previousPageUrl = currentMedia?.pageUrl ?? null;
  const previousCandidateUrl = currentMedia?.candidates?.[0]?.url ?? null;
  const previousVideoId =
    videoIdOf(previousPageUrl ?? "") ||
    videoIdOf(previousCandidateUrl ?? "") ||
    lastSyncedVideoID;
  const incomingCandidateUrl = payload?.candidates?.[0]?.url ?? null;
  const incomingPageUrl = payload?.pageUrl ?? incomingCandidateUrl ?? currentMedia?.pageUrl ?? null;
  const incomingVideoId =
    videoIdOf(incomingPageUrl ?? "") ||
    videoIdOf(incomingCandidateUrl ?? "");
  const sameYouTubeVideo = Boolean(
    previousVideoId && incomingVideoId && previousVideoId === incomingVideoId,
  );

  const previous = new Map(
    (currentMedia?.candidates ?? []).map((candidate) => [
      sameYouTubeVideo ? candidateKey(candidate) : candidate.url,
      candidate,
    ]),
  );
  const candidates = (Array.isArray(payload.candidates) ? payload.candidates : []).map((candidate) => {
    const key = sameYouTubeVideo ? candidateKey(candidate) : candidate.url;
    const kept = previous.get(key);
    if (!kept) return candidate;
    const merged = { ...kept, ...candidate };
    // Ensure the latest candidate URL from the current payload is used.
    merged.url = candidate.url;
    // The background payload carries explicit nulls for unknown optional
    // metadata; never let them clobber values we already resolved locally
    // (e.g. a probed size arriving before a candidate re-discovery).
    if (candidate.size == null && kept.size != null) merged.size = kept.size;
    if (candidate.duration == null && kept.duration != null) merged.duration = kept.duration;
    if (candidate.mime == null && kept.mime != null) merged.mime = kept.mime;
    // Variant list: when the new payload carries no variants, inherit the
    // previously parsed variants of the old candidate.
    if (!Array.isArray(candidate.variants) && Array.isArray(kept.variants)) {
      merged.variants = kept.variants;
    }
    if (candidate.inspecting == null && kept.inspecting != null) merged.inspecting = kept.inspecting;
    if (candidate.inspectError == null && kept.inspectError != null) merged.inspectError = kept.inspectError;
    if (candidate.qualityLabel == null && kept.qualityLabel != null) merged.qualityLabel = kept.qualityLabel;
    return merged;
  });

  const incomingTitle = typeof payload.title === "string" ? payload.title.trim() : "";
  const previousTitle = typeof currentMedia?.title === "string" ? currentMedia.title.trim() : "";
  const isExactSamePage = Boolean(
    incomingPageUrl && previousPageUrl && incomingPageUrl === previousPageUrl,
  );
  const resolvedTitle = incomingTitle
    ? payload.title
    : ((sameYouTubeVideo || isExactSamePage) && previousTitle ? currentMedia.title : "");
  // Title provenance travels with the title it describes: a retained
  // previous title keeps the previous source.
  const incomingTitleSource = typeof payload.titleSource === "string" ? payload.titleSource : "document";
  const resolvedTitleSource = incomingTitle || !previousTitle
    ? incomingTitleSource
    : (currentMedia.titleSource ?? "document");

  currentMedia = {
    pageUrl: incomingPageUrl,
    title: resolvedTitle,
    titleSource: resolvedTitleSource,
    candidates,
    filteredSummary: normalizeFilteredSummary(payload.filteredSummary),
  };
  // After SPA navigation (A→B) the page's candidates are replaced
  // wholesale; clear the inspection dedupe set so returning to A
  // re-inspects, and the old video's variant data is dropped along with
  // the candidate objects (chrome-extension-spec §5.8). A same-video parameter
  // change is not a transition (§2): videoId-keyed inspection state stays
  // usable.
  if (currentMedia.pageUrl !== previousPageUrl) {
    if (!(incomingVideoId && incomingVideoId === lastSyncedVideoID)) {
      autoInspectedUrls.clear();
      youTubeInspections.clear();
      openAccordionUrl = null;
    }
    lastSyncedVideoID = incomingVideoId;
  }
  renderMediaCandidates(currentMedia);
}

// Redacted filter counts (technical-spec §8.4): only the three 0–100000
// count keys are accepted.
function normalizeFilteredSummary(raw) {
  const summary = { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return summary;
  for (const key of ["diagnosticAudio", "streamSegments", "smallResources"]) {
    const value = Number(raw[key]);
    if (Number.isSafeInteger(value) && value >= 0) {
      summary[key] = Math.min(value, 100_000);
    }
  }
  return summary;
}

function renderMediaCandidates(payload) {
  // The cookie status row refreshes together with the candidates: when
  // unauthorized yet a site-adapter candidate has been resolved, the
  // consequences of "guest quality" must be spelled out, otherwise the
  // downgrade is silent (Bilibili's API claims 4K support but actually
  // serves only 480P tracks, with no visible anomaly in the UI); the row
  // title switches between authorize/re-parse semantics in sync.
  updateCookieStatusRow(payload);
  updateCookieShortcutVisibility(payload);
  // Display ordering (identical across sites): video/audio first,
  // decorative images last; within the same priority, descending by
  // discovery confidence (dom > headers > magic > fetch > extension).
  const sortForDisplay = globalThis.MacIDMMediaUtils?.sortCandidatesForDisplay
    ?? ((list) => list);
  const candidates = sortForDisplay(
    (Array.isArray(payload.candidates) ? payload.candidates : []).slice(),
  );
  mediaCount.textContent = candidates.length > 0
    ? t("popup.resourceCount", { count: candidates.length })
    : t("popup.noResources");
  updateSniffingIndicator(candidates);
  // Redacted count feedback for false-positive suppression: appears only
  // when something was actually filtered and does not take part in the
  // DOM-rebuild skip logic below (updated directly like mediaCount).
  const summary = payload.filteredSummary ?? { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };
  const filteredTotal = summary.diagnosticAudio + summary.streamSegments + summary.smallResources;
  if (filteredTotal > 0) {
    filteredNote.textContent = t("common.filteredNoise", { count: filteredTotal });
    filteredNote.hidden = false;
  } else {
    filteredNote.hidden = true;
  }
  const title = String(payload.title ?? "").trim();
  // Host of the sniffed page (not the extension page): the shared naming
  // rules mirror the App's host-matched brand-suffix strip and need it.
  let pageHostname = "";
  try { pageHostname = new URL(payload.pageUrl || "").hostname; } catch { pageHostname = ""; }
  // Skip the expensive DOM rebuild when nothing material has changed. This
  // preserves <details> open state, scroll position, and focus that would
  // otherwise be destroyed by the 1.2s auto-refresh timer.
  const fingerprint = candidates
    .map((c) =>
      `${c.url}|${c.cardTitle ?? ""}|${c.mime ?? ""}|${c.fileExtension ?? ""}|${c.filenameHint}|${c.supported}|${c.inspecting}|${c.enqueued}|${c.size ?? ""}|${c.inspectError ?? ""}|${c.pairNote ?? ""}|${c.variants?.length ?? 0}|${youTubeInspections.get(candidateKey(c))?.stage ?? ""}|${youTubeInspections.get(candidateKey(c))?.variantCount ?? 0}|${probeFingerprint(c)}`,
    )
    .join("\n") + "\n" + title + "\n" + i18n.currentLanguage()
    // Accordion open state participates in the fingerprint so toggling a
    // stream row re-renders even when candidate data is unchanged.
    + "\n" + (openAccordionUrl ?? "");
  if (fingerprint === lastRenderFingerprint && mediaList.children.length > 0) return;
  lastRenderFingerprint = fingerprint;

  mediaList.replaceChildren();
  if (candidates.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = payload.pageUrl
      ? t("popup.listeningHint")
      : t("popup.sniffUnsupported");
    mediaList.append(empty);
    return;
  }
  // B2: Detect same-named candidates with different URLs so we can append
  // a resolution/quality label to the title for differentiation (e.g.
  // multiple X HLS variants that share the page title).
  const nameCount = new Map();
  for (const candidate of candidates) {
    if (isCollapsedSegment(candidate)) continue;
    const name = globalThis.MacIDMMediaUtils?.smartMediaName
      ? globalThis.MacIDMMediaUtils.smartMediaName(candidate, rowBaseTitle(candidate), candidates.length, pageHostname)
      : (candidate.filenameHint || candidate.displayName || t("common.mediaResource"));
    nameCount.set(name, (nameCount.get(name) || 0) + 1);
  }
  // Fragment/segment candidates default to one collapsed group at the end,
  // so a player cannot fill the Popup with internal requests.
  const fragments = [];
  for (const candidate of candidates) {
    if (isCollapsedSegment(candidate)) {
      fragments.push(candidate);
    } else {
      mediaList.append(renderCandidate(candidate, nameCount));
    }
  }
  if (fragments.length > 0) {
    const fragmentEl = renderFragmentGroup(fragments);
    if (fragmentEl) mediaList.append(fragmentEl);
  }

  // Auto-inspect candidates that need quality parsing (HLS/DASH/YouTube/
  // Bilibili). The user should not have to click a button just to see
  // available qualities — inspection starts automatically on first render.
  for (const candidate of candidates) {
    if (autoInspectedUrls.has(candidateKey(candidate))) continue;
    if (candidate.inspecting) continue;
    if (Array.isArray(candidate.variants)) continue;
    const isManifest = candidate.format === "hls" || candidate.format === "dash";
    const isYouTube = candidate.siteAdapter === "youtube";
    const needsInspection = candidate.siteAdapter === "bilibili" || isYouTube || isManifest;
    if (!needsInspection) continue;
    autoInspectedUrls.add(candidateKey(candidate));
    // Mark as inspecting immediately so an expanded accordion shows
    // "Parsing…" right away; the result replaces it in place when ready.
    // YouTube's stage text is driven by the shared snapshot, not a boolean
    // parsing placeholder.
    if (!isYouTube) candidate.inspecting = true;
    const c = candidate;
    setTimeout(() => inspectCandidate(c), 200);
  }

  // Real-media metadata probe (duration/resolution/codec): fills gaps the URL
  // cannot provide. Runs after render; when metadata lands we re-render so the
  // meta row picks it up (the probe result participates in the fingerprint).
  scheduleMetadataProbe(candidates);

  // Release any preview decoder when no drawer is open (popup compact/closed).
  if (!openAccordionUrl) releasePreview();
}

// URLs we already attempted this popup lifetime: a failed probe must not be
// retried on every auto-refresh tick.
const metadataProbeAttempted = new Set();
function probeFingerprint(candidate) {
  const meta = globalThis.MacIDMMediaMetadataProbe?.cached?.(candidate.url);
  if (!meta) return "";
  return `${meta.duration ?? ""}|${meta.width ?? ""}|${meta.height ?? ""}|${meta.codec ?? ""}`;
}
function scheduleMetadataProbe(candidates) {
  const probe = globalThis.MacIDMMediaMetadataProbe;
  if (!probe?.probeCandidates) return;
  const targets = (Array.isArray(candidates) ? candidates : [])
    .filter((c) => probe.needsProbe?.(c) && !metadataProbeAttempted.has(c.url));
  if (targets.length === 0) return;
  for (const c of targets) { metadataProbeAttempted.add(c.url); metadataPending.add(c.url); }
  updateSniffingIndicator(candidates);
  setTimeout(async () => {
    try {
      // Request one result per message so a slow resource cannot hold back
      // metadata already available for another row. The page owns scheduling.
      await Promise.all(targets.map(async candidate => {
        try {
          let result = null;
          if (currentTabID != null) {
            try {
              const response = await chrome.tabs.sendMessage(currentTabID, {
                type: "macidm.probeMediaMeta", urls: [candidate.url],
              });
              result = response?.results?.find(item => item.url === candidate.url && item.meta);
            } catch { /* Use the local loader if the content script is unavailable. */ }
          }
          if (!result) {
            [result] = await probe.probeCandidates([candidate], {
              priority: "interactive",
              onResult(value) {
                if (value?.meta) probe.store?.(value.url, value.meta);
                metadataPending.delete(candidate.url);
                renderMediaCandidates(currentMedia ?? { candidates: [] });
              },
            });
          }
          if (result?.meta) probe.store?.(result.url, result.meta);
        } finally {
          metadataPending.delete(candidate.url);
          renderMediaCandidates(currentMedia ?? { candidates: [] });
        }
      }));
    } finally {
      for (const c of targets) metadataPending.delete(c.url);
      updateSniffingIndicator(currentMedia?.candidates ?? []);
    }
  }, 150);
}

// ---- inline media preview (opt-in) ----
// hls.js is vendored under lib/ and injected on demand; when the file is
// absent (not yet fetched) HLS probe/preview degrade gracefully to disabled.
let hlsLoadPromise = null;
function ensureHlsLib() {
  if (globalThis.Hls) return Promise.resolve(globalThis.Hls);
  if (hlsLoadPromise) return hlsLoadPromise;
  hlsLoadPromise = new Promise((resolve) => {
    const script = document.createElement("script");
    script.src = chrome.runtime.getURL("lib/hls.light.min.js");
    script.onload = () => resolve(globalThis.Hls ?? null);
    script.onerror = () => resolve(null);
    document.head.appendChild(script);
  });
  return hlsLoadPromise;
}

async function loadPreviewSetting() {
  try {
    const stored = await chrome.storage.local.get(STORAGE_SETTINGS_KEY);
    previewEnabled = stored?.[STORAGE_SETTINGS_KEY]?.previewEnabled === true;
    previewToggle.checked = previewEnabled;
  } catch {
    previewEnabled = false;
  }
}

function releasePreview() {
  if (previewHls) {
    try { previewHls.destroy(); } catch { /* ignore */ }
    previewHls = null;
  }
  if (previewVideo) {
    try {
      previewVideo.pause();
      previewVideo.removeAttribute("src");
      previewVideo.load();
    } catch { /* ignore */ }
    previewVideo = null;
  }
}

function isPreviewable(candidate) {
  if (!candidate || candidate.supported === false) return false;
  const url = candidate.url || "";
  if (!/^https?:/i.test(url)) return false;
  if (candidate.format === "dash" || candidate.format === "dash-json") return false;
  const isHls = candidate.format === "hls" || /\.m3u8(?:[?#]|$)/i.test(url);
  if (isHls) return Boolean(globalThis.Hls && globalThis.Hls.isSupported?.());
  return true;
}

function buildPreviewElement(candidate) {
  if (!isPreviewable(candidate)) return null;
  releasePreview();
  const wrap = document.createElement("div");
  wrap.className = "pv-preview";
  const video = document.createElement("video");
  video.controls = true;
  video.muted = true;
  video.playsInline = true;
  video.preload = "metadata";
  previewVideo = video;
  const url = candidate.url;
  const isHls = candidate.format === "hls" || /\.m3u8(?:[?#]|$)/i.test(url);
  if (isHls && globalThis.Hls) {
    const hls = new globalThis.Hls({ enableWorker: false });
    previewHls = hls;
    hls.on(globalThis.Hls.Events.MANIFEST_PARSED, (_event, data) => {
      const levels = data?.levels || [];
      if (levels.length > 0) {
        // Auto-select the highest-bitrate level for preview.
        let best = 0;
        for (let i = 1; i < levels.length; i += 1) {
          if ((levels[i].bitrate || 0) > (levels[best].bitrate || 0)) best = i;
        }
        hls.currentLevel = best;
      }
      video.play?.().catch(() => {});
    });
    hls.on(globalThis.Hls.Events.ERROR, (_event, data) => {
      if (data?.fatal) hls.stopLoad();
    });
    hls.loadSource(url);
    hls.attachMedia(video);
  } else {
    video.src = url;
  }
  wrap.append(video);
  return wrap;
}

function renderFragmentGroup(fragments) {
  // When only one group exists, the collapsed summary would say "N
  // segments" (N = totalRequests from segmentCount) but expanding reveals
  // just one entry — confusing the user. Render it as a normal candidate
  // row instead; its pairNote already carries the segment-count and
  // incompleteness info.
  if (fragments.length === 1) {
    // But if that single group is unsupported (multi-segment, no manifest),
    // don't render it at all — it would show "not supported yet" with a
    // misleading "N segments" note. The HLS manifest or site-adapter
    // candidate (which IS supported) is already shown as a regular
    // candidate above.
    if (fragments[0].supported === false) return null;
    return renderCandidate(fragments[0]);
  }
  const details = document.createElement("details");
  details.className = "fragment-group";
  details.open = fragmentGroupExpanded;
  details.addEventListener("toggle", () => {
    fragmentGroupExpanded = details.open;
  });
  const summary = document.createElement("summary");
  const formats = [...new Set(
    fragments.map((candidate) => String(candidate.fileExtension || "unknown").toUpperCase()),
  )].join("/");
  const totalRequests = fragments.reduce(
    (total, candidate) => total + (Number.isSafeInteger(candidate.segmentCount) ? candidate.segmentCount : 1),
    0,
  );
  // Show the number of distinct groups (what the user sees when expanding),
  // with the raw request count as context. Fixes the "says 11 but shows 1"
  // confusion when many segments collapse into a single group entry.
  summary.textContent = t("popup.fragmentGroupSummary", {
    groups: fragments.length,
    formats,
    requests: totalRequests,
  });
  details.append(summary);
  for (const candidate of fragments) {
    details.append(renderCandidate(candidate));
  }
  return details;
}

function renderCandidate(candidate, nameCount) {
  const fragment = document.createDocumentFragment();
  const row = document.createElement("article");
  row.className = "media-row";
  if (candidate.pairKind === "m4s-pair") row.classList.add("media-row-pair");

  const content = document.createElement("div");
  content.className = "media-content";
  const title = document.createElement("strong");
  const smartName = globalThis.MacIDMMediaUtils?.smartMediaName
    ? globalThis.MacIDMMediaUtils.smartMediaName(
      candidate,
      rowBaseTitle(candidate),
      currentMedia.candidates?.length ?? 1,
      (() => {
        try { return new URL(currentMedia.pageUrl || "").hostname; } catch { return ""; }
      })(),
    )
    : (candidate.filenameHint || candidate.displayName || t("common.mediaResource"));
  // B2: For same-named but different-URL resources (e.g. X HLS variants),
  // append the resolution/quality label to the title for differentiation.
  let displayName = smartName;
  if (nameCount && (nameCount.get(smartName) || 0) > 1) {
    // Bitrate is a meta slot, not a name: "标题 · 3422 kbps" reads as part
    // of the title. Only resolution-style labels differentiate rows.
    const resLabel = candidate.qualityLabel && !/kbps|Mbps/iu.test(candidate.qualityLabel)
      ? candidate.qualityLabel
      : "";
    if (resLabel) displayName = `${smartName} · ${resLabel}`;
  }
  title.textContent = displayName;
  const meta = document.createElement("div");
  meta.className = "media-meta";
  // The "format · quality · size · duration" slots only show items that
  // have values: when metadata is missing no "unknown" placeholder is
  // shown, avoiding whole-row noise.
  const metaSlots = [formatLabel(candidate)];
  if (candidate.qualityLabel) metaSlots.push(candidate.qualityLabel);
  // Real-media probe metadata (resolution/codec, and duration below) fills
  // gaps the URL cannot provide; it never overrides an already-known value.
  const probeMeta = globalThis.MacIDMMediaMetadataProbe?.cached?.(candidate.url) ?? null;
  const probeWidth = probeMeta?.width || 0;
  const probeHeight = probeMeta?.height || 0;
  const resolutionSlot = (!candidate.qualityLabel && probeHeight)
    ? (globalThis.MacIDMMediaUtils?.resolutionLabel?.(probeWidth, probeHeight) || "")
    : "";
  if (resolutionSlot) metaSlots.push(resolutionSlot);
  const sizeSlot = formatSize(candidate);
  const hiddenSizeSlots = [
    t("common.unknown"),
    t("common.sizeUnknown"),
    t("common.probing"),
    t("common.parsing"),
  ];
  if (!hiddenSizeSlots.includes(sizeSlot)) {
    metaSlots.push(sizeSlot);
  }
  const durationSlot = formatDuration(candidate.duration ?? probeMeta?.duration ?? null);
  if (durationSlot) metaSlots.push(durationSlot);
  const codecSlot = globalThis.MacIDMMediaUtils?.codecFamily?.(probeMeta?.codec) || "";
  if (codecSlot) metaSlots.push(codecSlot);

  const isDashJson = candidate.format === "dash-json";
  const isManifest = candidate.format === "hls" || candidate.format === "dash";
  const isYouTube = candidate.siteAdapter === "youtube";
  const needsInspection = candidate.siteAdapter === "bilibili" || isYouTube || isManifest;
  // YouTube shared-inspection stage (§5.2): the collapsed main row can
  // also show stage texts like "reading page qualities…" or "found 8
  // qualities · still completing…", not just a boolean parsing flag.
  if (isYouTube) {
    const stageText = youTubeStageText(youTubeInspections.get(candidateKey(candidate)));
    if (stageText) metaSlots.push(stageText);
  }

  const metaIcon = document.createElement("span");
  metaIcon.className = "meta-icon";
  const category = globalThis.MacIDMCategory?.categoryForCandidate?.(candidate) ?? "other";
  metaIcon.innerHTML = globalThis.MacIDMCategory?.categoryIconSVG?.(category, 12) ?? "";

  const metaText = document.createElement("span");
  metaText.className = "meta-text";
  metaText.textContent = metaSlots.join(" · ");

  meta.append(metaIcon, metaText);
  // Inspection in flight: the main row's meta area shows the spinner
  // directly (no need to expand the drawer to see "Parsing…"); once the
  // inspection completes it is replaced by result slots like "highest
  // spec: ~XX MB". candidate.inspecting is part of the render fingerprint,
  // so state changes trigger an in-place re-render.
  const ytInFlight = isYouTube
    && (() => {
      const stage = youTubeInspections.get(candidateKey(candidate))?.stage;
      return !!stage && !["complete", "partial", "failed", "unsupported"].includes(stage);
    })();
  if (needsInspection && !candidate.inspectError && (candidate.inspecting || ytInFlight)) {
    const spinner = document.createElement("span");
    spinner.className = "meta-spinner";
    spinner.setAttribute("aria-hidden", "true");
    spinner.title = t("common.parsing");
    meta.append(spinner);
  }

  content.append(title, meta);

  // Zero inline controls: technical details like the URL, inference
  // marker and pair note all go into the whole-row tooltip.
  const tooltipParts = [displayName];
  if (candidate.displayURL) tooltipParts.push(candidate.displayURL);
  if (candidate.serverFilename) {
    tooltipParts.push(t("popup.serverFilename", { name: candidate.serverFilename }));
  }
  if (candidate.confidence === "extension") tooltipParts.push(t("popup.metaInferred"));
  if (candidate.pairNote) tooltipParts.push(candidate.pairNote);

  row.append(content);

  // dash-json is a DASH-manifest JSON identified by response-body deep
  // scanning, not a directly downloadable file; rows with
  // supported===false (e.g. stream segments) are likewise not
  // submittable. Both kinds of rows stay static, with capability notes in
  // the tooltip.
  if (candidate.supported === false || isDashJson) {
    row.classList.add("static");
    tooltipParts.push(isDashJson ? t("popup.actionNeedSiteParse") : t("popup.actionUnsupported"));
    row.title = tooltipParts.join("\n");
    fragment.append(row);
    return fragment;
  }

  // Unified drawer interaction (identical across sites): every
  // submittable candidate row expands on click — the expanded view shows
  // the full title; sub-download items are listed when present, and
  // otherwise at least a "download now" sub-item is offered.
  // Failed-inspection rows keep the red short text and the exceptional
  // "Authorize Cookie" button (permission requests must be triggered by a
  // user gesture) and expand too: the drawer keeps the error message and
  // download entry without losing the expanded state early.
  // Accordion key includes format/pairKind: same-URL candidates of different
  // formats (site-adapter row + raw track row on Bilibili watch pages) must
  // expand independently instead of opening together.
  const stateKey = `${candidateKey(candidate)}|${candidate.format ?? ""}|${candidate.pairKind ?? ""}`;
  const isOpen = openAccordionUrl === stateKey;
  if (isOpen) row.classList.add("open");
  row.classList.add("clickable");
  row.title = tooltipParts.join("\n");
  if (needsInspection && candidate.inspectError) {
    const errorWrap = document.createElement("div");
    errorWrap.className = "media-error-row";
    const error = document.createElement("small");
    error.className = "media-error";
    error.textContent = candidate.inspectError;
    errorWrap.append(error);
    if (currentOrigin) {
      const authorize = document.createElement("button");
      authorize.type = "button";
      authorize.className = "media-action";
      authorize.textContent = t("popup.authorizeCookieShort");
      authorize.addEventListener("click", (event) => {
        event.stopPropagation();
        authorizeCookieAndRetry(candidate, authorize);
      });
      errorWrap.append(authorize);
    }
    const chevron = document.createElement("span");
    chevron.className = "pv-chevron";
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = "›";
    row.append(errorWrap, chevron);
  } else {
    const chevron = document.createElement("span");
    chevron.className = "pv-chevron";
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = "›";
    row.append(chevron);
  }
  row.addEventListener("click", () => {
    openAccordionUrl = isOpen ? null : stateKey;
    renderMediaCandidates(currentMedia);
  });
  fragment.append(row);
  if (isOpen) fragment.append(renderQualityAccordion(candidate));
  return fragment;
}

function renderQualityAccordion(candidate) {
  const sub = document.createElement("div");
  sub.className = "pv-sub";
  // Opt-in inline preview at the top of the expanded drawer.
  if (previewEnabled) {
    const preview = buildPreviewElement(candidate);
    if (preview) sub.append(preview);
  }
  // YouTube goes through the shared coordinator snapshot:
  // stages/partial results/failures and retries all update in place
  // inside the drawer.
  if (candidate.siteAdapter === "youtube") {
    return renderYouTubeAccordion(candidate, sub);
  }
  // Inspection failed and expanded: the drawer shows the short error text
  // and keeps the "download now" entry.
  if (candidate.inspectError && !candidate.inspecting) {
    const errorLine = document.createElement("div");
    errorLine.className = "pv-opt parsing";
    errorLine.textContent = candidate.inspectError;
    sub.append(errorLine);
    sub.append(buildDownloadNowOption(candidate));
    return sub;
  }
  if (candidate.inspecting) {
    // Inspection unfinished when opened: show "Parsing…" first; once done
    // the fingerprint change triggers a re-render that swaps in the
    // options in place (autoInspectedUrls guarantees no repeated
    // inspection within the session).
    const parsing = document.createElement("div");
    parsing.className = "pv-opt parsing";
    parsing.textContent = t("common.parsing");
    sub.append(parsing);
    return sub;
  }
  // Only offer variants with meaningful structured info (resolution,
  // bitrate, codec, or a non-generic label); a list of indistinguishable
  // "default quality" entries is worse than the direct-download fallback.
  const meaningfulVariants = (Array.isArray(candidate.variants) ? candidate.variants : [])
    .filter(hasVariantInfo)
    .slice(0, 20);
  if (meaningfulVariants.length === 0) {
    // No quality choice (direct link/image/single-quality stream):
    // uniformly offer the "download now" sub-item.
    sub.append(buildDownloadNowOption(candidate));
    return sub;
  }
  for (const variant of meaningfulVariants) {
    const option = document.createElement("div");
    option.className = "pv-opt";
    option.textContent = variantOptionLabel(variant);
    option.title = variantTooltip(variant);
    option.addEventListener("click", () => enqueueVariant(candidate, variant, option));
    sub.append(option);
  }
  return sub;
}

/// A single "download now" sub-item: candidates with no quality choice all
/// submit to the App confirmation window through it.
function buildDownloadNowOption(candidate) {
  const direct = document.createElement("div");
  direct.className = "pv-opt";
  direct.setAttribute("role", "button");
  direct.setAttribute("tabindex", "0");
  direct.setAttribute("data-macidm-btn-direct", "");
  direct.textContent = t("popup.downloadNow");
  const submit = () => submitCandidate(candidate, direct);
  direct.addEventListener("click", (event) => {
    event.stopPropagation();
    submit();
  });
  direct.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      event.stopPropagation();
      submit();
    }
  });
  return direct;
}

/// YouTube accordion: while completion continues, partial results grow in
/// place; failure/partial completion keeps existing qualities and offers
/// "re-parse" (§5.3 items 7–8), without closing the drawer or losing the
/// expanded state.
function renderYouTubeAccordion(candidate, sub) {
  const snapshot = youTubeInspections.get(candidateKey(candidate));
  const variants = Array.isArray(snapshot?.variants) ? snapshot.variants : [];
  const meaningfulVariants = variants.filter(hasVariantInfo).slice(0, 20);
  const stage = snapshot?.stage ?? "discovered";

  if (stage === "unsupported") {
    const note = document.createElement("div");
    note.className = "pv-opt parsing";
    note.textContent = t("youtube.stageUnsupported");
    sub.append(note);
    return sub;
  }
  for (const variant of meaningfulVariants) {
    const option = document.createElement("div");
    option.className = "pv-opt";
    option.textContent = variantOptionLabel(variant);
    option.title = variantTooltip(variant);
    option.addEventListener("click", () => enqueueVariant(candidate, variant, option));
    sub.append(option);
  }
  if (meaningfulVariants.length === 0) {
    if (stage === "partial" || stage === "failed") {
      const note = document.createElement("div");
      note.className = "pv-opt parsing";
      note.textContent = stage === "failed"
        ? t("youtube.stageFailed")
        : t("youtube.stagePartial");
      sub.append(note);
    } else if (stage === "complete") {
      // Complete but indistinguishable: unify on the "download now"
      // sub-item.
      sub.append(buildDownloadNowOption(candidate));
      return sub;
    } else {
      const parsing = document.createElement("div");
      parsing.className = "pv-opt parsing";
      parsing.textContent = youTubeStageText(snapshot) ?? t("common.parsing");
      sub.append(parsing);
    }
  } else if (stage === "partial" || stage === "failed") {
    // Partial qualities + failure/partial completion: keep the results,
    // append the status and a retry action.
    const note = document.createElement("div");
    note.className = "pv-opt parsing";
    note.textContent = stage === "failed"
      ? t("youtube.stageFailed")
      : t("youtube.stagePartial");
    sub.append(note);
  }
  if ((stage === "partial" || stage === "failed") && snapshot?.retryable) {
    // With no qualities, still keep the "download now" entry.
    if (meaningfulVariants.length === 0) {
      sub.append(buildDownloadNowOption(candidate));
    }
    const retry = document.createElement("div");
    retry.className = "pv-opt";
    retry.setAttribute("role", "button");
    retry.setAttribute("tabindex", "0");
    retry.textContent = t("youtube.retry");
    const doRetry = () => retryYouTubeInspection(candidate);
    retry.addEventListener("click", doRetry);
    retry.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        doRetry();
      }
    });
    sub.append(retry);
  }
  if ((stage === "partial" || stage === "failed") && !cookieGranted && currentOrigin) {
    // Login-state qualities need an authorized site cookie: the App no longer
    // reads Chrome's on-disk Cookies DB (Full Disk Access), so YouTube falls
    // back to anonymous extraction without a granted cookie. Offer the same
    // per-origin authorization entry used by failed generic inspections, then
    // re-run the shared YouTube inspection with the granted cookie.
    const authorize = document.createElement("div");
    authorize.className = "pv-opt";
    authorize.setAttribute("role", "button");
    authorize.setAttribute("tabindex", "0");
    authorize.textContent = t("popup.authorizeCookieShort");
    const doAuthorize = () => authorizeCookieAndRetry(candidate, authorize);
    authorize.addEventListener("click", doAuthorize);
    authorize.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        doAuthorize();
      }
    });
    sub.append(authorize);
  }
  return sub;
}

/// Stage → main-row copy: appears dynamically only for in-progress stages;
/// after completion it shows no "done" marker and no "N qualities" count —
/// the main-row experience stays consistent across sites.
function youTubeStageText(snapshot) {
  return globalThis.MacIDMMediaPresentation.youTubeStageText(snapshot, t);
}

/// Coordinator snapshot landing: candidate objects are rebuilt on every
/// refresh, and the snapshot map survives independently of candidates; it
/// also syncs variants for size estimation/format slots. Keys use the
/// unified identity (§2): when only the same video's parameters change,
/// the current candidate can still consume the existing final state.
/// First positive duration across parsed variants: App inspections return a
/// per-variant duration (Bilibili playurl, HLS sub-playlist total) and all
/// variants of one asset share it, so the first hit is the asset's. Feeds
/// the main row's duration meta slot; never overrides a known value.
function backfillCandidateDuration(candidate, variants) {
  if (!candidate || (Number.isFinite(candidate.duration) && candidate.duration > 0)) return;
  for (const variant of Array.isArray(variants) ? variants : []) {
    const value = variant?.duration;
    if (Number.isFinite(value) && value > 0) {
      candidate.duration = value;
      return;
    }
  }
}

function applyYouTubeSnapshot(snapshot) {
  if (!snapshot?.pageUrl) return;
  const key = snapshotKey(snapshot);
  youTubeInspections.set(key, snapshot);
  const candidate = currentCandidate(snapshot.pageUrl);
  if (candidate) {
    candidate.variants = Array.isArray(snapshot.variants) ? snapshot.variants : [];
    backfillCandidateDuration(candidate, candidate.variants);
    candidate.inspecting = false;
    if (snapshot.stage === "complete" || snapshot.stage === "partial") {
      candidate.inspectError = "";
    }
  }
  lastRenderFingerprint = "";
  renderMediaCandidates(currentMedia);
}

/// "Re-parse": force one restart of the shared inspection (the
/// coordinator's dedupe guarantees a single in-flight copy).
async function retryYouTubeInspection(candidate) {
  try {
    const result = await chrome.runtime.sendMessage({
      type: "youtube.retryInspection",
      tabId: currentTabID,
      url: candidate.url,
    });
    if (result?.ok && result.snapshot) {
      applyYouTubeSnapshot(result.snapshot);
      return;
    }
    showToast(t("popup.receiveUnavailable"), "error");
  } catch {
    showToast(t("popup.receiveUnavailable"), "error");
  }
}

// Client-side budget for one quality-parse round trip. The App kills its
// yt-dlp inspection after 30s, but a wedged yt-dlp (e.g. a dead system
// proxy holding connections open) can keep the native request pending far
// longer — without this guard the accordion would show "Parsing…" forever.
const INSPECT_TIMEOUT_MS = 60_000;

function inspectWithTimeout(message) {
  return Promise.race([
    Promise.resolve(chrome.runtime.sendMessage(message)),
    new Promise((resolve) => {
      setTimeout(
        () => resolve({ ok: false, timedOut: true }),
        INSPECT_TIMEOUT_MS,
      );
    }),
  ]);
}

async function inspectCandidate(candidate) {
  const activeCandidate = currentCandidate(candidate.url) ?? candidate;
  // YouTube: shared coordinator (§5.1) — the Popup and the overlay share
  // one inspection and one snapshot; opening/closing the Popup does not
  // cancel the in-page inspection, and reopening reads the latest state.
  if (candidate.siteAdapter === "youtube") {
    await inspectYouTubeViaCoordinator(activeCandidate);
    return;
  }
  activeCandidate.inspecting = true;
  renderMediaCandidates(currentMedia);
  try {
    const result = await inspectWithTimeout({
      type: "media.inspect",
      tabId: currentTabID,
      url: candidate.url,
      // The Popup is opened by a toolbar click, so parsing qualities here is a
      // user gesture: the Host may wake an App the user quit earlier instead
      // of failing the row with a launch timeout.
      userInitiated: true,
      mediaKind: candidate.siteAdapter === "bilibili"
        ? "dash"
        : candidate.format,
    });
    const latestCandidate = currentCandidate(candidate.url) ?? activeCandidate;
    if (result?.ok && Array.isArray(result.variants)) {
      latestCandidate.variants = result.variants;
      // 主行时长槽：App 逐 variant 回传的总时长回填到 candidate 上
      // （B 站 playurl、HLS 子清单共享同一 duration）。
      backfillCandidateDuration(latestCandidate, result.variants);
      latestCandidate.inspectError = "";
    } else if (result?.timedOut) {
      latestCandidate.inspectError = t("popup.inspectTimeout");
    } else {
      latestCandidate.inspectError = friendlyInspectError(result?.message, candidate);
    }
  } catch {
    const latestCandidate = currentCandidate(candidate.url) ?? activeCandidate;
    latestCandidate.inspectError = t("popup.inspectUnavailable");
  } finally {
    const latestCandidate = currentCandidate(candidate.url) ?? activeCandidate;
    latestCandidate.inspecting = false;
    renderMediaCandidates(currentMedia);
  }
}

/// YouTube shared-inspection entry: send a single ensure request; the
/// coordinator dedupes in-flight inspections by tabId + videoId;
/// subsequent updates arrive via the snapshot stream.
async function inspectYouTubeViaCoordinator(candidate) {
  try {
    const result = await chrome.runtime.sendMessage({
      type: "youtube.ensureInspection",
      tabId: currentTabID,
      url: candidate.url,
    });
    if (result?.ok && result.snapshot) {
      applyYouTubeSnapshot(result.snapshot);
      return;
    }
    const latestCandidate = currentCandidate(candidate.url) ?? candidate;
    latestCandidate.inspectError = t("popup.receiveUnavailable");
    renderMediaCandidates(currentMedia);
  } catch {
    const latestCandidate = currentCandidate(candidate.url) ?? candidate;
    latestCandidate.inspectError = t("popup.receiveUnavailable");
    renderMediaCandidates(currentMedia);
  }
}

// Exceptional button on failed-inspection rows: request cookie permission
// per site (needs a user gesture), then automatically retry the
// inspection; a second failure escalates to "you may not be logged in to
// this site" to avoid repeated authorization attempts.
async function authorizeCookieAndRetry(candidate, button) {
  if (!currentOrigin) return;
  button.disabled = true;
  button.textContent = t("popup.cookieAuthorizing");
  let granted = false;
  try {
    granted = await chrome.permissions.request({
      permissions: ["cookies"],
      origins: [`${currentOrigin}/*`],
    });
  } catch {
    showToast(t("popup.cookieRequestFailed"), "error");
    button.disabled = false;
    button.textContent = t("popup.authorizeCookieShort");
    return;
  }
  await refreshPermission();
  if (!granted) {
    showToast(t("popup.cookieDenied"), "error");
    button.disabled = false;
    button.textContent = t("popup.authorizeCookieShort");
    return;
  }
  // The ledger is the single source of truth for site-level authorization:
  // record it immediately after a successful permission request.
  try {
    await addAuthorizedOrigin(chrome.storage, currentOrigin);
  } catch {
    showToast(t("popup.cookieRequestFailed"), "error");
    button.disabled = false;
    button.textContent = t("popup.authorizeCookieShort");
    return;
  }
  await refreshPermission();
  showToast(t("popup.cookieRetryParsing"), "success");
  const target = currentCandidate(candidate.url) ?? candidate;
  target.inspectError = "";
  await inspectCandidate(target);
  const latest = currentCandidate(candidate.url) ?? target;
  if (latest.inspectError) {
    latest.inspectError = t("popup.cookieGrantedStillFailed");
    renderMediaCandidates(currentMedia);
  }
}

async function submitCandidate(candidate, rowEl) {
  // Momentarily gray the row as debounce; feedback goes through the Toast
  // uniformly, leaving no "submitted" state on the row.
  if (rowEl?.classList.contains("busy")) return;
  rowEl?.classList.add("busy");
  try {
    const downloadMessage = {
      type: "media.download",
      tabId: currentTabID,
      url: candidate.url,
      mediaKind: candidate.siteAdapter === "bilibili"
        ? "dash"
        : candidate.siteAdapter === "youtube"
          ? "youtube"
          : candidate.format,
      filenameHint: candidate.filenameHint,
      // Naming trust model (technical spec §8.1): mark whether the hint was
      // synthesized from the title or derived from the URL tail.
      filenameHintSource: globalThis.MacIDMMediaUtils?.filenameHintSourceFor?.(candidate) ?? "urlPath",
      // Gallery rows carry per-card attribution; the page-level title may be
      // branding or another card's caption and must not name the task.
      pageTitle: String(candidate.cardTitle ?? "").trim() || currentMedia.title,
      duration: candidate.duration,
      // A site-adapter candidate's candidate.size comes from incidental
      // response-header observation (possibly only a few KB) and must not
      // be fed to the App as the estimated size; only variant metadata is
      // trusted.
      estimatedSize: candidate.siteAdapter
        ? estimateCandidateSize(candidate)
        : candidate.size,
    };
    // Paired candidates carry the audio/video track URLs so the App can
    // build a DASH-pair task directly.
    if (candidate.pairKind === "m4s-pair") {
      downloadMessage.pairVideoUrl = candidate.pairVideoUrl;
      downloadMessage.pairAudioUrl = candidate.pairAudioUrl;
      downloadMessage.pairCid = candidate.pairCid;
      downloadMessage.pairNote = candidate.pairNote;
    }
    const result = await chrome.runtime.sendMessage(downloadMessage);
    if (result?.ok) {
      showToast(t("popup.confirmWindowOpened"), "success");
      return;
    }
    showToast(result?.message ?? t("popup.submitFailed"), "error");
  } catch {
    showToast(t("popup.receiveUnavailable"), "error");
  } finally {
    rowEl?.classList.remove("busy");
  }
}

function currentCandidate(url) {
  if (!url) return undefined;
  const key = globalThis.MacIDMYouTubeFormats?.youTubeStateKey?.(url);
  return currentMedia.candidates.find((candidate) => {
    if (candidate.url === url) return true;
    if (key && candidateKey(candidate) === key) return true;
    return false;
  });
}

function friendlyInspectError(message, candidate) {
  // The generic takeover-rejection message ("MacIDM rejected this
  // takeover" / "MacIDM takeover failed") is misleading for inspection
  // failures. Replace it with site-specific guidance so the user knows
  // what to do next.
  const isGenericRejection =
    !message ||
    message.includes(t("protocol.error.appRejected")) ||
    message.includes(t("protocol.takeoverFailedPrefix"));
  if (!isGenericRejection) return message;
  if (candidate?.siteAdapter === "bilibili") {
    return t("common.inspectErrorBilibili");
  }
  if (candidate?.siteAdapter === "youtube") {
    return t("common.inspectErrorYouTube");
  }
  return t("common.inspectErrorGeneric");
}

async function enqueueVariant(candidate, variant, optionEl) {
  if (!variant?.url || optionEl?.dataset.busy) return;
  if (optionEl) optionEl.dataset.busy = "true";
  try {
    const result = await chrome.runtime.sendMessage({
      type: "media.download",
      tabId: currentTabID,
      url: variant.url,
      mediaKind: candidate.siteAdapter === "bilibili"
        ? "dash"
        : candidate.siteAdapter === "youtube"
          ? "youtube"
          : candidate.format,
      filenameHint: candidate.filenameHint,
      filenameHintSource: globalThis.MacIDMMediaUtils?.filenameHintSourceFor?.(candidate) ?? "urlPath",
      // Gallery rows carry per-card attribution; the page-level title may be
      // branding or another card's caption and must not name the task.
      pageTitle: String(candidate.cardTitle ?? "").trim() || currentMedia.title,
      duration: variant.duration,
      estimatedSize: estimatedSizeForVariant(variant),
      pairVideoUrl: variant.pairAudioUrl ? variant.url : variant.pairVideoUrl,
      pairAudioUrl: variant.pairAudioUrl,
      pairCid: variant.pairCid,
      pairNote: variant.pairAudioUrl ? t("common.pairNoteMerge") : candidate.pairNote,
    });
    if (result?.ok) {
      openAccordionUrl = null;
      renderMediaCandidates(currentMedia);
      showToast(t("popup.confirmWindowOpened"), "success");
      return;
    }
    showToast(result?.message ?? t("popup.submitFailed"), "error");
  } catch {
    showToast(t("popup.receiveUnavailable"), "error");
  } finally {
    if (optionEl) delete optionEl.dataset.busy;
  }
}

async function refreshPermission() {
  if (!currentOrigin) {
    downloadAll.disabled = true;
    cookieGranted = false;
    updateCookieStatusRow(currentMedia);
    updateCookieShortcutVisibility();
    return;
  }
  let granted = false;
  try {
    // Site-level authorization consults the chrome.storage ledger: the
    // origins argument of permissions.contains is hollowed out by global
    // host_permissions and returns true for every page.
    granted = await isOriginAuthorized(chrome, currentOrigin);
  } catch {
    granted = false;
  }
  cookieGranted = granted;
  updateCookieStatusRow(currentMedia);
  updateCookieShortcutVisibility();
  downloadAll.disabled = false;
}

/// The status row refreshes together with the candidates: when
/// unauthorized yet a site-adapter candidate has been resolved, the
/// consequences of "guest quality" must be spelled out, otherwise the
/// downgrade is silent (Bilibili's API claims 4K support but actually
/// serves only 480P tracks, with no visible anomaly in the UI). When
/// authorized, the row title switches to re-parse semantics, avoiding a
/// stale "click to authorize" hint.
function updateCookieStatusRow(payload) {
  cookieStatus.textContent = cookieStatusTextFor(payload);
  cookieRow.title = cookieGranted
    ? t("popup.cookieRowTitleGranted")
    : t("popup.cookieRowTitle");
}

/// Menu row copy: when authorized, show "authorized · click to re-parse"
/// (the row remains the re-parse entry; login-state changes need a manual
/// refresh); when unauthorized and the current page has already resolved a
/// site-adapter candidate (i.e. silently downgraded to guest quality),
/// spell out both the consequence and the action entry.
function cookieStatusTextFor(payload) {
  if (cookieGranted) return t("popup.cookieGrantedShort");
  const degraded = (payload?.candidates ?? []).some(
    (candidate) => candidate?.siteAdapter === "bilibili",
  );
  return degraded ? t("popup.cookieNotGrantedGuest") : t("popup.cookieNotGranted");
}

// Visibility of the one-click authorize shortcut next to the title: it
// appears whenever the current site is unauthorized, so the user need not
// open the ⋯ menu to find the authorize entry; hidden once authorized
// (user request: never show it when already authorized).
function updateCookieShortcutVisibility(payload = currentMedia) {
  if (!cookieShortcut) return;
  const show = !cookieGranted && !!currentOrigin;
  cookieShortcut.hidden = !show;
}

// Clicking the menu row: when unauthorized, request cookies permission
// for the current site (needs a user gesture) and re-parse after the
// grant; when already authorized, only re-parse (login-state changes
// likewise require re-asking the App).
async function authorizeSiteCookiesAndReparse() {
  if (!currentOrigin || cookieRowInFlight) return;
  cookieRowInFlight = true;
  try {
    if (!cookieGranted) {
      let granted = false;
      try {
        granted = await chrome.permissions.request({
          permissions: ["cookies"],
          origins: [`${currentOrigin}/*`],
        });
      } catch {
        showToast(t("popup.cookieRequestFailed"), "error");
        return;
      }
      if (!granted) {
        showToast(t("popup.cookieDenied"), "error");
        return;
      }
      // The ledger is the single source of truth for site-level
      // authorization: record it immediately after a successful permission
      // request.
      try {
        await addAuthorizedOrigin(chrome.storage, currentOrigin);
      } catch {
        showToast(t("popup.cookieRequestFailed"), "error");
        return;
      }
      showToast(t("popup.cookieRetryParsing"), "success");
    } else {
      showToast(t("popup.cookieReparse"), "success");
    }
    await refreshPermission();
    await reparseInspectableCandidates();
  } finally {
    cookieRowInFlight = false;
  }
}

/// Clear cached variants and re-ask the App: authorization only changes
/// the request context of subsequent inspections; without re-asking, the
/// panel would keep showing the pre-authorization guest qualities. The
/// target set is every candidate needing site parsing (Bilibili adapter +
/// HLS/DASH manifests), not just the "quality" concept; the persistent
/// refresh entry next to the title shares this re-sniff path with the
/// cookie flow.
let reparseInFlight = false;
async function reparseInspectableCandidates() {
  if (reparseInFlight) return;
  const targets = (currentMedia.candidates ?? []).filter(
    (candidate) =>
      candidate?.siteAdapter === "bilibili"
      || candidate?.format === "hls"
      || candidate?.format === "dash",
  );
  if (targets.length === 0) return;
  reparseInFlight = true;
  try {
    for (const candidate of targets) {
      candidate.variants = [];
      candidate.inspectError = "";
    }
    renderMediaCandidates(currentMedia);
    await Promise.allSettled(targets.map((candidate) => inspectCandidate(candidate)));
  } finally {
    reparseInFlight = false;
  }
}

function hasVariantInfo(variant) {
  if (!variant) return false;
  // A variant is "meaningful" if variantLabel() can produce something
  // more specific than the generic "default quality" fallback.
  return variantLabel(variant) !== t("popup.defaultQuality");
}

function variantLabel(variant) {
  if (!variant) return t("popup.defaultQuality");
  // Use the server-provided label if it already contains useful detail.
  // The "auto" label (the raw Chinese value compared below) comes straight
  // from the site API and is not translated.
  const label = String(variant.label ?? "").trim();
  if (label && label !== "自动" && label !== t("popup.defaultQuality")) return label;
  // Build a label with the unified slot grammar
  // (quality · frame rate · codec family · bitrate) when the server label
  // is generic.
  const built = globalThis.MacIDMMediaUtils?.variantDisplayLabel?.(variant) ?? "";
  if (built) return built;
  // B2: Last resort — infer resolution from URL query params.
  if (variant.url) {
    try {
      const u = new URL(variant.url);
      const w = u.searchParams.get("w") || u.searchParams.get("width");
      const h = u.searchParams.get("h") || u.searchParams.get("height");
      if (w && h) return `${w}×${h}`;
      if (h && /^\d{2,5}$/u.test(h)) return `${h}p`;
    } catch { /* ignore */ }
  }
  return t("popup.defaultQuality");
}

function variantTooltip(variant) {
  if (!variant) return "";
  const parts = [];
  // B2: Always show full info — resolution, bitrate, codec, estimated
  // size — even when some fields are missing (display "unknown").
  if (variant.width && variant.height) {
    parts.push(t("common.tooltipResolution", { value: `${variant.width}×${variant.height}` }));
  } else if (variant.height) {
    parts.push(t("common.tooltipResolution", { value: `${variant.height}p` }));
  } else {
    let resolved = false;
    if (variant.url) {
      try {
        const u = new URL(variant.url);
        const w = u.searchParams.get("w") || u.searchParams.get("width");
        const h = u.searchParams.get("h") || u.searchParams.get("height");
        if (w && h) {
          parts.push(t("common.tooltipResolution", { value: `${w}×${h}` }));
          resolved = true;
        } else if (h) {
          parts.push(t("common.tooltipResolution", { value: `${h}p` }));
          resolved = true;
        }
      } catch { /* ignore */ }
    }
    if (!resolved) parts.push(t("common.tooltipResolutionUnknown"));
  }
  if (variant.bandwidth > 0) {
    parts.push(t("common.tooltipBitrate", { value: (variant.bandwidth / 1_000_000).toFixed(2) }));
  } else {
    parts.push(t("common.tooltipBitrateUnknown"));
  }
  if (variant.fps > 0) {
    parts.push(t("common.tooltipFps", { value: Math.round(variant.fps) }));
  }
  const codecSlot = globalThis.MacIDMMediaUtils?.codecFamily?.(variant.codecs) ?? "";
  if (codecSlot) {
    parts.push(t("common.tooltipCodec", { value: codecSlot }));
  } else {
    parts.push(t("common.tooltipCodecUnknown"));
  }
  const estimatedSize = estimatedSizeForVariant(variant);
  if (estimatedSize != null) {
    parts.push(t("common.tooltipEstimatedSize", { size: formatBytes(estimatedSize) ?? t("common.unknown") }));
  } else {
    parts.push(t("common.tooltipEstimatedSizeUnknown"));
  }
  const durationText = formatDuration(variant.duration);
  parts.push(durationText
    ? t("common.tooltipDuration", { value: durationText })
    : t("common.tooltipDurationUnknown"));
  if (variant.url) {
    try {
      const u = new URL(variant.url);
      parts.push(t("common.tooltipSource", { host: u.hostname }));
    } catch { /* ignore */ }
  }
  return parts.join("\n");
}

function formatLabel(value) {
  const candidate = typeof value === "object" ? value : null;
  const extension = candidate ? candidate.fileExtension : value;
  // HLS/DASH: show the stream type rather than just the playlist extension.
  if (candidate?.format === "hls") return t("common.formatHLS");
  if (candidate?.format === "dash") return t("common.formatDASH");
  if (candidate?.format === "dash-json") return t("popup.formatDashJson");
  // YouTube product contract (technical-spec §3.4): the UI selects a
  // quality/codec variant, while App/yt-dlp + FFmpeg uniformly outputs
  // MP4 in the end; a source variant's container (e.g. VP9's webm) is not
  // the final output container and must not appear in the format column.
  if (candidate?.siteAdapter === "youtube") return "MP4";
  if (typeof extension === "string" && extension.trim()) return extension.toUpperCase();
  return t("common.formatUnknown");
}

function formatSize(candidate) {
  // dash-json manifests cannot be estimated directly; site parsing takes
  // over.
  if (candidate.format === "dash-json") return t("common.unknown");
  // For HLS/DASH the Content-Length we observed is only the playlist, not
  // the media itself; showing it as "size" would be misleading. But after
  // inspection, variants may carry estimated sizes — show those.
  if (
    candidate.format === "hls" || candidate.format === "dash"
    || candidate.siteAdapter === "youtube" || candidate.siteAdapter === "bilibili"
  ) {
    const variantSize = estimateCandidateSize(candidate);
    if (variantSize != null) {
      return t("common.approxHighestSize", { size: formatBytes(variantSize) ?? t("common.unknown") });
    }
    // While auto-inspection is in progress, show a transitional state;
    // once it completes, refresh to the estimate or "unknown".
    if (candidate.inspecting) return t("common.parsing");
    return t("common.unknown");
  }
  if (Number.isSafeInteger(candidate.size)) return formatBytes(candidate.size) ?? t("common.unknown");
  if (candidate.sizeProbeFailed === true) return t("common.sizeUnknown");
  // The background actively probes unknown sizes (HEAD / Range); the value
  // usually appears within a few seconds on the next auto-refresh.
  return t("common.probing");
}

// Byte/duration formatting delegates to the single implementation in
// media-utils.js (invalid input returns null).
function formatBytes(value) {
  return globalThis.MacIDMMediaUtils?.formatBytes?.(value) ?? null;
}

function formatDuration(seconds) {
  return globalThis.MacIDMMediaUtils?.formatDuration?.(seconds) ?? null;
}

function estimateCandidateSize(candidate) {
  return globalThis.MacIDMMediaPresentation.estimateCandidateSize(
    candidate,
    youTubeInspections,
    hasVariantInfo,
  );
}

function estimatedSizeForVariant(variant) {
  return globalThis.MacIDMMediaPresentation.estimatedSizeForVariant(variant);
}

function variantOptionLabel(variant) {
  const label = variantLabel(variant);
  const estimatedSize = estimatedSizeForVariant(variant);
  const sizeText = estimatedSize == null
    ? null
    : t("common.approxSize", { size: formatBytes(estimatedSize) ?? t("common.unknown") });
  return [label, sizeText].filter(Boolean).join(" · ");
}

function isCollapsedSegment(candidate) {
  return candidate?.pairKind === "m4s-fragment" || candidate?.pairKind === "stream-segment";
}

// All feedback is transient: a top-center toast (shared/panel-ui.js) with
// semantic text color replaces the old always-red footer slot, so success
// messages are no longer misread as errors.
function showToast(message, kind) {
  if (!message) return;
  globalThis.MacIDMPanelUI?.showToast(document.body, message, { kind });
}

function httpOrigin(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}
