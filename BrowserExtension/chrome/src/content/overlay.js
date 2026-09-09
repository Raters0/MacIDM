// MacIDM media overlay: an IDM-style floating download button pinned to the
// top-right corner of <video>/<audio> elements. Shadow DOM isolates styles
// from the page. The button only appears when candidates exist, never
// auto-downloads, and every action still ends at the App confirmation sheet.
(function installMacIDMOverlay(global) {
  if (global.__macIDMOverlayInstalled) return;
  global.__macIDMOverlayInstalled = true;

  const MAX_ATTACHMENTS = 12;
  const MIN_ELEMENT_WIDTH = 220;
  const MIN_ELEMENT_HEIGHT = 120;
  const Z_INDEX = "2147483646";

  // i18n core + locale catalogs load before this script (manifest order).
  // The indirection keeps the overlay functional even if the global is
  // missing, at the cost of showing raw keys.
  function t(key, params) {
    return globalThis.MacIDMI18n?.t(key, params) ?? key;
  }

  let pageTitle = "";
  let candidates = [];
  let rawCandidates = [];
  // Redacted filter counts for false-positive suppression (same snapshot
  // source as the Popup); holds the three count keys.
  let filteredSummary = { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };
  let openPanelFor = null;
  let openPanelSignature = "";
  let syncScheduled = false;
  let repositionScheduled = false;
  let cachedTabTitle = "";
  let cachedTabURL = "";
  let cachedTabID = null;
  let tabTitleFetched = false;
  let lastSyncedPageURL = "";
  let lastSyncedVideoID = "";
  // Page-session epoch (AI handover doc §3.3): incremented on a real page
  // transition; a late async tab-title reply whose epoch differs from the
  // one captured at request time is ignored entirely so it cannot pollute
  // the new page.
  let pageEpoch = 0;
  let runtimeMessageUnavailable = false;
  // Site cookie authorization state (the SW queries the authorizedOrigins
  // ledger): when unauthorized, the panel header shows the "authorize site
  // cookies" entry; after granting, updates arrive via
  // macidm.cookieAuthorized.
  let cookieGranted = false;
  // Translucent overlay scrollbar attachment. Mounting must wait until the
  // panel is inserted into the shadow DOM (a detached container has no
  // parent node, so the thumb would be mounted inside the container and get
  // clipped); before removing or replacing the panel it must be detached
  // first — the thumb is a sibling of the panel inside .wrap and is not
  // removed together with the panel.
  let slimScrollbarDetach = null;
  const autoInspectedUrls = new Set();
  // Inspection results survive panel closes (the panel DOM is destroyed on
  // close) and candidate rebuilds (coalesceMediaCandidates returns fresh
  // objects on every sync), so reopening the panel renders the cached
  // variants instead of demanding another manual parse click.
  const inspectedVariants = new Map(); // candidate url -> variants
  // Inspection failures render as the red short text on the row (clicking
  // the row degrades to a direct download); keyed like inspectedVariants.
  const inspectionFailures = new Map(); // candidate url -> message
  // In-flight inspections show "Parsing…" inside an expanded submenu.
  const inspectingUrls = new Set();
  // Candidate URL whose quality submenu is accordion-expanded (one at a
  // time); preserved across panel rebuilds triggered by fresh data.
  let openSubFor = null;
  // YouTube shared-inspection snapshots (AI handover doc §5.1–5.2):
  // candidate url -> snapshot. Shares the background coordinator's single
  // inspection and its stage state with the Popup.
  const youTubeInspections = new Map();
  // Unique id sequence for aria-controls ↔ submenu pairing.
  let submenuIdSeq = 0;

  function nextSubmenuId() {
    submenuIdSeq += 1;
    return submenuIdSeq;
  }

  const attachments = new Map(); // element -> { host, shadow, button }

  // Unified YouTube page identity (AI handover doc §2): the primary key for
  // inspection snapshots, variant caches, auto-inspection dedupe and expand
  // state is the videoId, not the changeable full URL; non-YouTube
  // candidates keep using the original URL key. Normalization is only for
  // state association and never rewrites the URL submitted to the App.
  function candidateKey(candidate) {
    return globalThis.MacIDMMediaPresentation.candidateKey(candidate);
  }

  function snapshotKey(snapshot) {
    return globalThis.MacIDMMediaPresentation.snapshotKey(snapshot);
  }

  function videoIdOf(url) {
    return globalThis.MacIDMMediaPresentation.videoIdOf(url);
  }

  function resetInspectionState() {
    autoInspectedUrls.clear();
    inspectedVariants.clear();
    inspectionFailures.clear();
    inspectingUrls.clear();
    youTubeInspections.clear();
    openSubFor = null;
  }

  // In cross-origin iframes the overlay cannot access the parent page's
  // document.title or meta tags. Fetch the tab title from the background
  // service worker which can use the Chrome tabs API.
  function ensureTabTitle() {
    if (tabTitleFetched) return;
    tabTitleFetched = true;
    // Page-session token (§3.3): capture the current epoch when sending the
    // request; drop the reply if the page truly transitioned before it
    // lands.
    const requestEpoch = pageEpoch;
    try {
      sendRuntimeMessage({ type: "overlay.tabTitle" }).then((result) => {
        // A stale request arriving after SPA navigation is ignored whole —
        // no cache writes, no candidate recompute, no panel refresh; the new
        // page's own fresh request (tabTitleFetched already reset) takes
        // effect instead.
        if (requestEpoch !== pageEpoch) return;
        if (!result?.ok) return;
        if (result.title) cachedTabTitle = String(result.title).slice(0, 300);
        if (result.url) cachedTabURL = String(result.url);
        if (result.tabId) cachedTabID = result.tabId;
        if (cachedTabURL) {
          // The tab title must not backfill an empty title with a stale one
          // after an SPA transition (§7): the top-level frame only adopts it
          // when the tab URL returned by the background matches the current
          // page URL; a cross-origin iframe cannot get the parent page's
          // session title at all and still backfills from the tab title by
          // design.
          if (!pageTitle && (cachedTabURL === lastSyncedPageURL || global !== global.top)) {
            pageTitle = cachedTabTitle || pageTitle;
          }
          // The reply URL must not override the updated real candidate URL
          // (§3.3): when a same-video parameter change has already updated
          // the page URL, candidate recompute uses the latest synced URL and
          // does not fall back to the stale URL in the reply.
          const coalesceURL =
            lastSyncedPageURL
            && videoIdOf(lastSyncedPageURL)
            && videoIdOf(lastSyncedPageURL) === videoIdOf(cachedTabURL)
              ? lastSyncedPageURL
              : cachedTabURL;
          const previousCandidates = candidates;
          candidates = coalesceCandidates(coalesceURL);
          // If the updated candidates differ (e.g. the tab URL revealed a
          // Bilibili/YouTube page adapter that was missing before), reset
          // autoInspectedUrls so inspection re-fires for the new
          // site-adapter candidate.
          if (JSON.stringify(previousCandidates) !== JSON.stringify(candidates)) {
            // Same-video parameter changes do not clear inspection state
            // (§2): results keyed by videoId must remain consumable.
            if (videoIdOf(coalesceURL) !== lastSyncedVideoID) resetInspectionState();
            // Candidate updates must not close an open panel (§3.2): the
            // close on a real page transition is done synchronously at
            // transition time by syncCandidates/
            // handleURLTransitionIfNeeded; same-video candidate changes
            // only re-render in place, preserving open and expanded state.
            refreshOpenPanel();
          }
          scheduleSync();
        }
      }).catch(() => {});
    } catch {
      // Extension context may be invalidated; ignore.
    }
  }

  function sendRuntimeMessage(message) {
    if (runtimeMessageUnavailable) return Promise.resolve(null);
    try {
      return Promise.resolve(chrome.runtime.sendMessage(message)).catch(() => null);
    } catch {
      runtimeMessageUnavailable = true;
      return Promise.resolve(null);
    }
  }

  // Query the SW for the current tab's top-level page site-cookie
  // authorization state (content scripts cannot call chrome.permissions
  // directly). The state only toggles the header authorize entry / granted
  // hint; the panel signature excludes it, so a change requires a forced
  // rebuild or the header would keep showing the stale state.
  function refreshCookiePermission() {
    sendRuntimeMessage({ type: "overlay.permissionState" }).then((result) => {
      const next = result?.cookieGranted === true;
      if (next === cookieGranted) return;
      cookieGranted = next;
      refreshOpenPanel(true);
    });
  }

  /// The overlay's immediate defense against SPA navigation (AI handover
  /// doc §5.1): the content script's transition snapshot has a 120 ms
  /// notification debounce, so for the first few hundred ms after
  /// pushState the panel would keep its open state. The overlay itself can
  /// synchronously see `location.href`: DOM mutation callbacks compare the
  /// URL first, and on a real transition (not a same-video parameter
  /// change) immediately close every open panel without waiting for the
  /// transition snapshot, and without depending on when the old media
  /// element is removed from the DOM.
  function handleURLTransitionIfNeeded() {
    if (!lastSyncedPageURL) return;
    const currentURL = global.location?.href ?? "";
    if (!currentURL || currentURL === lastSyncedPageURL) return;
    const previousVideoId = lastSyncedVideoID;
    const incomingVideoId = videoIdOf(currentURL);
    // Same video with only parameter/fragment changes: panel, expand state
    // and qualities are preserved (§3.2); candidates are still updated
    // normally by the subsequent transition snapshot.
    if (previousVideoId && incomingVideoId === previousVideoId) return;
    pageEpoch += 1;
    lastSyncedPageURL = currentURL;
    lastSyncedVideoID = incomingVideoId;
    tabTitleFetched = false;
    cachedTabURL = "";
    cachedTabTitle = "";
    closeAllPanels();
    resetInspectionState();
  }

  function install() {
    // Load the persisted language choice; panels render on demand so the
    // resolved language applies from the first user interaction.
    globalThis.MacIDMI18n?.init?.()?.catch?.(() => {});
    // Subscribe to the shared inspection snapshot stream (§5.1): the
    // coordinator pushes to this tab on every stage/variant change, so the
    // overlay and the Popup see the same counts, sources and stages.
    try {
      chrome.runtime?.onMessage?.addListener?.((message) => {
        // After the authorize window finishes, the SW pushes the latest
        // authorization state: update button visibility; on a fresh grant,
        // clear the old (guest-quality) inspection cache so the next
        // inspection re-asks the App with cookies.
        if (message?.type === "macidm.cookieAuthorized") {
          cookieGranted = message.granted === true;
          if (cookieGranted) resetInspectionState();
          // The panel signature excludes the authorization state; a forced
          // rebuild is required to swap the authorize entry / granted hint.
          refreshOpenPanel(true);
          return;
        }
        if (message?.type !== "macidm.youTubeInspectionUpdate") return;
        const snapshot = message.snapshot;
        if (!snapshot?.pageUrl) return;
        if (cachedTabID != null && snapshot.tabId !== cachedTabID) return;
        applyYouTubeSnapshot(snapshot);
      });
    } catch {
      // Degrade silently when the extension context is invalidated.
    }
    refreshCookiePermission();
    // Language changed elsewhere (popup select or another frame): rebuild
    // every attachment so fab tooltips and open panels use the new copy.
    globalThis.MacIDMI18n?.onChange?.(() => {
      closeAllPanels();
      for (const element of [...attachments.keys()]) detach(element);
      syncAttachments();
    });
    const observer = new MutationObserver(() => {
      handleURLTransitionIfNeeded();
      scheduleSync();
    });
    // Attribute changes matter too: players toggle video visibility via
    // style/class (YouTube keeps <video> hidden behind the cover image
    // until playback starts), which moves the fab anchor without any DOM
    // insertion or removal.
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["style", "class", "hidden", "width", "height"],
    });
    global.addEventListener("scroll", scheduleReposition, { passive: true, capture: true });
    global.addEventListener("resize", scheduleReposition, { passive: true });
    scheduleSync();
  }

  // ---- public API used by content-script.js ----

  function syncCandidates(snapshot) {
    // SPA navigation changes the page URL without reloading the content
    // script; the one-shot tab-title fetch and cached tab URL must be
    // refreshed or the panel keeps the previous video's title.
    const incomingURL = String(snapshot?.pageUrl ?? "");
    if (incomingURL && incomingURL !== lastSyncedPageURL) {
      const previousVideoId = lastSyncedVideoID;
      const incomingVideoId = videoIdOf(incomingURL);
      const sameYouTubeVideo =
        Boolean(previousVideoId) && incomingVideoId === previousVideoId;
      lastSyncedPageURL = incomingURL;
      lastSyncedVideoID = incomingVideoId;
      tabTitleFetched = false;
      cachedTabURL = "";
      cachedTabTitle = "";
      // Navigated to a new top-level page: its site authorization state may
      // differ, so re-query to refresh the header authorize entry.
      refreshCookiePermission();
      if (!sameYouTubeVideo) {
        // Real page transition (AI handover doc §3.1): synchronously close
        // every open panel before applying the new page's candidates and
        // refreshOpenPanel — the new page's panel must stay collapsed and
        // may only expand after the user clicks again on that page; it must
        // not inherit the previous page's open state, nor depend on when
        // the old media element is removed from the DOM. Increment the
        // page-session epoch so pending stale async tab-title replies are
        // invalidated wholesale (§3.3).
        pageEpoch += 1;
        closeAllPanels();
        // A→B discards the previous video's inspection snapshots and expand
        // state (§3.1/§5.1).
        resetInspectionState();
      }
    }
    pageTitle = String(snapshot?.title ?? "").slice(0, 300);
    rawCandidates = Array.isArray(snapshot?.candidates) ? snapshot.candidates : [];
    filteredSummary = readFilteredSummary(snapshot);
    candidates = coalesceCandidates(snapshot?.pageUrl || global.location?.href || "");
    // Always fetch the tab title/URL from the background, even in the
    // top-level frame. The content script's location.href may differ from
    // the tab URL (SPA navigation, history.pushState) and cross-origin
    // iframes have no access to the parent page's URL at all. Without the
    // correct tab URL, coalesceMediaCandidates cannot detect Bilibili/
    // YouTube page adapters, causing the overlay to show raw CDN segments
    // instead of the site-adapter candidate the Popup already has.
    ensureTabTitle();
    scheduleSync();
    refreshOpenPanel();
  }

  function coalesceCandidates(pageURL) {
    const coalescer = globalThis.MacIDMMediaUtils?.coalesceMediaCandidates;
    return typeof coalescer === "function"
      ? coalescer(rawCandidates, pageTitle, pageURL)
      : rawCandidates;
  }

  // Redacted filter counts carried on the snapshot (technical-spec §8.4):
  // invalid values are clamped to zero so page data cannot affect panel
  // rendering.
  function readFilteredSummary(snapshot) {
    const raw = snapshot?.filteredSummary;
    const count = (value) => {
      const parsed = Number(value);
      return Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(parsed, 100_000) : 0;
    };
    return {
      diagnosticAudio: count(raw?.diagnosticAudio),
      streamSegments: count(raw?.streamSegments),
      smallResources: count(raw?.smallResources),
    };
  }

  // ---- attachment lifecycle ----

  function scheduleSync() {
    if (syncScheduled) return;
    syncScheduled = true;
    requestAnimationFrame(() => {
      syncScheduled = false;
      syncAttachments();
    });
  }

  function scheduleReposition() {
    if (repositionScheduled) return;
    repositionScheduled = true;
    requestAnimationFrame(() => {
      repositionScheduled = false;
      repositionAll();
    });
  }

  function syncAttachments() {
    const elements = [...document.querySelectorAll("video, audio")]
      .filter(isAttachable)
      .slice(0, MAX_ATTACHMENTS);
    const keep = new Set(elements);
    for (const element of [...attachments.keys()]) {
      if (!keep.has(element) || !isAttachable(element)) {
        detach(element);
        keep.delete(element);
      }
    }
    for (const element of elements) {
      if (!attachments.has(element)) attach(element);
    }
    repositionAll();
  }

  function isAttachable(element) {
    if (!(element instanceof HTMLMediaElement)) return false;
    if (candidates.length === 0) return false;
    return findAnchorElement(element) != null;
  }

  // Sites like YouTube hide <video> behind a cover image until playback
  // starts. Two hiding styles exist: the element collapses to a zero-size
  // rect, or it keeps its full box but is translated off-screen (YouTube
  // shifts the video above the visible #movie_player cover). In both cases
  // fall back to the nearest visible ancestor (the poster/player container)
  // so the fab stays reachable above the cover; once the video itself is
  // large and mostly on-screen the anchor moves back onto it.
  function findAnchorElement(element) {
    if (isUsableAnchor(element)) return element;
    let ancestor = element.parentElement;
    for (let depth = 0; ancestor && depth < 6; depth += 1) {
      if (isElementVisible(ancestor)) {
        const box = ancestor.getBoundingClientRect();
        if (box.width >= MIN_ELEMENT_WIDTH && box.height >= MIN_ELEMENT_HEIGHT) {
          return ancestor;
        }
      }
      ancestor = ancestor.parentElement;
    }
    return null;
  }

  // A media element anchors the fab when it is large enough and at least
  // roughly within the viewport. Off-screen-but-full-size boxes (the
  // translated-video hiding trick) fail the intersection test even though
  // they pass the size test.
  function isUsableAnchor(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width < MIN_ELEMENT_WIDTH || rect.height < MIN_ELEMENT_HEIGHT) return false;
    const viewW = global.innerWidth || 0;
    const viewH = global.innerHeight || 0;
    if (viewW <= 0 || viewH <= 0) return true;
    const visibleWidth = Math.min(rect.right, viewW) - Math.max(rect.left, 0);
    const visibleHeight = Math.min(rect.bottom, viewH) - Math.max(rect.top, 0);
    if (visibleWidth <= 0 || visibleHeight <= 0) return false;
    return (visibleWidth * visibleHeight) / (rect.width * rect.height) >= 0.25;
  }

  function isElementVisible(element) {
    const style = global.getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden";
  }

  function attach(element) {
    const host = document.createElement("div");
    host.setAttribute("data-macidm-overlay", "");
    host.style.cssText = `position:absolute;z-index:${Z_INDEX};width:0;height:0;`;
    const shadow = host.attachShadow({ mode: "open" });
    shadow.innerHTML = `
      <style>
        /* Token values mirror src/shared/tokens.css (the App's AppTheme);
           shadow roots cannot load the shared stylesheet, so keep the two
           in sync when the palette changes. light-dark() follows the
           system appearance via the color-scheme on .wrap. */
        .wrap { position: relative; color-scheme: light dark; }
        /* v4 FAB: flat square button with a neutral surface and a gray
           download glyph — no blue fill, no badge. */
        .fab {
          position: absolute; top: 0; right: 6px;
          width: 28px; height: 28px; border-radius: 6px;
          background: light-dark(rgba(255, 255, 255, 0.94), rgba(44, 48, 56, 0.94));
          border: none; cursor: pointer;
          display: flex; align-items: center; justify-content: center;
          box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
          opacity: 0.35; transition: opacity .15s ease, transform .15s ease;
          padding: 0;
        }
        .wrap:hover .fab, .fab:focus-visible, .fab.open { opacity: 1; transform: scale(1.05); }
        .fab svg { width: 14px; height: 14px; fill: light-dark(#5f6b7d, #98a1b3); }
        /* v4 panel: width adapts to content (300–500px), right edge aligned
           with the FAB, 340px cap with internal scroll and a sticky header. */
        .panel {
          position: absolute; top: 32px; right: 6px;
          width: max-content; min-width: 300px; max-width: 500px;
          max-height: 340px; overflow-y: auto; overscroll-behavior: contain;
          background: light-dark(rgba(255, 255, 255, 0.97), rgba(32, 35, 41, 0.97));
          color: light-dark(#1f2329, #e8eaf0);
          border: 1px solid light-dark(rgba(15, 23, 42, 0.12), rgba(255, 255, 255, 0.12));
          border-radius: 8px;
          box-shadow: light-dark(0 8px 24px rgba(15, 23, 42, 0.16), 0 8px 24px rgba(0, 0, 0, 0.4));
          font: 12px/1.5 -apple-system, "PingFang SC", sans-serif;
          backdrop-filter: blur(8px); overflow-x: hidden;
        }
        .panel header {
          position: sticky; top: 0; z-index: 1;
          background: light-dark(rgba(255, 255, 255, 0.97), rgba(32, 35, 41, 0.97));
          padding: 10px 14px 8px; font-weight: 600; font-size: 12px;
          display: flex; justify-content: space-between; align-items: center; gap: 8px;
          border-bottom: 1px solid light-dark(rgba(15, 23, 42, 0.08), rgba(255, 255, 255, 0.08));
        }
        .panel header .header-titlegroup {
          display: inline-flex; align-items: baseline; gap: 4px; min-width: 0;
        }
        .panel header .header-title {
          font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        .panel header .header-count { color: light-dark(#64748b, #98a1b3); font-weight: 400; flex: none; }
        .panel header .header-actions { display: flex; align-items: center; gap: 8px; flex: none; }
        .panel .authorize {
          background: none; border: none; cursor: pointer; font: inherit;
          font-size: 11px; font-weight: 400; white-space: nowrap; padding: 0 2px;
          color: light-dark(#4c5be0, #a5adfa);
        }
        .panel .authorize:hover { text-decoration: underline; }
        .panel .close {
          background: none; border: none; color: light-dark(#64748b, #98a1b3);
          cursor: pointer; font-size: 14px; padding: 0 2px;
        }
        .panel .cookie-granted {
          font-size: 11px; white-space: nowrap; padding: 0 2px;
          color: light-dark(#64748b, #98a1b3); cursor: default;
        }
        /* Whole-row click model (same as the Popup): the row is the only
           click target, hover is a 5% neutral fill with no side bar, and
           submit feedback is a toast instead of inline state. */
        .item {
          position: relative; padding: 10px 14px; cursor: pointer;
          border-top: 1px solid light-dark(rgba(15, 23, 42, 0.05), rgba(255, 255, 255, 0.05));
        }
        .item:first-of-type { border-top: none; }
        .item:hover { background: light-dark(rgba(15, 23, 42, 0.05), rgba(255, 255, 255, 0.06)); }
        .item.busy { opacity: 0.55; pointer-events: none; }
        .item.static { cursor: default; }
        .item.static:hover { background: transparent; }
        .item.static.filtered-note {
          color: light-dark(#64748b, #98a1b3); font-size: 11px; padding: 8px 14px;
        }
        .item.has-sub { padding-right: 30px; }
        .name {
          font-weight: 600; color: light-dark(#111318, #fff);
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }
        /* Expanded candidate full title (AI handover doc §5.5): .item.open
           switches to full multi-line wrapping. The panel already has a
           340px max height with internal scrolling, so long titles only add
           content height. */
        .item.open .name {
          white-space: normal; text-overflow: clip; overflow-wrap: anywhere;
        }
        .meta {
          color: light-dark(#64748b, #98a1b3); margin-top: 2px;
          display: flex; align-items: center; gap: 5px; overflow: hidden;
        }
        .meta-icon { display: inline-flex; flex: none; opacity: .85; }
        .meta-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        /* Parsing spinner on the main row: an inline rotating ring in the
           meta area (same style as the Popup), replaced by result slots
           like "highest spec: ~XX MB" once parsing completes. */
        .meta-spinner {
          display: inline-flex; flex: none; width: 11px; height: 11px;
          border-radius: 50%;
          border: 2px solid light-dark(rgba(15, 23, 42, 0.15), rgba(255, 255, 255, 0.18));
          border-top-color: light-dark(#64748b, #98a1b3);
          animation: macidm-meta-spin .8s linear infinite;
        }
        @keyframes macidm-meta-spin { to { transform: rotate(360deg); } }
        .chevron {
          position: absolute; right: 12px; top: 50%; transform: translateY(-50%);
          color: light-dark(#98a1b3, #64748b); font-size: 14px; line-height: 1;
          transition: transform .15s ease;
        }
        .item.open .chevron { transform: translateY(-50%) rotate(90deg); }
        /* Accordion quality submenu: expands in place directly below its row. */
        .submenu { padding: 2px 0 6px; }
        /* Sub-items are real <button>s: reset UA button chrome so they keep
           the row look while gaining native keyboard activation. */
        .sub-item {
          display: block; width: 100%; box-sizing: border-box; text-align: left;
          padding: 6px 12px 6px 26px; font-size: 11px; font-family: inherit;
          cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          background: none; border: none; color: inherit;
        }
        .sub-item:hover {
          background: light-dark(rgba(15, 23, 42, 0.05), rgba(255, 255, 255, 0.06));
          color: light-dark(#4c5be0, #a5adfa);
        }
        .sub-item.parsing { color: light-dark(#64748b, #98a1b3); cursor: default; }
        .sub-item.parsing:hover { background: transparent; color: light-dark(#64748b, #98a1b3); }
        .failure { color: light-dark(#d33c41, #f0868a); margin-top: 6px; word-break: break-word; }
        /* Keyboard focus ring: visible on light, dark and busy page
           backgrounds (inner outline + tinted fill). */
        .item:focus-visible, .sub-item:focus-visible, .close:focus-visible, .authorize:focus-visible {
          outline: 2px solid light-dark(#4c5be0, #a5adfa);
          outline-offset: -2px;
          background: light-dark(rgba(76, 91, 224, 0.12), rgba(165, 173, 250, 0.16));
        }
        .item:focus-visible:hover { background: light-dark(rgba(76, 91, 224, 0.16), rgba(165, 173, 250, 0.2)); }
        /* Visually hidden live region for screen-reader status changes
           (parsing / parse failed / submitted / communication failed);
           never shown visually. */
        .sr-status {
          position: absolute; width: 1px; height: 1px; margin: -1px;
          padding: 0; border: 0; overflow: hidden;
          clip: rect(0 0 0 0); clip-path: inset(50%); white-space: nowrap;
        }
      </style>
      <div class="wrap">
        <button class="fab" type="button" data-macidm-fab aria-expanded="false">
          <svg viewBox="0 0 24 24"><path d="M11 3h2v9.17l3.59-3.58L18 10l-6 6-6-6 1.41-1.41L11 12.17V3zm-7 15h16v2H4v-2z"/></svg>
        </button>
        <div class="sr-status" role="status" aria-live="polite" data-macidm-status></div>
      </div>`;
    const button = shadow.querySelector(".fab");
    button.title = t("overlay.fabTitle");
    button.setAttribute("aria-label", t("overlay.fabTitle"));
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      event.preventDefault();
      togglePanel(element, shadow, button);
    }, true);
    document.documentElement.appendChild(host);
    attachments.set(element, { host, shadow, button });
  }

  function detach(element) {
    const attachment = attachments.get(element);
    if (!attachment) return;
    attachment.host.remove();
    attachments.delete(element);
    if (openPanelFor === element) {
      openPanelFor = null;
      // When the host is removed the thumb is destroyed along with the
      // shadow; clear the handle to avoid a dangling reference.
      detachPanelScrollbar();
    }
  }

  function repositionAll() {
    for (const [element, attachment] of attachments) {
      if (!element.isConnected || candidates.length === 0) {
        detach(element);
        continue;
      }
      // Anchor to the media element itself, or to its visible player
      // container while a cover hides the element (findAnchorElement).
      // A missing anchor only hides the host instead of detaching it:
      // scroll events do not re-run syncAttachments, so detaching here
      // would leave the fab gone forever after scrolling the video back
      // into view.
      const anchor = findAnchorElement(element);
      if (!anchor) {
        attachment.host.style.display = "none";
        continue;
      }
      const rect = anchor.getBoundingClientRect();
      const scrollX = global.scrollX || document.documentElement.scrollLeft;
      const scrollY = global.scrollY || document.documentElement.scrollTop;
      attachment.host.style.left = `${rect.left + scrollX + rect.width}px`;
      // Prefer above the element; fall back to inside top-right when there
      // is not enough room above (e.g. video flush with the iframe top).
      if (rect.top >= 32) {
        attachment.host.style.top = `${rect.top + scrollY - 32}px`;
      } else {
        attachment.host.style.top = `${rect.top + scrollY + 6}px`;
      }
      const visible =
        rect.bottom > 0 && rect.top < global.innerHeight && rect.width >= MIN_ELEMENT_WIDTH;
      attachment.host.style.display = visible ? "" : "none";
    }
  }

  // ---- keyboard & live-region helpers ----

  // Enter/Space activation: real-button keyboard semantics for div rows.
  function isActivationKey(event) {
    return event.key === "Enter" || event.key === " " || event.key === "Spacebar";
  }

  function addRowActivation(row, handler) {
    row.addEventListener("click", handler);
    row.addEventListener("keydown", (event) => {
      if (!isActivationKey(event)) return;
      event.preventDefault();
      event.stopPropagation();
      handler(event);
    });
  }

  // Status announcements: written to the persistent role="status" region
  // inside the shadow (panel rebuilds do not destroy it); announce single
  // status changes only, never re-announce the whole candidate list.
  function announce(itemEl, message) {
    const region = itemEl?.getRootNode?.()?.querySelector?.(".sr-status");
    if (region) region.textContent = message;
  }

  function announceToOpenPanels(message) {
    for (const [, attachment] of attachments) {
      if (!attachment.shadow.querySelector(".panel")) continue;
      const region = attachment.shadow.querySelector(".sr-status");
      if (region) region.textContent = message;
    }
  }

  // ---- element scope (scoped model) ----

  // The anchor media element's own resource URLs: src/currentSrc, the
  // poster cover and child <source> elements (fragment stripped;
  // blob:/mse: placeholders kept as-is). The poster is an element
  // attribute and 100% attributable — image-host domains cannot
  // distinguish covers from recommended thumbnails, but the attribute can.
  function elementOwnURLs(element) {
    const urls = new Set();
    const add = (raw) => {
      if (!raw) return;
      const str = String(raw);
      if (/^(?:blob:|mse:)/iu.test(str)) {
        urls.add(str);
        return;
      }
      try {
        const url = new URL(str, global.location?.href);
        if (url.protocol === "http:" || url.protocol === "https:") {
          url.hash = "";
          urls.add(url.href);
        }
      } catch {}
    };
    try {
      add(element.currentSrc || element.getAttribute("src"));
      add(element.getAttribute("poster"));
      for (const source of element.querySelectorAll("source")) {
        add(source.getAttribute("src"));
      }
    } catch {}
    return urls;
  }

  // The overlay only shows candidates within the anchor element's scope
  // (rules in media-utils.filterCandidatesForElementScope); page-level
  // resources belong to the whole-page scope and are shown by the Popup.
  function scopeCandidatesForElement(element, list) {
    const filter = globalThis.MacIDMMediaUtils?.filterCandidatesForElementScope;
    if (typeof filter !== "function") return list;
    return filter(list, elementOwnURLs(element));
  }

  // ---- panel ----

  // Translucent overlay scrollbar: appears while scrolling and auto-hides
  // after it stops (same implementation as the Popup). attach must be
  // called after the panel enters the shadow DOM — see the
  // slimScrollbarDetach comment; detach the old attachment first so
  // refreshOpenPanel does not leave a stale thumb behind after replacing
  // the panel.
  function attachPanelScrollbar(panel) {
    detachPanelScrollbar();
    slimScrollbarDetach = globalThis.MacIDMSlimScrollbar?.attach?.(panel) ?? null;
  }

  function detachPanelScrollbar() {
    slimScrollbarDetach?.();
    slimScrollbarDetach = null;
  }

  function togglePanel(element, shadow, button) {
    const existing = shadow.querySelector(".panel");
    if (existing) {
      // The thumb is mounted on .wrap and does not disappear with
      // panel.remove(); detach it first.
      detachPanelScrollbar();
      existing.remove();
      button.classList.remove("open");
      button.setAttribute("aria-expanded", "false");
      openPanelFor = null;
      openPanelSignature = "";
      openSubFor = null;
      return;
    }
    closeAllPanels();
    const panel = buildPanel(element, shadow, button);
    // Narrow anchors: cap the adaptive panel width at the anchor width
    // minus the side gutters so it never spills past the player edge.
    const anchor = findAnchorElement(element);
    if (anchor) {
      const anchorWidth = Math.floor(anchor.getBoundingClientRect().width);
      if (anchorWidth - 16 < 500) {
        panel.style.maxWidth = `${anchorWidth - 16}px`;
      }
    }
    shadow.querySelector(".wrap").append(panel);
    // Only after entering the DOM is there a parent node to mount the
    // thumb on (see attachPanelScrollbar).
    attachPanelScrollbar(panel);
    button.classList.add("open");
    button.setAttribute("aria-expanded", "true");
    openPanelFor = element;
    openPanelSignature = panelSignature();
  }

  function closeAllPanels() {
    detachPanelScrollbar();
    for (const [, attachment] of attachments) {
      attachment.shadow.querySelector(".panel")?.remove();
      attachment.button.classList.remove("open");
      attachment.button.setAttribute("aria-expanded", "false");
    }
    openPanelFor = null;
    openPanelSignature = "";
    openSubFor = null;
  }

  // Compact identity of the current candidate list; used to rebuild an
  // already-open panel when new data arrives (late size probes, SPA
  // navigation) instead of freezing the first snapshot forever.
  function panelSignature() {
    return JSON.stringify([
      pageTitle,
      // The element's own resources (currentSrc/poster may change with
      // playback/stream switches) take part in the signature: when
      // candidates are unchanged but ownURLs differ the panel must still
      // refresh, or the scope-filtered results go stale.
      openPanelFor ? [...elementOwnURLs(openPanelFor)].sort() : [],
      candidates.map((candidate) => [
        candidate.url,
        candidate.size ?? null,
        candidate.supported !== false,
        candidate.displayName ?? "",
        Array.isArray(candidate.variants) ? candidate.variants.length : 0,
        inspectionFailures.get(candidateKey(candidate)) ?? "",
        youTubeInspections.get(candidateKey(candidate))?.stage ?? "",
        youTubeInspections.get(candidateKey(candidate))?.variantCount ?? 0,
      ]),
      filteredSummary,
    ]);
  }

  function refreshOpenPanel(force = false) {
    if (!openPanelFor) return;
    const attachment = attachments.get(openPanelFor);
    const old = attachment?.shadow.querySelector(".panel");
    if (!attachment || !old) {
      openPanelFor = null;
      openPanelSignature = "";
      openSubFor = null;
      return;
    }
    const signature = panelSignature();
    if (!force && signature === openPanelSignature) return;
    openPanelSignature = signature;
    // Preserve scroll position: when expanding/collapsing a submenu
    // triggers a full panel rebuild, the user's scroll position must not
    // reset to the top. Note: setting scrollTop on a detached element has
    // no effect; assign it after insertion.
    const preservedScrollTop = old.scrollTop;
    // The old thumb is a sibling of the old panel inside .wrap;
    // replaceWith does not carry it away.
    detachPanelScrollbar();
    const replacement = buildPanel(openPanelFor, attachment.shadow, attachment.button);
    // Preserve the narrow-anchor width cap computed when the panel opened.
    replacement.style.maxWidth = old.style.maxWidth;
    old.replaceWith(replacement);
    // When content shrinks (collapsing a submenu), clamp to the new
    // maximum scrollable value; skip clamping before layout.
    const maxScroll = replacement.scrollHeight - replacement.clientHeight;
    replacement.scrollTop =
      replacement.scrollHeight > 0 ? Math.min(preservedScrollTop, Math.max(0, maxScroll)) : preservedScrollTop;
    // Attach the scrollbar after the panel enters the DOM and after the
    // scrollTop restore, so the scroll event fired by the programmatic
    // assignment does not flash the thumb.
    attachPanelScrollbar(replacement);
  }

  function buildPanel(element, shadow, button) {
    const panel = document.createElement("div");
    panel.className = "panel";
    panel.setAttribute("data-macidm-panel", "");
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", t("overlay.panelTitle"));
    // Scoped model: this panel only shows candidates within the anchor
    // element's scope (the element's own resources + video/audio candidates
    // attributable to the player); page-level images etc. belong to the
    // whole-page scope and are only shown in the Popup.
    const scoped = scopeCandidatesForElement(element, candidates)
      .filter((candidate) => candidate.supported !== false);
    const supported = globalThis.MacIDMMediaUtils?.sortCandidatesForDisplay
      ? globalThis.MacIDMMediaUtils.sortCandidatesForDisplay(scoped)
      : scoped;
    panel.setAttribute("data-macidm-panel-count", String(supported.length));
    const header = document.createElement("header");
    // Left side: the title and count merge into one "downloadable content
    // (N)" label, the count sitting right next to the title inside the
    // parentheses.
    const titleGroup = document.createElement("span");
    titleGroup.className = "header-titlegroup";
    titleGroup.setAttribute(
      "aria-label",
      t("overlay.panelTitleCount", { count: supported.length }),
    );
    const titleText = document.createElement("span");
    titleText.className = "header-title";
    titleText.textContent = t("overlay.panelTitle");
    const count = document.createElement("span");
    count.className = "header-count";
    count.setAttribute("aria-hidden", "true");
    count.textContent = `(${supported.length})`;
    titleGroup.append(titleText, count);
    // Right side: authorize entry (when unauthorized) or granted hint
    // (when authorized) + persistent refresh + close button.
    const actions = document.createElement("div");
    actions.className = "header-actions";
    if (!cookieGranted) {
      const authorize = document.createElement("button");
      authorize.className = "authorize";
      authorize.type = "button";
      authorize.textContent = t("overlay.authorizeCookies");
      authorize.title = t("overlay.authorizeCookiesTitle");
      authorize.addEventListener("click", (event) => {
        event.stopPropagation();
        // A content script can neither pop the permission dialog nor open
        // the popup directly: hand it to the SW to first try
        // chrome.action.openPopup() (the popup has a one-click authorize
        // entry), falling back to the small authorize window on failure.
        sendRuntimeMessage({ type: "overlay.openPopup" });
      });
      actions.append(authorize);
    } else {
      // Granted hint: user feedback said the overlay gave no hint of the
      // authorization state. A persistent silent text, not an action entry.
      const grantedHint = document.createElement("span");
      grantedHint.className = "cookie-granted";
      grantedHint.textContent = t("overlay.cookieAuthorizedHint");
      grantedHint.title = t("overlay.cookieAuthorizedHintTitle");
      actions.append(grantedHint);
    }
    const close = document.createElement("button");
    close.className = "close";
    close.type = "button";
    close.textContent = "✕";
    close.setAttribute("aria-label", t("overlay.closeAria"));
    close.addEventListener("click", () => {
      togglePanel(element, shadow, button);
      // Return focus to the FAB after closing so focus is not lost to body.
      button.focus?.();
    });
    actions.append(close);
    header.append(titleGroup, actions);
    panel.append(header);
    // Escape closes the panel and returns to the FAB; keyboard users do
    // not need to Tab to the close button.
    panel.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      togglePanel(element, shadow, button);
      button.focus?.();
    });

    if (supported.length === 0) {
      const empty = document.createElement("div");
      empty.className = "item static";
      empty.textContent = t("overlay.listening");
      panel.append(empty);
      appendFilteredNote(panel);
      return panel;
    }

    for (const candidate of supported.slice(0, 20)) {
      panel.append(buildItem(candidate));
    }
    appendFilteredNote(panel);
    // The overlay scrollbar is not mounted here: at this point the panel
    // is not yet inserted into the shadow DOM, so attach must be performed
    // by the caller (togglePanel / refreshOpenPanel) after insertion.
    return panel;
  }

  // "Filtered N suspected noise candidates": explainable feedback for
  // false-positive suppression, containing only redacted counts
  // (diagnosticAudio + streamSegments + smallResources) and no URLs.
  function appendFilteredNote(panel) {
    const filteredTotal = filteredSummary.diagnosticAudio + filteredSummary.streamSegments + filteredSummary.smallResources;
    if (filteredTotal <= 0) return;
    const note = document.createElement("div");
    note.className = "item static filtered-note";
    note.setAttribute("data-macidm-filtered-note", "");
    note.textContent = t("common.filteredNoise", { count: filteredTotal });
    panel.append(note);
  }

  function buildItem(candidate) {
    const item = document.createElement("div");
    item.className = "item";
    item.setAttribute("data-macidm-item", "");
    item.setAttribute("data-macidm-item-url", candidate.url || "");
    item.setAttribute("data-macidm-item-format", candidate.format || "");
    item.setAttribute("data-macidm-item-site", candidate.siteAdapter || "");
    item.setAttribute("data-macidm-item-status", "idle");

    // Cached inspection results are attached before any slot reads the
    // candidate: each page re-report brings a fresh object without variants, so
    // estimating afterwards made the main row alternate between an estimate and
    // nothing at all.
    const stateKey = candidateKey(candidate);
    const cachedVariants = inspectedVariants.get(stateKey);
    if (Array.isArray(cachedVariants) && cachedVariants.length > 0) {
      candidate.variants = cachedVariants;
    }
    const ytSnapshot = candidate.siteAdapter === "youtube"
      ? youTubeInspections.get(stateKey)
      : null;
    // Sync snapshot-carried variants onto the candidate for reuse by the
    // main-row estimate and the submission.
    if (Array.isArray(ytSnapshot?.variants) && ytSnapshot.variants.length > 0) {
      candidate.variants = ytSnapshot.variants;
      inspectedVariants.set(stateKey, ytSnapshot.variants);
    }

    // Inspection state computed up front: the main row's meta spinner and
    // data-macidm-item-status share the same verdict so the two cannot
    // drift apart.
    const isManifest = candidate.format === "hls" || candidate.format === "dash";
    const isYouTube = candidate.siteAdapter === "youtube";
    const needsInspection = candidate.siteAdapter === "bilibili" || isYouTube || isManifest;
    const failureMessage = inspectionFailures.get(stateKey);
    const ytInFlight = !!ytSnapshot
      && !["complete", "partial", "failed", "unsupported"].includes(ytSnapshot.stage);
    const inspectionInFlight = needsInspection
      && !failureMessage
      && (inspectingUrls.has(stateKey) || ytInFlight);

    const name = document.createElement("div");
    name.className = "name";
    name.setAttribute("data-macidm-item-name", "");
    const fullName = smartName(candidate);
    name.textContent = fullName;
    // Single-line ellipsis: the tooltip carries the full title plus the URL
    // (the dedicated source-link row was removed in v4).
    name.title = fullName + (candidate.displayURL ? `\n${candidate.displayURL}` : "");
    const meta = document.createElement("div");
    meta.className = "meta";
    // The "format · quality · size · duration" slots only show items that
    // have values: when metadata is missing no "unknown" placeholder is
    // shown, avoiding whole-row noise.
    const metaSlots = [formatLabel(candidate)];
    if (candidate.qualityLabel) metaSlots.push(candidate.qualityLabel);
    const sizeSlot = formatSize(candidate);
    if (![t("common.unknown"), t("common.sizeUnknown"), t("common.probing"), t("common.parsing")].includes(sizeSlot)) {
      metaSlots.push(sizeSlot);
    }
    const durationSlot = formatDuration(candidate.duration);
    if (durationSlot) metaSlots.push(durationSlot);
    // YouTube shared-inspection stage (§5.2): the collapsed main row shows
    // the stage text directly.
    if (ytSnapshot) {
      const stageText = youTubeStageText(ytSnapshot);
      if (stageText) metaSlots.push(stageText);
    }
    // The leading category icon matches the App's seven categories
    // (video/document/archive/...).
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
    // spec: ~XX MB".
    if (inspectionInFlight) {
      const spinner = document.createElement("span");
      spinner.className = "meta-spinner";
      spinner.setAttribute("aria-hidden", "true");
      spinner.title = t("common.parsing");
      meta.append(spinner);
    }
    item.append(name, meta);

    // Unified drawer interaction (identical across sites): every actionable
    // candidate row expands on click — the expanded view shows the full
    // title; sub-download items are listed when present, and otherwise at
    // least a "download now" sub-item is offered. Failed-inspection rows
    // expand too: the drawer shows the failure reason and keeps the
    // download entry.
    const isOpen = openSubFor === stateKey;
    item.classList.add("has-sub");
    if (isOpen) item.classList.add("open");
    item.setAttribute("role", "button");
    item.setAttribute("tabindex", "0");
    item.setAttribute("aria-expanded", String(isOpen));
    const submenuId = `macidm-submenu-${nextSubmenuId()}`;
    item.setAttribute("aria-controls", submenuId);
    const chevron = document.createElement("span");
    chevron.className = "chevron";
    chevron.setAttribute("aria-hidden", "true");
    chevron.textContent = "›";
    item.append(chevron);
    addRowActivation(item, () => {
      openSubFor = isOpen ? null : stateKey;
      refreshOpenPanel(true);
    });

    if (needsInspection && failureMessage && !isYouTube) {
      item.setAttribute("data-macidm-item-status", "failed");
    } else if (needsInspection) {
      item.setAttribute("data-macidm-item-status", inspectionInFlight ? "inspecting" : "ready");
      // Auto-inspect once per page so opening the submenu reveals parsed
      // qualities without any extra click; the outcome is cached.
      if (!Array.isArray(candidate.variants) && !autoInspectedUrls.has(stateKey)) {
        autoInspectedUrls.add(stateKey);
        // Honor the page-epoch invariant: a real navigation within the 200ms
        // window invalidates the scheduled inspection along with the page's
        // other in-flight async results.
        const scheduledEpoch = pageEpoch;
        setTimeout(() => {
          if (scheduledEpoch === pageEpoch) inspectVariants(candidate);
        }, 200);
      }
    }

    const nodes = [item];
    if (isOpen) nodes.push(buildSubmenu(candidate, item, submenuId, failureMessage));
    const wrapper = document.createDocumentFragment();
    wrapper.append(...nodes);
    return wrapper;
  }

  /// A single "download now" sub-item: candidates with no quality choice
  /// (direct links, failed inspections, single-quality streams) all submit
  /// to the App confirmation window through it.
  function buildDownloadNowItem(candidate, itemEl) {
    const direct = document.createElement("button");
    direct.type = "button";
    direct.className = "sub-item";
    direct.setAttribute("data-macidm-btn-direct", "");
    direct.textContent = t("overlay.downloadNow");
    direct.addEventListener("click", (event) => {
      event.stopPropagation();
      submitDownload(candidate, null, itemEl);
    });
    return direct;
  }

  function buildSubmenu(candidate, itemEl, submenuId, failureMessage) {
    const submenu = document.createElement("div");
    submenu.className = "submenu";
    submenu.setAttribute("data-macidm-submenu", "");
    // Group semantics + aria-controls pairing so screen readers understand
    // the accordion parent row expands into this list.
    submenu.setAttribute("role", "group");
    submenu.setAttribute("aria-label", t("overlay.qualitiesGroup"));
    if (submenuId) submenu.id = submenuId;
    // YouTube goes through the shared coordinator snapshot: partial
    // results keep growing in place; failures keep existing qualities plus
    // a retry.
    if (candidate.siteAdapter === "youtube") {
      return renderYouTubeSubmenu(candidate, submenu, itemEl);
    }
    // Failed inspections no longer render blunt error copy (when
    // unauthorized the header already has the authorize entry; when logged
    // out it is handed to the Popup's site-session flow): the drawer simply
    // keeps the "download now" item.
    if (failureMessage) {
      submenu.append(buildDownloadNowItem(candidate, itemEl));
      return submenu;
    }
    // Branch for no variants: candidates needing parsing (HLS/DASH/
    // Bilibili) show "Parsing…"; candidates without a parsing step (direct
    // links/images etc.) at least offer the "download now" sub-item.
    if (!Array.isArray(candidate.variants) || candidate.variants.length === 0) {
      const needsParse = candidate.siteAdapter === "bilibili"
        || candidate.format === "hls"
        || candidate.format === "dash";
      if (needsParse) {
        const parsing = document.createElement("div");
        parsing.className = "sub-item parsing";
        parsing.setAttribute("role", "status");
        parsing.textContent = t("common.parsing");
        submenu.append(parsing);
        return submenu;
      }
      submenu.append(buildDownloadNowItem(candidate, itemEl));
      return submenu;
    }
    const labeledVariants = candidate.variants
      .slice(0, 12)
      .map((variant) => ({ variant, label: overlayVariantLabel(variant) }))
      .filter((entry) => entry.label);
    if (labeledVariants.length === 0) {
      // Parsed but qualities indistinguishable: unify on the "download
      // now" sub-item.
      submenu.append(buildDownloadNowItem(candidate, itemEl));
      return submenu;
    }
    for (const { variant, label } of labeledVariants) {
      // Real <button>: native Enter/Space activation and focus semantics.
      const option = document.createElement("button");
      option.type = "button";
      option.className = "sub-item";
      option.setAttribute("data-macidm-btn-variant", "");
      option.setAttribute("data-macidm-variant-label", label);
      option.textContent = label;
      option.title = overlayVariantTooltip(variant);
      option.addEventListener("click", async (event) => {
        event.stopPropagation();
        const ok = await submitDownload(candidate, variant, itemEl);
        if (ok) {
          openSubFor = null;
          refreshOpenPanel(true);
        }
      });
      submenu.append(option);
    }
    return submenu;
  }

  function renderVariants(candidate, variants) {
    candidate.variants = variants;
    // Persist the parsed outcome: candidate objects are rebuilt on every
    // syncCandidates call, and closing the panel destroys the rendered
    // DOM — the cache is the only place the result survives both.
    const stateKey = candidateKey(candidate);
    inspectedVariants.set(stateKey, variants);
    inspectionFailures.delete(stateKey);
  }

  // Client-side budget for one quality-parse round trip: a wedged yt-dlp
  // on the App side (e.g. a dead system proxy) can otherwise keep the
  // submenu on "Parsing…" forever.
  const INSPECT_TIMEOUT_MS = 60_000;

  function inspectWithTimeout(message) {
    return Promise.race([
      sendRuntimeMessage(message),
      new Promise((resolve) => {
        setTimeout(() => resolve({ ok: false, timedOut: true }), INSPECT_TIMEOUT_MS);
      }),
    ]);
  }

  async function inspectVariants(candidate) {
    if (candidate.siteAdapter === "youtube") {
      // YouTube shared coordinator (§5.1): the overlay and Popup trigger a
      // single inspection; stages and variants arrive via the snapshot
      // stream and the expanded submenu updates in place.
      try {
        const result = await sendRuntimeMessage({
          type: "youtube.ensureInspection",
          tabId: cachedTabID ?? undefined,
          url: candidate.url,
        });
        if (result?.ok && result.snapshot) applyYouTubeSnapshot(result.snapshot);
      } catch {
        // Coordinator unreachable: keep the candidate row and do not fake
        // a network error.
      }
      return;
    }
    if (inspectingUrls.has(candidateKey(candidate))) return;
    inspectingUrls.add(candidateKey(candidate));
    // Refresh the panel as soon as inspection starts: the main row's meta
    // spinner is visible without expanding the drawer; an already-expanded
    // submenu shows "Parsing…" in sync. The finally block refreshes
    // everything to the result.
    refreshOpenPanel(true);
    announceToOpenPanels(t("overlay.statusParsing"));

    // YouTube: page-first — read the current page's player response,
    // completing instantly without going through App/yt-dlp; fall back to
    // the App inspection when page data is missing or the video ID does
    // not match. Shares the same resolution flow in youtube-format-utils.js
    // with the Popup, keeping both quality lists identical (AI handover
    // doc §5.1).
    const isYouTube = candidate.siteAdapter === "youtube";
    try {
      const result = await globalThis.MacIDMYouTubeFormats.resolveYouTubeQualities({
        pageUrl: candidate.url,
        requestPageQualities: isYouTube
          ? () => globalThis.MacIDMYouTubeFormats.extractPageQualities(candidate.url)
          : null,
        requestAppInspection: () => inspectWithTimeout({
          type: "media.inspect",
          tabId: cachedTabID || undefined,
          url: candidate.url,
          mediaKind: candidate.siteAdapter === "bilibili"
            ? "dash"
            : isYouTube
              ? "youtube"
              : candidate.format,
        }),
      });
      if (result?.ok && Array.isArray(result.variants) && result.variants.length > 0) {
        renderVariants(candidate, result.variants);
      } else if (result?.timedOut) {
        inspectionFailures.set(candidateKey(candidate), t("overlay.inspectTimeout"));
        announceToOpenPanels(t("overlay.inspectTimeout"));
      } else {
        // The row renders the red short text; clicking it degrades to a
        // direct download of the current resource.
        const message = friendlyInspectFailure(result?.message, candidate);
        inspectionFailures.set(candidateKey(candidate), message);
        announceToOpenPanels(message);
      }
    } catch {
      const message = t("overlay.parseFailedDirect");
      inspectionFailures.set(candidateKey(candidate), message);
      announceToOpenPanels(message);
    } finally {
      inspectingUrls.delete(candidateKey(candidate));
      refreshOpenPanel(true);
    }
  }

  function friendlyInspectFailure(message, candidate) {
    // The generic takeover-rejection message is misleading for inspection.
    // Replace it with site-specific guidance so the user knows what to do.
    const isGenericRejection =
      !message ||
      message.includes(t("protocol.error.appRejected")) ||
      message.includes(t("protocol.takeoverFailedPrefix"));
    if (!isGenericRejection) return message || t("overlay.noQualityOptions");
    if (candidate?.siteAdapter === "bilibili") {
      return t("common.inspectErrorBilibili");
    }
    if (candidate?.siteAdapter === "youtube") {
      return t("common.inspectErrorYouTube");
    }
    return t("common.inspectErrorGeneric");
  }

  /// Stage → main-row copy (same mapping as the Popup): appears
  /// dynamically only for in-progress stages; after completion it shows no
  /// "done" marker and no "N qualities" count — the main-row experience
  /// stays consistent across sites.
  function youTubeStageText(snapshot) {
    return globalThis.MacIDMMediaPresentation.youTubeStageText(snapshot, t);
  }

  /// Coordinator snapshot landing: survives candidate rebuilds; an open
  /// panel refreshes in place. Keys use the unified identity (§2): when
  /// only the same video's parameters change, the current candidate can
  /// still consume the existing snapshot.
  function applyYouTubeSnapshot(snapshot) {
    if (!snapshot?.pageUrl) return;
    const key = snapshotKey(snapshot);
    youTubeInspections.set(key, snapshot);
    if (Array.isArray(snapshot.variants) && snapshot.variants.length > 0) {
      inspectedVariants.set(key, snapshot.variants);
      inspectionFailures.delete(key);
    }
    inspectingUrls.delete(key);
    if (snapshot.stage === "partial") {
      announceToOpenPanels(t("youtube.stagePartial"));
    } else if (snapshot.stage === "failed") {
      announceToOpenPanels(t("youtube.stageFailed"));
    }
    refreshOpenPanel(true);
  }

  /// YouTube submenu: partial results keep growing in place; failure/
  /// partial completion keeps existing qualities and appends a retry.
  function renderYouTubeSubmenu(candidate, submenu, itemEl) {
    const snapshot = youTubeInspections.get(candidateKey(candidate));
    const variants = Array.isArray(snapshot?.variants) ? snapshot.variants : [];
    const labeledVariants = variants
      .slice(0, 12)
      .map((variant) => ({ variant, label: overlayVariantLabel(variant) }))
      .filter((entry) => entry.label);
    const stage = snapshot?.stage ?? "discovered";

    if (stage === "unsupported") {
      const note = document.createElement("div");
      note.className = "sub-item parsing";
      note.setAttribute("role", "status");
      note.textContent = t("youtube.stageUnsupported");
      submenu.append(note);
      return submenu;
    }
    for (const { variant, label } of labeledVariants) {
      const option = document.createElement("button");
      option.type = "button";
      option.className = "sub-item";
      option.setAttribute("data-macidm-btn-variant", "");
      option.setAttribute("data-macidm-variant-label", label);
      option.textContent = label;
      option.title = overlayVariantTooltip(variant);
      option.addEventListener("click", async (event) => {
        event.stopPropagation();
        const ok = await submitDownload(candidate, variant, itemEl);
        if (ok) {
          openSubFor = null;
          refreshOpenPanel(true);
        }
      });
      submenu.append(option);
    }
    if (labeledVariants.length === 0) {
      if (stage === "complete") {
        // Complete but indistinguishable: unify on the "download now"
        // sub-item.
        submenu.append(buildDownloadNowItem(candidate, itemEl));
        return submenu;
      }
      const parsing = document.createElement("div");
      parsing.className = "sub-item parsing";
      parsing.setAttribute("role", "status");
      parsing.textContent = stage === "partial" || stage === "failed"
        ? (stage === "failed"
          ? t("youtube.stageFailed")
          : t("youtube.stagePartial"))
        : (youTubeStageText(snapshot) ?? t("common.parsing"));
      submenu.append(parsing);
    } else if (stage === "partial" || stage === "failed") {
      const note = document.createElement("div");
      note.className = "sub-item parsing";
      note.setAttribute("role", "status");
      note.textContent = stage === "failed"
        ? t("youtube.stageFailed")
        : t("youtube.stagePartial");
      submenu.append(note);
    }
    if ((stage === "partial" || stage === "failed") && snapshot?.retryable) {
      // Failure/partial completion keeps existing qualities; with no
      // qualities the "download now" entry is still kept.
      if (labeledVariants.length === 0) {
        submenu.append(buildDownloadNowItem(candidate, itemEl));
      }
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "sub-item";
      retry.setAttribute("data-macidm-btn-retry", "");
      retry.textContent = t("youtube.retry");
      retry.addEventListener("click", async (event) => {
        event.stopPropagation();
        const result = await sendRuntimeMessage({
          type: "youtube.retryInspection",
          tabId: cachedTabID ?? undefined,
          url: candidate.url,
        });
        if (result?.ok && result.snapshot) applyYouTubeSnapshot(result.snapshot);
      });
      submenu.append(retry);
    }
    return submenu;
  }

  function estimatedSizeForVariant(variant) {
    if (!variant) return null;
    const directSize = Number.isSafeInteger(variant.estimatedSize) && variant.estimatedSize >= 0
      ? variant.estimatedSize
      : null;
    const estimateFn = globalThis.MacIDMMediaUtils?.estimateVariantSize;
    const estimatedSize = directSize ?? (estimateFn ? estimateFn(variant) : null);
    return Number.isSafeInteger(estimatedSize) && estimatedSize >= 0 ? estimatedSize : null;
  }

  function overlayVariantBaseLabel(variant) {
    if (!variant) return "";
    const label = String(variant.label ?? "").trim();
    if (label && label !== "自动" && label !== t("popup.defaultQuality")) return label;
    const built = globalThis.MacIDMMediaUtils?.variantDisplayLabel?.(variant) ?? "";
    if (built) return built;
    if (variant.url) {
      try {
        const u = new URL(variant.url);
        const w = u.searchParams.get("w") || u.searchParams.get("width");
        const h = u.searchParams.get("h") || u.searchParams.get("height");
        if (w && h) return `${w}×${h}`;
        if (h && /^\d{2,5}$/u.test(h)) return `${h}p`;
      } catch { /* ignore */ }
    }
    return "";
  }

  function overlayVariantLabel(variant) {
    const baseLabel = overlayVariantBaseLabel(variant);
    const estimatedSize = estimatedSizeForVariant(variant);
    const sizeText = estimatedSize == null
      ? null
      : t("common.approxSize", { size: formatBytes(estimatedSize) ?? t("common.unknown") });
    return [baseLabel, sizeText].filter(Boolean).join(" · ");
  }

  function overlayVariantTooltip(variant) {
    if (!variant) return "";
    const parts = [];
    // Slotted: missing items show "unknown", consistent with the Popup's
    // variantTooltip.
    if (variant.width && variant.height) {
      parts.push(t("common.tooltipResolution", { value: `${variant.width}×${variant.height}` }));
    } else if (variant.height) {
      parts.push(t("common.tooltipResolution", { value: `${variant.height}p` }));
    } else {
      parts.push(t("common.tooltipResolutionUnknown"));
    }
    if (variant.fps > 0) parts.push(t("common.tooltipFps", { value: Math.round(variant.fps) }));
    if (variant.bandwidth > 0) {
      parts.push(t("common.tooltipBitrate", { value: (variant.bandwidth / 1_000_000).toFixed(2) }));
    } else {
      parts.push(t("common.tooltipBitrateUnknown"));
    }
    const codecSlot = globalThis.MacIDMMediaUtils?.codecFamily?.(variant.codecs) ?? "";
    if (codecSlot) {
      parts.push(t("common.tooltipCodec", { value: codecSlot }));
    } else {
      parts.push(t("common.tooltipCodecUnknown"));
    }
    const directSize = Number.isSafeInteger(variant.estimatedSize) ? variant.estimatedSize : null;
    const estimateFn = globalThis.MacIDMMediaUtils?.estimateVariantSize;
    const estimatedSize = directSize ?? (estimateFn ? estimateFn(variant) : null);
    parts.push(estimatedSize != null
      ? t("common.tooltipEstimatedSize", { size: formatBytes(estimatedSize) ?? t("common.unknown") })
      : t("common.tooltipEstimatedSizeUnknown"));
    const durationText = formatDuration(variant.duration);
    parts.push(durationText
      ? t("common.tooltipDuration", { value: durationText })
      : t("common.tooltipDurationUnknown"));
    return parts.join("\n");
  }

  // Returns true when the App accepted the submission. Feedback is a
  // top-center toast (shared/panel-ui.js) — the row only grays out for the
  // duration of the round-trip and keeps no "submitted" style state.
  async function submitDownload(candidate, variant, itemEl) {
    if (!itemEl || itemEl.classList.contains("busy")) return false;
    itemEl.classList.add("busy");
    itemEl.setAttribute("data-macidm-item-status", "submitting");
    try {
      const result = await sendRuntimeMessage({
        type: "media.download",
        tabId: cachedTabID || undefined,
        url: variant?.url ?? candidate.url,
        mediaKind: candidate.siteAdapter === "bilibili"
          ? "dash"
          : candidate.siteAdapter === "youtube"
            ? "youtube"
            : candidate.format,
        mime: variant?.mime ?? candidate.mime,
        filenameHint: variant?.filenameHint ?? candidate.filenameHint,
        pageTitle: cleanedPageTitle(),
        pairVideoUrl: variant?.pairAudioUrl
          ? (variant?.pairVideoUrl ?? variant.url)
          : (variant?.pairVideoUrl ?? candidate.pairVideoUrl),
        pairAudioUrl: variant?.pairAudioUrl ?? candidate.pairAudioUrl,
        pairCid: variant?.pairCid ?? candidate.pairCid,
        pairNote: variant?.pairAudioUrl ? t("common.pairNoteMerge") : candidate.pairNote,
        duration: variant?.duration ?? candidate.duration,
        // A site-adapter candidate's (youtube/bilibili) candidate.size comes
        // from incidental response-header observation and may be only a few
        // KB; it must not be fed to the App as the estimated size. Variants
        // prefer their own reliable estimate; the candidate falls back to a
        // reliable size only for non-adapter sites.
        estimatedSize: variant
          ? estimatedSizeForVariant(variant)
          : (candidate.siteAdapter ? null : (Number.isSafeInteger(candidate.size) && candidate.size >= 0 ? candidate.size : null)),
      });
      if (result?.ok) {
        itemEl.setAttribute("data-macidm-item-status", "submitted");
        // No more visual "sent to MacIDM" toast: after a successful send
        // the App confirmation window pops up automatically, so duplicate
        // feedback carries no information. The screen-reader status stays.
        announce(itemEl, t("overlay.toastSent"));
        return true;
      }
      const failureMessage = result?.message || t("overlay.submitNotReceived");
      itemEl.setAttribute("data-macidm-item-status", "submit_failed");
      showPanelToast(itemEl, failureMessage, "error");
      announce(itemEl, failureMessage);
      return false;
    } catch {
      itemEl.setAttribute("data-macidm-item-status", "submit_failed");
      showPanelToast(itemEl, t("overlay.commFailed"), "error");
      announce(itemEl, t("overlay.commFailed"));
      return false;
    } finally {
      itemEl.classList.remove("busy");
    }
  }

  function showPanelToast(itemEl, message, kind) {
    const wrap = itemEl?.getRootNode?.()?.querySelector?.(".wrap");
    if (!wrap) return;
    // The .wrap is a 0×0 anchor around the FAB: a percentage max-width
    // resolves against it and collapses the toast to its padding alone (a
    // ~26px white speck with the message clipped away). Pin a pixel width so
    // the feedback stays readable.
    globalThis.MacIDMPanelUI?.showToast(wrap, message, { kind, maxWidth: "280px" });
  }

  // ---- naming / formatting ----

  function smartName(candidate) {
    // Use the shared utility to keep naming consistent between Popup and
    // Overlay. Falls back to the local implementation if the shared module
    // is not loaded (e.g. in a cross-origin iframe before injection).
    if (globalThis.MacIDMMediaUtils?.smartMediaName) {
      return globalThis.MacIDMMediaUtils.smartMediaName(candidate, cleanedPageTitle(), candidates.length);
    }
    const base = cleanedPageTitle();
    const hint = String(candidate.filenameHint ?? "").trim();
    if (base) {
      if (hint && hint.toLowerCase().startsWith(base.toLowerCase())) return hint;
      const generic = /^(index|master|playlist|media|video|audio|manifest)\b/i.test(hint);
      return generic || candidates.length <= 1 ? base : `${base} · ${hint}`;
    }
    return hint || candidate.displayName || t("common.mediaResource");
  }

  function cleanedPageTitle() {
    // In cross-origin iframes the local DOM has no useful title or meta tags;
    // prefer the tab title fetched from the background service worker.
    if (global !== global.top && cachedTabTitle) {
      return cachedTabTitle.replace(/\s+/g, " ").slice(0, 120);
    }
    // Use the shared intelligent resolver when available (picks the most
    // content-specific title from og:title / twitter:title / document.title).
    if (globalThis.MacIDMMediaUtils?.resolvePageTitle) {
      const resolved = globalThis.MacIDMMediaUtils.resolvePageTitle();
      if (resolved) return resolved.slice(0, 120);
    }
    const og =
      document.querySelector('meta[property="og:title"]')?.getAttribute("content") ||
      document.querySelector('meta[name="twitter:title"]')?.getAttribute("content") ||
      "";
    const raw = (og || pageTitle || cachedTabTitle || document.title || "").trim();
    return raw.replace(/\s+/g, " ").slice(0, 120);
  }

  function formatLabel(value) {
    const candidate = typeof value === "object" ? value : null;
    const extension = candidate ? candidate.fileExtension : value;
    if (candidate?.format === "hls") return t("common.formatHLS");
    if (candidate?.format === "dash") return t("common.formatDASH");
    // YouTube product contract (AI handover doc §4.4): the final output is
    // uniformly MP4; a source variant's container (e.g. VP9's webm) is not
    // the final output container.
    if (candidate?.siteAdapter === "youtube") return "MP4";
    if (typeof extension === "string" && extension.trim()) return extension.toUpperCase();
    return t("common.formatUnknown");
  }

  function formatSize(candidate) {
    // An m4s-pair candidate is not an ordinary direct link: it skips the
    // "probing…" branch (a HEAD probe will never yield its size); estimate
    // and prefix "~" when bandwidth/duration exist, otherwise show
    // "unknown".
    if (candidate.pairKind === "m4s-pair") {
      const estimateFn = globalThis.MacIDMMediaUtils?.estimateVariantSize;
      const pairSize = estimateFn ? estimateFn(candidate) : null;
      return pairSize != null
        ? t("common.approxSize", { size: formatBytes(pairSize) ?? t("common.unknown") })
        : t("common.unknown");
    }
    // Site adapters resolve the real size only after quality inspection;
    // they are never HTTP-probed, so "probing" would never settle.
    if (
      candidate.siteAdapter === "youtube" || candidate.siteAdapter === "bilibili"
      || candidate.format === "hls" || candidate.format === "dash"
    ) {
      const variantSize = estimateCandidateSize(candidate);
      if (variantSize != null) {
        return t("common.approxHighestSize", { size: formatBytes(variantSize) ?? t("common.unknown") });
      }
      return t("common.unknown");
    }
    if (Number.isSafeInteger(candidate.size)) return formatBytes(candidate.size) ?? t("common.unknown");
    // Terminal probe state: three HEAD/Range attempts failed (CDN refuses
    // anonymous probes). Show a settled value instead of "probing" forever.
    if (candidate.sizeProbeFailed === true) return t("common.sizeUnknown");
    // Background actively probes unknown sizes; refresh on next panel open.
    return t("common.probing");
  }

  function hasVariantInfo(variant) {
    if (!variant) return false;
    return overlayVariantBaseLabel(variant) !== "";
  }

  function estimateCandidateSize(candidate) {
    return globalThis.MacIDMMediaPresentation.estimateCandidateSize(
      candidate,
      youTubeInspections,
      hasVariantInfo,
    );
  }

  // Byte/duration formatting delegates to the single implementation in
  // media-utils.js (invalid input returns null).
  function formatBytes(value) {
    return globalThis.MacIDMMediaUtils?.formatBytes?.(value) ?? null;
  }

  function formatDuration(seconds) {
    return globalThis.MacIDMMediaUtils?.formatDuration?.(seconds) ?? null;
  }

  global.MacIDMOverlay = Object.freeze({ syncCandidates });
  install();
})(globalThis);
