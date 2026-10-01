// Bounded, metadata-only cache of YouTube player responses captured from the
// page's own `/youtubei/v1/player` traffic (chrome-extension-spec §5.8).
//
// Why it exists: a list/home hover preview fetches exactly one player response
// per hovered video (measured ~125 KB, carrying the full `formats` +
// `adaptiveFormats` set), but the floating preview player sits outside every
// card and the page URL carries no video identity. Without this cache the
// card's quality panel had to fall back to an App/yt-dlp extraction — 13–90 s,
// and a hard failure whenever YouTube's bot check rejects an unauthenticated
// run. With it, the shared in-page pipeline answers a card row exactly like a
// watch page does.
//
// Hard boundaries:
// - **Metadata only.** Signed media URLs, `signatureCipher` and every field
//   outside the whitelist are dropped on the way in, so no secret or
//   session-bound value can reach the ISOLATED world, the Popup, or the App.
// - Keyed by videoId, TTL-bounded and capacity-bounded; the content script
//   clears it on SPA navigation.
// - No selection logic lives here: `playerResponseFor` rebuilds the minimal
//   player-response shape that `MacIDMYouTubeFormats.extractFromPlayerResponseObject`
//   already consumes, so track dedup/labels/size estimates stay single-sourced.
(function installYouTubePlayerMetadata(global) {
  if (global.MacIDMYouTubePlayerMetadata) return;

  const TTL_MS = 30 * 60 * 1000;
  const MAX_ENTRIES = 24;
  const MAX_FORMATS = 80;
  const MAX_TITLE = 200;
  const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{5,}$/u;
  // Insertion-ordered so the oldest entry is the first key; `store` deletes and
  // re-inserts on refresh, which also gives LRU eviction for free.
  const entries = new Map(); // videoId -> { storedAt, details, formats, adaptiveFormats }

  function clipString(value, max) {
    return typeof value === "string" && value
      ? value.replace(/\s+/gu, " ").trim().slice(0, max)
      : undefined;
  }

  function finiteNumber(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : undefined;
  }

  function triStateBoolean(value) {
    return value === true || value === false ? value : undefined;
  }

  /// Whitelist pick for one streamingData track: exactly the fields the shared
  /// normalization pipeline reads (itag / geometry / bitrate / fps / container
  /// MIME / contentLength) — never `url`, `signatureCipher`, or anything else.
  /// Must stay in sync with the MAIN-world picker in fetch-interceptor.js
  /// (a MAIN-world script cannot import shared modules); this second pass is
  /// defence in depth, not the only filter.
  function pickFormat(format) {
    if (!format || typeof format !== "object") return null;
    const picked = {
      itag: finiteNumber(format.itag),
      width: finiteNumber(format.width),
      height: finiteNumber(format.height),
      bitrate: finiteNumber(format.bitrate),
      fps: finiteNumber(format.fps),
      mimeType: clipString(format.mimeType, 256),
      // contentLength arrives as a string in player responses; keep it a
      // bounded digit string so the size estimator sees the same shape the
      // watch-page path produces.
      contentLength: typeof format.contentLength === "string"
        ? format.contentLength.slice(0, 32)
        : undefined,
    };
    for (const key of Object.keys(picked)) {
      if (picked[key] === undefined) delete picked[key];
    }
    return picked.itag !== undefined || picked.height !== undefined ? picked : null;
  }

  function pickFormats(list) {
    if (!Array.isArray(list)) return [];
    const out = [];
    for (const format of list) {
      const picked = pickFormat(format);
      if (picked) out.push(picked);
      if (out.length >= MAX_FORMATS) break;
    }
    return out;
  }

  /// Accept one MAIN-world payload. Returns true when the stored metadata
  /// changed (callers may republish); a repeated identical payload only
  /// refreshes the entry's position and timestamp.
  function store(payload, now = Date.now()) {
    const videoId = typeof payload?.videoId === "string" ? payload.videoId.trim() : "";
    if (!VIDEO_ID_PATTERN.test(videoId)) return false;
    const formats = pickFormats(payload?.formats);
    const adaptiveFormats = pickFormats(payload?.adaptiveFormats);
    if (formats.length === 0 && adaptiveFormats.length === 0) return false;
    const details = {
      videoId,
      title: clipString(payload?.title, MAX_TITLE),
      lengthSeconds: typeof payload?.lengthSeconds === "string"
        ? payload.lengthSeconds.replace(/[^\d]/gu, "").slice(0, 12) || undefined
        : undefined,
      isLive: triStateBoolean(payload?.isLive),
      isUpcomingLive: triStateBoolean(payload?.isUpcomingLive),
      isLiveContent: triStateBoolean(payload?.isLiveContent),
    };
    for (const key of Object.keys(details)) {
      if (details[key] === undefined) delete details[key];
    }
    const previous = entries.get(videoId);
    const changed = !previous
      || JSON.stringify(previous.details) !== JSON.stringify(details)
      || JSON.stringify(previous.formats) !== JSON.stringify(formats)
      || JSON.stringify(previous.adaptiveFormats) !== JSON.stringify(adaptiveFormats);
    entries.delete(videoId);
    entries.set(videoId, { storedAt: now, details, formats, adaptiveFormats });
    while (entries.size > MAX_ENTRIES) {
      const oldest = entries.keys().next().value;
      if (oldest === undefined) break;
      entries.delete(oldest);
    }
    return changed;
  }

  function liveEntry(videoId, now = Date.now()) {
    const entry = typeof videoId === "string" ? entries.get(videoId) : undefined;
    if (!entry) return null;
    if (now - entry.storedAt > TTL_MS) {
      entries.delete(videoId);
      return null;
    }
    return entry;
  }

  function has(videoId, now = Date.now()) {
    return liveEntry(videoId, now) != null;
  }

  /// Minimal player-response shape for `MacIDMYouTubeFormats`: the same field
  /// names the watch-page path reads, rebuilt from whitelisted metadata only.
  function playerResponseFor(videoId, now = Date.now()) {
    const entry = liveEntry(videoId, now);
    if (!entry) return null;
    return {
      videoDetails: { ...entry.details },
      streamingData: {
        formats: entry.formats.map((format) => ({ ...format })),
        adaptiveFormats: entry.adaptiveFormats.map((format) => ({ ...format })),
      },
    };
  }

  function videoIds(now = Date.now()) {
    const ids = [];
    for (const videoId of [...entries.keys()]) {
      if (liveEntry(videoId, now)) ids.push(videoId);
    }
    return ids;
  }

  function clear() {
    entries.clear();
  }

  global.MacIDMYouTubePlayerMetadata = Object.freeze({
    TTL_MS,
    MAX_ENTRIES,
    MAX_FORMATS,
    store,
    has,
    playerResponseFor,
    videoIds,
    clear,
  });
})(globalThis);
