// Reads duration and resolution using the browser media loader; HLS requires hls.js.
// The browser controls metadata byte ranges, so preload is not a strict byte budget.
(function installMediaMetadataProbe(global) {
  if (global.MacIDMMediaMetadataProbe) return;

  const MAX_CONCURRENT = 4;
  const PROBE_TIMEOUT_MS = 6_000;
  const MAX_CACHE_ENTRIES = 200;

  const cache = new Map(); // normalized url -> meta
  const inFlight = new Map(); // normalized URL -> shared queued/running operation

  function keyOf(url) {
    try {
      const u = new URL(url);
      u.hash = "";
      return u.href;
    } catch {
      return String(url || "");
    }
  }

  function isFinitePositive(n) {
    return typeof n === "number" && Number.isFinite(n) && n > 0;
  }

  function needsProbe(candidate) {
    if (!candidate || typeof candidate.url !== "string") return false;
    if (!/^https?:/i.test(candidate.url)) return false;
    if (candidate.supported === false || candidate.siteAdapter || candidate.pairKind) return false;
    if (candidate.format === "image" || String(candidate.mime || "").startsWith("image/")) return false;
    if (candidate.format === "dash" || candidate.format === "dash-json") return false;
    if (cached(keyOf(candidate.url))) return false;
    // Already has duration AND resolution: nothing authoritative to add.
    if (isFinitePositive(candidate.duration) && candidate.width && candidate.height) return false;
    return true;
  }

  function store(url, meta) {
    const key = keyOf(url);
    if (cache.size >= MAX_CACHE_ENTRIES) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    cache.set(key, meta);
    return meta;
  }

  function cached(url) {
    return cache.get(keyOf(url)) ?? null;
  }

  function probeDirect(url, registerCancel) {
    return new Promise((resolve) => {
      const video = global.document?.createElement?.("video");
      if (!video) return resolve(null);
      let settled = false;
      const timer = global.setTimeout(() => finish(null), PROBE_TIMEOUT_MS);
      function finish(meta) {
        if (settled) return;
        settled = true;
        global.clearTimeout(timer);
        try {
          video.removeAttribute("src");
          video.load?.();
        } catch {
          // Best-effort release.
        }
        resolve(meta);
      }
      registerCancel(() => finish(null));
      video.preload = "metadata";
      video.muted = true;
      video.playsInline = true;
      video.addEventListener("loadedmetadata", () => {
        finish({
          duration: isFinitePositive(video.duration) ? video.duration : null,
          width: video.videoWidth || 0,
          height: video.videoHeight || 0,
          codec: "",
          bitrate: null,
          variants: null,
        });
      });
      video.addEventListener("error", () => finish(null));
      video.src = url;
    });
  }

  function bestLevel(levels) {
    if (!Array.isArray(levels) || levels.length === 0) return null;
    return levels.slice().sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
  }

  function probeHls(url, registerCancel) {
    return new Promise((resolve) => {
      const Hls = global.Hls;
      const video = global.document?.createElement?.("video");
      if (!Hls || typeof Hls.isSupported !== "function" || !Hls.isSupported() || !video) {
        return resolve(null);
      }
      let hls = null;
      let settled = false;
      let meta = null;
      const timer = global.setTimeout(() => finish(meta), PROBE_TIMEOUT_MS);
      function finish(result) {
        if (settled) return;
        settled = true;
        global.clearTimeout(timer);
        try { hls?.destroy?.(); } catch { /* ignore */ }
        try {
          video.removeAttribute("src");
          video.load?.();
        } catch { /* ignore */ }
        resolve(result);
      }
      try {
        registerCancel(() => finish(null));
        hls = new Hls({ enableWorker: false });
        hls.on(Hls.Events.MANIFEST_PARSED, (_event, data) => {
          const levels = (data?.levels || []).map((level) => ({
            width: level.width || 0,
            height: level.height || 0,
            bitrate: level.bitrate || 0,
            videoCodec: level.videoCodec || "",
            audioCodec: level.audioCodec || "",
          }));
          const best = bestLevel(levels);
          meta = {
            duration: null,
            width: best?.width || 0,
            height: best?.height || 0,
            codec: best?.videoCodec || "",
            bitrate: best?.bitrate || null,
            variants: levels.length > 0 ? levels : null,
          };
        });
        hls.on(Hls.Events.LEVEL_LOADED, (_event, data) => {
          const total = data?.details?.totalduration;
          if (meta && isFinitePositive(total)) meta.duration = total;
          finish(meta);
        });
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (data?.fatal) finish(meta);
        });
        hls.loadSource(url);
        hls.attachMedia(video);
      } catch {
        finish(null);
      }
    });
  }

  function isHls(candidate) {
    return candidate?.format === "hls" || /\.m3u8(?:[?#]|$)/i.test(candidate.url || "");
  }

  // Each URL has one operation and independent subscribers. UI cancellation
  // only stops the resource when its final subscriber leaves.
  let active = 0;
  let releasing = false;
  let suspended = false;
  const MAX_QUEUED = 200;

  function settle(entry, meta) {
    if (inFlight.get(entry.key) !== entry) return;
    inFlight.delete(entry.key);
    for (const subscriber of entry.subscribers) subscriber.finish(meta);
    entry.subscribers.clear();
  }

  function pump() {
    if (releasing || suspended) return;
    while (active < MAX_CONCURRENT) {
      const queued = [...inFlight.values()].filter(entry => entry.state === "queued");
      const entry = queued.find(entry => entry.priority === "interactive") ?? queued[0];
      if (!entry || (entry.priority !== "interactive" && active >= MAX_CONCURRENT - 1)) return;
      entry.state = "running";
      active += 1;
      const registerCancel = cancel => { entry.cancel = cancel; };
      Promise.resolve().then(() => {
        if (entry.cancelled) return null;
        return isHls(entry.candidate)
          ? probeHls(entry.key, registerCancel)
          : probeDirect(entry.key, registerCancel);
      }).catch(() => null).then(meta => {
        if (entry.cancelled) return;
        if (meta) store(entry.key, meta);
        settle(entry, meta);
      }).finally(() => { active -= 1; pump(); });
    }
  }

  function subscribe(candidate, priority, signal) {
    const key = keyOf(candidate.url);
    if (signal?.aborted || suspended) return Promise.resolve(null);
    const hit = cache.get(key);
    if (hit) return Promise.resolve(hit);
    let entry = inFlight.get(key);
    if (!entry) {
      if (inFlight.size >= MAX_QUEUED + MAX_CONCURRENT) return Promise.resolve(null);
      entry = { key, candidate, priority, state: "queued", subscribers: new Set(), cancelled: false };
      inFlight.set(key, entry);
    } else if (priority === "interactive") {
      entry.priority = priority;
    }
    return new Promise(resolve => {
      let finished = false;
      const subscriber = {
        finish(meta) {
          if (finished) return;
          finished = true;
          signal?.removeEventListener?.("abort", abort);
          resolve(meta);
        },
      };
      const abort = () => {
        entry.subscribers.delete(subscriber);
        subscriber.finish(null);
        if (!entry.subscribers.size) {
          entry.cancelled = true;
          inFlight.delete(key);
          entry.cancel?.();
          pump();
        }
      };
      entry.subscribers.add(subscriber);
      signal?.addEventListener?.("abort", abort, { once: true });
      pump();
    });
  }

  async function probeCandidates(candidates, { onResult, priority = "background", signal } = {}) {
    const eligible = (Array.isArray(candidates) ? candidates : [])
      .filter(candidate => needsProbe(candidate) || (candidate?.url && cached(candidate.url)));
    return Promise.all(eligible.map(async candidate => {
      const meta = await subscribe(candidate, priority, signal);
      const result = { url: candidate.url, meta };
      if (!signal?.aborted) { try { onResult?.(result); } catch {} }
      return result;
    }));
  }

  function releaseAll() {
    releasing = true;
    for (const entry of [...inFlight.values()]) {
      entry.cancelled = true;
      entry.cancel?.();
      settle(entry, null);
    }
    releasing = false;
  }
  global.addEventListener?.("pagehide", () => { suspended = true; releaseAll(); });
  global.addEventListener?.("pageshow", () => { suspended = false; });

  global.MacIDMMediaMetadataProbe = Object.freeze({
    cached,
    needsProbe,
    probeCandidates,
    store,
    releaseAll,
  });
})(globalThis);
