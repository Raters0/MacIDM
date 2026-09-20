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

  /// Unified display name used by both Popup and Overlay. Follows the same
  /// trust model as the App's naming chain (technical spec §8.1): a name
  /// synthesized from a content identity (site adapter, m4s pair, segment
  /// group) outranks the page title, and a generic/brand page title never
  /// prefixes another name — a Bilibili homepage row must not read
  /// "哔哩哔哩 … · card title". Also avoids the "Title · Title.mp4"
  /// duplication that happened when filenameHint was already derived from
  /// the page title.
  function smartMediaName(candidate, pageTitle = "", candidateCount = 1, hostname = "") {
    const host = String(hostname || "").toLowerCase();
    const base = stripHostSuffix(String(pageTitle || "").trim().slice(0, 120), host);
    const hint = String(candidate?.filenameHint ?? "").trim();
    // A name synthesized from a content identity (site adapter, m4s pair,
    // segment group — technical spec §8.1 "titleDerived") outranks the page
    // title so multi-card pages keep per-card names; generic synthesized
    // labels ("YouTube 视频.mp4") never outrank a confirmed specific title.
    const hintStem = hint.replace(/\.[a-z0-9]{1,4}$/iu, "").trim();
    if (hint && hintStem && filenameHintSourceFor(candidate) === "titleDerived"
      && !isGenericOrBrandTitle(hintStem, host)) {
      return hint;
    }
    if (base && !isGenericOrBrandTitle(base, host)) {
      // If filenameHint already starts with the page title, don't duplicate.
      if (hint && hint.toLowerCase().startsWith(base.toLowerCase())) {
        return hint;
      }
      const generic = /^(download|index|master|playlist|media|video|audio|manifest)\b/i.test(hint);
      return generic || candidateCount <= 1 ? base : `${base} · ${hint}`;
    }
    // Generic/brand (or missing) page title: never a prefix. A name
    // synthesized from a content identity (site adapter, m4s pair, segment
    // group — technical spec §8.1 "titleDerived") outranks the brand label,
    // so a Bilibili homepage row reads "card title.mp4", not
    // "哔哩哔哩 … · card title.mp4".
    if (hint && filenameHintSourceFor(candidate) === "titleDerived") return hint;
    // The brand label remains only as the last readable fallback when the
    // candidate carries no identity name — the same order the App uses.
    return base || hint || candidate?.displayName || t("common.mediaResource");
  }

  /// Provenance of a candidate's filenameHint (technical spec §8.1 naming
  /// trust model). Names synthesized from the page title (site adapters,
  /// m4s pairs, fragment groups) are "titleDerived" and may outrank the
  /// title on the App side; plain URL-tail names are "urlPath" and never do.
  function filenameHintSourceFor(candidate) {
    if (!candidate || typeof candidate !== "object") return "urlPath";
    // Synthesis sites may declare the real provenance explicitly (a pair
    // row that kept its URL-tail name must not claim titleDerived trust).
    if (candidate.filenameHintSource === "titleDerived" || candidate.filenameHintSource === "urlPath") {
      return candidate.filenameHintSource;
    }
    if (candidate.siteAdapter) return "titleDerived";
    if (candidate.pairKind === "m4s-pair" || candidate.pairKind === "stream-segment") {
      return "titleDerived";
    }
    return "urlPath";
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

  // Pair explicitly marked audio-only/video-only tracks only after the scope
  // observer proves they belong to one player. Never infer ownership from a
  // CDN host, expiry directory, caption or matching duration.
  const SPLIT_AUDIO_RE = /(media-audio|audio[-_.]|[-_.]audio|mp4a|\.aac\b|\.m4a\b)/iu;
  const SPLIT_VIDEO_RE = /(media-video|video[-_.]|[-_.]video|avc1|hvc1|hevc|h264|h265|av01|vp9)/iu;
  function classifySplitStream(candidate) {
    if (!candidate || typeof candidate.url !== "string") return null;
    if (candidate.siteAdapter || candidate.pairKind) return null;
    if (candidate.format !== "video" && candidate.format !== "audio") return null;
    let path = "";
    try {
      path = decodeURIComponent(new URL(candidate.url).pathname);
    } catch {
      return null;
    }
    if (SPLIT_AUDIO_RE.test(path)) return "audio";
    if (SPLIT_VIDEO_RE.test(path)) return "video";
    return null;
  }
  function splitStreamGroupKey(candidate) {
    // CDN expiry directories are shared by unrelated videos and can differ
    // between one video's tracks. Only actual player ownership can group them.
    return typeof candidate.mediaOwner === "string" && candidate.mediaOwner
      ? candidate.mediaOwner : null;
  }
  function durationsCompatible(video, audio) {
    const a = Number.isFinite(video?.duration) && video.duration > 0 ? video.duration : null;
    const b = Number.isFinite(audio?.duration) && audio.duration > 0 ? audio.duration : null;
    if (a === null || b === null) return true;
    return Math.abs(a - b) <= 2;
  }
  function pairSplitStreamCandidates(candidates, pageTitle = "") {
    if (!Array.isArray(candidates)) return [];
    const others = [];
    const groups = new Map();
    for (const candidate of candidates) {
      const kind = classifySplitStream(candidate);
      const key = kind ? splitStreamGroupKey(candidate) : null;
      if (!kind || !key) {
        others.push(candidate);
        continue;
      }
      const group = groups.get(key) ?? { video: [], audio: [] };
      group[kind].push(candidate);
      groups.set(key, group);
    }
    const result = others;
    for (const group of groups.values()) {
      if (group.video.length === 0 || group.audio.length === 0) {
        result.push(...group.video, ...group.audio);
        continue;
      }
      const video = [...group.video].sort((a, b) => (b.size ?? 0) - (a.size ?? 0))[0];
      const audio = group.audio.find((entry) => durationsCompatible(video, entry));
      if (!audio) {
        // Every audio disagrees with the best video's duration: treat the
        // batch as unpaired rather than muxing mismatched tracks.
        result.push(...group.video, ...group.audio);
        continue;
      }
      // Extra video-only renditions stay as their own rows; only the best
      // video consumes the single audio track for the merged pair.
      result.push(...group.video.filter((entry) => entry !== video), ...group.audio.filter((entry) => entry !== audio));
      const title = String(pageTitle || "").trim();
      result.push({
        ...video,
        format: "video",
        fileExtension: "mp4",
        displayName: (title || String(video.displayName || "")).slice(0, 80),
        // Only claim a title-derived name when a real page title exists;
        // on gallery pages the pair keeps the video's own URL-tail hint
        // (honestly urlPath-sourced) so the per-card caption still names
        // the row and the App derives the filename from the submitted
        // page title instead of a branding-baked hint.
        ...(title
          ? { filenameHint: `${sanitizePairFilename(title)}.mp4`.slice(0, 255), filenameHintSource: "titleDerived" }
          : { filenameHintSource: "urlPath" }),
        size:
          Number.isSafeInteger(video.size) && Number.isSafeInteger(audio.size)
            ? video.size + audio.size
            : (video.size ?? null),
        pairKind: "m4s-pair",
        pairVideoUrl: video.url,
        pairAudioUrl: audio.url,
        pairNote: t("common.pairNoteMerge"),
        collapsed: false,
      });
    }
    return result;
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
    // Server-authoritative Content-Disposition name is display-only metadata
    // (tooltip). It is NOT forwarded as filenameHint/filenameHintSource: the
    // bridge validator only accepts browserResolved/titleDerived/urlPath, and
    // the naming trust model ranks a *probed* CD name below pageTitle/urlPath,
    // so promoting it here would both break older Apps and invert priorities.
    const serverFilename =
      typeof raw?.cdFilename === "string" && raw.cdFilename.trim()
        ? raw.cdFilename.trim().slice(0, 255)
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
      ...(serverFilename ? { serverFilename } : {}),
      qualityLabel: isBlob || isMSE ? "" : qualityLabel({ url, mime, format, fileExtension }),
    };
  }

  function coalesceMediaCandidates(candidates, pageTitle = "", pageURL = "", previewIdentities = []) {
    if (!Array.isArray(candidates)) return [];
    const isYouTubePage = isYouTubePageURL(pageURL);
    let paired = pairSplitStreamCandidates(pairM4sCandidates(candidates, pageTitle), pageTitle).filter(
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

    // List/homepage hover previews: one identity per mounted card player.
    // The page URL is never treated as a single video; only the card's
    // /video/BV|av link is, with the card heading as the display title.
    // Include adapters already present in `paired` (second-pass coalesce /
    // service-worker forwarding) so the same bvid is never synthesized twice.
    const seenPreviewBvids = new Set(
      [
        ...kept.map((candidate) => bilibiliVideoIDFromURL(candidate?.url)),
        ...paired
          .filter((candidate) => candidate?.siteAdapter === "bilibili")
          .map((candidate) => bilibiliVideoIDFromURL(candidate?.url)),
      ].filter(Boolean),
    );
    for (const identity of Array.isArray(previewIdentities) ? previewIdentities : []) {
      const bvid = identity?.bvid ? String(identity.bvid) : bilibiliVideoIDFromURL(identity?.pageURL);
      const page = normalizeHTTPURL(identity?.pageURL ?? "");
      if (!bvid || !page || seenPreviewBvids.has(bvid)) continue;
      if (bilibiliVideoIDFromURL(page) !== bvid) continue;
      // Never fall back to the multi-video page title (homepage branding);
      // an empty card heading becomes the generic Bilibili media label.
      const title = String(identity.title ?? "").trim() || t("common.bilibiliMedia");
      const base = sanitizePairFilename(title);
      kept.push({
        url: page,
        mime: "text/html",
        format: "video",
        fileExtension: "mp4",
        supported: true,
        displayName: title.slice(0, 80),
        displayURL: redactedURL(page),
        size: null,
        filenameHint: `${base}.mp4`.slice(0, 255),
        siteAdapter: "bilibili",
        pairNote: t("common.bilibiliPairNote"),
        collapsed: false,
      });
      seenPreviewBvids.add(bvid);
    }

    // Any live Bilibili site adapter (page or preview) covers bilivideo
    // streams better than a raw m4s observation: the adapter path re-resolves
    // tracks and titles, and the page only ever plays one preview at a time.
    const hasAnyBilibiliAdapter = isBilibiliPage
      || kept.some((candidate) => candidate?.siteAdapter === "bilibili");

    // Separate-audio masters (X/Twitter): media playlists living strictly
    // deeper under another observed HLS candidate's directory on the same
    // host are its renditions (master /pl/x.m3u8 → /pl/avc1/*, /pl/mp4a/*).
    // Fold them into the master row; alone they read as duplicate
    // "HLS 流媒体" rows (video-only variants and the audio rendition).
    // Two masters in one directory share depth and never fold each other.
    const foldedHls = new Set();
    {
      const entries = paired
        .filter((c) => c?.format === "hls")
        .map((c) => {
          try {
            const u = new URL(c.url);
            return {
              url: c.url,
              host: u.host,
              dir: u.pathname.slice(0, u.pathname.lastIndexOf("/") + 1),
              path: u.pathname,
              depth: u.pathname.split("/").filter(Boolean).length,
            };
          } catch { return null; }
        })
        .filter(Boolean);
      for (const sub of entries) {
        let shallowest = null;
        for (const other of entries) {
          if (other.url === sub.url || other.host !== sub.host) continue;
          if (sub.depth <= other.depth) continue;
          if (!sub.path.startsWith(other.dir)) continue;
          if (!shallowest || other.depth < shallowest.depth) shallowest = other;
        }
        if (shallowest) foldedHls.add(sub.url);
      }
    }

    const pairedTracks = new Set(paired.filter(c => c?.pairKind === "m4s-pair")
      .flatMap(c => [c.pairVideoUrl, c.pairAudioUrl]));
    const coveredCIDs = new Set(paired.filter(c => c?.pairKind === "m4s-pair").map(c => c.pairCid));
    for (const candidate of paired) {
      if (candidate?.format === "hls" && foldedHls.has(candidate.url)) continue;
      if (!candidate.siteAdapter && !candidate.pairKind && pairedTracks.has(candidate.url)) continue;
      // Suppress only evidence belonging to the adapter or an existing pair.
      // Homepage previews fetch m4s from rotating mirror hosts (not only
      // *.bilivideo.com), so bilibili-style {cid}-1-{formatId}.m4s naming is
      // also adapter-covered once a site candidate exists. Complete m4s pairs
      // remain as a fallback.
      if (hasAnyBilibiliAdapter && !candidate?.siteAdapter && candidate?.pairKind !== "m4s-pair") {
        if (isBilibiliStreamCandidate(candidate) || extractM4sInfo(candidate?.url)) continue;
      }
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
    // Coalescing is repeated in content, background and UI. It must be
    // idempotent: an adapter/paired row supersedes its raw URL observation.
    const byURL = new Map();
    const rank = c => c.siteAdapter ? 3 : c.pairKind === "m4s-pair" ? 2 : 1;
    for (const candidate of kept) {
      const key = normalizeHTTPURL(candidate.url) || candidate.url;
      const old = byURL.get(key);
      if (!old || rank(candidate) > rank(old)) byURL.set(key, candidate);
    }
    return [...byURL.values()];
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

  /// BV/av identity from a Bilibili /video/ URL. Null for other paths and
  /// non-Bilibili hosts. Distinct from isBilibiliPageURL: a multi-video list
  /// page is never a page identity, but a single card link inside it is.
  function bilibiliVideoIDFromURL(value) {
    try {
      const url = new URL(String(value ?? ""), "https://www.bilibili.com/");
      const host = url.hostname.toLowerCase().replace(/^www\./u, "");
      if (host !== "bilibili.com" && !host.endsWith(".bilibili.com")) return null;
      const match = url.pathname.match(/^\/video\/(BV[0-9A-Za-z]+|av\d+)/iu);
      return match ? match[1] : null;
    } catch {
      return null;
    }
  }

  function isBilibiliHost(value) {
    try {
      const host = new URL(String(value ?? "")).hostname.toLowerCase().replace(/^www\./u, "");
      return host === "bilibili.com" || host.endsWith(".bilibili.com");
    } catch {
      return false;
    }
  }

  /// Card title next to a Bilibili video link. The cover link's own text is
  /// usually overlay chrome ("添加至稍后再看…播放…弹幕"), so it is never
  /// preferred over the heading.
  function findBilibiliCardTitle(scope) {
    if (!scope || typeof scope.querySelector !== "function") return "";
    const selectors = [
      "h3 a[href*='/video/']",
      "h3",
      "[class*='info--tit']",
      "[class*='video-card__info'] [class*='tit']",
      "[class*='title'] a[href*='/video/']",
    ];
    for (const selector of selectors) {
      let node = null;
      try {
        node = scope.querySelector(selector);
      } catch {
        continue;
      }
      const text = String(node?.textContent ?? "")
        .replace(/\s+/gu, " ")
        .trim();
      if (text.length >= 2 && !/^添加至稍后再看/u.test(text)) return text.slice(0, 200);
    }
    return "";
  }

  /// Walk up from a media element to the enclosing Bilibili video card and
  /// resolve { bvid, pageURL, title }. Used for list/homepage hover previews
  /// where the page URL itself carries no single-video identity. Prefers the
  /// nearest ancestor that also carries a non-empty heading title (the cover
  /// wrapper alone has the video link but only overlay chrome text).
  function extractBilibiliCardIdentity(element, pageURL = "") {
    if (!element || typeof element.closest !== "function") return null;
    const boundary = element.closest(".bili-video-card, .video-page-card-small");
    if (!boundary) return null;
    let node = element;
    let best = null;
    for (let depth = 0; node && node.nodeType === 1 && depth < 12; depth += 1) {
      const link = (() => {
        try {
          return node.querySelector?.("a[href*='/video/BV'], a[href*='/video/av']");
        } catch {
          return null;
        }
      })();
      if (link) {
        const href = link.getAttribute?.("href") || link.href || "";
        const page = normalizeHTTPURL(href, pageURL || undefined);
        const bvid = page ? bilibiliVideoIDFromURL(page) : null;
        if (bvid && page) {
          const identity = { bvid, pageURL: page, title: findBilibiliCardTitle(node) };
          if (identity.title) return identity;
          if (!best) best = identity;
        }
      }
      if (node === boundary) break;
      node = node.parentElement;
    }
    return best;
  }

  /// Currently mounted Bilibili card previews (hover players). Returns at most
  /// one identity per bvid, in DOM order. Never synthesizes an identity for
  /// the whole multi-video page — only for cards that actually host a player.
  function collectBilibiliPreviewIdentities(doc, pageURL = "") {
    if (!doc || typeof doc.querySelectorAll !== "function") return [];
    const href = String(pageURL || doc.location?.href || "");
    if (!isBilibiliHost(href)) return [];
    // Watch/bangumi pages already have a page-level adapter; previews there
    // must not add competing identities.
    if (isBilibiliPageURL(href)) return [];

    const seen = new Set();
    const identities = [];
    let videos = [];
    try {
      videos = [...doc.querySelectorAll("video")];
    } catch {
      return [];
    }
    for (const video of videos.slice(0, 32)) {
      const identity = extractBilibiliCardIdentity(video, href);
      if (!identity || seen.has(identity.bvid)) continue;
      seen.add(identity.bvid);
      identities.push(identity);
    }
    return identities.slice(0, 8);
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
      // Query values can select a different player resource, not just a signature.
      url.hash = "";
      return `${format}:${url.href}`;
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

  // Strip a trailing site-brand suffix ("… - 抖音", "… | YouTube") that many
  // sites append to document.title / og:title. Bilibili stacks two underscore
  // separated tails ("标题_哔哩哔哩_bilibili") on both document.title and
  // og:title: accept `_` as a separator and match one-or-more consecutive
  // brand tails so the whole suffix drops in one pass — otherwise the
  // unresolved brand token makes isGenericOrBrandTitle flag the specific
  // title as generic and the site adapter falls back to "Bilibili 媒体".
  const BRAND_SUFFIX_RE = /(?:[-–—|·_]\s*(?:抖音|哔哩哔哩|bilibili|优酷|爱奇艺|腾讯视频|YouTube|youtube)\s*)+$/iu;
  function stripBrandSuffix(title) {
    return String(title || "").replace(BRAND_SUFFIX_RE, "").trim();
  }
  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  }
  // Strip a trailing "- <siteToken>" suffix (e.g. "… - example") in addition to
  // the known-brand list, so site-branded document titles reduce to content.
  function stripSiteSuffix(title, siteToken) {
    if (!siteToken || siteToken.length < 3) return String(title || "");
    const re = new RegExp(`[-–—|·]\\s*${escapeRegExp(siteToken)}\\s*$`, "iu");
    return String(title || "").replace(re, "").trim();
  }

  // Mirror of the App's DownloadNaming.semanticPageTitle: strip a trailing
  // "<sep> <host>" segment ("… - bilibili", "… | example.com") when the
  // suffix matches one of the page hosts (full host, host without "www.",
  // or the host's first label), so real titles containing separators
  // ("Love is War - Episode 3") are never truncated. Keeps the extension's
  // display naming and the App's naming chain on one rule set.
  function stripHostSuffix(title, hostname) {
    const text = String(title || "");
    const raw = String(hostname || "").toLowerCase();
    const withoutWWW = raw.replace(/^www\./u, "");
    if (!withoutWWW) return text;
    const firstLabel = withoutWWW.split(".")[0] || withoutWWW;
    const tokens = new Set([raw, withoutWWW, firstLabel].filter((token) => token.length >= 3));
    let separatorIndex = -1;
    for (const sep of ["-", "\u2013", "\u2014", "|"]) {
      const at = text.lastIndexOf(sep);
      if (at > separatorIndex) separatorIndex = at;
    }
    if (separatorIndex < 0) return text;
    const suffix = text.slice(separatorIndex + 1).trim().toLowerCase();
    const stem = text.slice(0, separatorIndex).trim();
    if (!suffix || stem.length < 3 || !tokens.has(suffix)) return text;
    return stem;
  }

  // True when a title is empty or reads as a generic/brand page name rather
  // than specific content (used to decide whether a proximity-resolved title
  // should override it on SPA pages).
  const GENERIC_TITLE_TOKENS = /(抖音|哔哩哔哩|bilibili|youtube|优酷|爱奇艺|腾讯视频|精选|首页|homepage|\bhome\b)/iu;
  function isGenericOrBrandTitle(title, hostname) {
    const text = stripBrandSuffix(String(title || "").trim());
    if (text.length < 2) return true;
    if (GENERIC_TITLE_TOKENS.test(text)) return true;
    const siteToken = String(hostname || "").replace(/^www\./iu, "").split(".")[0].toLowerCase();
    if (siteToken.length >= 3 && text.toLowerCase().includes(siteToken)) return true;
    return false;
  }

  const TITLE_BOILERPLATE = /(登录|注册|订阅|关注|下载|分享|收藏|点赞|缓冲|buffering|loading|加载|章节|上一集|下一集|弹幕|发送|全屏|倍速|清晰度|清屏|键盘快捷键|login|sign\s?in|subscribe|follow|share|download|cookie|privacy|keyboard shortcuts|稍后再看|稍后观看|不感兴趣|举报|复制链接|自动连播|watch\s+later)/iu;
  // Player interaction-hint sentences ("点击按住可拖动视频", "双击播放", swipe
  // gestures) live inside card modules as block text and read as long
  // captions; they are instructions, never titles.
  const TITLE_INSTRUCTION_RE = /(点击|长按|双击|拖动|滑动|上滑|下滑|左右滑|可拖动|可循环|试试|轻触).{0,12}(播放|拖动|切换|弹幕|点赞|倍速|视频|滑动)|双击.{0,6}播放|单击.{0,6}暂停/u;
  function cleanTitleText(raw) {
    let text = String(raw || "").trim().replace(/\s+/gu, " ");
    // Drop trailing expand/collapse affordances common on clipped titles.
    text = text.replace(/(?:展开|收起|更多|more|less|\.\.\.|…)\s*$/iu, "").trim();
    return text;
  }
  function titleLikeness(text, isHeading) {
    if (text.length < 4 || text.length > 120) return -Infinity;
    if (TITLE_BOILERPLATE.test(text)) return -Infinity;
    if (TITLE_INSTRUCTION_RE.test(text)) return -Infinity;
    // Player chrome leaks into [class*='title'] pools: chapter markers and
    // timecode badges ("莉莉斯00:57", "00:12 / 05:33") read like short titles.
    // A mm:ss timecode anywhere disqualifies the text.
    if (/\d{1,2}:\d{2}/u.test(text)) return -Infinity;
    // Pure hashtags / numbers / punctuation are not titles. CJK ideographs
    // are \W under the u flag, so the guard must use Unicode punctuation /
    // symbol classes — an ASCII \W class would reject every pure-Chinese
    // title (Douyin/Bilibili card captions) and starve the proximity
    // heuristic on Chinese sites.
    if (/^[#＃\d\s\p{P}\p{S}]+$/u.test(text)) return -Infinity;
    let score = Math.min(text.length, 120) / 40;
    if (isHeading) score += 2;
    // Hashtags are common in Douyin captions; penalize lightly so a real
    // caption with tags still outranks chrome/author fragments.
    const hashtags = (text.match(/#[^\s#]+/gu) || []).length;
    score -= Math.min(hashtags * 0.2, 0.6);
    return score;
  }
  const TITLE_MODULE_SELECTORS = [
    '[role="dialog"]', '[class*="modal"]', '[class*="player"]', '[class*="card"]',
    "article", "section",
  ];
  // Player-internal UI (control bar, subtitle/quality menus, danmaku panel,
  // toasts, chapter lists) carries long title-like text in [class*='title']
  // nodes (Bilibili's subtitle menu once named every row). Pool entries
  // inside these containers are chrome, never content titles.
  const TITLE_CHROME_SELECTORS = [
    '[class*="control"]', '[class*="menu"]', '[class*="subtitle"]', '[class*="danmaku"]',
    '[class*="toast"]', '[class*="buffer"]', '[class*="chapter"]', '[class*="setting"]',
    '[class*="error"]', '[class*="notice"]',
    // Hover-revealed card affordances (watch-later / queue / report buttons)
    // are interactive chrome: their labels ("添加至稍后再看") read like short
    // captions and outrank the real title in the leaf pool while hovering.
    'button', '[role="button"]', '[class*="action"]', '[class*="toolbar"]',
    '[class*="watchlater"]', '[class*="watch-later"]',
  ];
  function isPlayerChrome(el, module) {
    if (!el || typeof el.closest !== "function" || !module) return false;
    for (const selector of TITLE_CHROME_SELECTORS) {
      let hit = null;
      try { hit = el.closest(selector); } catch { hit = null; }
      if (hit && hit !== module && containsNode(module, hit)) return true;
    }
    return false;
  }
  // Accessibility-only text (X's visually hidden keyboard-shortcut H2:
  // "要查看键盘快捷键，按下问号") carries real title-like words but never
  // renders: a 1×1 clip box (clip: rect(1px,…)) positioned off-flow. It must
  // not win the title pool, so moduleTitle skips elements with no rendered
  // box of their own. Layout-less environments (unit-test shims) report
  // zero-size rects without throwing and have no computed style at all —
  // "unknown" must degrade to visible, never to hidden.
  function isVisuallyHiddenTitle(el) {
    if (!el || typeof el.getBoundingClientRect !== "function") return false;
    let box = null;
    try {
      box = el.getBoundingClientRect();
    } catch {
      return false;
    }
    if (!box) return false;
    let style = null;
    try {
      style = global.getComputedStyle(el);
    } catch {
      return false;
    }
    if (!style) return false;
    if (style.display === "none" || style.visibility === "hidden") return true;
    const clip = String(style.clip || "");
    if (clip !== "auto" && clip !== "none" && clip !== "") {
      const match = clip.match(/rect\(([^)]*)\)/u);
      if (match) {
        const parts = match[1].split(/[ ,]+/u).map((part) => parseFloat(part));
        if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
          const [top, right, bottom, left] = parts;
          // A degenerate clip rect clips everything away (a11y hiding).
          if (right - left <= 1 || bottom - top <= 1) return true;
        }
      }
    }
    // A near-zero box only counts as hidden when the element is out of flow;
    // an in-flow zero-size node can still render glyphs.
    if ((box.width <= 1 || box.height <= 1)
        && (style.position === "absolute" || style.position === "fixed")) {
      return true;
    }
    return false;
  }
  function containsNode(root, node) {
    for (let current = node; current; current = current.parentElement) {
      if (current === root) return true;
    }
    return false;
  }
  function moduleBoxOk(module) {
    const box = module.getBoundingClientRect?.();
    return !box || (box.width >= 200 && box.height >= 120);
  }
  // Candidate title modules from nearest to farthest. The player shell
  // wrapping a hover-preview video often carries no heading (the caption
  // lives in a sibling subtree of the card), so stopping at the first
  // matching ancestor traps the title pool inside an empty shell (Douyin
  // feed cards, Bilibili homepage cards). Callers walk outward until a
  // module actually yields title-like text.
  function titleModules(doc, anchorEl) {
    const modules = [];
    const push = (module) => {
      if (module && !modules.includes(module) && moduleBoxOk(module)) modules.push(module);
    };
    if (anchorEl && anchorEl.nodeType === 1) {
      if (typeof anchorEl.matches === "function") {
        let node = anchorEl.parentElement;
        // X nests the tweet video >10 wrapper divs above the article; a
        // bounded walk must reach far enough to leave the empty player
        // shell before falling back to the page body.
        for (let depth = 0; node && node.nodeType === 1 && depth < 20; depth += 1) {
          for (const selector of TITLE_MODULE_SELECTORS) {
            let hit = false;
            try { hit = node.matches(selector); } catch { hit = false; }
            if (hit) {
              push(node);
              break;
            }
          }
          if (modules.length >= 4) break;
          node = node.parentElement;
        }
      }
      // Deep-nesting fallback (X): when even the widened walk found no
      // module, jump straight to the nearest ancestor per selector.
      if (modules.length === 0 && typeof anchorEl.closest === "function") {
        for (const selector of TITLE_MODULE_SELECTORS) {
          try { push(anchorEl.closest(selector)); } catch { /* ignore */ }
        }
      }
    }
    push(doc.body || doc.documentElement || null);
    return modules;
  }
  function moduleTitle(module, options = {}) {
    const collect = (selector, isHeading) => {
      try {
        return [...module.querySelectorAll(selector)]
          .filter((el) => !isPlayerChrome(el, module) && !isVisuallyHiddenTitle(el))
          .map((el) => ({
            text: cleanTitleText(el.textContent),
            isHeading,
          }));
      } catch {
        return [];
      }
    };
    const pool = [
      ...collect("h1, h2, h3, h4, [role='heading']", true),
      // X/Twitter: the tweet body carries no heading/[class*='title'] (classes
      // are obfuscated hashes); without it the outward walk reaches the page
      // body and picks chrome headings like the composer prompt.
      ...collect("[data-testid='tweetText'], [data-e2e*='title'], [data-e2e*='desc'], [itemprop='name'], [class*='title']", false),
    ];
    // Card captions sometimes carry no class/data-e2e/heading at all (Douyin
    // jingxuan cards use a bare <span>), and caption containers embed inline
    // hashtag/mention spans (so they are not leaves). For bounded modules
    // (never the page body, where such text is everywhere) leaf and
    // inline-only containers join the pool, letting the real caption outrank
    // author/time fragments like "0v0前天".
    if (options.leafFallback) {
      const inlineOnlyText = (el) => {
        if (el.children.length === 0) return true;
        try {
          for (const child of el.children) {
            const display = String(global.getComputedStyle(child).display || "");
            if (display === "none") continue;
            if (!display.startsWith("inline")) return false;
          }
          return true;
        } catch {
          return false;
        }
      };
      try {
        for (const el of module.querySelectorAll("*")) {
          if (isPlayerChrome(el, module) || !inlineOnlyText(el)
              || isVisuallyHiddenTitle(el)) continue;
          pool.push({ text: cleanTitleText(el.textContent), isHeading: false });
        }
      } catch {
        // Ignore traversal failures; the selector pool still applies.
      }
    }
    let best = "";
    let bestScore = -Infinity;
    let bestHeading = false;
    for (const { text, isHeading } of pool) {
      const score = titleLikeness(text, isHeading);
      if (score > bestScore) {
        bestScore = score;
        best = text;
        bestHeading = isHeading;
      }
    }
    if (!best) return null;
    return { text: best.slice(0, 200), score: bestScore, isHeading: bestHeading };
  }
  // A module's best text only stops the outward walk when it reads as a real
  // heading or a reasonably long caption; short survivor text (player chrome
  // that slipped the filters) keeps the walk moving toward the card.
  const MODULE_TITLE_ACCEPT_SCORE = 0.45;
  // Generic, site-independent content-title heuristic: locate the bounded
  // module (card/modal/player container) owning the active media element and
  // pick the most title-like text inside it, walking outward from the player
  // shell to the enclosing card when the shell carries no heading. Covers
  // SPA pages whose document.title never updates because the title lives
  // beside the player.
  /// X/Twitter 系域名（类名混淆、标题文本不可信）。
  function isXHostURL(href) {
    try {
      return [
        "x.com", "www.x.com", "mobile.x.com",
        "twitter.com", "www.twitter.com", "mobile.twitter.com",
      ].includes(new URL(String(href ?? ""), "https://x.com/").hostname);
    } catch {
      return false;
    }
  }

  function resolveContentTitle(doc, anchorEl) {
    if (!doc || typeof doc.querySelector !== "function") return "";
    // X/推文正文、alt 与推荐区文本都不可作文件名（营销账号、emoji 噪声、
    // 同页其它推文串扰）：用户要求 X 文件名只用 URL 路径里的媒体 ID，
    // 禁用标题推导，filenameHint 回落 urlPath。
    if (isXHostURL(global.location?.href)) return "";
    if (anchorEl && isBilibiliHost(global.location?.href)) {
      const card = anchorEl.closest?.(".bili-video-card, .video-page-card-small");
      if (card) return findBilibiliCardTitle(card);
      if (anchorEl.closest?.(".bpx-player-container") && isBilibiliPageURL(global.location?.href)) {
        return String(doc.querySelector("h1")?.textContent || "").trim().slice(0, 200);
      }
      // Avatars, banners and other images do not inherit a feed card's title.
      if (String(anchorEl.tagName).toUpperCase() === "IMG") return "";
    }
    const siteTitle = douyinContentTitle(doc, anchorEl);
    if (siteTitle) return siteTitle;
    // 抖音 feed 的旧 docTitle 不在这里拦截：卡片 caption 的 leaf 池路径是
    // 合法的；页级兜底（resolvePageTitle / overlay cleanedPageTitle）才是
    // 残留标题的入口，已在两处分别守卫。
    // 弹幕不进入标题池由 douyinContentTitle 的 playerContainer 守卫保证：
    // anchor 在播放器容器内时只认归属范围内的 video-desc；desc 不可达时
    // 再把该播放器模块从近似 walk 中剔除（模块内除 desc 外只有弹幕/控件
    // 文本），防止弹幕经 leaf 池冒充标题；播放器外的卡片 caption 走既有路径。
    let douyinPlayerModule = null;
    try {
      if (["douyin.com", "www.douyin.com"].includes(new URL(global.location?.href ?? "").hostname)) {
        douyinPlayerModule = anchorEl?.closest?.("[class*='playerContainer'], .xgplayer") ?? null;
      }
    } catch { /* ignore */ }
    let fallback = "";
    let fallbackScore = -Infinity;
    const body = doc.body || doc.documentElement || null;
    for (const module of titleModules(doc, anchorEl)) {
      if (module === douyinPlayerModule) continue;
      const hit = moduleTitle(module, { leafFallback: module !== body });
      if (!hit) continue;
      if (hit.score > fallbackScore) {
        fallbackScore = hit.score;
        fallback = hit.text;
      }
      if (hit.isHeading || hit.score >= MODULE_TITLE_ACCEPT_SCORE) return hit.text;
    }
    return fallback;
  }
  // Douyin fast-path: detail/modal keeps document.title at the brand name;
  // the real title lives in [data-e2e="video-desc"] (with hashtags appended).
  function douyinContentTitle(doc, anchorEl = null) {
    try {
      if (!["douyin.com", "www.douyin.com"].includes(new URL(global.location.href).hostname)) return "";
      // Semantic card fields carry the actual caption, including short titles,
      // hashtags and words such as 分享 that generic chrome filters reject.
      const card = anchorEl?.closest?.(".jingxuanVideoCard, .waterfall-videoCardContainer");
      if (card) {
        const caption = card.querySelector('[data-feed-ad-click-refer="title"]');
        const cover = card.querySelector("img.discover-video-card-img");
        return String(caption?.textContent || cover?.getAttribute("alt") || "")
          .trim().replace(/\s+/gu, " ").slice(0, 200);
      }
      // Detail pages preload adjacent players. Never read a different player's
      // description or its chapter summary to name this element. Douyin's own
      // jingxuan player is NOT xgplayer — its container class carries
      // "playerContainer"; missing it made the resolver fall through to the
      // generic pool inside the player, where danmaku bullets won as titles.
      const player = anchorEl?.closest?.(".xgplayer, [class*='playerContainer']");
      if (anchorEl && !player) return "";
      let root = player || doc;
      if (!anchorEl) {
        const players = [...(doc.querySelectorAll?.(".xgplayer, [class*='playerContainer']") ?? [])];
        if (players.length) {
          root = players.find(node => {
            const rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.right > 0
              && rect.top < global.innerHeight && rect.left < global.innerWidth
              && global.getComputedStyle(node).visibility !== "hidden";
          });
          if (!root) return "";
        }
      }
      if (root === doc) {
        return cleanTitleText(doc.querySelector?.('[data-e2e="video-desc"]')?.textContent).slice(0, 200);
      }
      // The player container itself carries no description: walk upward to its
      // owning modal/detail scope, but never past an ancestor that holds more
      // than one player (adjacent preloaded players' descriptions are off
      // limits). No desc → give up; the generic pool inside the player would
      // name danmaku bullets.
      let text = "";
      let scope = root;
      for (let hop = 0; scope && hop < 4; hop += 1) {
        const playerCount = scope.querySelectorAll?.(".xgplayer, [class*='playerContainer']")?.length ?? 0;
        if (hop > 0 && playerCount > 1) break;
        text = cleanTitleText(scope.querySelector('[data-e2e="video-desc"]')?.textContent);
        if (text) break;
        scope = scope.parentElement;
      }
      return text.slice(0, 200);
    } catch { return ""; }
  }

  // Intelligently resolve the best page title from available metadata.
  // Different sites place the "real" content title in different locations:
  // some use og:title for the video name while document.title carries site
  // branding, and vice-versa. This scorer prefers the title that looks most
  // like specific content rather than a generic site name.
  // 抖音 SPA 的 feed 路由不重置 document.title/og meta：从详情页返回后二者
  // 残留上一个视频的标题（实测复现）。feed 上页级标题整体不可信，行名只能
  // 来自卡片语义字段或通用名。
  function isDouyinFeedPage(href = global.location?.href) {
    try {
      const url = new URL(String(href ?? ""));
      if (!["douyin.com", "www.douyin.com"].includes(url.hostname)) return false;
      if (url.searchParams.has("modal_id")) return false;
      return ["", "/", "/jingxuan", "/recommend"].includes(url.pathname.replace(/\/+$/u, "")) || url.pathname === "";
    } catch {
      return false;
    }
  }

  function resolvePageTitle(doc = document, anchorEl = null) {
    // X：页级标题（"xxx on X"/og）同样不作文件名——App 的命名信任模型里
    // pageTitle 优先于 urlPath hint，必须从源头置空，文件名才能落到
    // URL 媒体 ID（用户要求）。
    if (isXHostURL(global.location?.href ?? "")) return "";
    // feed 上无锚点的页级解析（docTitle/og）整体不可信；带锚点时先走下方
    // douyin 快速路径，失败后同样不冒用残留的 og/docTitle。
    const douyinFeed = isDouyinFeedPage();
    if (douyinFeed && !anchorEl) return "";
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
    // Site fast-path: Douyin detail/modal title.
    const douyin = douyinContentTitle(doc, anchorEl);
    if (douyin) return douyin;
    // feed 上卡片语义字段/desc 均未命中：宁可空标题，也不冒用残留的 og/docTitle。
    if (douyinFeed) return "";
    // Generic proximity: when we know the active player and the document
    // title is generic/brand-only (typical SPA), prefer the title inside the
    // player's own module.
    if (anchorEl) {
      let hostname = "";
      try {
        hostname = location.hostname;
      } catch {
        hostname = "";
      }
      if (isGenericOrBrandTitle(doc.title, hostname)) {
        const generic = resolveContentTitle(doc, anchorEl);
        if (generic) return generic;
      }
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

    let hostname = "";
    try {
      hostname = location.hostname.replace(/^www\./iu, "");
    } catch {
      hostname = "";
    }
    // Extract the recognizable site token from the hostname (e.g. "hanime1"
    // from "hanime1.me", "agedm" from "agedm.io") for branding detection.
    const siteToken = hostname.split(".")[0].toLowerCase();

    const candidates = [ogTitle, twitterTitle, docTitle]
      .map((t) => stripHostSuffix(
        stripSiteSuffix(stripBrandSuffix(t.trim().replace(/\s+/g, " ")), siteToken),
        hostname,
      ))
      .filter((t) => t.length >= 2);
    if (candidates.length === 0) return "";

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

  // Only explicit element attribution may enter an overlay. The caller
  // supplies live DOM URLs and URLs resolved by a bounded site association.
  // Unknown ownership remains in the Popup, including video/audio traffic.
  function filterCandidatesForElementScope(candidates, ownURLs) {
    if (!Array.isArray(candidates)) return [];
    const own = new Set();
    try {
      for (const item of ownURLs ?? []) {
        if (typeof item === "string") own.add(item.split("#", 1)[0]);
      }
    } catch {}
    return candidates.filter((candidate) => {
      if (!candidate || typeof candidate.url !== "string") return false;
      if (!own.has(candidate.url.split("#", 1)[0])) return false;
      if (candidate.pairKind === "m4s-pair"
          && (!own.has(String(candidate.pairVideoUrl || "").split("#", 1)[0])
            || !own.has(String(candidate.pairAudioUrl || "").split("#", 1)[0]))) return false;
      if (candidate.format === "image") return false;
      const mime = String(candidate.mime ?? "").toLowerCase();
      if (mime.startsWith("image/")) return false;
      return Boolean(candidate.siteAdapter)
        || ["video", "audio", "hls", "dash", "dash-json", "blob"].includes(candidate.format)
        || mime.startsWith("video/") || mime.startsWith("audio/");
    });
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
    resolveContentTitle,
    isGenericOrBrandTitle,
    stripBrandSuffix,
    stripHostSuffix,
    shortName,
    extractM4sInfo,
    m4sGroupKey,
    pairM4sCandidates,
    mediaExtension,
    coalesceMediaCandidates,
    isBilibiliPageURL,
    bilibiliVideoIDFromURL,
    extractBilibiliCardIdentity,
    collectBilibiliPreviewIdentities,
    qualityLabel,
    codecFamily,
    variantDisplayLabel,
    smartMediaName,
    filenameHintSourceFor,
    resolutionLabel,
    estimateVariantSize,
    estimateYouTubeMergedSize,
    confidenceRank,
    displayPriority,
    sortCandidatesForDisplay,
    filterCandidatesForElementScope,
    formatBytes,
    formatDuration,
    isDouyinFeedPage,
    youTubeVideoIDFromURL,
    isYouTubeWatchPage,
  });
})(globalThis);
