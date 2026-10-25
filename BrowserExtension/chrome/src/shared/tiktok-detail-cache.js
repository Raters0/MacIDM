// Keeps preloaded TikTok item direct URLs by item_id with bounded size and
// lifetime. Feed capture posts items from explore/recommend item_list and
// item/detail responses; a fresh detail page contributes its SSR
// webapp.video-detail itemStruct. Modal lookup uses the page URL's
// /video/<id> path or modal_item_id; card lookup requires the ID in that
// card's DOM. Entries contain media metadata only and do not initiate
// downloads.
(function installTikTokDetailCache(global) {
  const TTL = 30 * 60 * 1000;
  const MAX_ENTRIES = 48;
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

  function videoIdOf(pageURL) {
    try {
      const url = new URL(String(pageURL ?? ""), "https://www.tiktok.com/");
      if (!/(^|\.)tiktok\.com$/iu.test(url.hostname)) return null;
      const match = url.pathname.match(/\/video\/(\d{6,25})/u);
      if (match) return match[1];
      return url.searchParams.get("modal_item_id") || null;
    } catch {
      return null;
    }
  }

  /// itemStruct → 有界条目。webapp 形状里 playAddr 是直链字符串、
  /// bitrateInfo[].PlayAddr 是 { UrlList, DataSize } 对象（移动端形状的
  /// play_addr.url_list 一并容忍）；档位按 Bitrate 降序排列，保证合成时
  /// urls[0] 是可判定的最高码率档。
  function normalizeItemStruct(item) {
    try {
      if (!item || typeof item !== "object") return null;
      const id = String(item.id ?? "");
      if (!/^\d{6,25}$/u.test(id)) return null;
      const video = item.video;
      if (!video || typeof video !== "object") return null;
      const seen = new Set();
      const urls = [];
      const push = (addr) => {
        if (typeof addr === "string") {
          if (!/^https?:/iu.test(addr) || seen.has(addr)) return;
          seen.add(addr);
          urls.push({ url: addr, size: null });
          return;
        }
        const size = Number(addr?.DataSize ?? addr?.data_size);
        const list = Array.isArray(addr?.UrlList)
          ? addr.UrlList
          : (Array.isArray(addr?.url_list) ? addr.url_list : []);
        const url = list.find((candidate) => /^https?:/iu.test(String(candidate ?? "")));
        if (!url || seen.has(url)) return;
        seen.add(url);
        urls.push({ url, size: Number.isSafeInteger(size) && size > 0 ? size : null });
      };
      const gears = (Array.isArray(video.bitrateInfo) ? video.bitrateInfo : [])
        .filter((gear) => gear && typeof gear === "object")
        .sort((a, b) => (Number(b?.Bitrate) || 0) - (Number(a?.Bitrate) || 0));
      for (const gear of gears) {
        push(gear?.PlayAddr);
        if (urls.length >= MAX_URLS) break;
      }
      if (urls.length < MAX_URLS) push(video.playAddr ?? video.play_addr);
      if (urls.length === 0) return null;
      const duration = Number(video.duration);
      return {
        itemId: id,
        desc: String(item.desc ?? ""),
        duration: Number.isFinite(duration) && duration > 0 ? duration : null,
        urls,
      };
    } catch {
      return null;
    }
  }

  function store(entry) {
    try {
      if (!entry || typeof entry.itemId !== "string" || entry.itemId.length === 0) return;
      const urls = (Array.isArray(entry.urls) ? entry.urls : [])
        .filter((u) => u && typeof u.url === "string" && /^https?:/i.test(u.url))
        .slice(0, MAX_URLS);
      if (urls.length === 0) return;
      prune();
      cache.set(entry.itemId, {
        itemId: entry.itemId,
        desc: String(entry.desc ?? "").slice(0, 300),
        duration: Number.isFinite(entry.duration) && entry.duration > 0 ? entry.duration : null,
        urls,
        at: Date.now(),
      });
    } catch {
      // 缓存失败不影响页面；详情数据仍可能经普通观察路径到达。
    }
  }

  function get(itemId, now = Date.now()) {
    prune(now);
    return cache.get(String(itemId ?? "")) ?? null;
  }

  /// 当前页面 video id（路径 /video/<id> 或 modal_item_id）匹配的直链数组；
  /// 非 tiktok host、无 id 或无命中时返回空。
  function associatedURLs(pageURL, now = Date.now()) {
    const itemId = videoIdOf(pageURL);
    if (!itemId) return [];
    const entry = get(itemId, now);
    return entry ? entry.urls.map((u) => u.url) : [];
  }

  /// 合成候选：desc 为语义标题（titleDerived 信任级）；直链取缓存里的
  /// 最高码率档（store 前已按 Bitrate 降序）。
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
    const itemId = videoIdOf(pageURL);
    if (!itemId) return [];
    const candidate = synthesize(get(itemId, now));
    return candidate ? [candidate] : [];
  }

  /// feed 卡片关联：对 htmlHas(itemId) 为真的条目合成候选（卡片 DOM 含
  /// 条目 id 时，卡片内的预览播放器可归属）。
  function feedCardCandidates(htmlHas, now = Date.now()) {
    try {
      if (typeof htmlHas !== "function") return [];
      prune(now);
      const result = [];
      for (const entry of cache.values()) {
        if (!htmlHas(entry.itemId)) continue;
        const candidate = synthesize(entry);
        if (candidate) result.push(candidate);
      }
      return result;
    } catch {
      return [];
    }
  }

  /// 元素归属证据：卡片 DOM 文本含条目 item_id 时，该条目直链属于卡片内
  /// 预览播放器（有界站点关联）。
  function urlsForCardText(cardText, now = Date.now()) {
    try {
      const text = typeof cardText === "string" ? cardText : String(cardText ?? "");
      if (!text) return [];
      prune(now);
      const urls = [];
      for (const entry of cache.values()) {
        if (!text.includes(entry.itemId)) continue;
        for (const item of entry.urls) urls.push(item.url);
      }
      return urls;
    } catch {
      return [];
    }
  }

  /// 元素归属证据：详情 feed 的 slide DOM 不携带 item id，但 slide 内的
  /// video-desc 文本与缓存条目 desc 的前缀一致（同源数据）时，该条目直链
  /// 属于 slide 内播放器。前缀取 desc 归一化后的前 40 字符，过短不匹配。
  function urlsForDescText(descText, now = Date.now()) {
    try {
      const text = String(descText ?? "").replace(/\s+/gu, " ").trim();
      if (text.length < 8) return [];
      prune(now);
      const urls = [];
      for (const entry of cache.values()) {
        const head = String(entry.desc ?? "").replace(/\s+/gu, " ").trim().slice(0, 40);
        if (head.length < 8 || !text.includes(head)) continue;
        for (const item of entry.urls) urls.push(item.url);
      }
      return urls;
    } catch {
      return [];
    }
  }

  /// 卡片标题证据：slide 文本与缓存条目 desc 前缀一致时返回该条目的
  /// desc（titleDerived），供卡片标题打点优先于通用 DOM 解析。
  function descForSlideText(descText, now = Date.now()) {
    try {
      const text = String(descText ?? "").replace(/\s+/gu, " ").trim();
      if (text.length < 8) return "";
      prune(now);
      for (const entry of cache.values()) {
        const head = String(entry.desc ?? "").replace(/\s+/gu, " ").trim().slice(0, 40);
        if (head.length < 8 || !text.includes(head)) continue;
        return String(entry.desc ?? "").trim();
      }
      return "";
    } catch {
      return "";
    }
  }

  /// feed slide（详情 feed 与 For You）候选合成：slide 的 video-desc 文本
  /// 按 desc 前缀命中条目时合成该条目候选；同一 URL 只合成一次。
  function slideCandidates(descTexts, now = Date.now()) {
    try {
      prune(now);
      const seen = new Set();
      const result = [];
      for (const text of Array.isArray(descTexts) ? descTexts.slice(0, 24) : []) {
        const normalized = String(text ?? "").replace(/\s+/gu, " ").trim();
        if (normalized.length < 8) continue;
        for (const entry of cache.values()) {
          const head = String(entry.desc ?? "").replace(/\s+/gu, " ").trim().slice(0, 40);
          if (head.length < 8 || !normalized.includes(head)) continue;
          const candidate = synthesize(entry);
          if (candidate && !seen.has(candidate.url)) {
            seen.add(candidate.url);
            result.push(candidate);
          }
          break;
        }
      }
      return result;
    } catch {
      return [];
    }
  }

  function clear() {
    cache.clear();
  }

  global.MacIDMTikTokDetailCache = Object.freeze({
    normalizeItemStruct,
    store,
    get,
    videoIdOf,
    associatedURLs,
    associatedCandidates,
    feedCardCandidates,
    slideCandidates,
    urlsForCardText,
    urlsForDescText,
    descForSlideText,
    clear,
  });
})(globalThis);
