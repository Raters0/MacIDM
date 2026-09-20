// Keeps preloaded Douyin detail URLs by aweme_id with bounded size and lifetime.
// Modal lookup uses modal_id; card lookup requires the ID in that card's DOM.
// Entries contain media metadata only and do not initiate downloads.
(function installDouyinDetailCache(global) {
  const TTL = 30 * 60 * 1000;
  const MAX_ENTRIES = 12;
  const MAX_URLS = 8;
  const cache = new Map();

  function prune(now = Date.now()) {
    for (const [key, entry] of cache) {
      if (now - entry.at > TTL) cache.delete(key);
    }
    while (cache.size > MAX_ENTRIES) {
      const oldest = cache.keys().next().value;
      if (oldest === undefined) break;
      cache.delete(oldest);
    }
  }

  function modalIdOf(pageURL) {
    try {
      const url = new URL(String(pageURL ?? ""), "https://www.douyin.com/");
      if (!/(^|\.)douyin\.com$/iu.test(url.hostname)) return null;
      return url.searchParams.get("modal_id") || null;
    } catch {
      return null;
    }
  }

  function store(entry) {
    try {
      if (!entry || typeof entry.awemeId !== "string" || entry.awemeId.length === 0) return;
      const urls = (Array.isArray(entry.urls) ? entry.urls : [])
        .filter((u) => u && typeof u.url === "string" && /^https?:/i.test(u.url))
        .slice(0, MAX_URLS);
      if (urls.length === 0) return;
      prune();
      cache.set(entry.awemeId, {
        awemeId: entry.awemeId,
        desc: String(entry.desc ?? "").slice(0, 300),
        duration: Number.isFinite(entry.duration) && entry.duration > 0 ? entry.duration : null,
        urls,
        at: Date.now(),
      });
    } catch {
      // 缓存失败不影响页面；详情数据仍可能经普通观察路径到达。
    }
  }

  function get(awemeId, now = Date.now()) {
    prune(now);
    return cache.get(String(awemeId ?? "")) ?? null;
  }

  /// 当前页面 modal_id 匹配的直链数组；无 modal_id 或无命中时返回空。
  function associatedURLs(pageURL, now = Date.now()) {
    const modalId = modalIdOf(pageURL);
    if (!modalId) return [];
    const entry = get(modalId, now);
    return entry ? entry.urls.map((u) => u.url) : [];
  }

  /// 合成候选：desc 为语义标题（titleDerived 信任级）；直链取缓存里的
  /// 最优档（store 保持 play_addr 在前、bit_rate 降序在后）。
  function synthesize(entry) {
    const best = entry?.urls?.[0];
    if (!best) return null;
    const base = String(entry.desc ?? "").replace(/\s+/gu, " ").trim();
    return {
      url: best.url,
      mime: "video/mp4",
      format: "video",
      fileExtension: "mp4",
      size: Number.isSafeInteger(best.size) && best.size > 0 ? best.size : null,
      supported: true,
      confidence: "dom",
      displayName: base ? base.slice(0, 80) : undefined,
      filenameHint: base ? `${base.slice(0, 120)}.mp4` : undefined,
      filenameHintSource: base ? "titleDerived" : undefined,
      duration: entry.duration ?? undefined,
    };
  }

  function associatedCandidates(pageURL, now = Date.now()) {
    const modalId = modalIdOf(pageURL);
    if (!modalId) return [];
    const candidate = synthesize(get(modalId, now));
    return candidate ? [candidate] : [];
  }

  /// feed 卡片关联：对 htmlHas(awemeId) 为真的条目合成候选（弹窗关闭后
  /// 把 FAB 钉回卡片：预览字节是预加载的，没有新请求可观察）。
  function feedCardCandidates(htmlHas, now = Date.now()) {
    try {
      if (typeof htmlHas !== "function") return [];
      prune(now);
      const result = [];
      for (const entry of cache.values()) {
        if (!htmlHas(entry.awemeId)) continue;
        const candidate = synthesize(entry);
        if (candidate) result.push(candidate);
      }
      return result;
    } catch {
      return [];
    }
  }

  /// 元素归属证据：卡片 DOM 文本含条目 aweme_id 时，该条目直链属于
  /// 卡片内预览播放器（有界站点关联）。
  function urlsForCardText(cardText, now = Date.now()) {
    try {
      const text = typeof cardText === "string" ? cardText : String(cardText ?? "");
      if (!text) return [];
      prune(now);
      const urls = [];
      for (const entry of cache.values()) {
        if (!text.includes(entry.awemeId)) continue;
        for (const item of entry.urls) urls.push(item.url);
      }
      return urls;
    } catch {
      return [];
    }
  }

  function clear() {
    cache.clear();
  }

  global.MacIDMDouyinDetailCache = Object.freeze({
    store,
    get,
    associatedURLs,
    associatedCandidates,
    feedCardCandidates,
    urlsForCardText,
    clear,
  });
})(globalThis);
