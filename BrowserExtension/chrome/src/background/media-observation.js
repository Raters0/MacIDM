import { t } from "../shared/i18n-access.js";
import "../shared/youtube-format-utils.js";

export const BACKGROUND_MEDIA_TTL_MS = 2 * 60 * 1_000;
export const BACKGROUND_MEDIA_PER_ORIGIN_LIMIT = 100;

export function httpOrigin(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    return url.origin;
  } catch {
    return null;
  }
}

export function isHttpURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function rememberBackgroundCandidate(
  buckets,
  initiatorURL,
  candidate,
  now = Date.now(),
  ttlMs = BACKGROUND_MEDIA_TTL_MS,
  limit = BACKGROUND_MEDIA_PER_ORIGIN_LIMIT,
) {
  const origin = httpOrigin(initiatorURL);
  if (!origin || !candidate || typeof candidate.url !== "string") return false;
  pruneBackgroundCandidates(buckets, now);
  const bucket = buckets.get(origin) ?? { expiresAt: now + ttlMs, candidates: new Map() };
  bucket.expiresAt = now + ttlMs;
  bucket.candidates.set(candidate.url, { ...candidate });
  while (bucket.candidates.size > limit) {
    const first = bucket.candidates.keys().next().value;
    if (first === undefined) break;
    bucket.candidates.delete(first);
  }
  buckets.set(origin, bucket);
  return true;
}

export function takeBackgroundCandidates(
  buckets,
  pageURL,
  now = Date.now(),
) {
  pruneBackgroundCandidates(buckets, now);
  const origin = httpOrigin(pageURL);
  if (!origin) return [];
  const bucket = buckets.get(origin);
  return bucket ? [...bucket.candidates.values()].map((candidate) => ({ ...candidate })) : [];
}

export function pruneBackgroundCandidates(buckets, now = Date.now()) {
  for (const [origin, bucket] of buckets) {
    if (!bucket || bucket.expiresAt <= now) buckets.delete(origin);
  }
}

export function normalizeFilteredSummary(raw) {
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

export function normalizeFileExtension(value) {
  if (typeof value !== "string") return null;
  const extension = value.replace(/^\.+/u, "").trim().toLowerCase();
  return /^[a-z0-9]{1,8}$/u.test(extension) ? extension : null;
}

export const KNOWN_MEDIA_EXTENSIONS = new Set([
  "m3u8", "mpd", "mp4", "m4v", "webm", "mov", "mp3", "m4a", "aac", "flac",
  "ogg", "m4s", "ts", "mp2t", "mkv", "avi", "wmv", "flv", "opus", "wav",
]);

export function extensionFromCandidate(candidate) {
  try {
    const lastPathComponent = new URL(String(candidate?.url ?? "")).pathname.split("/").pop() ?? "";
    const extension = lastPathComponent.includes(".")
      ? lastPathComponent.split(".").pop()?.toLowerCase() ?? ""
      : "";
    if (KNOWN_MEDIA_EXTENSIONS.has(extension)) {
      return extension;
    }
  } catch {
    // MIME and semantic fallback below.
  }
  const mime = String(candidate?.mime ?? "").toLowerCase().split(";")[0].trim();
  const mimeMap = {
    "application/vnd.apple.mpegurl": "m3u8",
    "application/x-mpegurl": "m3u8",
    "application/dash+xml": "mpd",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/mp2t": "ts",
    "video/x-matroska": "mkv",
    "video/x-flv": "flv",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/aac": "aac",
    "audio/ogg": "ogg",
    "audio/opus": "opus",
    "audio/wav": "wav",
    "audio/flac": "flac",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/svg+xml": "svg",
    "image/bmp": "bmp",
    "image/x-icon": "ico",
    "image/vnd.microsoft.icon": "ico",
    "image/tiff": "tiff",
    "image/heic": "heic",
    "image/heif": "heif",
  };
  if (mimeMap[mime]) return mimeMap[mime];
  if (mime.includes("mpegurl")) return "m3u8";
  if (mime.includes("dash+xml")) return "mpd";
  if (mime.startsWith("video/mp4")) return "mp4";
  if (mime.startsWith("video/webm")) return "webm";
  if (mime.startsWith("video/")) return "mp4";
  if (mime.startsWith("audio/")) return "m4a";
  if (candidate?.format === "hls") return "m3u8";
  if (candidate?.format === "dash") return "mpd";
  if (candidate?.format === "blob") return "";
  return "";
}

export function normalizeCandidates(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((candidate) => {
      const url = String(candidate?.url ?? "");
      return url.startsWith("blob:") || isHttpURL(url);
    })
    .slice(0, 100)
    .map((candidate) => {
      const normalized = {
        url: String(candidate.url),
        mime: String(candidate.mime ?? "").slice(0, 256),
        format: ["hls", "dash", "dash-json", "video", "audio", "image", "blob"].includes(candidate.format)
          ? candidate.format
          : "video",
        fileExtension: normalizeFileExtension(candidate.fileExtension)
          ?? extensionFromCandidate(candidate),
        supported: candidate.supported !== false && !String(candidate.url).startsWith("blob:"),
        displayName: String(candidate.displayName ?? t("common.mediaResource")).slice(0, 80),
        displayURL: String(candidate.displayURL ?? t("common.mediaResource")).slice(0, 512),
        size:
          Number.isSafeInteger(candidate.size) && candidate.size >= 0
            ? Math.min(candidate.size, Number.MAX_SAFE_INTEGER)
            : null,
        duration: Number.isFinite(candidate.duration) && candidate.duration > 0
          ? candidate.duration
          : undefined,
        filenameHint:
          typeof candidate.filenameHint === "string"
            ? candidate.filenameHint.slice(0, 255)
            : undefined,
      };
      if (["dom", "headers", "magic", "fetch", "extension"].includes(candidate.confidence)) {
        normalized.confidence = candidate.confidence;
      }
      if (candidate.pairKind === "m4s-pair" || candidate.pairKind === "m4s-fragment") {
        normalized.pairKind = candidate.pairKind;
      }
      if (isHttpURL(candidate.pairVideoUrl)) {
        normalized.pairVideoUrl = String(candidate.pairVideoUrl);
      }
      if (isHttpURL(candidate.pairAudioUrl)) {
        normalized.pairAudioUrl = String(candidate.pairAudioUrl);
      }
      if (typeof candidate.pairCid === "string" && candidate.pairCid) {
        normalized.pairCid = candidate.pairCid.slice(0, 32);
      }
      if (typeof candidate.pairNote === "string" && candidate.pairNote) {
        normalized.pairNote = candidate.pairNote.slice(0, 120);
      }
      if (candidate.collapsed === true) normalized.collapsed = true;
      if (typeof candidate.qualityLabel === "string") {
        normalized.qualityLabel = candidate.qualityLabel.slice(0, 60);
      }
      if (candidate.siteAdapter === "bilibili" || candidate.siteAdapter === "youtube") {
        normalized.siteAdapter = candidate.siteAdapter;
      }
      if (candidate.sizeProbeFailed === true) normalized.sizeProbeFailed = true;
      if (candidate.pairKind === "stream-segment") normalized.pairKind = "stream-segment";
      if (typeof candidate.segmentExtension === "string" && candidate.segmentExtension) {
        normalized.segmentExtension = normalizeFileExtension(candidate.segmentExtension);
      }
      if (Number.isSafeInteger(candidate.segmentCount) && candidate.segmentCount > 0) {
        normalized.segmentCount = Math.min(candidate.segmentCount, 100_000);
      }
      return normalized;
    });
}

export function mergeCandidates(existing, incoming) {
  const seen = new Map();
  const merged = [];
  for (const candidate of [...existing, ...incoming]) {
    const url = candidate.url;
    if (seen.has(url)) {
      const index = seen.get(url);
      const earlier = merged[index];
      const earlierHasSize = Number.isSafeInteger(earlier?.size) && earlier.size >= 0;
      const candidateHasSize = Number.isSafeInteger(candidate?.size) && candidate.size >= 0;
      if (!earlierHasSize && candidateHasSize) {
        merged[index] = candidate;
      }
      continue;
    }
    seen.set(url, merged.length);
    merged.push(candidate);
  }
  return merged.slice(0, 100);
}

function videoIdOf(url) {
  return globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(url) ?? "";
}

export function mergeTabMediaCache(existing, incoming, frameId = 0) {
  if (!incoming || typeof incoming !== "object") return existing ?? null;
  const isMainFrame = frameId === 0;

  const incomingCandidates = Array.isArray(incoming.candidates)
    ? normalizeCandidates(incoming.candidates)
    : [];
  const incomingPageUrl = isHttpURL(incoming.pageUrl) ? incoming.pageUrl : null;
  const rawIncomingTitle = typeof incoming.title === "string" ? incoming.title.trim().slice(0, 300) : "";

  // 1. Determine pageUrl.
  const pageUrl = isMainFrame && incomingPageUrl
    ? incomingPageUrl
    : (existing?.pageUrl ?? incomingPageUrl);

  // 2. Candidate merge: when the main frame carries a siteAdapter
  // (bilibili/youtube), the main frame wins; otherwise merge as a deduped
  // URL union.
  const hasSiteAdapterCandidate = incomingCandidates.some(
    (candidate) => candidate.siteAdapter === "bilibili" || candidate.siteAdapter === "youtube",
  );
  const candidates = isMainFrame && hasSiteAdapterCandidate
    ? incomingCandidates
    : mergeCandidates(existing?.candidates ?? [], incomingCandidates);

  // 3. Video identity and generation-change detection.
  const prevVideoId = videoIdOf(existing?.pageUrl);
  const incVideoId = videoIdOf(incomingPageUrl);
  const isYouTubeTransition = Boolean((prevVideoId || incVideoId) && prevVideoId !== incVideoId);
  const isSameYouTubeVideo = Boolean(prevVideoId && incVideoId && prevVideoId === incVideoId);

  // 4. Title merge decision.
  const prevTitle = typeof existing?.title === "string" ? existing.title.trim().slice(0, 300) : "";
  let title = "";

  if (!isMainFrame) {
    // iframe updates must never rewrite the main-frame title.
    title = prevTitle;
  } else if (isYouTubeTransition) {
    // YouTube generation change (A→B, video→home/non-video,
    // home/non-video→video): never fall back to the old video's cached
    // title! If the incoming title equals the old video's title, treat it
    // as stale tabs.title data and reject it.
    const isStaleFromPrevVideo = Boolean(prevTitle && rawIncomingTitle && rawIncomingTitle.toLowerCase() === prevTitle.toLowerCase());
    if (rawIncomingTitle.length >= 3 && !isStaleFromPrevVideo) {
      title = rawIncomingTitle;
    } else {
      title = "";
    }
  } else if (isSameYouTubeVideo) {
    // Same YouTube video (query/fragment change or periodic polling):
    // update when a valid new title arrives; keep the existing confirmed
    // title when the incoming title is empty.
    title = rawIncomingTitle.length >= 3 ? rawIncomingTitle : prevTitle;
  } else {
    // Non-YouTube page: match by exact URL.
    const isExactSamePage = Boolean(incomingPageUrl && existing?.pageUrl && incomingPageUrl === existing.pageUrl);
    if (rawIncomingTitle.length >= 3) {
      title = rawIncomingTitle;
    } else if (isExactSamePage) {
      title = prevTitle;
    } else {
      title = "";
    }
  }

  // 5. Filter-count summary.
  const incomingSummary = isMainFrame && incoming.filteredSummary != null
    ? normalizeFilteredSummary(incoming.filteredSummary)
    : null;
  const filteredSummary = incomingSummary ?? existing?.filteredSummary ?? { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };

  return {
    pageUrl,
    title,
    candidates,
    filteredSummary,
  };
}

export function buildSafeYouTubeCandidate(pageUrl) {
  const localizedTitle = t("media.youtubeVideo") || "YouTube video";
  return {
    url: pageUrl,
    mime: "video/mp4",
    format: "video",
    fileExtension: "mp4",
    supported: true,
    displayName: localizedTitle,
    displayURL: pageUrl,
    size: null,
    filenameHint: `${localizedTitle}.mp4`,
    siteAdapter: "youtube",
    inspecting: true,
  };
}

export function alignMediaTabStateWithLiveURL(cached, livePageUrl) {
  const liveIsHttp = isHttpURL(livePageUrl);
  const targetPageUrl = liveIsHttp ? livePageUrl : (isHttpURL(cached?.pageUrl) ? cached.pageUrl : null);
  const liveVideoId = videoIdOf(targetPageUrl);
  const cachedVideoId = videoIdOf(cached?.pageUrl);

  const fallbackSummary = { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };

  if (liveVideoId) {
    // Live URL is a YouTube video (e.g. video B):
    const isSameVideo = Boolean(cached && cachedVideoId && cachedVideoId === liveVideoId);
    if (isSameVideo) {
      // Cached data belongs to the current video B (possibly differing only
      // by query/fragment): keep the resolved variants and sizes, and align
      // the primary candidate URL and pageUrl to the live URL.
      const candidates = (Array.isArray(cached.candidates) ? cached.candidates : [])
        .map((candidate) => {
          if (candidate.siteAdapter === "youtube" && videoIdOf(candidate.url) === liveVideoId) {
            return { ...candidate, url: targetPageUrl };
          }
          return candidate;
        })
        .filter((candidate) => {
          if (candidate.siteAdapter === "youtube") {
            return videoIdOf(candidate.url) === liveVideoId;
          }
          return true;
        });

      return {
        ok: true,
        pageUrl: targetPageUrl,
        title: typeof cached.title === "string" ? cached.title : "",
        candidates: candidates.length > 0 ? candidates : [buildSafeYouTubeCandidate(targetPageUrl)],
        filteredSummary: cached.filteredSummary ?? fallbackSummary,
      };
    }

    // Cached data is for old video A, a non-video, or absent:
    // never return A's title / candidates / size! Return video B's safe
    // initial adapter candidate.
    return {
      ok: true,
      pageUrl: targetPageUrl,
      title: "",
      candidates: [buildSafeYouTubeCandidate(targetPageUrl)],
      filteredSummary: fallbackSummary,
    };
  }

  // Live URL is a non-YouTube-video page or a non-video page:
  if (targetPageUrl) {
    if (cachedVideoId) {
      // Was a YouTube video, now the YouTube home page or another page:
      // clear the video state.
      return {
        ok: true,
        pageUrl: targetPageUrl,
        title: "",
        candidates: [],
        filteredSummary: fallbackSummary,
      };
    }
    const isExactSamePage = Boolean(cached && cached.pageUrl && cached.pageUrl === targetPageUrl);
    if (isExactSamePage) {
      return {
        ok: true,
        pageUrl: targetPageUrl,
        title: typeof cached.title === "string" ? cached.title : "",
        candidates: Array.isArray(cached.candidates) ? cached.candidates : [],
        filteredSummary: cached.filteredSummary ?? fallbackSummary,
      };
    }
    return {
      ok: true,
      pageUrl: targetPageUrl,
      title: "",
      candidates: [],
      filteredSummary: fallbackSummary,
    };
  }

  return {
    ok: true,
    pageUrl: null,
    title: "",
    candidates: [],
    filteredSummary: fallbackSummary,
  };
}
