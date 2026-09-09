(function installDiscovery(global) {
  const mediaPattern = /\.(?:m3u8|mpd|mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mp2t|mkv|avi|wmv|flv|opus|wav)(?:$|[?#])/iu;

  function normalizeHTTPURL(value, baseURL) {
    try {
      const url = new URL(value, baseURL);
      url.hash = "";
      return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
    } catch {
      return null;
    }
  }

  function mimeTypeFromURL(value) {
    try {
      const url = new URL(value);
      return (url.searchParams.get("mime") || url.searchParams.get("type") || "")
        .trim()
        .toLowerCase();
    } catch {
      return "";
    }
  }

  function collectLinks(anchors, baseURL, limit = 1_000) {
    const seen = new Set();
    const result = [];
    for (const anchor of anchors) {
      const url = normalizeHTTPURL(anchor.href ?? anchor, baseURL);
      if (!url || seen.has(url)) continue;
      seen.add(url);
      result.push({
        url,
        text: String(anchor.textContent ?? "").trim().replace(/\s+/gu, " ").slice(0, 160),
      });
      if (result.length >= limit) break;
    }
    return result;
  }

  function mediaFormat(value, mime = "") {
    const lower = String(value).toLowerCase();
    const type = String(mime || mimeTypeFromURL(value)).toLowerCase();
    if (/\.m3u8(?:$|[?#])/iu.test(lower) || type.includes("mpegurl")) return "hls";
    if (/\.mpd(?:$|[?#])/iu.test(lower) || type.includes("dash+xml")) return "dash";
    if (type.startsWith("audio/") || /\.(?:mp3|m4a|aac|flac|ogg|opus|wav)(?:$|[?#])/iu.test(lower)) {
      return "audio";
    }
    return "video";
  }

  /// The URL's path portion (without query parameters or fragment).
  /// Analytics/reporting requests copy the whole media address into a query
  /// parameter (e.g. Bilibili log/web beacons embedding a CDN m4s address);
  /// an extension inside the parameters is not candidate evidence —
  /// extension checks must look at the path only.
  function mediaPathOf(value) {
    const str = String(value ?? "");
    try {
      return new URL(str).pathname;
    } catch {
      // For non-URL shapes, conservatively take the part before the first
      // ?/# (callers pass already-normalized absolute addresses; this
      // branch is only a fallback).
      return str.split(/[?#]/u, 1)[0];
    }
  }

  function isMediaCandidate(value, mime = "") {
    const type = String(mime || mimeTypeFromURL(value));
    return (
      mediaPattern.test(mediaPathOf(value)) ||
      /^video\//iu.test(type) ||
      /^audio\//iu.test(type) ||
      /(?:mpegurl|dash\+xml)/iu.test(type)
    );
  }

  const LAZY_ATTRS = ["data-src", "data-video", "data-url", "data-hls", "data-dash", "data-mp4"];
  const EXTENDED_MEDIA_TAGS = new Set(["VIDEO", "AUDIO", "SOURCE", "EMBED", "OBJECT", "IFRAME"]);

  /**
   * Extracts media candidate URLs from a single DOM Element.
   */
  function extractElementCandidates(el, baseURL = "", checkMediaFn = isMediaCandidate) {
    if (!el || typeof el.getAttribute !== "function") return [];
    const result = [];
    const tagName = String(el.tagName || "").toUpperCase();

    // 1. Tag specific direct src / data
    if (!tagName || EXTENDED_MEDIA_TAGS.has(tagName)) {
      const raw = el.getAttribute("src") || el.getAttribute("data") || el.currentSrc || "";
      if (raw && !raw.startsWith("blob:")) {
        const url = normalizeHTTPURL(raw, baseURL);
        if (url && checkMediaFn(url)) {
          const duration =
            Number.isFinite(el.duration) && el.duration > 0 ? el.duration : undefined;
          result.push({
            url,
            mime: el.type || "",
            text: el.title || el.getAttribute?.("aria-label") || "",
            duration,
            confidence: "dom",
          });
        }
      } else if ((tagName === "VIDEO" || tagName === "AUDIO" || !tagName) && (el.readyState >= 1 || el.srcObject)) {
        result.push({
          url: el.currentSrc || "mse:player",
          mime: "video/mp4",
          duration: Number.isFinite(el.duration) && el.duration > 0 ? el.duration : undefined,
          confidence: "dom",
        });
      }
    }

    // 2. Check lazy loading data attributes
    for (const attr of LAZY_ATTRS) {
      const raw = el.getAttribute(attr) || "";
      if (raw) {
        const url = normalizeHTTPURL(raw, baseURL);
        if (url && checkMediaFn(url)) {
          result.push({ url, mime: "", text: "", confidence: "dom" });
        }
      }
    }

    return result;
  }

  /**
   * Pure incremental DOM mutation candidate extractor.
   * Only scans added subtrees and changed attribute targets, eliminating full-page querySelectorAll.
   */
  function extractDOMMutationCandidates(mutations, baseURL = "", checkMediaFn = isMediaCandidate) {
    if (!Array.isArray(mutations) || mutations.length === 0) return [];
    const seen = new Set();
    const result = [];
    const subSelectors = "video, audio, source, embed, object, iframe, [data-src], [data-video], [data-url], [data-hls], [data-dash], [data-mp4]";

    for (let i = 0; i < mutations.length; i++) {
      const mutation = mutations[i];
      if (!mutation) continue;

      if (mutation.type === "childList" && mutation.addedNodes) {
        const addedNodes = mutation.addedNodes;
        for (let j = 0; j < addedNodes.length; j++) {
          const node = addedNodes[j];
          if (!node || node.nodeType !== 1) continue; // Only element nodes (nodeType === 1)

          // 1. Check the node itself
          const selfCandidates = extractElementCandidates(node, baseURL, checkMediaFn);
          for (let k = 0; k < selfCandidates.length; k++) {
            const item = selfCandidates[k];
            if (!seen.has(item.url)) {
              seen.add(item.url);
              result.push(item);
            }
          }

          // 2. Check targeted elements within the added subtree only
          if (typeof node.querySelectorAll === "function") {
            try {
              const matches = node.querySelectorAll(subSelectors);
              for (let k = 0; k < matches.length; k++) {
                const subItem = matches[k];
                const subCandidates = extractElementCandidates(subItem, baseURL, checkMediaFn);
                for (let m = 0; m < subCandidates.length; m++) {
                  const item = subCandidates[m];
                  if (!seen.has(item.url)) {
                    seen.add(item.url);
                    result.push(item);
                  }
                }
              }
            } catch {}
          }
        }
      } else if (mutation.type === "attributes" && mutation.target && mutation.target.nodeType === 1) {
        const targetCandidates = extractElementCandidates(mutation.target, baseURL, checkMediaFn);
        for (let k = 0; k < targetCandidates.length; k++) {
          const item = targetCandidates[k];
          if (!seen.has(item.url)) {
            seen.add(item.url);
            result.push(item);
          }
        }
      }
    }

    return result;
  }

  /**
   * Pure incremental Performance entries candidate extractor.
   */
  function extractPerformanceEntriesCandidates(entries, checkMediaFn = isMediaCandidate) {
    if (!Array.isArray(entries) || entries.length === 0) return [];
    const seen = new Set();
    const result = [];

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (!entry || typeof entry.name !== "string") continue;
      const url = normalizeHTTPURL(entry.name);
      if (!url || seen.has(url)) continue;

      const isMediaInitiator = ["video", "audio", "source", "embed"].includes(entry.initiatorType);
      if (isMediaInitiator || checkMediaFn(url)) {
        seen.add(url);
        result.push({
          url,
          text: "",
          size: entry.transferSize > 0 ? entry.transferSize : undefined,
          confidence: "extension",
        });
      }
    }

    return result;
  }

  /**
   * Extracts media candidates across the entire document root.
   * Intended strictly for initial page load, explicit refresh, or low-frequency idle reconciliation.
   */
  function extractFullDOMCandidates(root = (typeof document !== "undefined" ? document : null), baseURL = "", checkMediaFn = isMediaCandidate) {
    if (!root || typeof root.querySelectorAll !== "function") return [];
    const seen = new Set();
    const result = [];
    const selector = "video, audio, source, embed, object, iframe, [data-src], [data-video], [data-url], [data-hls], [data-dash], [data-mp4]";

    try {
      const elements = root.querySelectorAll(selector);
      for (let i = 0; i < elements.length; i++) {
        const el = elements[i];
        const elCandidates = extractElementCandidates(el, baseURL, checkMediaFn);
        for (let j = 0; j < elCandidates.length; j++) {
          const item = elCandidates[j];
          if (!seen.has(item.url)) {
            seen.add(item.url);
            result.push(item);
          }
        }
      }
    } catch {}

    return result;
  }

  /**
   * Extracts media URLs from a broader set of elements including
   * <embed>, <object>, <iframe>, and <source> tags that the original
   * scanner missed. Also checks data-* attributes commonly used by
   * lazy-loading frameworks (data-src, data-video, data-url, etc.).
   */
  function collectExtendedMediaCandidates(baseURL) {
    const seen = new Set();
    const result = [];
    const limit = 2_000;

    // Standard media elements
    const mediaSelectors = [
      "video[src]", "video source[src]",
      "audio[src]", "audio source[src]",
      "embed[src]", "object[data]",
      "iframe[src]",
    ];
    for (const selector of mediaSelectors) {
      for (const el of document.querySelectorAll(selector)) {
        const raw = el.getAttribute("src") || el.getAttribute("data") || "";
        const url = normalizeHTTPURL(raw, baseURL);
        if (url && !seen.has(url) && isMediaCandidate(url)) {
          seen.add(url);
          result.push({ url, text: el.title || el.getAttribute("aria-label") || "" });
          if (result.length >= limit) return result;
        }
      }
    }

    // Lazy-loading data attributes commonly used by video players
    const lazyAttrs = ["data-src", "data-video", "data-url", "data-hls", "data-dash", "data-mp4"];
    for (const attr of lazyAttrs) {
      for (const el of document.querySelectorAll(`[${attr}]`)) {
        const raw = el.getAttribute(attr) || "";
        const url = normalizeHTTPURL(raw, baseURL);
        if (url && !seen.has(url) && isMediaCandidate(url)) {
          seen.add(url);
          result.push({ url, text: "" });
          if (result.length >= limit) return result;
        }
      }
    }

    return result;
  }

  /**
   * Performance-based media detection: uses the Resource Timing API
   * to discover media URLs that were loaded dynamically (e.g., by
   * JavaScript video players) and are invisible to DOM scanning.
   * Only returns resources with media-like MIME types or extensions.
   */
  function collectPerformanceMediaCandidates() {
    try {
      const entries = performance.getEntriesByType("resource");
      return extractPerformanceEntriesCandidates(entries, isMediaCandidate);
    } catch {
      return [];
    }
  }

  global.MacIDMDiscovery = {
    collectLinks,
    isMediaCandidate,
    mediaFormat,
    normalizeHTTPURL,
    extractElementCandidates,
    extractDOMMutationCandidates,
    extractPerformanceEntriesCandidates,
    extractFullDOMCandidates,
    collectExtendedMediaCandidates,
    collectPerformanceMediaCandidates,
  };
})(globalThis);
