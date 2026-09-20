// Read attribution from the live element on every render. No tab-wide fallback,
// playback-timing heuristic, or retained DOM ownership survives element reuse.
(function installMediaElementScope(global) {
  if (global.MacIDMMediaElementScope) return;
  let snapshot = null;
  let minimumGeneration = 0;
  let lastGeneration = -1;
  const TTL = 5 * 60 * 1000;
  function requestSnapshot() {
    try { global.postMessage?.({ type: "macidm.requestMediaSourceSnapshot" }, "*"); } catch {}
  }
  global.addEventListener?.("message", event => {
    if (event.source !== global) return;
    const data = event.data;
    if (data?.type === "macidm.resetSniffState") {
      snapshot = null;
      minimumGeneration = lastGeneration + 1;
      global.MacIDMOverlay?.refreshScope?.();
      return;
    }
    if (data?.type !== "macidm.mediaSourceSnapshot" || data.pageURL !== global.location?.href) return;
    if (!Number.isSafeInteger(data.generation) || data.generation < minimumGeneration || data.generation < lastGeneration) return;
    const readMap = (entries, maxEntries, maxURLs, blobKeys = false) => {
      const map = new Map();
      if (!Array.isArray(entries)) return map;
      const validURL = raw => {
        if (typeof raw !== "string" || raw.length > 8192) return null;
        return global.MacIDMMediaUtils?.normalizeHTTPURL(raw);
      };
      for (const entry of entries.slice(0, maxEntries)) {
        if (!Array.isArray(entry) || !Array.isArray(entry[1])) continue;
        const [raw, values] = entry;
        const key = blobKeys
          ? (typeof raw === "string" && raw.length <= 8192 && raw.startsWith(`blob:${global.location?.origin ?? new URL(data.pageURL).origin}/`) ? raw : null)
          : validURL(raw);
        if (key) map.set(key, new Set(values.slice(0, maxURLs).map(validURL).filter(Boolean)));
      }
      return map;
    };
    try {
      lastGeneration = data.generation;
      snapshot = { pageURL: data.pageURL, at: Date.now(),
        blobs: readMap(data.blobs, 16, 128, true), parents: readMap(data.parents, 128, 8) };
      global.MacIDMOverlay?.refreshScope?.();
    } catch { snapshot = null; }
  });
  requestSnapshot();

  // The observer only broadcasts when its state changes, so a one-shot
  // request at install time cannot keep an MSE page scoping correctly for
  // the whole session: once the snapshot passes its TTL (or arrives empty
  // before the player wired blob→stream ownership), every blob player loses
  // its candidates and its FAB silently disappears minutes into playback.
  // Re-ask with a throttle while any expansion actually involves a blob:
  // the response path already wakes the overlay via refreshScope().
  let lastRequestAt = Date.now();
  const moduleLoadedAt = lastRequestAt;
  function maybeRequestSnapshot() {
    const now = Date.now();
    // Warm-up: right after load the player is still wiring blob→stream
    // ownership, so retry fast (the FAB of a freshly opened detail page
    // must not wait a 15-second throttle window to appear).
    const interval = now - moduleLoadedAt < 60_000 ? 3_000 : 15_000;
    if (now - lastRequestAt < interval) return;
    lastRequestAt = now;
    requestSnapshot();
  }

  // A paused/preloaded player may produce no further DOM events. Retry even
  // without overlay renders, but only while a blob player is mounted.
  global.setInterval?.(() => {
    const media = global.document?.querySelectorAll?.("video, audio") ?? [];
    if ([...media].some(element => [...ownURLs(element, global.location?.href)]
      .some(url => url.startsWith("blob:")))) maybeRequestSnapshot();
  }, 3_000);

  function addObservedURLs(urls, pageURL) {
    const hasBlob = () => {
      for (const url of urls) if (String(url).startsWith("blob:")) return true;
      return false;
    };
    const stale = !snapshot || snapshot.pageURL !== pageURL || Date.now() - snapshot.at > TTL;
    if (hasBlob()) maybeRequestSnapshot();
    if (stale) return;
    const queue = [...urls];
    // Follow only actual blob ownership and explicit playlist ancestry.
    // No JSON API collection, host, filename prefix, or time-window inference.
    for (let i = 0; i < queue.length && i < 512; i += 1) {
      for (const url of [...(snapshot.blobs.get(queue[i]) ?? []), ...(snapshot.parents.get(queue[i]) ?? [])]) {
        if (urls.has(url)) continue;
        urls.add(url);
        queue.push(url);
      }
    }
  }

  const MEDIA_ATTRIBUTES = ["src", "data-src", "data-video", "data-url", "data-hls", "data-dash", "data-mp4"];

  function ownURLs(element, pageURL) {
    const urls = new Set();
    const add = (raw) => {
      if (!raw) return;
      try {
        const url = new URL(raw, pageURL);
        if (!["http:", "https:", "blob:"].includes(url.protocol)) return;
        url.hash = "";
        urls.add(url.href);
      } catch {}
    };
    const declaredSrc = element?.getAttribute?.("src");
    // During load(), currentSrc may still describe the previous resource.
    // Prefer the newly declared source until the element catches up.
    if (!declaredSrc) add(element?.currentSrc);
    for (const node of [element, ...(element?.querySelectorAll?.("source") ?? [])]) {
      for (const attribute of MEDIA_ATTRIBUTES) add(node?.getAttribute?.(attribute));
    }
    return urls;
  }

  // X's poster and official media URL carry the same namespaced media ID.
  // The namespace is essential: a tweet ID, a bare CDN host, or a thumbnail
  // elsewhere in the enclosing article is not evidence for this player.
  function xMediaIdentity(raw, poster = false) {
    try {
      const url = new URL(raw);
      if (url.protocol !== "https:" || url.port) return null;
      if (url.hostname !== (poster ? "pbs.twimg.com" : "video.twimg.com")) return null;
      const pattern = poster
        ? /^\/(amplify_video|ext_tw_video)_thumb\/(\d+)\//u
        : /^\/(amplify_video|ext_tw_video)\/(\d+)\//u;
      const match = url.pathname.match(pattern);
      if (match) return `${match[1]}:${match[2]}`;
      const gif = url.pathname.match(poster
        ? /^\/tweet_video_thumb\/([A-Za-z0-9_-]+)\.[a-zA-Z0-9]+$/u
        : /^\/tweet_video\/([A-Za-z0-9_-]+)\.[a-zA-Z0-9]+$/u);
      return gif ? `tweet_video:${gif[1]}` : null;
    } catch {
      return null;
    }
  }

  function mainAdapter(element, pageURL) {
    try {
      const host = new URL(pageURL).hostname.toLowerCase();
      const utils = global.MacIDMMediaUtils;
      let root = null;
      let adapter = null;
      let url = pageURL;
      if (["youtube.com", "www.youtube.com", "m.youtube.com"].includes(host)
          && utils?.isYouTubeWatchPage(pageURL)) {
        root = element.closest?.('[id="movie_player"]');
        adapter = "youtube";
      } else if (host === "bilibili.com" || host.endsWith(".bilibili.com")) {
        const card = element.closest?.(".bili-video-card, .bili-video-card__image--hover, [class*='video-card']");
        if (card) {
          const identity = utils?.extractBilibiliCardIdentity?.(element, pageURL);
          if (!identity) return null;
          root = element.closest?.(".bpx-player-container") || card;
          url = identity.pageURL;
          adapter = "bilibili";
        } else if (utils?.isBilibiliPageURL(pageURL)) {
          root = element.closest?.(".bpx-player-container");
          adapter = "bilibili";
        }
      }
      const media = root?.querySelectorAll?.("video, audio");
      return media?.length === 1 && media[0] === element ? { adapter, url } : null;
    } catch { return null; }
  }

  function filterCandidates(element, candidates, pageURL = global.location?.href) {
    const filter = global.MacIDMMediaUtils?.filterCandidatesForElementScope;
    if (!element || typeof filter !== "function" || !Array.isArray(candidates)) return [];
    const urls = ownURLs(element, pageURL);
    addObservedURLs(urls, pageURL);
    // 抖音详情：detail 预解析直链归属当前弹窗播放器（modal_id 匹配的
    // 有界站点关联）——弹窗播放器走 MSE，字节观察无法把直链关联到元素。
    // 卡片关联：元素所在卡片 DOM 文本含条目 aweme_id 时同样归属
    //（弹窗关闭后钉回卡片的 FAB 依赖这条路径）。
    try {
      if (/(^|\.)douyin\.com$/iu.test(new URL(pageURL).hostname)) {
        for (const url of global.MacIDMDouyinDetailCache?.associatedURLs?.(pageURL) ?? []) {
          urls.add(url);
        }
        const card = element.closest?.(".jingxuanVideoCard, .waterfall-videoCardContainer");
        if (card) {
          // aweme_id 在卡片属性（链接/埋点）里而非可见文本，用 outerHTML。
          for (const url of global.MacIDMDouyinDetailCache?.urlsForCardText?.(card.outerHTML ?? "") ?? []) {
            urls.add(url);
          }
        }
      }
    } catch { /* ignore */ }
    let xPage = false;
    try {
      xPage = ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
        .includes(new URL(pageURL).hostname);
    } catch {}
    const identities = new Set();
    if (xPage) {
      const posterID = xMediaIdentity(element.getAttribute?.("poster"), true);
      if (posterID) identities.add(posterID);
      for (const url of urls) {
        const id = xMediaIdentity(url);
        if (id) identities.add(id);
      }
    }
    const adapter = mainAdapter(element, pageURL);
    for (const candidate of candidates) {
      if (candidate?.siteAdapter) {
        // A preview card owns its own URL, even when mounted on a watch
        // page. Preserve query identity (including Bilibili multi-P).
        if (candidate.siteAdapter === adapter?.adapter
            && global.MacIDMMediaUtils.normalizeHTTPURL(candidate.url)
              === global.MacIDMMediaUtils.normalizeHTTPURL(adapter.url)) urls.add(candidate.url);
      } else if (identities.has(xMediaIdentity(candidate?.url))) {
        urls.add(candidate.url);
      }
    }
    const scoped = filter(candidates, urls);
    // A verified site's parser already offers complete track/quality choices.
    // Raw observations of that same player must not add parallel drawers.
    const primary = scoped.filter(c => c.siteAdapter === adapter?.adapter);
    return adapter && primary.length ? primary : scoped;
  }

  // URLs still owned by mounted players (the observer retains liveBlobs
  // across resets). The content-script uses this to keep such candidates
  // alive through same-document SPA transitions: a modal open must not drop
  // streams that were preloaded before the transition and are never
  // re-requested, while an unmounted player's URLs stay cleared.
  function liveURLs() {
    const urls = new Set();
    // The snapshot includes preloaded and formerly attached blobs. Retain only
    // sources still declared by mounted players, never every historical record.
    for (const element of global.document?.querySelectorAll?.("video, audio") ?? []) {
      const owned = ownURLs(element, global.location?.href);
      addObservedURLs(owned, snapshot?.pageURL);
      for (const url of owned) if (!url.startsWith("blob:")) urls.add(url);
    }
    return urls;
  }

  function annotateOwnership(candidates) {
    const owners = new Map();
    for (const element of global.document?.querySelectorAll?.("video, audio") ?? []) {
      const urls = ownURLs(element, global.location?.href);
      const identity = element.getAttribute?.("src") || element.currentSrc;
      if (!identity) continue;
      addObservedURLs(urls, global.location?.href);
      for (const url of urls) {
        const set = owners.get(url) ?? new Set();
        set.add(identity); owners.set(url, set);
      }
    }
    return candidates.map(candidate => {
      const set = owners.get(candidate.url);
      return { ...candidate, mediaOwner: set?.size === 1 ? [...set][0] : undefined };
    });
  }

  function recoverableCandidates() {
    const result = [];
    for (const url of liveURLs()) {
      const parsed = new URL(url);
      // Recover complete containers only. Arbitrary byte endpoints and stream
      // segments still require the normal discovery/governance pipeline.
      const declared = parsed.searchParams.get("mime_type");
      const douyin = parsed.hostname.endsWith(".douyinvod.com")
        && ["douyin.com", "www.douyin.com"].includes(new URL(global.location.href).hostname);
      const mime = douyin && declared === "video_mp4" ? "video/mp4" : "";
      if (!mime && !/\.(?:mp4|m4a|webm)(?:$)/iu.test(parsed.pathname)) continue;
      result.push({ url, mime, confidence: "dom" });
      if (result.length >= 32) break;
    }
    return result;
  }

  global.MacIDMMediaElementScope = Object.freeze({ filterCandidates, liveURLs, recoverableCandidates, annotateOwnership });
})(globalThis);
