// Shared YouTube in-page quality parsing module
// (docs/specifications/chrome-extension-spec.md §5.8).
//
// The Popup (via content-script message routing), the content script
// (direct call), and the overlay (direct in-page call) reuse this one
// implementation, eliminating the two-path split where "the overlay can
// parse but the Popup cannot". Classic script: loaded by the manifest
// content_scripts and by popup.html <script>; unit tests execute it
// directly in a vm.
//
// Data-flow constraints:
// - Read the current ytd-watch-flexy.playerData first, then
//   window.ytInitialPlayerResponse, and only then fall back to scanning
//   script tags;
// - After SPA navigation, the caller URL's video ID must match the player
//   response's videoId; never mix in the previous video's data;
// - Return only the normalized fields needed for qualities; never return
//   or persist the raw page response;
// - Variant URLs carry MacIDM's own fragment
//   `#height=<n>[&itag=<id>[&a=1]]` written via the URL object (wholly
//   replacing the page's original fragment such as `#t=90`), parsed by the
//   App/yt-dlp download backend to pin quality/codec exactly;
// - Keep the video+audio combined size-estimate semantics; leave it empty
//   when data is insufficient rather than fabricating precise values;
// - Parse results are short-lived in-memory data; never auto-create
//   download tasks.
(function installMacIDMYouTubeFormats(global) {
  if (global.MacIDMYouTubeFormats) return;

  // media-utils.js (earlier in manifest order) only exists by call time;
  // degrade safely to no estimation when absent in test environments.
  function mergedSizeEstimate(rawFormats, height, duration) {
    const fn = global.MacIDMMediaUtils?.estimateYouTubeMergedSize;
    return typeof fn === "function" ? fn(rawFormats, height, duration) ?? null : null;
  }

  function variantLabelFor(variant) {
    const fn = global.MacIDMMediaUtils?.variantDisplayLabel;
    return typeof fn === "function" ? fn(variant) ?? "" : "";
  }

  /// Extracts the video ID from a YouTube page URL (?v=, /shorts/<id>, or
  /// /live/<id>). Delegates first to media-utils.js's single decision entry
  /// point so the shallow (candidate synthesis) and deep (in-page parsing)
  /// rules agree; both reject bare paths with a missing ID (§4.5). Falls
  /// back to a local implementation with the same rules when media-utils is
  /// absent in test environments.
  function videoIdFromPageURL(value) {
    const shared = global.MacIDMMediaUtils?.youTubeVideoIDFromURL;
    if (typeof shared === "function") return shared(value) ?? null;
    try {
      const url = new URL(value);
      const isValidID = (id) => /^[A-Za-z0-9_-]{5,}$/.test(id || "");
      if (url.pathname === "/watch") {
        const v = url.searchParams.get("v");
        return isValidID(v) ? v : null;
      }
      const match = url.pathname.match(/^\/(?:shorts|live)\/([^/]+)/);
      if (match && isValidID(match[1])) return match[1];
    } catch {
      // fall through
    }
    return null;
  }

  /// Unified page identity: the correlation key for parse state is the
  /// videoId, not the changeable full URL. Returns the stable state key
  /// `youtube:<videoId>`; non-video pages return null. Used only to
  /// correlate state across the coordinator, Popup, and overlay — never
  /// rewrites the page URL actually submitted to the App, and never drops
  /// query params the user needs.
  function youTubeStateKey(value) {
    const id = videoIdFromPageURL(value);
    return id ? `youtube:${id}` : null;
  }

  /// The current page's player response. After SPA navigation,
  /// window.ytInitialPlayerResponse still belongs to the previous video;
  /// the current video's live data sits on the watch page's polymer
  /// component. Both are validated against the URL's video ID — a
  /// half-updated state must never mix two videos.
  function currentYouTubePlayerResponse(doc, loc) {
    try {
      const expectedID = new URLSearchParams(loc.search).get("v");
      const flexyData = doc.querySelector("ytd-watch-flexy")?.playerData;
      if (
        flexyData && typeof flexyData === "object" &&
        (!expectedID || flexyData.videoDetails?.videoId === expectedID)
      ) {
        return flexyData;
      }
      const live = global.ytInitialPlayerResponse;
      if (
        live && typeof live === "object" &&
        (!expectedID || live.videoDetails?.videoId === expectedID)
      ) {
        return live;
      }
    } catch {
      // Fall through to the script-tag scan.
    }
    return null;
  }

  /// Script-tag fallback: when the page has not exposed playerData yet,
  /// scan for the ytInitialPlayerResponse assignment script and extract
  /// the JSON object.
  function scanScriptsForPlayerResponse(doc) {
    try {
      const scripts = doc.querySelectorAll("script");
      for (const s of scripts) {
        const text = s.textContent || "";
        const marker = "ytInitialPlayerResponse = ";
        const idx = text.indexOf(marker);
        if (idx < 0) continue;
        const jsonStart = text.indexOf("{", idx);
        if (jsonStart < 0) continue;
        let depth = 0;
        let inString = false;
        let escape = false;
        let jsonEnd = -1;
        for (let i = jsonStart; i < text.length; i++) {
          const c = text[i];
          if (escape) {
            escape = false;
            continue;
          }
          if (c === "\\") {
            escape = true;
            continue;
          }
          if (c === '"') {
            inString = !inString;
            continue;
          }
          if (inString) continue;
          if (c === "{") depth++;
          else if (c === "}") {
            depth--;
            if (depth === 0) {
              jsonEnd = i + 1;
              break;
            }
          }
        }
        if (jsonEnd < 0) continue;
        return JSON.parse(text.substring(jsonStart, jsonEnd));
      }
    } catch {
      // Fall through
    }
    return null;
  }

  /// Duration comes from the player response's videoDetails.lengthSeconds
  /// (a string of seconds); used by variant tooltips and size estimation.
  function videoDurationFromPlayerResponse(pr) {
    const raw = pr?.videoDetails?.lengthSeconds;
    const seconds = Number(raw);
    return Number.isFinite(seconds) && seconds > 0 ? seconds : null;
  }

  /// In-page live-semantics classification (§3.1): based only on stable
  /// structured fields in the player response; never treat "formats exist"
  /// as equivalent to VOD (an active live stream also carries formats).
  /// Returns "currentlyLive" / "upcoming" / "replayNotReady" / "vod" /
  /// "unknown":
  /// - isLive === true → live right now;
  /// - isUpcomingLive === true → scheduled/upcoming live;
  /// - live content without downloadable tracks → replay not generated yet;
  /// - isLive/isUpcomingLive both explicitly false → finished replay or a
  ///   plain VOD;
  /// - modern responses often omit the isLive flags: an explicit
  ///   isLiveContent === false with downloadable tracks also structurally
  ///   rules out live/upcoming/live-replay, treated as VOD;
  /// - missing/contradictory flags (old pages/restricted responses) →
  ///   unknown; the caller must force a fallback to the App check.
  function livePhaseFromPlayerResponse(pr) {
    const details = pr?.videoDetails;
    if (!details || typeof details !== "object") return "unknown";
    if (details.isLive === true) return "currentlyLive";
    if (details.isUpcomingLive === true) return "upcoming";
    const streaming = pr?.streamingData;
    const hasFormats =
      (Array.isArray(streaming?.formats) && streaming.formats.length > 0)
      || (Array.isArray(streaming?.adaptiveFormats) && streaming.adaptiveFormats.length > 0);
    if (!hasFormats && details.isLiveContent === true) return "replayNotReady";
    if (details.isLive === false && details.isUpcomingLive === false) return "vod";
    if (details.isLiveContent === false && hasFormats) return "vod";
    return "unknown";
  }

  /// Whether a live phase must be blocked at inspection time (same
  /// semantics as the App's YouTubeLiveClassifier).
  function isBlockedLivePhase(phase) {
    return phase === "currentlyLive" || phase === "upcoming" || phase === "replayNotReady";
  }

  /// Video codec-family normalization: at the same height and container,
  /// different codec families (H.264/VP9/AV1/HEVC) are meaningfully
  /// different choices and must not be folded together; better/worse only
  /// applies within a family.
  function codecFamilyOf(codecs) {
    const video = String(codecs || "").split(",")[0].trim().toLowerCase();
    if (video.startsWith("avc1") || video.startsWith("avc")) return "h264";
    if (video.startsWith("vp09") || video.startsWith("vp9")) return "vp9";
    if (video.startsWith("av01") || video.startsWith("av1")) return "av1";
    if (video.startsWith("hev1") || video.startsWith("hvc1")) return "hevc";
    return video || "unknown";
  }

  /// Quality comparison within a group (height + container + codec family):
  /// higher fps wins, then higher bitrate on a tie; if both tie, keep the
  /// first seen. Progressive entries usually precede adaptive ones, so the
  /// old "keep the first entry" logic let low-fps/low-bitrate formats shadow
  /// better formats in the same family.
  function isBetterFormatThan(candidate, incumbent) {
    const candidateFps = candidate.fps || 0;
    const incumbentFps = incumbent.fps || 0;
    if (candidateFps !== incumbentFps) return candidateFps > incumbentFps;
    return (candidate.bitrate || 0) > (incumbent.bitrate || 0);
  }

  /// Converts ytInitialPlayerResponse into a video-track list (progressive
  /// + adaptive). Dedup strategy: group by height + container + codec
  /// family and keep the best fps/bitrate entry per group; different codec
  /// families (e.g. H.264 vs AV1 in 1080p MP4) always remain separate
  /// choices, and each chosen entry carries its exact itag unchanged (§4.3).
  function formatsFromPlayerResponse(pr) {
    if (!pr || !pr.streamingData) return null;
    const all = (pr.streamingData.formats || []).concat(
      pr.streamingData.adaptiveFormats || [],
    );
    const normalized = all
      .filter(function (f) {
        return f.width && f.height;
      })
      .map(function (f) {
        const mime = f.mimeType || "";
        const codecs = (mime.match(/codecs="([^"]+)"/) || [])[1] || "";
        const isWebm = mime.includes("webm");
        return {
          itag: f.itag,
          width: f.width,
          height: f.height,
          bitrate: f.bitrate,
          contentLength: f.contentLength,
          codecs: codecs,
          ext: isWebm ? "webm" : "mp4",
          fps: f.fps,
          // Progressive tracks (e.g. itag 18/22) carry their own audio;
          // the download side uses this to decide whether to add an m4a
          // track, avoiding a merged double audio track.
          hasAudio: /(?:mp4a|opus|vorbis|ac-3|ec-3)/.test(codecs),
        };
      });
    const best = {};
    for (const format of normalized) {
      const key = format.height + "_" + format.ext + "_" + codecFamilyOf(format.codecs);
      if (!best[key] || isBetterFormatThan(format, best[key])) {
        best[key] = format;
      }
    }
    const formats = Object.values(best).sort(function (a, b) {
      return b.height - a.height || (b.bitrate || 0) - (a.bitrate || 0);
    });
    return formats.length > 0 ? formats : null;
  }

  /// Raw streamingData tracks (progressive + adaptive, source-tagged) so
  /// the video+audio merged size estimate mirrors the App's mp4+m4a
  /// selector semantics.
  function rawFormatsFromPlayerResponse(pr) {
    if (!pr || !pr.streamingData) return [];
    const progressive = (pr.streamingData.formats || []).map((f) => ({ ...f, isAdaptive: false }));
    const adaptive = (pr.streamingData.adaptiveFormats || []).map((f) => ({ ...f, isAdaptive: true }));
    return progressive.concat(adaptive);
  }

  /// Converts the normalized format list into the variant list shared by
  /// Popup/overlay (same shape as the App's media.inspect variants). The
  /// variant URL writes MacIDM's own fragment
  /// `height=<n>[&itag=<id>[&a=1]]` via the URL object so the App/yt-dlp
  /// download backend pins the exact user-selected resolution and codec;
  /// the page's original fragment is replaced wholesale, never producing a
  /// double fragment like `#t=90#height=…`.
  function variantURL(pageURL, format) {
    const params = new URLSearchParams();
    params.set("height", String(format.height));
    if (/^\d{1,5}$/.test(String(format.itag ?? ""))) {
      params.set("itag", String(format.itag));
      if (format.hasAudio) params.set("a", "1");
    }
    try {
      const url = new URL(pageURL);
      url.hash = params.toString();
      return url.href;
    } catch {
      // Fallback when pageURL cannot be parsed: plain string concatenation
      // (no itag information).
      return `${pageURL}#height=${format.height}`;
    }
  }

  /// Per-track size estimate once the itag is validated: the video track's
  /// own size (contentLength, or bitrate×duration when missing) plus the
  /// best m4a audio track when it has none, mirroring the download side's
  /// `<itag>+ba[ext=m4a]` selector; without a usable itag, falls back to
  /// the resolution-based merged estimate.
  function mergedSizeEstimateForFormat(format, rawFormats, duration) {
    const fallback = mergedSizeEstimate(rawFormats, format.height, duration);
    if (!/^\d{1,5}$/.test(String(format.itag ?? ""))) return fallback;
    const contentLength = Number.parseInt(format.contentLength, 10);
    const videoSize = Number.isSafeInteger(contentLength) && contentLength > 0
      ? contentLength
      : format.bitrate && duration
        ? Math.round((format.bitrate * duration) / 8)
        : null;
    if (format.hasAudio) return videoSize ?? fallback;
    let audioSize = null;
    const audios = rawFormats.filter((r) => (r.mimeType || "").startsWith("audio/"));
    const m4a = audios.filter((r) => (r.mimeType || "").includes("mp4"));
    for (const audio of m4a.length ? m4a : audios) {
      const raw = Number.parseInt(audio.contentLength, 10);
      const size = Number.isSafeInteger(raw) && raw > 0
        ? raw
        : audio.bitrate && duration
          ? Math.round((audio.bitrate * duration) / 8)
          : null;
      if (size != null && (audioSize == null || size > audioSize)) audioSize = size;
    }
    if (videoSize == null && audioSize == null) return fallback;
    return (videoSize ?? 0) + (audioSize ?? 0);
  }

  function buildVariantsFromFormats(formats, rawFormats, duration, pageURL) {
    return formats.map((f) => {
      // The estimate uses the track the user actually picks (exact itag);
      // when the itag is missing, fall back to the resolution-based
      // estimate under the App's download convention (mp4 video + m4a
      // audio merge).
      const mergedSize = mergedSizeEstimateForFormat(f, rawFormats, duration);
      const variant = {
        url: variantURL(pageURL, f),
        // Stable dedup-key metadata (§5.3): the itag and has-audio flag
        // travel with the variant so the coordinator can merge
        // in-page/out-of-page results without relying on signed URLs.
        itag: /^\d{1,5}$/.test(String(f.itag ?? "")) ? f.itag : undefined,
        hasAudio: f.hasAudio === true,
        width: f.width,
        height: f.height,
        bandwidth: f.bitrate,
        codecs: f.codecs,
        estimatedSize: mergedSize ?? (f.contentLength ? Number.parseInt(f.contentLength, 10) : null),
        fileExtension: f.ext,
        fps: f.fps,
        duration: duration,
      };
      // Unified slot grammar (resolution · fps · codec family · bitrate);
      // the container format stays out of the label.
      variant.label = variantLabelFor(variant);
      return variant;
    });
  }

  /// In-page quality extraction entry point: reads the current page's
  /// player response and normalizes it into a variant list. Returns
  /// { ok: true, videoId, variants } or { ok: false, reason }.
  /// reason: "notYouTubePage" (caller URL is not a video page) /
  /// "noPlayerData" (no parsable player data on the page) /
  /// "urlMismatch" (page video differs from the requested URL, SPA race) /
  /// "noFormats" (player data has no usable video tracks) /
  /// "liveUnsupported" (live now/upcoming/replay not generated; blocked at
  /// inspection, §3.1) /
  /// "liveStatusUnknown" (live status unknowable; must fall back to the
  /// App check, §3.1).
  function extractPageQualities(pageURL) {
    const requestedID = videoIdFromPageURL(pageURL);
    if (!requestedID) {
      return { ok: false, reason: "notYouTubePage" };
    }
    const pr = currentYouTubePlayerResponse(document, global.location)
      || scanScriptsForPlayerResponse(document);
    if (!pr || typeof pr !== "object") {
      return { ok: false, reason: "noPlayerData" };
    }
    return resultFromPlayerResponse(pr, pageURL, requestedID);
  }

  /// Runs the same validation/normalization pipeline on an already-held
  /// player response object (including the bounded snapshot passed in via
  /// postMessage from the MAIN world bridge). The return shape is exactly
  /// that of extractPageQualities.
  function extractFromPlayerResponseObject(playerResponse, pageURL) {
    const requestedID = videoIdFromPageURL(pageURL);
    if (!requestedID) {
      return { ok: false, reason: "notYouTubePage" };
    }
    if (!playerResponse || typeof playerResponse !== "object") {
      return { ok: false, reason: "noPlayerData" };
    }
    return resultFromPlayerResponse(playerResponse, pageURL, requestedID);
  }

  /// Shared validation/normalization pipeline: video-ID consistency →
  /// live semantics → variant normalization.
  function resultFromPlayerResponse(pr, pageURL, requestedID) {
    // SPA navigation race: when the page has already moved to the next
    // video, reject the previous URL's request — never hand video B's data
    // to video A's candidate.
    const actualID = pr.videoDetails?.videoId;
    if (!actualID) {
      return { ok: false, reason: "noPlayerData" };
    }
    if (requestedID !== actualID) {
      return { ok: false, reason: "urlMismatch" };
    }
    // Live semantics come before quality parsing (§3.1): having formats
    // does not mean VOD; blocked phases go through the structured
    // unsupported flow, unknowable phases force an App/yt-dlp check, and
    // variants are never returned directly.
    const livePhase = livePhaseFromPlayerResponse(pr);
    if (isBlockedLivePhase(livePhase)) {
      return { ok: false, reason: "liveUnsupported", livePhase };
    }
    if (livePhase !== "vod") {
      return { ok: false, reason: "liveStatusUnknown", livePhase };
    }
    const formats = formatsFromPlayerResponse(pr);
    if (!formats) {
      return { ok: false, reason: "noFormats" };
    }
    const duration = videoDurationFromPlayerResponse(pr);
    const rawFormats = rawFormatsFromPlayerResponse(pr);
    return {
      ok: true,
      videoId: actualID,
      variants: buildVariantsFromFormats(formats, rawFormats, duration, pageURL),
    };
  }

  /// Stable variant dedup key: use the itag when present; otherwise
  /// height + container + codec family + fps + has-audio. Never dedup by
  /// the signed URL — signatures rotate for the same quality, and
  /// different qualities can share a signature pattern.
  function variantStableKey(variant) {
    if (/^\d{1,5}$/.test(String(variant?.itag ?? ""))) {
      return `itag:${variant.itag}`;
    }
    const family = codecFamilyOf(variant?.codecs);
    const hasAudio = variant?.hasAudio === true ? "a" : "v";
    return [
      "meta",
      variant?.height ?? 0,
      variant?.fileExtension ?? "",
      family,
      variant?.fps ?? 0,
      hasAudio,
    ].join(":");
  }

  /// Merges two variant lists by stable key (shared by in-page progressive
  /// completion and in-page/yt-dlp result merging). Same-key entries
  /// complement each other's fields: in-page size estimates and App-side
  /// labels/fields never overwrite one another; each only fills in fields
  /// the other lacks.
  function mergeVariantLists(existing, incoming) {
    const merged = new Map();
    const add = (variant) => {
      if (!variant || typeof variant !== "object") return;
      const key = variantStableKey(variant);
      const previous = merged.get(key);
      if (!previous) {
        merged.set(key, variant);
        return;
      }
      const filled = { ...previous };
      for (const [field, value] of Object.entries(variant)) {
        if (filled[field] == null && value != null) filled[field] = value;
      }
      merged.set(key, filled);
    };
    (Array.isArray(existing) ? existing : []).forEach(add);
    (Array.isArray(incoming) ? incoming : []).forEach(add);
    return [...merged.values()].sort(
      (a, b) => (b.height ?? 0) - (a.height ?? 0) || (b.bandwidth ?? 0) - (a.bandwidth ?? 0),
    );
  }

  /// Variant-set fingerprint: stable keys sorted and joined, so stability
  /// checks can compare sets for equality.
  function variantSetSignature(variants) {
    return (Array.isArray(variants) ? variants : [])
      .map(variantStableKey)
      .sort()
      .join("|");
  }

  function areVariantSetsEqual(a, b) {
    return variantSetSignature(a) === variantSetSignature(b);
  }

  /// §P2-2 shared failure mapping: a live block clearly identified in-page
  /// returns a structured unsupported result directly, reused by both the
  /// Popup and the overlay; it shows the existing localized copy (zh/en)
  /// and never passes through raw page text. The download layer's second
  /// live guard is unaffected: old tasks or submissions that bypassed the
  /// check are still re-checked by the Runner.
  function liveUnsupportedResolution(livePhase) {
    const t = globalThis.MacIDMI18n?.t;
    const message = typeof t === "function"
      ? t("protocol.error.mediaUnsupported")
      : "MEDIA_UNSUPPORTED";
    return {
      ok: false,
      reason: "liveUnsupported",
      livePhase,
      message,
      source: "page",
    };
  }

  /// Unified resolution flow: in-page first, App/yt-dlp as fallback.
  /// - requestPageQualities: returns the in-page parse result
  ///   ({ ok, variants } or null); a rejection counts as no in-page data;
  /// - requestAppInspection: returns a media.inspect-shaped result
  ///   ({ ok, variants, message?, timedOut? }).
  /// When in-page data is valid, App/yt-dlp is not called; when page data
  /// is missing, restricted, or unparsable, fall back to the App check.
  /// Exception: a live block clearly identified in-page short-circuits
  /// directly without triggering the 30–60s fallback (§P2-2). App/yt-dlp
  /// remains the fallback and the actual download backend.
  async function resolveYouTubeQualities({ pageUrl, requestPageQualities, requestAppInspection }) {
    if (typeof requestPageQualities === "function") {
      try {
        const pageResult = await requestPageQualities();
        if (
          pageResult?.ok === true &&
          Array.isArray(pageResult.variants) &&
          pageResult.variants.length > 0
        ) {
          return { ok: true, variants: pageResult.variants, source: "page" };
        }
        // Clearly identified live-now/upcoming/replay-not-ready: return the
        // structured unsupported result directly without calling the App
        // check; uncertain cases like liveStatusUnknown/noPlayerData/
        // urlMismatch keep falling back (§P2-2).
        if (pageResult?.ok === false && pageResult.reason === "liveUnsupported") {
          return liveUnsupportedResolution(pageResult.livePhase);
        }
      } catch {
        // In-page read failure (content script unreachable, etc.) → fall
        // back to the App.
      }
    }
    const result = await requestAppInspection();
    if (result?.ok === true && Array.isArray(result.variants)) {
      return { ok: true, variants: result.variants, source: "app" };
    }
    return {
      ok: false,
      timedOut: result?.timedOut === true,
      message: typeof result?.message === "string" ? result.message : undefined,
      source: "app",
    };
  }

  global.MacIDMYouTubeFormats = Object.freeze({
    videoIdFromPageURL,
    youTubeStateKey,
    currentYouTubePlayerResponse,
    scanScriptsForPlayerResponse,
    livePhaseFromPlayerResponse,
    isBlockedLivePhase,
    liveUnsupportedResolution,
    formatsFromPlayerResponse,
    rawFormatsFromPlayerResponse,
    extractPageQualities,
    extractFromPlayerResponseObject,
    variantStableKey,
    mergeVariantLists,
    variantSetSignature,
    areVariantSetsEqual,
    resolveYouTubeQualities,
  });
})(globalThis);
