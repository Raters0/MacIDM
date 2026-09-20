(function installMacIDMContent() {
  if (globalThis.__macIDMContentInstalled) return;
  globalThis.__macIDMContentInstalled = true;

  const discovery = globalThis.MacIDMDiscovery;
  const mediaUtils = globalThis.MacIDMMediaUtils;
  const candidates = new Map();
  const maxCandidates = 100;
  // Report message types from the MAIN world fetch-interceptor (kept in
  // sync with fetch-interceptor.js).
  const FETCH_CAPTURE_MESSAGE = "macidm.fetchCapture";
  const REQUEST_LEASE_MESSAGE = "macidm.requestSniffLease";
  const GRANT_LEASE_MESSAGE = "macidm.grantSniffLease";
  const SETTLE_LEASE_MESSAGE = "macidm.settleSniffLease";
  const RELEASE_LEASE_MESSAGE = "macidm.releaseSniffLease";
  const RESET_SNIFF_STATE_MESSAGE = "macidm.resetSniffState";

  // Player-data message types from the MAIN world youtube-player-bridge
  // (§5.1): properties like ytd-watch-flexy.playerData are only visible in
  // the MAIN world; the bridge forwards only the necessary normalized
  // fields (no signed media URLs), and the page session holds the latest
  // snapshot in memory.
  const YOUTUBE_PLAYER_DATA_MESSAGE = "macidm.youTubePlayerData";
  const YOUTUBE_PLAYER_REQUEST_MESSAGE = "macidm.requestYouTubePlayerData";
  let youTubePlayerSnapshot = null; // { videoId, capturedAt, data }
  // Candidate confidence tiers: repeated reports of the same candidate keep
  // the higher confidence.
  // dom (direct DOM read) > headers (confirmed via background webRequest
  //   response headers) > magic (response-body magic-number/JSON deep scan)
  //   > fetch (fetch/XHR URL capture) > extension (extension-name/
  //   Performance-entry inference only).
  const CONFIDENCE_RANK = { dom: 5, headers: 4, magic: 3, fetch: 2, extension: 1 };
  // Mirrors STORAGE_SETTINGS_KEY in constants.js; classic scripts cannot
  // import ES modules.
  const STORAGE_SETTINGS_KEY = "settings";
  let notifyTimer;
  let lastNotification = "";
  let runtimeMessageUnavailable = false;
  let observedPageURL = location.href;
  let performanceWatermark = 0;

  // The page session's confirmed title (§7): only a document.title proven to
  // belong to the current page may be published. Injection implies a full
  // page load, so the document.title at that moment belongs to this page;
  // on an SPA transition it is set to pending (""), and the real title is
  // published again only once attribution evidence holds — never fall back
  // to the old document.title.
  let confirmedPageTitle = typeof document.title === "string" ? document.title : "";
  // Provenance of confirmedPageTitle: a proximity-resolved title may be
  // replaced by a newer proximity result (hovering the next card on a feed),
  // while a document.title/snapshot-adopted specific title stays locked to
  // avoid flapping on gallery pages.
  let confirmedFromProximity = false;
  // Used only for change detection: at the transition instant
  // document.title is still the old page's title and cannot be published,
  // but we need to know when the SPA framework updates it.
  let lastDomTitle = confirmedPageTitle;
  // document.title snapshot at the transition instant: always reject this
  // value until attribution holds (the bridge's 1-second polling can easily
  // deliver the new page's snapshot before the SPA title update, when
  // document.title is still the old page's).
  let staleTitleAtTransition = "";
  // SPA title fallback timer: some SPAs never update document.title on route
  // change; after a short settle window we accept proximity/structured title
  // evidence instead of leaving the page title empty forever.
  let spaTitleFallbackTimer;
  // Sniff false-positive governance settings cache (undefined → the default
  // in shared/sniff-governance.js). The snapshot path is synchronous and
  // reads the cache first; storage changes refresh it asynchronously and
  // force a re-publish so the Popup's "filter noise candidates" toggle
  // takes effect immediately.
  let governanceSettings;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "macidm.scanLinks") {
      const resolved = mediaUtils?.resolvePageTitle
        ? mediaUtils.resolvePageTitle()
        : document.title.slice(0, 300);
      sendResponse({
        pageUrl: location.href,
        title: (resolved || document.title).slice(0, 300),
        links: discovery.collectLinks(document.querySelectorAll("a[href]"), location.href),
      });
      return false;
    }
    if (message?.type === "macidm.scanMedia" || message?.type === "macidm.getMediaCandidates") {
      scanDOMFull();
      sendResponse({ ok: true, ...snapshot() });
      return false;
    }
    if (message?.type === "macidm.probeMediaMeta") {
      // 页面上下文探针：popup（扩展源）的 <video preload=metadata> 会被抖音
      // 等签名 CDN 拒绝（缺页面 referer/cookie）；在页面内探测后回填 popup。
      const probe = globalThis.MacIDMMediaMetadataProbe;
      const urls = Array.isArray(message?.urls)
        ? message.urls.filter((u) => typeof u === "string")
        : [];
      if (!probe?.probeCandidates || urls.length === 0) {
        sendResponse({ ok: true, results: [] });
        return false;
      }
      probe.probeCandidates(urls.map((url) => ({ url })), { priority: "interactive" })
        .then((results) => sendResponse({ ok: true, results: results ?? [] }))
        .catch(() => sendResponse({ ok: false, results: [] }));
      return true; // 异步 sendResponse
    }
    if (message?.type === "macidm.addMediaCandidate") {
      // Candidate confirmed via background webRequest response-header
      // observation → confidence "headers".
      addCandidate({
        ...message.candidate,
        updateOnly: message.updateOnly === true,
        confidence:
          CONFIDENCE_RANK[message.candidate?.confidence] != null
            ? message.candidate.confidence
            : "headers",
      });
      sendResponse({ ok: true, ...snapshot() });
      return false;
    }
    if (message?.type === "macidm.getYouTubeQualities") {
      // Page-first resolution path for the Popup/coordinator: reads the
      // current page's player response and normalizes it.
      if (window !== window.top) return false;
      const waitMs = Number.isFinite(message.waitMs)
        ? Math.min(Math.max(message.waitMs, 0), 10_000)
        : 0;
      respondWithYouTubeQualities(message.pageUrl, waitMs, sendResponse);
      return true;
    }
    return false;
  });

  /// In-page quality response: extract from the current snapshot first;
  /// with no result, retry with bounded backoff within the deadline,
  /// asking the MAIN world bridge to re-read once before each retry.
  async function respondWithYouTubeQualities(pageUrl, waitMs, sendResponse) {
    const deadline = Date.now() + waitMs;
    let lastResult = null;
    for (;;) {
      const result = youTubeQualitiesNow(pageUrl);
      if (result) lastResult = result;
      if (result && (result.ok === true || result.reason === "liveUnsupported")) {
        sendResponse(result);
        return;
      }
      if (Date.now() >= deadline) {
        sendResponse(lastResult ?? { ok: false, reason: "noPlayerData" });
        return;
      }
      requestYouTubePlayerRead();
      const remaining = deadline - Date.now();
      await new Promise((resolve) => setTimeout(resolve, Math.max(50, Math.min(400, remaining))));
    }
  }

  /// One-shot extraction from the currently available data sources: try
  /// the bridge snapshot first, then fall back to a direct ISOLATED world
  /// read.
  function youTubeQualitiesNow(pageUrl) {
    const formats = globalThis.MacIDMYouTubeFormats;
    if (formats?.extractFromPlayerResponseObject && youTubePlayerSnapshot?.data) {
      const fromSnapshot = formats.extractFromPlayerResponseObject(
        youTubePlayerSnapshot.data,
        pageUrl,
      );
      if (fromSnapshot?.ok === true || fromSnapshot?.reason === "liveUnsupported") {
        return fromSnapshot;
      }
    }
    return formats?.extractPageQualities?.(pageUrl)
      ?? { ok: false, reason: "noPlayerData" };
  }

  /// Ask the MAIN world bridge to re-read the player data once (bounded
  /// debouncing happens inside the bridge).
  function requestYouTubePlayerRead() {
    try {
      window.postMessage({ type: YOUTUBE_PLAYER_REQUEST_MESSAGE }, "*");
    } catch {
      // Keep the existing polling snapshot path when the bridge is
      // unavailable.
    }
  }

  /// Unified SPA navigation entry: compares the current URL with the page
  /// session; on a real transition it clears all old-page state and
  /// immediately publishes the new page's entry candidates.
  function handlePageTransition() {
    if (location.href === observedPageURL) return false;
    const previousURL = observedPageURL;
    observedPageURL = location.href;

    const previousVideoId =
      globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(previousURL) ?? "";
    const currentVideoId =
      globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(location.href) ?? "";
    const isSameVideoParamChange =
      Boolean(previousVideoId) && previousVideoId === currentVideoId;

    if (isSameVideoParamChange) {
      scheduleNotification(true);
      return false;
    }

    // A real SPA transition: reset state completely. Resources still owned
    // by mounted players survive: same-document modal opens (feed →
    // ?modal_id=…) would otherwise drop streams preloaded before the
    // transition that playback never re-requests, leaving the Popup in the
    // listening state forever. The observer retains those blobs' ownership
    // across resets, so an unmounted player's URLs (YouTube A→B) stay
    // cleared and cross-video hygiene is preserved.
    const liveURLs = globalThis.MacIDMMediaElementScope?.liveURLs?.() ?? null;
    const retained = [];
    if (liveURLs && liveURLs.size > 0) {
      for (const [key, candidate] of candidates) {
        if (liveURLs.has(candidate.url)) retained.push([key, candidate]);
      }
    }
    candidates.clear();
    for (const [key, candidate] of retained) candidates.set(key, candidate);
    lastNotification = "";
    staleTitleAtTransition = typeof document.title === "string" ? document.title : "";
    confirmedPageTitle = "";
    confirmedFromProximity = false;
    lastDomTitle = staleTitleAtTransition;
    youTubePlayerSnapshot = null;

    // Clear incremental state and cancel old timers.
    pendingMutations = [];
    if (incrementalScanTimer != null) {
      clearTimeout(incrementalScanTimer);
      incrementalScanTimer = undefined;
    }
    if (notifyTimer != null) {
      clearTimeout(notifyTimer);
      notifyTimer = undefined;
    }

    // Set the Performance watermark so old-route history entries cannot
    // leak into the new generation.
    try {
      performanceWatermark = typeof performance?.now === "function" ? performance.now() : Date.now();
    } catch {
      performanceWatermark = Date.now();
    }

    // Tell the MAIN world to cancel in-flight readers and pending
    // requests.
    try {
      window.postMessage({ type: RESET_SNIFF_STATE_MESSAGE }, "*");
    } catch {}

    // SPA title fallback: give the framework ~2s to settle, then accept
    // whatever title evidence (document.title or proximity-resolved) exists.
    if (spaTitleFallbackTimer != null) {
      clearTimeout(spaTitleFallbackTimer);
    }
    spaTitleFallbackTimer = setTimeout(() => {
      spaTitleFallbackTimer = undefined;
      adoptTitleIfAttributed(true);
      refreshResolvedTitle(true);
    }, 2_000);

    globalThis.MacIDMOverlay?.handlePageTransition?.(location.href);
    scanDOMFull();
    scheduleNotification(true);
    return true;
  }

  function resetIfPageChanged() {
    return handlePageTransition();
  }

  function adoptTitleIfAttributed(force = false) {
    const domTitle = typeof document.title === "string" ? document.title.slice(0, 300).trim() : "";
    if (!domTitle) return;
    if (!force && staleTitleAtTransition && domTitle === staleTitleAtTransition) return;
    const urlVideoId =
      globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(location.href) ?? "";
    if (urlVideoId) {
      if (youTubePlayerSnapshot?.videoId !== urlVideoId) return;
    }
    if (confirmedPageTitle !== domTitle) {
      confirmedPageTitle = domTitle;
      confirmedFromProximity = false;
      scheduleNotification(true);
    }
  }

  // The currently-playing (else largest visible) media element, used as the
  // anchor for proximity-based content-title resolution.
  function activeMediaAnchor() {
    const medias = document.querySelectorAll("video, audio");
    let largest = null;
    let largestArea = 0;
    for (const el of medias) {
      if (!el.paused && el.readyState >= 2) return el;
      const rect = el.getBoundingClientRect();
      const area = rect.width * rect.height;
      if (area > largestArea) {
        largestArea = area;
        largest = el;
      }
    }
    return largest;
  }

  let lastResolvedTitleAt = 0;
  // Adopt a proximity/structured-resolved title when the confirmed title is
  // empty or a generic brand/page name (typical SPA detail/modal pages whose
  // document.title never updates). A specific confirmed title wins to avoid
  // flapping on gallery/list pages.
  function refreshResolvedTitle(force = false) {
    const now = Date.now();
    if (!force && now - lastResolvedTitleAt < 1_000) return;
    lastResolvedTitleAt = now;
    if (!mediaUtils?.resolvePageTitle) return;
    let resolved = "";
    try {
      resolved = mediaUtils.resolvePageTitle(document, activeMediaAnchor());
    } catch {
      return;
    }
    if (!resolved) return;
    const current = String(confirmedPageTitle || "").trim();
    const currentGeneric =
      current === "" ||
      (mediaUtils.isGenericOrBrandTitle
        ? mediaUtils.isGenericOrBrandTitle(current, location.hostname)
        : false);
    if ((currentGeneric || confirmedFromProximity) && resolved !== current) {
      confirmedPageTitle = resolved;
      confirmedFromProximity = true;
      scheduleNotification(true);
    }
  }

  function publishTitleIfChanged() {
    const domTitle = typeof document.title === "string" ? document.title : "";
    if (domTitle === lastDomTitle) return;
    lastDomTitle = domTitle;
    adoptTitleIfAttributed();
  }

  let pendingMutations = [];
  let incrementalScanTimer;

  function scanDOMFull() {
    resetIfPageChanged();
    publishTitleIfChanged();
    refreshResolvedTitle();

    if (discovery?.extractFullDOMCandidates) {
      const fullCandidates = discovery.extractFullDOMCandidates(document, location.href, discovery.isMediaCandidate);
      for (let i = 0; i < fullCandidates.length; i++) {
        addCandidate(fullCandidates[i]);
      }
    } else {
      for (const element of document.querySelectorAll(
        "video[src], audio[src], video source[src], audio source[src]",
      )) {
        const mediaEl = element.closest("video, audio");
        const duration =
          mediaEl && Number.isFinite(mediaEl.duration) && mediaEl.duration > 0
            ? mediaEl.duration
            : undefined;
        addCandidate({ url: element.src, mime: element.type || "", duration, confidence: "dom" });
      }
      for (const element of document.querySelectorAll("video:not([src]), audio:not([src])")) {
        const duration =
          Number.isFinite(element.duration) && element.duration > 0
            ? element.duration
            : undefined;
        if (element.currentSrc && !element.currentSrc.startsWith("blob:")) {
          addCandidate({ url: element.currentSrc, mime: element.type || "", duration, confidence: "dom" });
        } else if (element.readyState >= 1 || element.srcObject) {
          addCandidate({ url: element.currentSrc || "mse:player", mime: "video/mp4", duration, confidence: "dom" });
        }
      }
      if (discovery?.collectExtendedMediaCandidates) {
        for (const item of discovery.collectExtendedMediaCandidates(location.href)) {
          if (item.url) addCandidate({ url: item.url, mime: "", confidence: "dom" });
        }
      }
    }
  }

  function scanMedia() {
    scanDOMFull();
  }

  function scanPerformanceInitial() {
    try {
      performanceWatermark = typeof performance?.now === "function" ? performance.now() : 0;
      if (discovery?.collectPerformanceMediaCandidates) {
        for (const item of discovery.collectPerformanceMediaCandidates()) {
          if (item.url) {
            addCandidate({
              url: item.url,
              size: item.size > 0 ? item.size : undefined,
              confidence: "extension",
            });
          }
        }
      } else {
        for (const entry of performance.getEntriesByType("resource")) {
          if (discovery?.isMediaCandidate && discovery.isMediaCandidate(entry.name)) {
            addCandidate({ url: entry.name, confidence: "extension" });
          }
        }
      }
    } catch {}
  }

  function processIncrementalMutations() {
    resetIfPageChanged();
    publishTitleIfChanged();
    if (pendingMutations.length === 0) return;

    const batch = pendingMutations.splice(0, pendingMutations.length);
    if (discovery?.extractDOMMutationCandidates) {
      const incremental = discovery.extractDOMMutationCandidates(batch, location.href, discovery.isMediaCandidate);
      for (let i = 0; i < incremental.length; i++) {
        addCandidate(incremental[i]);
      }
    } else {
      scanDOMFull();
    }
  }

  function scheduleIncrementalScan() {
    if (incrementalScanTimer != null) return;
    incrementalScanTimer = window.setTimeout(() => {
      incrementalScanTimer = undefined;
      processIncrementalMutations();
    }, 25);
  }

  function addCandidate(raw) {
    const candidate = mediaUtils.normalizeMediaCandidate(raw, location.href);
    if (!candidate) return false;
    candidate.confidence =
      CONFIDENCE_RANK[raw?.confidence] != null ? raw.confidence : "extension";
    if (raw?.format === "dash-json") candidate.format = "dash-json";

    const groupKey = mediaUtils.m4sGroupKey ? mediaUtils.m4sGroupKey(candidate.url) : null;
    const key =
      groupKey ??
      (mediaUtils.normalizeResourceURL
        ? mediaUtils.normalizeResourceURL(candidate.url)
        : candidate.url);
    const previous = candidates.get(key);
    // Probe metadata updates an observed resource; it cannot discover a new
    // resource (in particular an adapter's HTML page URL).
    if (raw?.updateOnly && !previous) return false;
    if (previous) {
      if (groupKey) {
        const previousInfo = mediaUtils.extractM4sInfo?.(previous.url);
        const candidateInfo = mediaUtils.extractM4sInfo?.(candidate.url);
        const preferred =
          previousInfo && candidateInfo && candidateInfo.formatId < previousInfo.formatId
            ? previous
            : candidate;
        const merged = {
          ...preferred,
          mime: preferred.mime || previous.mime || candidate.mime,
          size: preferred.size ?? previous.size ?? candidate.size,
          duration: preferred.duration ?? previous.duration ?? candidate.duration,
          confidence: higherConfidence(previous, candidate),
          // A display-only server filename (Content-Disposition) arriving via
          // a later probe report survives the merge.
          ...(candidate.serverFilename ? { serverFilename: candidate.serverFilename } : {}),
        };
        if (
          merged.mime !== previous.mime ||
          merged.size !== previous.size ||
          merged.duration !== previous.duration ||
          merged.confidence !== previous.confidence ||
          merged.url !== previous.url
        ) {
          candidates.delete(key); // refresh recency so merges keep it alive
          candidates.set(key, merged);
          scheduleNotification();
        }
        return false;
      }
      candidates.delete(key);
      candidates.set(key, previous);
      const merged = {
        ...previous,
        mime: previous.mime || candidate.mime,
        size: previous.size ?? candidate.size,
        duration: previous.duration ?? candidate.duration,
        confidence: higherConfidence(previous, candidate),
        format: previous.format === "dash-json" ? "dash-json"
          : mediaUtils.mediaFormat(candidate.url, previous.mime || candidate.mime),
        ...(candidate.serverFilename ? { serverFilename: candidate.serverFilename } : {}),
        sizeProbeFailed:
          candidate.sizeProbeFailed === true
            ? true
            : (previous.sizeProbeFailed === true ? true : undefined),
      };
      if (
        merged.mime !== previous.mime ||
        merged.size !== previous.size ||
        merged.duration !== previous.duration ||
        merged.confidence !== previous.confidence ||
          merged.format !== previous.format ||
          merged.sizeProbeFailed !== previous.sizeProbeFailed
        ) {
          candidates.delete(key); // refresh recency so merges keep it alive
          candidates.set(key, merged);
          scheduleNotification();
        }
        return false;
    }
    if (candidates.size >= maxCandidates) {
      // Evict least-recently-seen, not first-inserted: image-heavy pages keep
      // adding fresh candidates, and FIFO eviction would push out the video/
      // audio candidates found by the initial DOM scan before the overlay
      // ever reads them. Re-inserting on every touch (below) keeps
      // long-lived media at the tail.
      const first = candidates.keys().next().value;
      if (first) candidates.delete(first);
    }
    candidates.set(key, {
      ...candidate,
      sizeProbeFailed: raw?.sizeProbeFailed === true ? true : candidate.sizeProbeFailed,
    });
    scheduleNotification();
    return true;
  }

  function higherConfidence(previous, candidate) {
    const previousRank = CONFIDENCE_RANK[previous?.confidence] ?? 0;
    const candidateRank = CONFIDENCE_RANK[candidate?.confidence] ?? 0;
    return candidateRank > previousRank
      ? candidate.confidence
      : (previous?.confidence ?? candidate.confidence);
  }

  function scheduleNotification(force = false) {
    if (notifyTimer != null) return;
    notifyTimer = window.setTimeout(() => {
      notifyTimer = undefined;
      const value = JSON.stringify(snapshot());
      if (!force && value === lastNotification) return;
      lastNotification = value;
      const parsed = JSON.parse(value);
      sendRuntimeMessage({ type: "media.candidatesUpdated", ...parsed });
      globalThis.MacIDMOverlay?.syncCandidates(parsed);
    }, 120);
  }

  function sendRuntimeMessage(message) {
    if (runtimeMessageUnavailable) return;
    try {
      Promise.resolve(chrome.runtime.sendMessage(message)).catch(() => {});
    } catch {
      runtimeMessageUnavailable = true;
    }
  }

  function douyinFeedCardCandidates() {
    const cache = globalThis.MacIDMDouyinDetailCache;
    try {
      if (!cache?.feedCardCandidates) return [];
      if (!/(^|\.)douyin\.com$/iu.test(location.hostname ?? "")) return [];
      const cards = document.querySelectorAll?.(".jingxuanVideoCard, .waterfall-videoCardContainer");
      if (!cards?.length) return [];
      // aweme_id 在卡片的链接/埋点属性里而非可见文本，用 outerHTML；
      // 只拼接一次，逐条目 includes 判定。
      let text = "";
      for (const card of cards) text += card.outerHTML ?? "";
      if (!text) return [];
      return cache.feedCardCandidates((awemeID) => text.includes(awemeID));
    } catch {
      return [];
    }
  }

  function snapshot() {
    for (const candidate of globalThis.MacIDMMediaElementScope?.recoverableCandidates?.() ?? []) {
      addCandidate(candidate);
    }
    // 抖音详情预解析：modal_id 匹配时合成详情直链候选（有界站点关联），
    // 让详情 FAB 无需等待播放器拉流即可出现。
    for (const candidate of globalThis.MacIDMDouyinDetailCache?.associatedCandidates?.(location.href) ?? []) {
      addCandidate(candidate);
    }
    // feed 卡片关联：弹窗关闭后预览字节是预加载的、没有新请求可观察；
    // 对 DOM 中出现其 aweme_id 的卡片合成详情直链候选，让钉住的 FAB
    // （overlay 合成 hover 路径）有可归属的候选。卡片文本扫描仅在详情
    // 缓存非空时进行。
    for (const candidate of douyinFeedCardCandidates()) {
      addCandidate(candidate);
    }
    const title = String(confirmedPageTitle ?? "").slice(0, 300);
    const observed = Array.from(candidates.values()).slice(0, maxCandidates);
    const governed = globalThis.MacIDMSniffGovernance
      ? globalThis.MacIDMSniffGovernance.applySniffGovernance(observed, governanceSettings)
      : { candidates: observed, filteredSummary: { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 } };
    // Title provenance for consumers: a title resolved from one card's module
    // on a gallery page must not name other cards' resources. "card" means the
    // confirmed title is card-scoped (page-level resolution disagrees); then
    // synthesized pair/segment names drop the page title and rows fall back
    // to per-candidate card attribution stamped below.
    let titleSource = confirmedFromProximity ? "content" : "document";
    if (confirmedFromProximity && mediaUtils?.resolvePageTitle) {
      try {
        const pageLevel = mediaUtils.resolvePageTitle(document, null);
        if (pageLevel !== title) titleSource = "card";
      } catch {
        titleSource = "card";
      }
    }
    const synthesisTitle = titleSource === "card"
      || (mediaUtils?.isGenericOrBrandTitle?.(title, location.hostname) ?? false)
      ? "" : title;
    // Bilibili list/homepage hover previews: attach card identity (bvid +
    // heading title) so the coalesced list can synthesize a site adapter
    // candidate instead of raw m4s + the page branding title.
    const previewIdentities = mediaUtils?.collectBilibiliPreviewIdentities
      ? mediaUtils.collectBilibiliPreviewIdentities(document, location.href)
      : [];
    const attributed = globalThis.MacIDMMediaElementScope?.annotateOwnership?.(governed.candidates) ?? governed.candidates;
    const coalesced = mediaUtils?.coalesceMediaCandidates
      ? mediaUtils.coalesceMediaCandidates(attributed, synthesisTitle, location.href, previewIdentities)
      : governed.candidates;
    // Per-candidate card attribution for direct-src resources (Douyin feed
    // previews): the popup names and submits such rows by their own card's
    // caption instead of the page-level title (which on galleries is either
    // branding or one arbitrary card's caption). Cover images are attributed
    // too — on a gallery most rows are image candidates whose src appears
    // on the card element that carries the caption.
    let stamped = coalesced;
    if (mediaUtils?.resolveContentTitle) {
      const cardTitleByURL = new Map();
      try {
        const candidateURLs = new Set(coalesced.map((candidate) => candidate?.url).filter(Boolean));
        let resolvedCount = 0;
        for (const el of [...document.querySelectorAll("video, audio"), ...document.querySelectorAll("img")]) {
          if (resolvedCount >= 40) break;
          const url = el.currentSrc
            || (el.tagName === "IMG" ? el.src : el.getAttribute?.("src"))
            || "";
          const owned = el.tagName === "IMG"
            ? (candidateURLs.has(url) ? [{ url }] : [])
            : (globalThis.MacIDMMediaElementScope?.filterCandidates?.(el, coalesced, location.href) ?? []);
          if (!owned.length) continue;
          const cardTitle = mediaUtils.resolveContentTitle(document, el);
          if (cardTitle) {
            for (const candidate of owned) cardTitleByURL.set(candidate.url, cardTitle);
            resolvedCount += 1;
          }
        }
      } catch {
        // Attribution is best-effort; rows fall back to page-level rules.
      }
      if (cardTitleByURL.size > 0) {
        stamped = coalesced.map((candidate) => {
          const cardTitle = cardTitleByURL.get(candidate?.url);
          return cardTitle ? { ...candidate, cardTitle } : candidate;
        });
      }
    }
    return {
      pageUrl: location.href,
      title,
      titleSource,
      candidates: stamped,
      filteredSummary: governed.filteredSummary,
    };
  }

  function loadGovernanceSettings() {
    try {
      Promise.resolve(chrome.storage?.local?.get(STORAGE_SETTINGS_KEY))
        .then((stored) => {
          const next = globalThis.MacIDMSniffGovernance?.normalizeSniffGovernance(
            stored?.[STORAGE_SETTINGS_KEY]?.sniffGovernance,
          );
          if (next == null || JSON.stringify(next) === JSON.stringify(governanceSettings)) return;
          governanceSettings = next;
          scheduleNotification(true);
        })
        .catch(() => {});
    } catch {}
  }

  chrome.storage?.onChanged?.addListener?.((changes, area) => {
    if (area !== "local" || !changes?.[STORAGE_SETTINGS_KEY]) return;
    loadGovernanceSettings();
  });
  loadGovernanceSettings();

  scanDOMFull();
  scanPerformanceInitial();
  scheduleNotification(true);

  for (const type of ["yt-navigate-finish", "yt-page-data-updated"]) {
    document.addEventListener(type, () => handlePageTransition());
  }

  new MutationObserver((records) => {
    pendingMutations.push(...records);
    scheduleIncrementalScan();
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["src", "data-src", "data-video", "data-url", "data-hls", "data-dash", "data-mp4"],
  });

  // Resource Timing Observer (without buffered: true to eliminate double historical delivery)
  let resourceObserver = null;
  if (typeof PerformanceObserver === "function") {
    try {
      resourceObserver = new PerformanceObserver((list) => {
        resetIfPageChanged();
        const entries = list.getEntries();
        // Filter out entries that started prior to or at the current generation watermark (startTime priority)
        const validEntries = entries.filter((e) => {
          if (performanceWatermark > 0) {
            const entryTime = (typeof e.startTime === "number" && Number.isFinite(e.startTime) && e.startTime > 0)
              ? e.startTime
              : ((typeof e.responseEnd === "number" && Number.isFinite(e.responseEnd) && e.responseEnd > 0) ? e.responseEnd : 0);
            if (entryTime > 0 && entryTime <= performanceWatermark) {
              return false;
            }
          }
          return true;
        });

        if (discovery?.extractPerformanceEntriesCandidates) {
          const incremental = discovery.extractPerformanceEntriesCandidates(validEntries, discovery.isMediaCandidate);
          for (let i = 0; i < incremental.length; i++) {
            addCandidate(incremental[i]);
          }
        } else {
          for (const entry of validEntries) {
            if (discovery?.isMediaCandidate && discovery.isMediaCandidate(entry.name)) {
              addCandidate({ url: entry.name, confidence: "extension" });
            }
          }
        }
      });
      resourceObserver.observe({ type: "resource" });
    } catch {
      resourceObserver = null;
    }
  }

  if (!resourceObserver && typeof window?.setInterval === "function") {
    window.setInterval(scanDOMFull, 2_500);
  }

  // MAIN World <-> ISOLATED World Message Bridge
  function handleMainWorldBridgeMessage(event) {
    try {
      if (!event || event.source !== window) return;
      const data = event.data;
      if (!data || typeof data !== "object") return;

      // The scope listener validates this snapshot later in the same message
      // dispatch. Publish on the debounce, after that validation has completed.
      if (data.type === "macidm.mediaSourceSnapshot" && data.pageURL === location.href) {
        scheduleNotification();
        return;
      }

      // 抖音详情预加载数据：直链入库后立即发布快照（弹窗打开时不再有
      // 网络请求可观察，详情 FAB 依赖这份预解析候选）。
      if (data.type === "macidm.douyin.detail") {
        try {
          globalThis.MacIDMDouyinDetailCache?.store?.(data);
        } catch {
          // 缓存失败不影响页面。
        }
        scheduleNotification();
        return;
      }

      // 1. Fetch capture candidate
      if (data.type === FETCH_CAPTURE_MESSAGE) {
        const url = typeof data.url === "string" ? data.url : "";
        if (!url) return;
        const viaMagic = data.via === "magic";
        addCandidate({
          url,
          mime: typeof data.mime === "string" ? data.mime : "",
          confidence: viaMagic ? "magic" : "fetch",
          format: data.format === "dash-json" ? "dash-json" : undefined,
        });
        return;
      }

      // 2. Sniff Lease Request (MAIN -> Background)
      if (data.type === REQUEST_LEASE_MESSAGE && typeof data.requestId === "string") {
        const requestId = data.requestId;
        try {
          chrome.runtime.sendMessage(
            {
              type: "macidm.sniff.acquireLease",
              requestedBytes: data.requestedBytes,
              tier: data.tier,
            },
            (response) => {
              try {
                window.postMessage(
                  {
                    type: GRANT_LEASE_MESSAGE,
                    requestId,
                    leaseId: response?.leaseId ?? null,
                    grantedBytes: response?.grantedBytes ?? 0,
                  },
                  "*",
                );
              } catch {}
            },
          );
        } catch {
          window.postMessage(
            {
              type: GRANT_LEASE_MESSAGE,
              requestId,
              leaseId: null,
              grantedBytes: 0,
            },
            "*",
          );
        }
        return;
      }

      // 3. Sniff Lease Settlement (MAIN -> Background)
      if (data.type === SETTLE_LEASE_MESSAGE && typeof data.leaseId === "string") {
        try {
          chrome.runtime.sendMessage({
            type: "macidm.sniff.settleLease",
            leaseId: data.leaseId,
            actualBytes: data.actualBytes,
          });
        } catch {}
        return;
      }

      // 4. Sniff Lease Release (MAIN -> Background)
      if (data.type === RELEASE_LEASE_MESSAGE && typeof data.leaseId === "string") {
        try {
          chrome.runtime.sendMessage({
            type: "macidm.sniff.releaseLease",
            leaseId: data.leaseId,
            reason: data.reason,
          });
        } catch {}
        return;
      }

      // 5. YouTube Player Data Message
      if (data.type === YOUTUBE_PLAYER_DATA_MESSAGE) {
        const payload = data.payload;
        const videoId = typeof payload?.videoId === "string" ? payload.videoId : "";
        if (!videoId || !payload || typeof payload !== "object") return;

        const urlVideoId =
          globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(location.href) ?? "";
        if (!urlVideoId || urlVideoId !== videoId) return;

        const pageChanged = handlePageTransition();
        const videoChanged = videoId !== (youTubePlayerSnapshot?.videoId ?? "");
        youTubePlayerSnapshot = { videoId, capturedAt: Date.now(), data: payload };

        let titleAdopted = false;
        const snapshotTitle =
          typeof payload?.videoDetails?.title === "string"
            ? payload.videoDetails.title.slice(0, 300).trim()
            : "";
        if (snapshotTitle) {
          if (confirmedPageTitle !== snapshotTitle) {
            confirmedPageTitle = snapshotTitle;
            confirmedFromProximity = false;
            titleAdopted = true;
          }
        } else {
          adoptTitleIfAttributed();
        }

        if (pageChanged || videoChanged || titleAdopted) {
          scheduleNotification(true);
        }
      }
    } catch {
      // ignore
    }
  }

  if (typeof window.addEventListener === "function") {
    window.addEventListener("message", handleMainWorldBridgeMessage);
  }
})();
