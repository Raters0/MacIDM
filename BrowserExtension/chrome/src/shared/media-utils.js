(function installMediaUtils(global) {
  // i18n loads after this script in the manifest, but every call site runs
  // later at runtime, so a lazy lookup is safe. Missing i18n falls back to
  // the raw key (tests load the catalogs via i18n-access.js).
  function t(key, params) {
    return global.MacIDMI18n?.t(key, params) ?? key;
  }

  const mediaPattern = /\.(?:m3u8|mpd|mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mp2t|mkv|avi|wmv|flv|opus|wav)(?:$|[?#])/iu;
  const knownExtensions = new Set([
    "m3u8", "mpd", "mp4", "m4v", "webm", "mov", "mp3", "m4a", "aac", "flac",
    "ogg", "m4s", "ts", "mp2t", "mkv", "avi", "wmv", "flv", "opus", "wav",
  ]);
  // Images are downloadable media too: their format label and filename must
  // never degrade to "unknown format".
  const imageExtensions = new Set([
    "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "bmp", "ico", "tiff", "heic", "heif",
  ]);

  function normalizeHTTPURL(value, baseURL) {
    try {
      const url = new URL(value, baseURL);
      url.hash = "";
      return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
    } catch {
      return null;
    }
  }

  // An explicit list of tracking/promotional params (conservative on
  // purpose): only these are removed; every other param — including x_
  // signature-style params and unknown params — is kept, because it may be
  // required for the download.
  function isTrackingParam(name) {
    const lower = String(name).toLowerCase();
    if (lower.startsWith("utm_")) return true;
    if (lower.startsWith("share_")) return true;
    return ["fbclid", "gclid", "gopvid", "spm"].includes(lower);
  }

  /// Normalized URL used purely as a dedup key: strips well-known tracking
  /// query params (utm_*, fbclid, gclid, gopvid, spm, share_*) and the
  /// fragment. The display/original URL is never affected. Returns the input
  /// string unchanged for values that cannot be parsed as http(s) URLs.
  function normalizeResourceURL(value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "http:" && url.protocol !== "https:") return String(value);
      for (const key of [...url.searchParams.keys()]) {
        if (isTrackingParam(key)) url.searchParams.delete(key);
      }
      url.hash = "";
      return url.href;
    } catch {
      return String(value);
    }
  }

  function mimeTypeFromURL(value) {
    try {
      const url = new URL(value);
      const mime = url.searchParams.get("mime") || url.searchParams.get("type") || "";
      return mime.trim().toLowerCase();
    } catch {
      return "";
    }
  }

  function mediaFormat(value, mime = "") {
    const lower = String(value).toLowerCase();
    const type = String(mime || mimeTypeFromURL(value)).toLowerCase();
    if (/\.m3u8(?:$|[?#])/iu.test(lower) || type.includes("mpegurl")) return "hls";
    if (/\.mpd(?:$|[?#])/iu.test(lower) || type.includes("dash+xml")) return "dash";
    if (type.startsWith("image/") || /\.(?:jpg|jpeg|png|gif|webp|avif|svg|bmp|ico|tiff|heic|heif)(?:$|[?#])/iu.test(lower)) {
      return "image";
    }
    if (type.startsWith("audio/") || /\.(?:mp3|m4a|aac|flac|ogg|opus|wav)(?:$|[?#])/iu.test(lower)) {
      return "audio";
    }
    return "video";
  }

  // Return the actual container/playlist extension shown to the user. The
  // semantic media kind ("video"/"audio") is still kept separately for the
  // bridge protocol, but it is too vague for a resource inspector.
  // MIME-to-extension mapping used by both mediaExtension and the
  // normalizeMediaCandidate fallback. This is a technical detection based
  // on the HTTP Content-Type header, not URL guessing.
  const MIME_EXTENSIONS = {
    "application/vnd.apple.mpegurl": "m3u8",
    "application/x-mpegurl": "m3u8",
    "application/dash+xml": "mpd",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/mp2t": "ts",
    "video/x-msvideo": "avi",
    "video/x-matroska": "mkv",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/aac": "aac",
    "audio/ogg": "ogg",
    "audio/opus": "opus",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
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

  function mimeToExtension(mime) {
    if (!mime) return "";
    const type = String(mime).toLowerCase().split(";", 1)[0].trim();
    if (MIME_EXTENSIONS[type]) return MIME_EXTENSIONS[type];
    if (type.includes("mpegurl")) return "m3u8";
    if (type.includes("dash+xml")) return "mpd";
    return "";
  }

  function mediaExtension(value, mime = "", format = "") {
    try {
      const url = new URL(value);
      const extension = url.pathname.split("/").pop()?.split(".").pop()?.toLowerCase() || "";
      if (knownExtensions.has(extension)) return extension;
      if (imageExtensions.has(extension)) return extension;
      // Unknown short extensions (e.g. "me" from hanime1.me, "io" from
      // agedm.io) are discarded by falling through to the MIME/mediaPattern
      // fallback below.
    } catch {
      // MIME and semantic format below are still useful for extension-less URLs.
    }
    const type = String(mime || mimeTypeFromURL(value)).toLowerCase().split(";", 1)[0].trim();
    if (MIME_EXTENSIONS[type]) return MIME_EXTENSIONS[type];
    if (type.includes("mpegurl")) return "m3u8";
    if (type.includes("dash+xml")) return "mpd";
    if (format === "hls") return "m3u8";
    if (format === "dash") return "mpd";
    if (format === "blob") return "blob";
    // B1: Fallback — when the URL path has no recognized extension and the
    // MIME is unknown, check mediaPattern for a media extension embedded
    // elsewhere in the full URL (e.g. a redirect URL whose query string
    // contains a media URL ending in .mp4 or .m3u8).
    try {
      const match = String(value).match(mediaPattern);
      if (match) {
        const matched = match[0].slice(1).replace(/[?#].*$/u, "").toLowerCase();
        if (matched && knownExtensions.has(matched)) return matched;
      }
    } catch {
      // ignore
    }
    return "";
  }

  function redactedURL(value) {
    if (String(value).startsWith("blob:")) return "blob:";
    try {
      const url = new URL(value);
      url.username = "";
      url.password = "";
      url.search = "";
      url.hash = "";
      return url.href;
    } catch {
      return t("common.mediaResource");
    }
  }

  function shortName(value) {
    try {
      const url = new URL(value);
      return decodeURIComponent(url.pathname.split("/").pop() || url.hostname).slice(0, 80);
    } catch {
      return t("common.mediaResource");
    }
  }

  // Bilibili m4s format_id → human-readable quality. Video tracks use
  // 100xxx (AVC) / 101xxx (HEVC) / 30xxx (AV1); audio tracks use 302xx.
  const bilibiliVideoQuality = {
    30016: "360P", 30032: "480P", 30064: "720P", 30066: "720P",
    30080: "1080P", 30112: "1080P+", 30116: "1080P60",
    30121: "1080P HDR", 30125: "1080P HDR", 30126: "1080P60",
    30077: "720P", 30078: "1080P",
    30127: "1080P60 HDR", 30128: "4K HDR",
    30129: "6K", 30130: "8K",
  };
  const bilibiliVideoCodec = (formatId) => {
    const id = String(formatId);
    if (id.startsWith("100")) return "H.264";
    if (id.startsWith("101")) return "H.265";
    if (id.startsWith("30")) return "AV1";
    return "";
  };
  const bilibiliAudioQuality = {
    30216: "64K", 30232: "132K", 30280: "192K",
    30250: "Dolby", 30251: "Hi-Res",
  };

  const resolutionTier = (h) => ({
    4320: "8K", 2160: "4K", 1440: "2K", 1080: "1080P",
    720: "720P", 480: "480P", 360: "360P",
  }[h] ?? "");

  function resolutionLabel(w, h) {
    // Standard heights use tier labels; encoders commonly pad the height to
    // a multiple of 16, so 1088 is really 1080p. Non-standard resolutions
    // fall back to W×H.
    const tier = resolutionTier(h) || (h % 16 === 8 ? resolutionTier(h - 8) : "");
    if (tier) return tier;
    return `${w}×${h}`;
  }

  /// Unified codec family names (matching the App's MediaVariantLabel):
  /// only the family is shown; FourCC details like avc1.640033 stay out of
  /// the presentation layer. Unknown codecs return "".
  function codecFamily(codecs) {
    const primary = String(codecs ?? "").split(",")[0].trim().toLowerCase();
    if (!primary) return "";
    if (primary.startsWith("avc1")) return "H.264";
    if (primary.startsWith("hev1") || primary.startsWith("hvc1")) return "H.265";
    if (primary.startsWith("av01")) return "AV1";
    if (primary.startsWith("vp09") || primary.startsWith("vp9")) return "VP9";
    if (primary.startsWith("mp4a")) return "AAC";
    if (primary.startsWith("opus")) return "Opus";
    if (primary.startsWith("ac-3") || primary.startsWith("ac3")) return "AC-3";
    if (primary.startsWith("ec-3") || primary.startsWith("ec3")) return "E-AC-3";
    return "";
  }

  /// Unified variant label grammar (matching the App side):
  /// {resolution} · {fps} · {codec family} · {bitrate}; missing slots are
  /// skipped with no "unknown" placeholders; size and container format stay
  /// out of the label. Returns "" when no information is available.
  function variantDisplayLabel(variant) {
    if (!variant) return "";
    const parts = [];
    const width = Number(variant.width) || 0;
    const height = Number(variant.height) || 0;
    if (width > 0 && height > 0) parts.push(resolutionLabel(width, height));
    else if (height > 0) parts.push(`${height}p`);
    if (variant.fps > 0) parts.push(`${Math.round(variant.fps)}fps`);
    const family = codecFamily(variant.codecs);
    if (family) parts.push(family);
    const bandwidth = Number(variant.bandwidth) || 0;
    // Matching the App side: below 1 kbps nothing is shown (avoids "0 kbps"
    // noise).
    if (bandwidth >= 1000) {
      const mbps = bandwidth / 1_000_000;
      parts.push(mbps >= 1 ? `${mbps.toFixed(1)} Mbps` : `${Math.round(bandwidth / 1000)} kbps`);
    }
    return parts.join(" · ");
  }

  /// Extract a human-readable quality/variant label from a media URL or
  /// candidate. Returns "" when no meaningful info can be inferred.
  function qualityLabel(candidate) {
    if (!candidate) return "";
    const url = candidate.url;
    if (!url || typeof url !== "string") return "";

    // Bilibili m4s format_id → quality + codec
    const m4sInfo = extractM4sInfo(url);
    if (m4sInfo) {
      if (m4sInfo.kind === "audio") {
        return bilibiliAudioQuality[m4sInfo.formatId]
          ? t("media.audioQuality", { quality: bilibiliAudioQuality[m4sInfo.formatId] })
          : t("media.audio");
      }
      const q = bilibiliVideoQuality[m4sInfo.formatId] || "";
      const codec = bilibiliVideoCodec(m4sInfo.formatId);
      return [q, codec].filter(Boolean).join(" · ") || t("media.formatId", { id: m4sInfo.formatId });
    }

    try {
      const u = new URL(url);
      // Resolution in path: /720x1280/ (X/Twitter, generic HLS, CDNs)
      const resMatch = u.pathname.match(/(\d{3,5})x(\d{3,5})/);
      if (resMatch) {
        const w = parseInt(resMatch[1], 10);
        const h = parseInt(resMatch[2], 10);
        const label = resolutionLabel(w, h);
        // X.com/Twitter: extract codec family from path (avc1/hev1)
        const codecMatch = u.pathname.match(/\/(avc1|hev1|hvc1|av01|vp09)\//i);
        const codec = codecMatch ? codecFamily(codecMatch[1]) : "";
        // X.com/Twitter: bitrate from path segment /br/XXXX or query
        const brMatch = u.pathname.match(/\/br\/(\d+)/);
        const bitrate = brMatch ? brMatch[1] : (u.searchParams.get("bitrate") || u.searchParams.get("br"));
        const parts = [label];
        if (codec) parts.push(codec);
        if (bitrate) parts.push(`${bitrate} kbps`);
        return parts.join(" · ");
      }
      // Query params: bitrate / height (only accept numeric values)
      const bitrate = u.searchParams.get("bitrate") || u.searchParams.get("br");
      if (bitrate && /^\d{2,8}$/u.test(bitrate)) return `${bitrate} kbps`;
      const height = u.searchParams.get("height") || u.searchParams.get("h");
      if (height && /^\d{2,5}$/u.test(height)) return `${height}P`;
      // itag (YouTube googlevideo): map to known quality
      const itag = u.searchParams.get("itag");
      if (itag) {
        const itagQuality = {
          18: "360P", 22: "720P", 37: "1080P", 38: "3072P",
          133: "240P", 134: "360P", 135: "480P", 136: "720P",
          137: "1080P", 138: "2160P", 160: "144P", 264: "1440P",
          266: "2160P", 298: "720P60", 299: "1080P60",
          302: "720P60", 303: "1080P60", 308: "1440P60",
          313: "2160P", 315: "2160P60", 330: "144P HDR",
          331: "240P HDR", 332: "360P HDR", 333: "480P HDR",
          334: "720P HDR", 335: "1080P HDR", 336: "1440P HDR",
          337: "2160P HDR",
        };
        return itagQuality[itag] || `itag ${itag}`;
      }
      // X.com amplify/ext_tw video: codec family in path without resolution
      const codecOnly = u.pathname.match(/\/(avc1|hev1|hvc1|av01|vp09)\//i);
      if (codecOnly) return codecFamily(codecOnly[1]);
    } catch {
      // ignore
    }
    return "";
  }

  /// Unified display name used by both Popup and Overlay. Avoids the
  /// "Title · Title.mp4" duplication that happened when filenameHint was
  /// already derived from the page title.
  function smartMediaName(candidate, pageTitle = "", candidateCount = 1) {
    const base = String(pageTitle || "").trim().slice(0, 120);
    const hint = String(candidate?.filenameHint ?? "").trim();
    if (base) {
      // If filenameHint already starts with the page title, don't duplicate.
      if (hint && hint.toLowerCase().startsWith(base.toLowerCase())) {
        return hint;
      }
      const generic = /^(index|master|playlist|media|video|audio|manifest)\b/i.test(hint);
      return generic || candidateCount <= 1 ? base : `${base} · ${hint}`;
    }
    return hint || candidate?.displayName || t("common.mediaResource");
  }
  /// Extracts {cid, formatId, kind} from a Bilibili m4s filename. Bilibili
  /// audio-track format_ids start with 302 (30216/30232/30280…); the rest
  /// are video tracks (100xxx AVC / 101xxx HEVC / 30xxx AV1). Returns null
  /// when unrecognized.
  function extractM4sInfo(value) {
    try {
      const u = new URL(value);
      if (u.protocol !== "http:" && u.protocol !== "https:") return null;
      const filename = decodeURIComponent(u.pathname.split("/").pop() ?? "");
      const match = filename.match(/^(\d+)-1-(\d+)\.m4s$/iu);
      if (!match) return null;
      const cid = match[1];
      const formatId = Number.parseInt(match[2], 10);
      const kind = match[2].startsWith("302") ? "audio" : "video";
      return { cid, formatId, kind };
    } catch {
      return null;
    }
  }

  // m4s with the same cid+kind collapse into one entry in the content
  // script, so dozens of same-named fragments cannot push real candidates
  // out of the list. Non-m4s returns null.
  function m4sGroupKey(value) {
    const info = extractM4sInfo(value);
    return info ? `m4s:${info.cid}:${info.kind}` : null;
  }

  function pairM4sCandidates(candidates, pageTitle = "") {
    if (!Array.isArray(candidates)) return [];
    const others = [];
    const groups = new Map();
    for (const candidate of candidates) {
      if (candidate?.pairKind === "m4s-pair" && normalizeHTTPURL(candidate.pairVideoUrl) && normalizeHTTPURL(candidate.pairAudioUrl)) {
        others.push(candidate);
        continue;
      }
      const info = extractM4sInfo(candidate?.url);
      if (!info) {
        others.push(candidate);
        continue;
      }
      const group = groups.get(info.cid) ?? { video: [], audio: [] };
      group[info.kind].push({ candidate, formatId: info.formatId });
      groups.set(info.cid, group);
    }
    const paired = [];
    const fragments = [];
    for (const [cid, group] of groups) {
      if (group.video.length > 0 && group.audio.length > 0) {
        const video = [...group.video].sort((a, b) => b.formatId - a.formatId)[0].candidate;
        const audio = [...group.audio].sort((a, b) => b.formatId - a.formatId)[0].candidate;
        const base = sanitizePairFilename(String(pageTitle).trim() || t("m4s.videoFallback", { cid }));
        paired.push({
          ...video,
          format: "video",
          fileExtension: "mp4",
          displayName: (String(pageTitle).trim() || t("m4s.videoFallback", { cid })).slice(0, 80),
          filenameHint: `${base}.mp4`.slice(0, 255),
          size: null,
          pairKind: "m4s-pair",
          pairVideoUrl: video.url,
          pairAudioUrl: audio.url,
          pairCid: cid,
          pairNote: t("common.pairNoteMerge"),
          collapsed: false,
        });
      } else {
        for (const { candidate } of [...group.video, ...group.audio]) {
          fragments.push({
            ...candidate,
            format: "video",
            pairKind: "m4s-fragment",
            pairCid: cid,
            pairNote: t("common.fragmentIncomplete"),
            collapsed: true,
          });
        }
      }
    }
    return [...others, ...paired, ...fragments];
  }

  function sanitizePairFilename(value) {
    const cleaned = String(value)
      .replace(/[/\\:*?"<>|]+/gu, "-")
      .replace(/\s+/gu, " ")
      .trim()
      .replace(/^\.+|\.+$/gu, "")
      .slice(0, 230);
    return cleaned || "media";
  }

  function mediaFilename(value, format = "video", fallback = "media") {
    try {
      const url = new URL(value);
      const rawName = decodeURIComponent(url.pathname.split("/").pop() || fallback);
      // Strip playlist extensions that are not the final container.
      const name = rawName
        .replace(/\.(?:m3u8|mpd)$/iu, "")
        .replace(/[^a-z0-9._-]+/giu, "-")
        .replace(/^-+|-+$/gu, "");
      const defaultExtension = format === "audio" ? "m4a" : format === "image" ? "jpg" : "mp4";
      // Only keep the existing extension if it is a recognized media or
      // image extension. This prevents domain suffixes like ".me" (hanime1.me),
      // ".vip" (18comic.vip), or ".io" (agedm.io) from leaking into filenames.
      const extMatch = name.match(/\.([a-z0-9]{1,8})$/iu);
      const extLower = extMatch ? extMatch[1].toLowerCase() : "";
      const hasKnownExtension = extMatch
        && (knownExtensions.has(extLower) || imageExtensions.has(extLower));
      if (hasKnownExtension) {
        // Limit stem length and re-append the validated extension to avoid
        // truncation cutting mid-extension on very long filenames. The stem
        // ends where the matched extension begins, so the extension is never
        // duplicated ("photo.jpg.jpg").
        const ext = extLower;
        const rawStem = name.slice(0, extMatch.index);
        const stem = rawStem.slice(0, Math.max(1, 230 - ext.length - 1));
        const stemClean = stem.replace(/\.+$/u, "");
        return `${stemClean || fallback}.${ext}`;
      }
      // Strip any unrecognized trailing extension before appending the correct one.
      const stripped = extMatch ? name.slice(0, extMatch.index) : name;
      const baseName = (stripped || fallback).slice(0, 230);
      return `${baseName}.${defaultExtension}`;
    } catch {
      return `media.${format === "audio" ? "m4a" : "mp4"}`;
    }
  }

  function normalizeMediaCandidate(raw, baseURL) {
    const rawURL = String(raw?.url ?? "");
    const isBlob = rawURL.startsWith("blob:");
    const isMSE = rawURL.startsWith("mse:");
    const url = isBlob || isMSE ? rawURL : normalizeHTTPURL(rawURL, baseURL);
    if (!url) return null;
    const mime = String(raw?.mime || mimeTypeFromURL(rawURL)).slice(0, 256);
    const format = isBlob || isMSE ? "blob" : mediaFormat(url, mime);
    // For MSE/blob players, infer the container from the MIME type rather
    // than showing "blob" (which renders as "Unknown format" in the UI). The
    // content-script sets mime "video/mp4" for MSE players it cannot inspect.
    let fileExtension;
    if (isBlob || isMSE) {
      const mimeLower = mime.toLowerCase().split(";")[0].trim();
      if (mimeLower.startsWith("audio/")) fileExtension = "m4a";
      else if (mimeLower.includes("mpegurl")) fileExtension = "m3u8";
      else if (mimeLower.includes("dash")) fileExtension = "mpd";
      else if (mimeLower.includes("webm")) fileExtension = "webm";
      else fileExtension = "mp4";
    } else {
      fileExtension = mediaExtension(url, mime, format);
      // When the URL has no detectable extension but the MIME is a
      // video/audio type, use the MIME to determine the container format.
      // This relies on the actual HTTP Content-Type header captured by the
      // webRequest listener, not on URL path guessing.
      if (!fileExtension && mime) {
        const mimeLower = mime.toLowerCase().split(";")[0].trim();
        if (mimeLower.startsWith("audio/")) {
          fileExtension = mimeToExtension(mimeLower) || "m4a";
        } else if (mimeLower.startsWith("video/")) {
          fileExtension = mimeToExtension(mimeLower) || "mp4";
        }
      }
    }
    const size = Number.isSafeInteger(raw?.size) && raw.size >= 0 ? raw.size : null;
    const duration =
      typeof raw?.duration === "number" && Number.isFinite(raw.duration) && raw.duration > 0
        ? raw.duration
        : null;
    return {
      url,
      mime,
      format,
      fileExtension,
      supported: !isBlob && !isMSE,
      displayName: isMSE ? t("media.msePlayer") : shortName(url),
      displayURL: isMSE ? "mse:" : redactedURL(url),
      size,
      duration,
      filenameHint: isMSE ? "media.mp4" : mediaFilename(url, format),
      qualityLabel: isBlob || isMSE ? "" : qualityLabel({ url, mime, format, fileExtension }),
    };
  }

  function coalesceMediaCandidates(candidates, pageTitle = "", pageURL = "") {
    if (!Array.isArray(candidates)) return [];
    const isYouTubePage = isYouTubePageURL(pageURL);
    let paired = pairM4sCandidates(candidates, pageTitle).filter(
      (candidate) => !isYouTubePlayerNoiseCandidate(candidate, isYouTubePage),
    );
    // MSE/blob placeholders (url "mse:player" or "blob:*") are only useful
    // when no real HTTP(S) stream URLs have been discovered yet. Once real
    // candidates exist, the placeholder just adds noise ("Unsupported") to the UI.
    const hasRealCandidates = paired.some(
      (c) => c && typeof c.url === "string" && c.url.startsWith("http"),
    );
    if (hasRealCandidates) {
      paired = paired.filter(
        (c) => !(typeof c.url === "string" && (c.url.startsWith("mse:") || c.url.startsWith("blob:"))),
      );
    }
    // YouTube's current web player serves SABR/UMP streams whose responses
    // carry `application/vnd.yt-ump` — invisible to response sniffing — so
    // no googlevideo candidate may ever be observed, especially after an SPA
    // navigation clears the cache before the new stream starts. On watch
    // pages always present one page-level candidate for the dedicated
    // extractor instead of relying on observed (and guaranteed-to-fail)
    // direct URLs.
    if (isYouTubeWatchPage(pageURL)) {
      const title = String(pageTitle).trim() || t("media.youtubeVideo");
      const base = sanitizePairFilename(title);
      return [{
        url: pageURL,
        mime: "text/html",
        format: "video",
        fileExtension: "mp4",
        supported: true,
        displayName: title.slice(0, 80),
        displayURL: redactedURL(pageURL),
        size: null,
        filenameHint: `${base}.mp4`.slice(0, 255),
        siteAdapter: "youtube",
        pairNote: t("media.youtubePairNote"),
        collapsed: false,
      }];
    }
    const manifestHosts = new Set(
      paired
        .filter((candidate) => candidate?.format === "hls" || candidate?.format === "dash")
        .map((candidate) => hostOf(candidate.url))
        .filter(Boolean),
    );
    const isBilibiliPage = isBilibiliPageURL(pageURL);
    const hasM4sPair = paired.some((candidate) => candidate?.pairKind === "m4s-pair");
    const hasDashJson = paired.some((candidate) => candidate?.format === "dash-json");
    // On Bilibili pages the adapter is the only deterministic primary
    // candidate: whether an observed pair forms depends on playback timing,
    // so letting it suppress adapter synthesis would make the same page
    // oscillate between having and lacking a quality menu, and different
    // observation timings would each produce a different set. Pairing is
    // demoted to a fallback for pages the adapter does not cover.
    const hasBilibiliAdapter = isBilibiliPage
      && !paired.some((candidate) => candidate?.siteAdapter === "bilibili");
    // Evidence-driven convergence (site-agnostic): once a complete pair, a
    // playurl-style dash-json, or a site adapter exists, same-family stray
    // single-track candidates and incomplete fragments are noise (incomplete
    // when downloaded alone), so they fold into one segment group instead of
    // flooding the list. Without evidence they may be the only clue, so they
    // stay as-is.
    const collapseStrays = isBilibiliPage || hasM4sPair || hasDashJson;
    const kept = [];
    const segmentGroups = new Map();
    const manifestKeys = new Set();

    if (hasBilibiliAdapter) {
      const title = String(pageTitle).trim() || t("common.bilibiliMedia");
      const base = sanitizePairFilename(title);
      kept.push({
        url: pageURL,
        mime: "text/html",
        format: "video",
        fileExtension: "mp4",
        supported: true,
        displayName: title.slice(0, 80),
        displayURL: redactedURL(pageURL),
        size: null,
        filenameHint: `${base}.mp4`.slice(0, 255),
        siteAdapter: "bilibili",
        pairNote: t("common.bilibiliPairNote"),
        collapsed: false,
      });
    }

    const coveredCIDs = new Set(paired.filter(c => c?.pairKind === "m4s-pair").map(c => c.pairCid));
    for (const candidate of paired) {
      // Suppress only evidence belonging to the adapter or an existing pair.
      if (isBilibiliPage && !candidate?.siteAdapter && isBilibiliStreamCandidate(candidate)) continue;
      if (candidate?.pairKind === "m4s-fragment" && coveredCIDs.has(candidate.pairCid)) continue;
      if (candidate?.siteAdapter === "bilibili") {
        kept.push(candidate);
        continue;
      }
      if (candidate?.format === "hls" || candidate?.format === "dash") {
        const key = manifestIdentity(candidate.url, candidate.format);
        if (manifestKeys.has(key)) continue;
        manifestKeys.add(key);
      }
      if (
        collapseStrays
        && candidate?.pairKind !== "m4s-pair"
        && (isBilibiliStreamCandidate(candidate) || extractM4sInfo(candidate?.url))
      ) {
        addSegmentGroup(segmentGroups, candidate);
        continue;
      }
      if (isLikelyStreamSegment(candidate, manifestHosts, pageURL)) {
        addSegmentGroup(segmentGroups, candidate);
        continue;
      }
      kept.push(candidate);
    }

    for (const group of segmentGroups.values()) {
      kept.push(buildSegmentGroupCandidate(group, pageTitle));
    }
    return kept;
  }

  function isLikelyStreamSegment(candidate, manifestHosts, pageURL) {
    const extension = mediaExtension(candidate?.url, candidate?.mime, candidate?.format);
    if (["m4s", "ts", "mp2t"].includes(extension)) {
      return manifestHosts.has(hostOf(candidate?.url)) || hostOf(candidate?.url) === hostOf(pageURL);
    }
    // X and similar HLS players sometimes request tiny .mp4 bootstrap/media
    // fragments without a segment-specific suffix. Only collapse them when a
    // manifest from the same host is already present, avoiding false positives
    // for a genuinely small standalone video.
    return extension === "mp4"
      && Number.isSafeInteger(candidate?.size)
      && candidate.size <= 16 * 1024
      && manifestHosts.has(hostOf(candidate?.url));
  }

  function isBilibiliStreamCandidate(candidate) {
    if (candidate?.pairKind === "m4s-pair") return false;
    const host = hostOf(candidate?.url);
    if (!host || !/(?:^|\.)bilivideo\.com$/iu.test(host)) return false;
    return true;
  }

  // Only pages the App's BilibiliPlayurlAdapter.supports can parse count as
  // "Bilibili pages": /video/BV|av, /bangumi/play/ss|ep, and the watch-later
  // list page /list/watchlater/?bvid=…&oid=… embedding the same player (the
  // video identity lives in query params and updates on SPA video switches).
  // This check must match the same-named implementation in
  // background/m4s-pairing.js verbatim, or the Popup and the overlay will
  // produce two different candidate sets.
  function isBilibiliPageURL(value) {
    const raw = String(value ?? "");
    if (/^https?:\/\/(?:[^./]+\.)*bilibili\.com\/(?:video|bangumi\/play)\//iu.test(raw)) return true;
    return isBilibiliWatchlaterURL(raw);
  }

  // A list page only qualifies when it carries a parsable video identity:
  // bvid=BV… takes priority; a purely numeric oid/avid is accepted when
  // missing. A bare list page without an identity synthesizes no site
  // candidate, to avoid treating the whole list as one video.
  function isBilibiliWatchlaterURL(value) {
    let url;
    try { url = new URL(String(value ?? "")); } catch { return false; }
    const host = url.hostname.toLowerCase().replace(/^www\./u, "");
    if (host !== "bilibili.com" && !host.endsWith(".bilibili.com")) return false;
    if (!/^\/list\/watchlater\/?$/iu.test(url.pathname)) return false;
    const bvid = url.searchParams.get("bvid") ?? "";
    if (/^BV[0-9A-Za-z]+$/u.test(bvid)) return true;
    const oid = url.searchParams.get("oid") ?? url.searchParams.get("avid") ?? "";
    return /^\d+$/u.test(oid);
  }

  function manifestIdentity(value, format = "") {
    try {
      const url = new URL(value);
      return `${format}:${url.hostname.toLowerCase()}${url.pathname.replace(/\/+$/u, "")}`;
    } catch {
      return `${format}:${String(value)}`;
    }
  }

  function isYouTubePageURL(value) {
    try {
      const hostname = new URL(value).hostname.toLowerCase().replace(/^www\./u, "");
      return hostname === "youtube.com" || hostname.endsWith(".youtube.com");
    } catch {
      return false;
    }
  }

  /// The single entry point for YouTube video IDs (unified rule, §4.5):
  /// `/watch?v=<id>`, `/shorts/<id>`, `/live/<id>`, and `youtu.be/<id>`;
  /// a missing ID (e.g. bare `/watch` or `/live/`) always returns null, so
  /// the shallow and deep checks agree — no more error-category drift where
  /// the shallow layer accepts and the deep layer rejects.
  function youTubeVideoIDFromURL(value) {
    const isValidID = (id) => /^[A-Za-z0-9_-]{5,}$/u.test(id || "");
    try {
      const url = new URL(value);
      const host = url.hostname.toLowerCase().replace(/^www\./u, "");
      if (host === "youtu.be") {
        const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
        return isValidID(id) ? id : null;
      }
      if (host !== "youtube.com" && !host.endsWith(".youtube.com")) return null;
      if (url.pathname === "/watch") {
        const v = url.searchParams.get("v");
        return isValidID(v) ? v : null;
      }
      const match = url.pathname.match(/^\/(?:shorts|live)\/([^/]+)/u);
      return match && isValidID(match[1]) ? match[1] : null;
    } catch {
      return null;
    }
  }

  // True for pages that actually play a single video: /watch?v=…, shared
  // youtu.be/<id> links, /shorts/<id> and /live/<id>. Channel/home pages
  // must not synthesize an extractor candidate.
  function isYouTubeWatchPage(value) {
    return youTubeVideoIDFromURL(value) != null;
  }

  function isYouTubePlayerNoiseCandidate(candidate, isYouTubePage) {
    if (!isYouTubePage || !candidate || candidate.format !== "audio") return false;
    try {
      const url = new URL(candidate.url);
      const hostname = url.hostname.toLowerCase().replace(/^www\./u, "");
      if (hostname !== "youtube.com" && !hostname.endsWith(".youtube.com")) return false;
      const filename = decodeURIComponent(url.pathname.split("/").pop() || "").toLowerCase();
      return url.pathname.includes("/s/player/")
        || ["failure.mp3", "no_input.mp3", "open.mp3", "success.mp3"].includes(filename);
    } catch {
      return false;
    }
  }

  function isYouTubeGoogleVideoCandidate(candidate) {
    if (!candidate) return false;
    try {
      const url = new URL(candidate.url);
      const host = url.hostname.toLowerCase().replace(/^www\./u, "");
      return host === "googlevideo.com"
        || (host.endsWith(".googlevideo.com") && url.pathname.includes("/videoplayback"));
    } catch {
      return false;
    }
  }

  function addSegmentGroup(groups, candidate) {
    const extension = mediaExtension(candidate?.url, candidate?.mime, candidate?.format) || "unknown";
    const host = hostOf(candidate?.url) || "media";
    const key = host;
    const group = groups.get(key) ?? { extension, extensions: new Set(), host, candidates: [] };
    group.extensions.add(extension);
    group.candidates.push(candidate);
    groups.set(key, group);
  }

  function buildSegmentGroupCandidate(group, pageTitle) {
    const first = group.candidates[0];
    const extension = [...(group.extensions ?? new Set([group.extension]))].join("/");
    const primaryExtension = group.extension;
    const count = group.candidates.length;
    const base = sanitizePairFilename(String(pageTitle).trim() || t("common.streamFallbackName"));
    return {
      ...first,
      format: first.format === "audio" ? "audio" : "video",
      fileExtension: extension,
      displayName: t("common.fragmentName", { title: String(pageTitle).trim() || t("common.streamFallbackName"), format: extension.toUpperCase() }).slice(0, 80),
      filenameHint: `${base}.${primaryExtension}`.slice(0, 255),
      displayURL: t("common.fragmentGroupURL", { url: first.displayURL || t("common.mediaResource"), count }).slice(0, 512),
      size: null,
      supported: false,
      pairKind: "stream-segment",
      segmentExtension: extension,
      segmentCount: count,
      pairNote: t("common.fragmentNote", { count, format: extension.toUpperCase() }),
      collapsed: true,
    };
  }

  function hostOf(value) {
    try { return new URL(value).hostname.toLowerCase(); } catch { return ""; }
  }

  // Intelligently resolve the best page title from available metadata.
  // Different sites place the "real" content title in different locations:
  // some use og:title for the video name while document.title carries site
  // branding, and vice-versa. This scorer prefers the title that looks most
  // like specific content rather than a generic site name.
  function resolvePageTitle(doc = document) {
    // YouTube SPA navigation never refreshes the og:title meta tag, so the
    // generic scorer below would keep the previous video's title forever.
    // The live player object always knows the current video.
    try {
      if (isYouTubeWatchPage(location.href)) {
        const playerTitle =
          doc.querySelector("ytd-watch-flexy")?.playerData?.videoDetails?.title ||
          doc.getElementById("movie_player")?.getVideoData?.()?.title ||
          "";
        const trimmed = String(playerTitle).trim();
        if (trimmed.length >= 2) return trimmed.slice(0, 200);
        const docOnly = (doc.title || "").replace(/\s*-\s*YouTube\s*$/iu, "").trim();
        if (docOnly.length >= 2) return docOnly.slice(0, 200);
      }
    } catch {
      // Fall back to the generic scorer.
    }
    let ogTitle = "";
    let twitterTitle = "";
    if (typeof doc.querySelector === "function") {
      ogTitle =
        doc.querySelector('meta[property="og:title"]')?.getAttribute("content") || "";
      twitterTitle =
        doc.querySelector('meta[name="twitter:title"]')?.getAttribute("content") || "";
    }
    const docTitle = doc.title || "";

    const candidates = [ogTitle, twitterTitle, docTitle]
      .map((t) => t.trim().replace(/\s+/g, " "))
      .filter((t) => t.length >= 2);
    if (candidates.length === 0) return "";

    let hostname = "";
    try {
      hostname = location.hostname.replace(/^www\./iu, "");
    } catch {
      hostname = "";
    }
    // Extract the recognizable site token from the hostname (e.g. "hanime1"
    // from "hanime1.me", "agedm" from "agedm.io") for branding detection.
    const siteToken = hostname.split(".")[0].toLowerCase();

    let best = candidates[0];
    let bestScore = -Infinity;
    for (const title of candidates) {
      let score = 0;
      const lower = title.toLowerCase();
      // Penalize titles that contain the site token — likely branding.
      if (siteToken.length >= 3 && lower.includes(siteToken)) score -= 4;
      // Penalize many separators — pattern "Content - Sub - Site Name".
      const separators = (title.match(/\s+[-–—|·]\s+/gu) || []).length;
      score -= separators;
      // Slight preference for longer, more descriptive titles.
      score += Math.min(title.length, 120) / 40;
      if (score > bestScore) {
        bestScore = score;
        best = title;
      }
    }
    return best.slice(0, 200);
  }

  /// Estimate the total download size for a media variant. For HLS this is
  /// computed as SUM(segment duration * bandwidth / 8). Returns null when
  /// not enough information is available to produce a meaningful estimate.
  function estimateVariantSize(variant) {
    if (!variant) return null;
    // HLS: SUM(segment duration * bandwidth / 8)
    if (Array.isArray(variant.segments) && variant.segments.length > 0) {
      const bandwidth = Number(variant.bandwidth) || 0;
      if (bandwidth > 0) {
        const totalDuration = variant.segments.reduce(
          (sum, seg) => sum + (Number(seg?.duration) || 0),
          0,
        );
        if (totalDuration > 0) {
          return Math.round((totalDuration * bandwidth) / 8);
        }
      }
    }
    // Fallback: use total duration * bandwidth when a segments array is
    // not available but the caller supplied an aggregate duration.
    const duration = Number(variant.duration) || 0;
    const bandwidth = Number(variant.bandwidth) || 0;
    if (duration > 0 && bandwidth > 0) {
      return Math.round((duration * bandwidth) / 8);
    }
    return null;
  }

  /// Estimate the merged download size of a YouTube video, mirroring the
  /// App's format selector `bv*[ext=mp4]+ba[ext=m4a]`: the best MP4 video
  /// track at height<=heightCap plus the best M4A audio track. `formats` is
  /// the raw streamingData list where every entry carries an `isAdaptive`
  /// tag (adaptiveFormats=true, progressive formats=false). Progressive
  /// tracks already mux audio in, so they never add an audio track on top.
  /// Exact contentLength wins; missing values fall back to duration*bitrate.
  function estimateYouTubeMergedSize(formats, heightCap, durationSeconds) {
    if (!Array.isArray(formats) || formats.length === 0) return null;
    const duration = Number(durationSeconds) || 0;
    const trackSize = (f) => {
      const exact = parseInt(f?.contentLength, 10);
      if (Number.isSafeInteger(exact) && exact > 0) return exact;
      const bitrate = Number(f?.bitrate) || 0;
      if (duration > 0 && bitrate > 0) return Math.round((duration * bitrate) / 8);
      return null;
    };

    const cap = Number(heightCap) || 0;
    const videos = formats.filter((f) => (Number(f?.height) || 0) > 0 && (cap <= 0 || f.height <= cap));
    if (videos.length === 0) return null;
    const isWebm = (f) => String(f?.mimeType || "").includes("webm");
    // The selector's `bv*` prefers video-only (adaptive) tracks; audio is
    // already muxed into progressive picks, so those never add a track.
    const videoOnly = videos.filter((f) => f.isAdaptive);
    const progressive = videos.filter((f) => !f.isAdaptive);
    const byQuality = (a, b) =>
      (Number(b?.height) || 0) - (Number(a?.height) || 0)
      || (Number(b?.bitrate) || 0) - (Number(a?.bitrate) || 0);
    const best = (pool) => pool.slice().sort(byQuality)[0];
    const preferMp4 = (pool) => {
      const mp4 = pool.filter((f) => !isWebm(f));
      return mp4.length > 0 ? mp4 : pool;
    };

    const audioAddition = () => {
      const audios = formats.filter((f) => !(Number(f?.height) || 0) && !(Number(f?.width) || 0));
      const m4a = preferMp4(audios);
      const audio = best(m4a);
      return trackSize(audio) ?? 0;
    };

    // Selector order: mp4 video-only (+audio), mp4 progressive,
    // any video-only (+audio), any progressive.
    const mp4VideoOnly = best(preferMp4(videoOnly));
    if (mp4VideoOnly) {
      const size = trackSize(mp4VideoOnly);
      if (size != null) return size + audioAddition();
    }
    const mp4Progressive = best(preferMp4(progressive));
    if (mp4Progressive) {
      const size = trackSize(mp4Progressive);
      if (size != null) return size;
    }
    const anyVideoOnly = best(videoOnly);
    if (anyVideoOnly) {
      const size = trackSize(anyVideoOnly);
      if (size != null) return size + audioAddition();
    }
    return trackSize(best(progressive));
  }

  /// Candidate discovery-confidence ranking (written by the content
  /// script): dom (direct DOM read) > headers (response-header confirmed)
  /// > magic (body magic-number/JSON deep scan) > fetch (URL capture)
  /// > extension (extension-only/Performance inference). Unknown sources
  /// return 0.
  const CONFIDENCE_RANK = { dom: 5, headers: 4, magic: 3, fetch: 2, extension: 1 };

  function confidenceRank(value) {
    return CONFIDENCE_RANK[value] ?? 0;
  }

  /// Display priority (consistent across sites): what users want from the
  /// sniff panel is usually video/audio; decorative page images (avatars/
  /// emoji) go last. Lower values sort first:
  /// 0 = site-adapter candidates (the page's primary candidate, always on
  ///     top — it carries quality selection and official parse results and
  ///     must never be pushed down by an observed candidate on confidence;
  ///     on Bilibili, misreported analytics candidates once took the top
  ///     rows and buried the primary candidate mid-list);
  /// 1 = pairings and manifests among video kinds (paired m4s, HLS/DASH
  ///     manifests);
  /// 2 = other video kinds (video MIME, blob/MSE players);
  /// 3 = audio; 4 = other direct links; 5 = images.
  function displayPriority(candidate) {
    const format = candidate?.format;
    const mime = String(candidate?.mime ?? "").toLowerCase();
    const url = String(candidate?.url ?? "");
    if (candidate?.siteAdapter) return 0;
    if (candidate?.pairKind === "m4s-pair") return 1;
    if (format === "hls" || format === "dash" || format === "dash-json") return 1;
    if (format === "video" || mime.startsWith("video/")) return 2;
    if (url.startsWith("blob:") || url.startsWith("mse:")) return 2;
    if (format === "audio" || mime.startsWith("audio/")) return 3;
    if (format === "image" || mime.startsWith("image/")) return 5;
    return 4;
  }

  /// Panel display sort: first by media-type priority (site-adapter primary
  /// candidates on top, video/audio before, images last), then by discovery
  /// confidence descending within the same priority, using a stable sort
  /// that preserves the relative order of ties. Shared by the Popup and the
  /// overlay so both surfaces agree on ordering.
  function sortCandidatesForDisplay(candidates) {
    if (!Array.isArray(candidates)) return candidates;
    return candidates
      .map((candidate, index) => ({ candidate, index }))
      .sort((a, b) => {
        const byPriority = displayPriority(a.candidate) - displayPriority(b.candidate);
        if (byPriority !== 0) return byPriority;
        const byConfidence = confidenceRank(b.candidate?.confidence) - confidenceRank(a.candidate?.confidence);
        if (byConfidence !== 0) return byConfidence;
        return a.index - b.index;
      })
      .map((entry) => entry.candidate);
  }

  /// Unified byte-size display (aligned with the App's ByteCountFormatter
  /// .file decimal convention): KB rounded to an integer, MB at most 1
  /// decimal, GB/TB at most 2 decimals, trailing zeros stripped; units stop
  /// at TB; a value that rounds up to 1000 promotes to the next unit, TB
  /// does not. Invalid/missing input returns null, keeping overlay/popup/
  /// download-all formatting consistent.
  function formatBytes(value) {
    if (!Number.isSafeInteger(value) || value < 0) return null;
    if (value < 1000) return `${value} B`;
    const units = ["KB", "MB", "GB", "TB"];
    const decimals = [0, 1, 2, 2];
    let size = value;
    let unitIndex = -1;
    while (size >= 1000 && unitIndex < units.length - 1) {
      size /= 1000;
      unitIndex += 1;
    }
    let rounded = Number(size.toFixed(decimals[unitIndex]));
    if (rounded >= 1000 && unitIndex < units.length - 1) {
      unitIndex += 1;
      size = rounded / 1000;
      rounded = Number(size.toFixed(decimals[unitIndex]));
    }
    return `${rounded} ${units[unitIndex]}`;
  }

  /// Unified duration display (seconds → h:mm:ss / mm:ss); invalid input
  /// returns null.
  function formatDuration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) return null;
    const total = Math.floor(seconds);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
  }

  /// Overlay element-scope filtering (scope system): the overlay anchors to
  /// a single media element and shows only candidates within that element's
  /// scope — the element's own resources (ownURLs: absolute src/currentSrc/
  /// poster URLs and blob:/mse: placeholders) and video/audio candidates
  /// attributable to the player (site adapters, paired m4s, streaming
  /// manifests, video/audio MIME, blob/MSE). Page-level images and other
  /// direct links are page-scope and shown only in the Popup. Pure function:
  /// ownURLs is a Set or array; comparison is URL equality only (fragments
  /// stripped on both sides). Per-element network attribution on
  /// multi-video pages is future architecture work; the current
  /// implementation attributes video traffic to the in-page player (on
  /// single-video pages, the only anchor).
  function filterCandidatesForElementScope(candidates, ownURLs) {
    if (!Array.isArray(candidates)) return candidates;
    // Accepts a Set or array; copies item by item instead of an instanceof
    // check so cross-realm sets (unit-test vm environments) and any
    // iterable input work.
    const own = new Set();
    try {
      for (const item of ownURLs ?? []) own.add(item);
    } catch {
      // Non-iterable input is treated as having no own resources.
    }
    const inScope = (candidate) => {
      if (!candidate || typeof candidate.url !== "string") return false;
      if (candidate.siteAdapter) return true;
      if (candidate.pairKind === "m4s-pair") return true;
      if (candidate.format === "hls" || candidate.format === "dash" || candidate.format === "dash-json") return true;
      const mime = String(candidate.mime ?? "").toLowerCase();
      if (candidate.format === "video" || mime.startsWith("video/")) return true;
      if (candidate.format === "audio" || mime.startsWith("audio/")) return true;
      if (candidate.url.startsWith("blob:") || candidate.url.startsWith("mse:")) return true;
      return own.has(candidate.url.split("#", 1)[0]);
    };
    return candidates.filter(inScope);
  }

  global.MacIDMMediaUtils = Object.freeze({
    mediaPattern,
    mimeTypeFromURL,
    mediaFormat,
    mediaFilename,
    normalizeHTTPURL,
    normalizeMediaCandidate,
    normalizeResourceURL,
    redactedURL,
    resolvePageTitle,
    shortName,
    extractM4sInfo,
    m4sGroupKey,
    pairM4sCandidates,
    mediaExtension,
    coalesceMediaCandidates,
    isBilibiliPageURL,
    qualityLabel,
    codecFamily,
    variantDisplayLabel,
    smartMediaName,
    resolutionLabel,
    estimateVariantSize,
    estimateYouTubeMergedSize,
    confidenceRank,
    displayPriority,
    sortCandidatesForDisplay,
    filterCandidatesForElementScope,
    formatBytes,
    formatDuration,
    youTubeVideoIDFromURL,
    isYouTubeWatchPage,
  });
})(globalThis);
