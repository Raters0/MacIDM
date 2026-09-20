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
  // Hover-autoplay card bounds for the persistent-FAB heuristic: a stable
  // cover container in this size range whose transient <video> comes and goes
  // with pointer hover keeps its FAB pinned to the card after preview stops.
  const MIN_CARD_WIDTH = 200;
  const MAX_CARD_WIDTH = 700;
  const MIN_CARD_HEIGHT = 150;
  const MAX_CARD_HEIGHT = 500;
  // Cap with LRU eviction: when full, unpinning the oldest persistent FAB
  // (not refusing the new pin) keeps fresh hover previews reachable.
  const MAX_PERSISTENT = 12;
  // Empty-candidate grace: SPA episode switches and sniffing restarts
  // transiently publish zero candidates. Unmounting FABs immediately makes
  // them vanish until re-sniffing catches up (and miss permanently when the
  // reload is served from cache); a connected element survives the window,
  // only sustained emptiness unmounts it.
  const EMPTY_CANDIDATES_GRACE_MS = 10_000;

  // i18n core + locale catalogs load before this script (manifest order).
  // The indirection keeps the overlay functional even if the global is
  // missing, at the cost of showing raw keys.
  function t(key, params) {
    return globalThis.MacIDMI18n?.t(key, params) ?? key;
  }

  let pageTitle = "";
  let pageTitleSource = "document";
  let candidates = [];
  let rawCandidates = [];
  // Timestamp of the first sync that published an empty candidate list;
  // 0 means "currently non-empty" (or freshly navigated).
  let candidatesEmptySince = 0;
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
  // 当前打开的抖音详情弹窗 aweme_id：关闭时用它把 FAB 钉回对应小卡片。
  let lastDouyinModalID = "";
  // Page-session epoch (chrome-extension-spec §5.7/§5.8): incremented on a real page
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
  // Duration backfilled from inspected variants (Bilibili playurl, HLS
  // sub-playlist total). Candidate objects are rebuilt on every sync, so
  // this cache is what keeps the main-row duration slot filled across
  // snapshots; keyed like inspectedVariants.
  const inspectedDurations = new Map(); // candidate url -> seconds
  // In-flight inspections show "Parsing…" inside an expanded submenu.
  const inspectingUrls = new Set();
  // Candidate URL whose quality submenu is accordion-expanded (one at a
  // time); preserved across panel rebuilds triggered by fresh data.
  let openSubFor = null;
  // YouTube shared-inspection snapshots (chrome-extension-spec §5.8):
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

  // Unified YouTube page identity (chrome-extension-spec §5.8): the primary key for
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
    inspectedDurations.clear();
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

  /// The overlay's immediate defense against SPA navigation
  /// (chrome-extension-spec §5.8): the content script's transition snapshot has a 120 ms
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
    // 抖音详情弹窗关闭：弹窗播放器 FAB 随播放器卸载，而用户刚看完这条
    // 视频——小卡片 FAB 不应要求重新 hover。对含该 aweme_id 的卡片合成
    // 一次 hover，预览视频出现后走现有 attach→离开→persistent 链钉住。
    const incomingDouyinModal = douyinModalIDOf(currentURL);
    if (incomingDouyinModal) {
      lastDouyinModalID = incomingDouyinModal;
    } else if (lastDouyinModalID) {
      pinDouyinCardForClosedModal(lastDouyinModalID);
      lastDouyinModalID = "";
    }
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
      attributeFilter: ["style", "class", "id", "hidden", "width", "height", "src", "poster",
        "data-src", "data-video", "data-url", "data-hls", "data-dash", "data-mp4"],
    });
    global.addEventListener("loadedmetadata", scheduleSync, { capture: true });
    global.addEventListener("emptied", scheduleSync, { capture: true });
    global.addEventListener("scroll", scheduleReposition, { passive: true, capture: true });
    global.addEventListener("resize", scheduleReposition, { passive: true });
    document.addEventListener?.("fullscreenchange", scheduleSync);
    global.addEventListener("playing", scheduleSync, { capture: true });
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
      // 抖音弹窗关闭检测在 handleURLTransitionIfNeeded（MutationObserver 驱动，
      // 实时性更好）；这里只补记录，避免两条路径遗漏切换。
      const incomingDouyinModal = douyinModalIDOf(incomingURL);
      if (incomingDouyinModal) {
        lastDouyinModalID = incomingDouyinModal;
      } else if (lastDouyinModalID) {
        pinDouyinCardForClosedModal(lastDouyinModalID);
        lastDouyinModalID = "";
      }
      tabTitleFetched = false;
      cachedTabURL = "";
      cachedTabTitle = "";
      // Navigated to a new top-level page: its site authorization state may
      // differ, so re-query to refresh the header authorize entry.
      refreshCookiePermission();
      if (!sameYouTubeVideo) {
        // Real page transition (chrome-extension-spec §5.8): synchronously close
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
        candidatesEmptySince = 0;
        // Persistent hover-card FABs are NOT detached here: opening a modal
        // over the feed hides them via isOccludedByModal (repositionAll), and
        // closing the modal must restore them. Only a real page change
        // unmounts their cover cards, which the identity/connectedness guards
        // in persistentIdentityValid detect.
      }
    }
    pageTitle = String(snapshot?.title ?? "").slice(0, 300);
    pageTitleSource = snapshot?.titleSource ?? "document";
    rawCandidates = Array.isArray(snapshot?.candidates) ? snapshot.candidates : [];
    candidates = coalesceCandidates(snapshot?.pageUrl || global.location?.href || "");
    if (candidates.length > 0) {
      candidatesEmptySince = 0;
    } else if (candidatesEmptySince === 0) {
      candidatesEmptySince = Date.now();
    }
    // Candidate objects are rebuilt on every sync: restore the duration a
    // previous inspection backfilled so the main-row meta slot does not flap
    // back to empty between snapshots.
    for (const candidate of candidates) {
      if (Number.isFinite(candidate?.duration) && candidate.duration > 0) continue;
      const duration = inspectedDurations.get(candidateKey(candidate));
      if (duration != null) candidate.duration = duration;
    }
    scheduleOverlayMetadataProbe(candidates);
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
      ? coalescer(rawCandidates, pageTitleSource === "card" ? "" : pageTitle, pageURL)
      : rawCandidates;
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
      const attachment = attachments.get(element);
      if (keep.has(element) && isAttachable(element)) {
        // Live element: refresh the scoped snapshot (used if hover removes the
        // video) and resume live anchoring if it was persistent.
        if (attachment) {
          const card = findCardContainer(element);
          const source = element.getAttribute?.("src") || element.currentSrc || "";
          if (card !== attachment.cardContainer || source !== attachment.sourceSnapshot
              || cardIdentity(card) !== attachment.cardIdentity) {
            attachment.snapshotCandidates = [];
            attachment.titleSnapshot = "";
            attachment.cardContainer = card;
            attachment.sourceSnapshot = source;
            attachment.cardIdentity = cardIdentity(card);
          }
          attachment.persistent = false;
          const scoped = scopeCandidatesForElement(element, candidates)
            .filter((candidate) => candidate.supported !== false);
          attachment.snapshotCandidates = scoped;
          const liveTitle = displayTitleFor(element);
          if (liveTitle) attachment.titleSnapshot = liveTitle;
        }
        continue;
      }
      keep.delete(element);
      // Hover-autoplay card: the transient <video> left but its stable cover
      // card remains — keep the FAB pinned to the card so the user can still
      // reach it after the preview stopped. An already-pinned attachment
      // skips the entry gates: only the card's own disappearance, an identity
      // change or a covering modal unpins it (repositionAll), so transient
      // gate failures cannot make the pinned FAB flicker.
      if (attachment?.persistent) continue;
      if (enterPersistentMode(element, attachment)) continue;
      // Empty-candidate grace: a still-connected element survives a transient
      // zero-candidate window (episode switch, sniffing restart); only
      // sustained emptiness beyond the grace unmounts it.
      if (candidates.length === 0 && element.isConnected
          && Date.now() - candidatesEmptySince < EMPTY_CANDIDATES_GRACE_MS) continue;
      detach(element);
    }
    for (const element of elements) {
      if (!attachments.has(element)) {
        const card = findCardContainer(element);
        // Hovering again creates a new video node. Replace the old card entry
        // rather than leaving two buttons/panels at the same corner.
        if (card) for (const [oldElement, old] of attachments) {
          if (oldElement !== element && old.cardContainer === card) detach(oldElement);
        }
        attach(element);
      }
    }
    repositionAll();
    refreshOpenPanel();
  }

  function isAttachable(element) {
    if (!(element instanceof HTMLMediaElement)) return false;
    const scoped = scopeCandidatesForElement(element, candidates).some((candidate) => candidate.supported !== false);
    if (!scoped || element.mediaKeys != null) return false;
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

  // Containment via parentElement walk so the rule works on real DOM nodes
  // and on the unit-test shim alike.
  function containsNode(root, node) {
    for (let current = node; current; current = current.parentElement) {
      if (current === root) return true;
    }
    return false;
  }

  // Site lightboxes keep the underlying page mounted: covered media stays
  // connected, computed-visible and geometrically on-screen, so geometry-only
  // visibility leaves stale FABs floating above the modal (x.com media
  // viewer). Walk the hit stack at the anchor center top-down: reaching a
  // fixed viewport-covering layer that does not contain the anchor before
  // the anchor's own paint means a modal scrim/content paints above it.
  // In-card click catchers and player chrome sit above the anchor but are
  // reached after nothing modal — the anchor proxy comes first — and fixed
  // full-page app shells contain every anchor, so both stay unoccluded.
  function isOccludedByModal(anchor) {
    if (typeof document.elementsFromPoint !== "function") return false;
    const rect = anchor.getBoundingClientRect?.();
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    const viewW = global.innerWidth || 0;
    const viewH = global.innerHeight || 0;
    if (viewW <= 0 || viewH <= 0) return false;
    const cx = Math.min(Math.max(rect.left + rect.width / 2, 0), viewW - 1);
    const cy = Math.min(Math.max(rect.top + rect.height / 2, 0), viewH - 1);
    let stack = null;
    try {
      stack = document.elementsFromPoint(cx, cy);
    } catch {
      return false;
    }
    if (!Array.isArray(stack) || stack.length === 0) return false;
    const isAnchorPaint = (element) => element === anchor || containsNode(element, anchor);
    for (const element of stack) {
      if (isAnchorPaint(element)) return false;
      if (typeof element.getBoundingClientRect !== "function") continue;
      const style = global.getComputedStyle(element);
      if (style.position !== "fixed" || style.display === "none" || style.visibility === "hidden") continue;
      const box = element.getBoundingClientRect();
      if (box.width < viewW * 0.9 || box.height < viewH * 0.9) continue;
      if (containsNode(element, anchor)) continue;
      return true;
    }
    return false;
  }

  // positionHost parks the button just inside the anchor's right edge; an
  // anchor whose right edge lies far outside the viewport (a carousel row
  // that pre-mounts the next slide off-screen) would park the FAB where no
  // one can reach it, so hide the host instead.
  function fabBoxInView(rect) {
    const viewW = global.innerWidth || 0;
    if (viewW <= 0) return true;
    return rect.right - 6 > 0 && rect.right - 34 < viewW;
  }

  // Modal players can be laid out wider than the viewport (Douyin's modal
  // video box overflows both edges while the visible picture is letterboxed
  // inside it). Such an anchor covers the whole viewport: hiding its FAB as
  // "off-screen" would remove the button from the only player on the page,
  // so the placement clamps to the viewport edge instead.
  function anchorCoversViewport(rect) {
    const viewW = global.innerWidth || 0;
    if (viewW <= 0) return false;
    return rect.left <= 0 && rect.right >= viewW && rect.width >= viewW;
  }

  function douyinModalIDOf(rawURL) {
    try {
      const url = new URL(String(rawURL ?? ""), "https://www.douyin.com/");
      if (!/(^|\.)douyin\.com$/iu.test(url.hostname)) return "";
      return url.searchParams.get("modal_id") || "";
    } catch {
      return "";
    }
  }

  // 抖音精选卡片 DOM 内嵌 aweme_id（链接/埋点属性），用它定位刚看过
  // 的那张卡。
  function findDouyinCardByAwemeID(awemeID) {
    if (!awemeID) return null;
    for (const card of document.querySelectorAll(
      ".jingxuanVideoCard, .waterfall-videoCardContainer, [data-e2e='waterfall-item']",
    )) {
      try {
        if (card.outerHTML && card.outerHTML.includes(awemeID)) return card;
      } catch {
        // outerHTML 不可用（测试 shim）：回退 textContent。
        if (card.textContent && card.textContent.includes(awemeID)) return card;
      }
    }
    return null;
  }

  // 合成 hover：mouseover/enter 触发页面预览自动播放；预览视频出现并被
  // overlay 附着后合成 mouseout/leave——视频卸载走 enterPersistentMode
  // 钉住 FAB。5 秒内预览未出现则放弃（普通 hover 路径仍可用）。
  function pinDouyinCardForClosedModal(awemeID) {
    const card = findDouyinCardByAwemeID(awemeID);
    if (!card || typeof card.dispatchEvent !== "function") return;
    const fire = (type, bubbles) => {
      try {
        card.dispatchEvent(new MouseEvent(type, { bubbles, cancelable: true, view: global }));
      } catch {
        // 合成事件失败不阻塞主流程。
      }
    };
    fire("mouseover", true);
    fire("mouseenter", false);
    const deadline = Date.now() + 5000;
    const tick = () => {
      const video = card.querySelector?.("video");
      if (video && attachments.has(video)) {
        fire("mouseout", true);
        fire("mouseleave", false);
        return;
      }
      if (Date.now() < deadline) {
        global.setTimeout?.(tick, 250);
      } else if (video) {
        // 预览已出现但尚未附着（候选未到位）：仍合成离开，后续的
        // hover 循环会重新触发附着。
        fire("mouseout", true);
        fire("mouseleave", false);
      }
    };
    global.setTimeout?.(tick, 250);
  }

  // A cover card container is a bounded, visible ancestor that carries a
  // persistent cover (an <img> thumbnail or a CSS background image). Hover-
  // autoplay feeds mount a transient <video> inside it; the container outlives
  // the video, so it is a stable anchor for a persistent FAB.
  function hasCoverImage(container) {
    if (container.querySelector("img")) return true;
    try {
      const bg = global.getComputedStyle(container).backgroundImage;
      if (bg && bg !== "none") return true;
    } catch {
      // Ignore style read failures; fall through to false.
    }
    return false;
  }

  function cardIdentity(card) {
    const image = card?.querySelector?.("img");
    return image ? `${image.getAttribute("src") || ""}|${image.getAttribute("alt") || ""}` : "";
  }

  function findCardContainer(element) {
    // The image box is stable while Douyin mounts/removes its preview shell.
    // Its hashed inner wrappers can change size during player startup.
    const siteCard = element.closest?.(".jingxuanVideoCard, .waterfall-videoCardContainer");
    const cover = siteCard?.querySelector?.(".videoImage");
    if (cover) return cover;
    let ancestor = element.parentElement;
    for (let depth = 0; ancestor && depth < 6; depth += 1) {
      if (isElementVisible(ancestor)) {
        const box = ancestor.getBoundingClientRect?.();
        if (box) {
          const inRange =
            box.width >= MIN_CARD_WIDTH && box.width <= MAX_CARD_WIDTH &&
            box.height >= MIN_CARD_HEIGHT && box.height <= MAX_CARD_HEIGHT;
          if (inRange && hasCoverImage(ancestor)) return ancestor;
        }
      }
      ancestor = ancestor.parentElement;
    }
    return null;
  }

  function countPersistent() {
    let n = 0;
    for (const [, attachment] of attachments) if (attachment.persistent) n += 1;
    return n;
  }

  // Switch a detached-by-hover attachment to persistent mode: pin the FAB to
  // the stable cover card and keep the last scoped candidate snapshot so the
  // panel still has content after the preview video was removed.
  function enterPersistentMode(element, attachment) {
    if (!attachment) return false;
    const card = attachment.cardContainer;
    const liveSource = element.getAttribute?.("src") || element.currentSrc || "";
    // Hover teardown often empties a still-connected video before removing it.
    // An empty source is not evidence of a different video in the same card.
    if (element.isConnected && ((liveSource && liveSource !== attachment.sourceSnapshot)
        || !containsNode(card, element))) return false;
    if (!card || !card.isConnected || !isElementVisible(card)) return false;
    const box = card.getBoundingClientRect();
    const semanticCard = card.closest?.(".jingxuanVideoCard, .waterfall-videoCardContainer");
    if (box.width < MIN_CARD_WIDTH || (!semanticCard && box.width > MAX_CARD_WIDTH)) return false;
    if (box.height < MIN_CARD_HEIGHT || (!semanticCard && box.height > MAX_CARD_HEIGHT)) return false;
    // A site modal covering the card is not a finished hover preview: a
    // persistent FAB pinned here would float above the modal.
    if (isOccludedByModal(card)) return false;
    if (!attachment.snapshotCandidates?.length || cardIdentity(card) !== attachment.cardIdentity) return false;
    if (countPersistent() >= MAX_PERSISTENT) {
      // LRU eviction: unpin the oldest persistent FAB so this fresh hover
      // preview can still pin its card (refusing the pin would leave the
      // newest hovered card without any button).
      let oldest = null;
      for (const [oldElement, old] of attachments) {
        if (oldElement === element || !old.persistent) continue;
        if (!oldest || old.persistentSince < oldest[1].persistentSince) oldest = [oldElement, old];
      }
      if (!oldest) return false;
      detach(oldest[0]);
    }
    attachment.persistent = true;
    attachment.persistentSince = Date.now();
    return true;
  }

  // Scoped candidates for the panel: a persistent (hover-away) attachment uses
  // its retained snapshot because the live element is gone; a live attachment
  // uses the real-time element scope.
  function persistentIdentityValid(element, attachment) {
    const card = attachment.cardContainer;
    return card?.isConnected && cardIdentity(card) === attachment.cardIdentity
      && (!element.isConnected || (containsNode(card, element)
        && (!(element.getAttribute?.("src") || element.currentSrc)
          || (element.getAttribute?.("src") || element.currentSrc) === attachment.sourceSnapshot)));
  }

  function scopedCandidatesForElement(element) {
    const attachment = attachments.get(element);
    if (attachment?.persistent) {
      if (!persistentIdentityValid(element, attachment)) return [];
      if (Array.isArray(attachment.snapshotCandidates) && attachment.snapshotCandidates.length > 0) {
        return attachment.snapshotCandidates.filter((candidate) => candidate.supported !== false);
      }
      return [];
    }
    return scopeCandidatesForElement(element, candidates);
  }

  // ---- real-media metadata probe (duration/resolution/codec) ----
  const metadataProbeAttempted = new Set();
  let panelMetadataController = null;
  global.addEventListener?.("pagehide", () => metadataProbeAttempted.clear());
  function probeMetaFor(candidate) {
    return globalThis.MacIDMMediaMetadataProbe?.cached?.(candidate?.url) ?? null;
  }
  function probeFingerprintFor(candidate) {
    const meta = probeMetaFor(candidate);
    if (!meta) return "";
    return `${meta.duration ?? ""}|${meta.width ?? ""}|${meta.height ?? ""}|${meta.codec ?? ""}`;
  }
  // Probe candidates that lack authoritative metadata; when results land,
  // refresh the open panel so its meta rows pick up duration/resolution/codec.
  function scheduleOverlayMetadataProbe(list, priority = "background", signal) {
    const probe = globalThis.MacIDMMediaMetadataProbe;
    if (!probe?.probeCandidates) return;
    const targets = (Array.isArray(list) ? list : [])
      .filter((c) => probe.needsProbe?.(c) && (priority === "interactive" || !metadataProbeAttempted.has(c.url)));
    if (targets.length === 0) return;
    for (const c of targets) {
      metadataProbeAttempted.add(c.url);
      if (metadataProbeAttempted.size > 200) metadataProbeAttempted.delete(metadataProbeAttempted.values().next().value);
    }
    global.setTimeout(() => {
      probe.probeCandidates(targets, { priority, signal, onResult(result) {
        if (result?.meta) refreshOpenPanel(true);
      } })
        .catch(() => {});
    }, 150);
  }

  // Shared FAB placement: top-right outside the anchor rect (unchanged
  // policy), clamped to the viewport edge for anchors that overflow it.
  function positionHost(attachment, rect, anchor) {
    const scrollX = global.scrollX || document.documentElement.scrollLeft || 0;
    const scrollY = global.scrollY || document.documentElement.scrollTop || 0;
    const viewW = global.innerWidth || 0;
    const rightEdge = anchorCoversViewport(rect) && viewW > 0
      ? Math.min(rect.left + rect.width, viewW + 6)
      : rect.left + rect.width;
    attachment.host.style.left = `${rightEdge + scrollX}px`;
    // Prefer above the element; fall back to inside top-right when there
    // is not enough room above (e.g. video flush with the iframe top, or a
    // fixed site header owning the outside band — Douyin detail).
    if (hasOutsideRoom(anchor, rect)) {
      attachment.host.style.top = `${rect.top + scrollY - 32}px`;
    } else {
      attachment.host.style.top = `${rect.top + scrollY + 6}px`;
    }
  }

  // Generic outside-room probe: the 32px band above the anchor's top-right
  // must be free or held by ordinary flow content. A fixed/sticky page
  // chrome (site header/nav) owning that band means an outside FAB would
  // float over unrelated UI, so placement falls back inside the anchor.
  // Static flow content (title blocks, previous grid rows) still counts as
  // room — the button painting above it is the unchanged policy.
  function hasOutsideRoom(anchor, rect) {
    if (rect.top < 32) return false;
    if (typeof document.elementsFromPoint !== "function") return true;
    const viewW = global.innerWidth || 0;
    const viewH = global.innerHeight || 0;
    if (viewW <= 0 || viewH <= 0) return true;
    const x = Math.min(Math.max(rect.right - 20, 0), viewW - 1);
    // Sample the intended FAB box (top edge and center): a header whose
    // bottom edge cuts into the box still owns part of it.
    for (const y of [rect.top - 26, rect.top - 16]) {
      let stack = null;
      try {
        stack = document.elementsFromPoint(x, y);
      } catch {
        return true;
      }
      if (!Array.isArray(stack) || stack.length === 0) continue;
      const top = stack[0];
      if (!top || top === document.body || top === document.documentElement) continue;
      if (top === anchor || containsNode(top, anchor) || containsNode(anchor, top)) continue;
      const style = global.getComputedStyle(top);
      // Full-bleed bands pinned to the viewport top are site headers even
      // when static; column-width flow content (title blocks, grid rows)
      // still counts as room.
      const box = top.getBoundingClientRect?.();
      const fullBleedTop = Boolean(box) && viewW > 0 && box.width >= viewW * 0.9 && box.top <= 4;
      if (style.position === "fixed" || style.position === "sticky" || fullBleedTop) return false;
    }
    return true;
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
        /* Expanded candidate full title (chrome-extension-spec §5.8): .item.open
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
    attachments.set(element, {
      host,
      shadow,
      button,
      // Stable cover-card container for hover-autoplay cards (persistent FAB).
      cardContainer: findCardContainer(element),
      persistent: false,
      persistentSince: 0,
      snapshotCandidates: scopeCandidatesForElement(element, candidates).filter(c => c.supported !== false),
      sourceSnapshot: element.getAttribute?.("src") || element.currentSrc || "",
      cardIdentity: cardIdentity(findCardContainer(element)),
      // Panel title cached while the element is live: a detached hover
      // preview has no ancestor chain left, and re-resolving proximity then
      // would leak another card's caption into the persistent panel.
      titleSnapshot: displayTitleFor(element),
    });
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
      // Persistent (hover-card) FABs: anchored to the stable cover container.
      // No TTL: they live as long as the card (identity + connectedness guards),
      // are hidden while a modal covers them, and the oldest is LRU-evicted
      // once MAX_PERSISTENT pins exist.
      if (attachment.persistent) {
        const card = attachment.cardContainer;
        if (!persistentIdentityValid(element, attachment)) {
          detach(element);
          continue;
        }
        const box = card.getBoundingClientRect();
        const cardVisible = box.bottom > 0 && box.top < global.innerHeight && box.width >= MIN_CARD_WIDTH;
        if (!cardVisible || isOccludedByModal(card)) {
          attachment.host.style.display = "none";
          continue;
        }
        positionHost(attachment, box, card);
        attachment.host.style.display = "";
        continue;
      }
      // Never detach on an empty candidate window here: a transient
      // candidates === [] (SPA episode switch, sniffing restart) must not
      // remove the FAB; syncAttachments' isAttachable gate is the single
      // place that unmounts unscoped live elements.
      if (!element.isConnected) {
        detach(element);
        continue;
      }
      // A hover card's cover container outlives the transient preview video
      // and carries no hover-scale transform: placing on it keeps the FAB at
      // the same card corner in live and persistent modes, so mounting or
      // removing the preview video never makes the button jump.
      const card = attachment.cardContainer;
      const stable = card && card.isConnected && isElementVisible(card) ? card : null;
      const anchor = stable ?? findAnchorElement(element);
      if (!anchor) {
        attachment.host.style.display = "none";
        continue;
      }
      const rect = anchor.getBoundingClientRect();
      positionHost(attachment, rect, anchor);
      const visible =
        rect.bottom > 0 && rect.top < global.innerHeight && rect.width >= MIN_ELEMENT_WIDTH
        && (anchorCoversViewport(rect) || fabBoxInView(rect)) && !isOccludedByModal(anchor);
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

  // ---- element scope ----

  function scopeCandidatesForElement(element, list) {
    const filter = globalThis.MacIDMMediaElementScope?.filterCandidates;
    // Dependency failure must never expand a local panel to page scope.
    return typeof filter === "function"
      ? filter(element, list, global.location?.href)
      : [];
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
      panelMetadataController?.abort();
      panelMetadataController = null;
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
    panelMetadataController = global.AbortController ? new global.AbortController() : null;
    scheduleOverlayMetadataProbe(scopedCandidatesForElement(element), "interactive", panelMetadataController?.signal);
    const panel = buildPanel(element, shadow, button);
    // Narrow anchors: cap the adaptive panel width at the anchor width
    // minus the side gutters so it never spills past the player edge.
    const attachmentForWidth = attachments.get(element);
    const anchor = attachmentForWidth?.persistent
      ? attachmentForWidth.cardContainer
      : findAnchorElement(element);
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
    panelMetadataController?.abort();
    panelMetadataController = null;
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
      openPanelFor ? displayTitleFor(openPanelFor) : "",
      // The element's own resources (currentSrc/poster may change with
      // playback/stream switches) take part in the signature: when
      // candidates are unchanged but ownURLs differ the panel must still
      // refresh, or the scope-filtered results go stale.
      openPanelFor ? scopedCandidatesForElement(openPanelFor).map((candidate) => candidate.url) : [],
      candidates.map((candidate) => [
        candidate.url,
        candidate.size ?? null,
        candidate.supported !== false,
        candidate.displayName ?? "",
        candidate.cardTitle ?? "",
        candidate.pairKind ?? "",
        candidate.fileExtension ?? "",
        Array.isArray(candidate.variants) ? candidate.variants.length : 0,
        inspectionFailures.get(candidateKey(candidate)) ?? "",
        youTubeInspections.get(candidateKey(candidate))?.stage ?? "",
        youTubeInspections.get(candidateKey(candidate))?.variantCount ?? 0,
        probeFingerprintFor(candidate),
      ]),
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
    const scoped = scopedCandidatesForElement(element)
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
      return panel;
    }

    for (const candidate of supported.slice(0, 20)) {
      panel.append(buildItem(candidate, element));
    }
    // The overlay scrollbar is not mounted here: at this point the panel
    // is not yet inserted into the shadow DOM, so attach must be performed
    // by the caller (togglePanel / refreshOpenPanel) after insertion.
    return panel;
  }

  function buildItem(candidate, element = openPanelFor) {
    const item = document.createElement("div");
    item.className = "item";
    item.setAttribute("data-macidm-item", "");
    item.setAttribute("data-macidm-item-url", candidate.url || "");
    item.setAttribute("data-macidm-item-format", candidate.format || "");
    item.setAttribute("data-macidm-item-site", candidate.siteAdapter || "");
    // Pair provenance is observable for automation/acceptance probes: a
    // merged split-stream row must be distinguishable from a lone stream.
    item.setAttribute("data-macidm-item-pair", candidate.pairKind || "");
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
      const ytDuration = firstVariantDuration(ytSnapshot.variants);
      if (ytDuration != null) {
        candidate.duration ??= ytDuration;
        inspectedDurations.set(stateKey, ytDuration);
      }
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
    const fullName = smartName(candidate, element);
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
    // Real-media probe metadata (resolution/codec, duration below) fills gaps
    // the URL cannot provide; never overrides an already-known value.
    const probeMeta = probeMetaFor(candidate);
    const probeHeight = probeMeta?.height || 0;
    const resolutionSlot = (!candidate.qualityLabel && probeHeight)
      ? (globalThis.MacIDMMediaUtils?.resolutionLabel?.(probeMeta?.width || 0, probeHeight) || "")
      : "";
    if (resolutionSlot) metaSlots.push(resolutionSlot);
    const sizeSlot = formatSize(candidate);
    if (![t("common.unknown"), t("common.sizeUnknown"), t("common.probing"), t("common.parsing")].includes(sizeSlot)) {
      metaSlots.push(sizeSlot);
    }
    const durationSlot = formatDuration(candidate.duration ?? probeMeta?.duration ?? null);
    if (durationSlot) metaSlots.push(durationSlot);
    const codecSlot = globalThis.MacIDMMediaUtils?.codecFamily?.(probeMeta?.codec) || "";
    if (codecSlot) metaSlots.push(codecSlot);
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
    if (isOpen) nodes.push(buildSubmenu(candidate, item, submenuId, failureMessage, element));
    const wrapper = document.createDocumentFragment();
    wrapper.append(...nodes);
    return wrapper;
  }

  /// A single "download now" sub-item: candidates with no quality choice
  /// (direct links, failed inspections, single-quality streams) all submit
  /// to the App confirmation window through it.
  function buildDownloadNowItem(candidate, itemEl, element = openPanelFor) {
    const direct = document.createElement("button");
    direct.type = "button";
    direct.className = "sub-item";
    direct.setAttribute("data-macidm-btn-direct", "");
    direct.textContent = t("overlay.downloadNow");
    direct.addEventListener("click", (event) => {
      event.stopPropagation();
      submitDownload(candidate, null, itemEl, element);
    });
    return direct;
  }

  function buildSubmenu(candidate, itemEl, submenuId, failureMessage, element = openPanelFor) {
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
      return renderYouTubeSubmenu(candidate, submenu, itemEl, element);
    }
    // Failed inspections no longer render blunt error copy (when
    // unauthorized the header already has the authorize entry; when logged
    // out it is handed to the Popup's site-session flow): the drawer simply
    // keeps the "download now" item.
    if (failureMessage) {
      submenu.append(buildDownloadNowItem(candidate, itemEl, element));
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
      submenu.append(buildDownloadNowItem(candidate, itemEl, element));
      return submenu;
    }
    const labeledVariants = candidate.variants
      .slice(0, 12)
      .map((variant) => ({ variant, label: overlayVariantLabel(variant) }))
      .filter((entry) => entry.label);
    if (labeledVariants.length === 0) {
      // Parsed but qualities indistinguishable: unify on the "download
      // now" sub-item.
      submenu.append(buildDownloadNowItem(candidate, itemEl, element));
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
        const ok = await submitDownload(candidate, variant, itemEl, element);
        if (ok) {
          openSubFor = null;
          refreshOpenPanel(true);
        }
      });
      submenu.append(option);
    }
    return submenu;
  }

  // First positive duration across parsed variants: App inspections return
  // a per-variant duration (Bilibili playurl, HLS sub-playlist total) and
  // all variants of one asset share it, so the first hit is the asset's.
  function firstVariantDuration(variants) {
    for (const variant of Array.isArray(variants) ? variants : []) {
      const value = variant?.duration;
      if (Number.isFinite(value) && value > 0) return value;
    }
    return null;
  }

  function renderVariants(candidate, variants) {
    candidate.variants = variants;
    // Backfill the main-row duration slot from the parsed variants (B站主行
    // “时长”槽、HLS 行时长都从这里来); never overrides a known value.
    const duration = firstVariantDuration(variants);
    if (duration != null) {
      candidate.duration ??= duration;
      inspectedDurations.set(candidateKey(candidate), duration);
    }
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
    // with the Popup, keeping both quality lists identical
    // (chrome-extension-spec §5.8).
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
          // This panel only exists after the user clicked the media FAB, so
          // the inspection is a user gesture: the Host may wake an App the
          // user quit instead of answering with a launch timeout.
          userInitiated: true,
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
  function renderYouTubeSubmenu(candidate, submenu, itemEl, element = openPanelFor) {
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
        const ok = await submitDownload(candidate, variant, itemEl, element);
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
        submenu.append(buildDownloadNowItem(candidate, itemEl, element));
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
        submenu.append(buildDownloadNowItem(candidate, itemEl, element));
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
  async function submitDownload(candidate, variant, itemEl, element = openPanelFor) {
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
        // Naming trust model (technical spec §8.1): tell the App whether the
        // hint was synthesized from the page title or merely derived from the
        // URL tail, so a URL-tail name never outranks the title on disk.
        filenameHintSource: globalThis.MacIDMMediaUtils?.filenameHintSourceFor?.(candidate) ?? "urlPath",
        pageTitle: displayTitleFor(element),
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

  // Per-attachment display title: the proximity-resolved title of the
  // anchor element's own module (card/modal/player) so multi-card pages
  // label rows with the hovered card's title instead of the page branding;
  // falls back to the page-level resolver.
  function displayTitleFor(element) {
    const attachment = attachments.get(element);
    // Persistent (or already-detached) hover-card attachment: reuse the
    // title cached while the preview was live; its element can no longer
    // resolve its own card module.
    if (attachment?.titleSnapshot && (attachment.persistent || !element.isConnected)) {
      return attachment.titleSnapshot;
    }
    if (element && globalThis.MacIDMMediaUtils?.resolveContentTitle) {
      try {
        const prox = globalThis.MacIDMMediaUtils.resolveContentTitle(document, element);
        if (prox) return prox.slice(0, 120);
      } catch {
        // Fall through to the page-level title.
      }
    }
    return cleanedPageTitle();
  }

  function smartName(candidate, element) {
    // Use the shared utility to keep naming consistent between Popup and
    // Overlay. Falls back to the local implementation if the shared module
    // is not loaded (e.g. in a cross-origin iframe before injection).
    const base = displayTitleFor(element);
    if (globalThis.MacIDMMediaUtils?.smartMediaName) {
      return globalThis.MacIDMMediaUtils.smartMediaName(
        candidate, base, candidates.length, global.location?.hostname ?? "");
    }
    const hint = String(candidate.filenameHint ?? "").trim();
    if (base) {
      if (hint && hint.toLowerCase().startsWith(base.toLowerCase())) return hint;
      const generic = /^(download|index|master|playlist|media|video|audio|manifest)\b/i.test(hint);
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
    // 抖音 feed：SPA 不重置 document.title，残留的是上一个详情页的视频标题；
    // og/meta/后台 tab title 同样残留 —— 页级标题整体不可信，回退通用名。
    if (globalThis.MacIDMMediaUtils?.isDouyinFeedPage?.()) return "";
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
    // YouTube product contract (technical-spec §3.4): the final output is
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

  global.MacIDMOverlay = Object.freeze({ syncCandidates, refreshScope: scheduleSync });
  install();
})(globalThis);
