// Main World fetch/XHR interceptor (world: "MAIN").
//
// Runs in the page's MAIN world so it can monkey-patch window.fetch and
// XMLHttpRequest to observe requests that page JavaScript fires dynamically
// (media files, HLS/DASH manifests, JSON APIs embedding media URLs).
// Captured URLs are handed back to the ISOLATED world content-script via
// window.postMessage with a fixed type marker.
//
// MAIN world scripts do NOT share globals with the other content scripts,
// so this file is fully self-contained: it must not rely on discovery.js or
// media-utils.js. All sniffing is best-effort — every step is wrapped in
// try/catch so the page's own networking can never be broken by us.
(function installMacIDMFetchInterceptor(global) {
  if (global.__macIDMFetchInterceptorInstalled) return;
  global.__macIDMFetchInterceptorInstalled = true;

  const MESSAGE_TYPE = "macidm.fetchCapture";
  const REQUEST_LEASE_TYPE = "macidm.requestSniffLease";
  const GRANT_LEASE_TYPE = "macidm.grantSniffLease";
  const SETTLE_LEASE_TYPE = "macidm.settleSniffLease";
  const RELEASE_LEASE_TYPE = "macidm.releaseSniffLease";
  const RESET_STATE_TYPE = "macidm.resetSniffState";

  // Tiered body sniffing budgets:
  // Tier 1: Manifest / XML / Plain Text (16KB - 64KB, max 2 rounds)
  // Tier 2: Explicit JSON (up to 512KB, max 8 rounds, full AST recursive scan)
  // Tier 3: Unknown / Binary (1KB - 4KB micro prefix)
  const MAX_SNIFF_CONTENT_LENGTH = 2 * 1024 * 1024;
  const TIER_BUDGETS = Object.freeze({
    MANIFEST: Object.freeze({ maxBytes: 64 * 1024, maxRounds: 2, label: "manifest" }),
    JSON: Object.freeze({ maxBytes: 512 * 1024, maxRounds: 8, label: "json" }),
    UNKNOWN: Object.freeze({ maxBytes: 4 * 1024, maxRounds: 1, label: "unknown" }),
  });

  const MAX_FRAME_CONCURRENT_SNIFFS = 2;
  const MAX_PAGE_SNIFF_BUDGET = 2 * 1024 * 1024; // 2MB
  const DEFAULT_PAGE_SNIFF_BUDGET = MAX_PAGE_SNIFF_BUDGET;
  const LEASE_REQUEST_TIMEOUT_MS = 1800; // MV3 SW wake-up headroom (bounded, fail-closed)
  const CLONE_HOLD_DEADLINE_MS = 100; // Short hold deadline: wait for the lease after the synchronous clone; on timeout cancel the clone to prevent tee-buffer buildup
  const TOTAL_SNIFF_READ_TIMEOUT_MS = 3000; // Total streaming-read timeout for one sniff, far below the Background lease TTL (30s)

  // ============================================================================
  // 2. State Machine & Sanitized Telemetry
  // ============================================================================

  const activeOperations = new Set(); // Set<OperationToken>
  const activeReaders = new Set(); // Set<ReadableStreamDefaultReader>
  const pendingLeaseRequests = new Map(); // requestId -> { resolve, holdTimer, requestTimer, holdTimedOut, reset, op }

  const localMetrics = {
    scheduled: 0,
    started: 0,
    completed: 0,
    aborted: 0,
    skippedByType: 0,
    skippedByConcurrency: 0,
    skippedByBudget: 0,
    leaseTimeout: 0,
    cloneError: 0,
    readError: 0,
    parseError: 0,
    bytesRead: 0,
  };

  function safeCancelStream(target) {
    if (!target || typeof target.cancel !== "function") return;
    try {
      const res = target.cancel();
      if (res && typeof res.then === "function" && typeof res.catch === "function") {
        res.catch(() => {});
      }
    } catch {
      // Swallow synchronous exceptions.
    }
  }

  function generateRequestId() {
    return "req_" + Math.random().toString(36).slice(2, 11) + "_" + Date.now().toString(36);
  }

  /**
   * Request a sniff lease reservation (truly async, fail-closed, asks the
   * Background coordinator for real ledger quota).
   */
  function requestSniffLease(requestedBytes, tierLabel = "unknown", op = null) {
    const bytes = Number.isFinite(requestedBytes) ? Math.max(0, requestedBytes) : 0;
    if (bytes <= 0) {
      return Promise.resolve({ leaseId: null, grantedBytes: 0, reason: "invalid_requested_bytes" });
    }

    const requestId = generateRequestId();

    return new Promise((resolve) => {
      let resolved = false;
      const safeResolve = (res) => {
        if (resolved) return;
        resolved = true;
        resolve(res);
      };

      // 1. Set the short hold deadline (prevents long tee-buffer buildup)
      const holdTimer = setTimeout(() => {
        if (pendingLeaseRequests.has(requestId)) {
          const item = pendingLeaseRequests.get(requestId);
          item.holdTimedOut = true;
          localMetrics.leaseTimeout += 1;
          if (op) {
            try {
              op.cancel("hold_timeout");
            } catch {}
          }
          safeResolve({ leaseId: null, grantedBytes: 0, reason: "hold_timeout" });
        }
      }, CLONE_HOLD_DEADLINE_MS);

      // 2. Set the fail-closed wake-up timeout timer (guards against SW
      // wake-up failure or lost messages)
      const requestTimer = setTimeout(() => {
        if (pendingLeaseRequests.has(requestId)) {
          pendingLeaseRequests.delete(requestId);
          safeResolve({ leaseId: null, grantedBytes: 0, reason: "timeout" });
        }
      }, LEASE_REQUEST_TIMEOUT_MS);

      // 3. Store in the pending-resolution map
      pendingLeaseRequests.set(requestId, {
        resolve: safeResolve,
        holdTimer,
        requestTimer,
        holdTimedOut: false,
        reset: false,
        op,
      });

      // 4. Send the lease reservation message to the ISOLATED world /
      // Background
      try {
        const postFn = typeof global.postMessage === "function"
          ? global.postMessage
          : (typeof window !== "undefined" && typeof window.postMessage === "function" ? window.postMessage : null);
        if (postFn) {
          postFn(
            {
              type: REQUEST_LEASE_TYPE,
              requestId,
              tier: tierLabel,
              requestedBytes: bytes,
            },
            "*",
          );
        } else {
          throw new Error("postMessage unavailable");
        }
      } catch {
        clearTimeout(holdTimer);
        clearTimeout(requestTimer);
        pendingLeaseRequests.delete(requestId);
        safeResolve({ leaseId: null, grantedBytes: 0, reason: "post_message_failed" });
      }
    });
  }

  // JSON deep-scan triple budget: depth / per-level width / total visits.
  const JSON_MAX_DEPTH = 6;
  const JSON_MAX_WIDTH = 50;
  const JSON_MAX_FIELDS = 2000;
  // Strings longer than this are almost never URLs (inline base64 / HTML).
  const JSON_MAX_STRING_LENGTH = 4096;

  const mediaPattern = /\.(?:m3u8|mpd|mp4|m4v|webm|mov|mp3|m4a|aac|flac|ogg|m4s|ts|mp2t|mkv|avi|wmv|flv|opus|wav)(?:$|[?#])/i;

  // ===== Bridge listener (ISOLATED World -> MAIN World) =====

  try {
    global.addEventListener("message", (event) => {
      try {
        if (!event || !event.data || typeof event.data !== "object") return;
        if (event.source && typeof window !== "undefined" && event.source !== window && event.source !== global && event.source !== globalThis) {
          return;
        }
        const msg = event.data;

        if (msg.type === GRANT_LEASE_TYPE && typeof msg.requestId === "string") {
          const pending = pendingLeaseRequests.get(msg.requestId);
          if (pending) {
            clearTimeout(pending.holdTimer);
            clearTimeout(pending.requestTimer);
            pendingLeaseRequests.delete(msg.requestId);

            const realLeaseId = typeof msg.leaseId === "string" && msg.leaseId ? msg.leaseId : null;
            const grantedBytes = Number.isFinite(msg.grantedBytes) ? Math.max(0, msg.grantedBytes) : 0;

            // If the request already hit its hold timeout, was reset, or its
            // op was cancelled, the real lease arriving now must be released
            // immediately — never leak it
            if (pending.holdTimedOut || pending.reset || (pending.op && pending.op.aborted)) {
              if (realLeaseId) {
                const releaseReason = pending.reset
                  ? "late_after_reset"
                  : (pending.holdTimedOut ? "late_after_timeout" : "late_after_abort");
                releaseSniffLease(realLeaseId, releaseReason);
              }
              pending.resolve({
                leaseId: null,
                grantedBytes: 0,
                reason: pending.reset ? "reset" : "late_after_timeout",
              });
              return;
            }

            if (realLeaseId && grantedBytes > 0) {
              pending.resolve({
                leaseId: realLeaseId,
                grantedBytes,
              });
            } else {
              pending.resolve({
                leaseId: null,
                grantedBytes: 0,
                reason: "denied_or_exhausted",
              });
            }
          }
        } else if (msg.type === RESET_STATE_TYPE) {
          // SPA Navigation reset: cancel active readers and mark pending requests
          cancelAllActiveReaders();
        }
      } catch {
        // Message handling must never crash page
      }
    });

    global.addEventListener("beforeunload", () => {
      cancelAllActiveReaders();
    });
  } catch {
    // ignore
  }

  function cancelAllActiveReaders() {
    for (const [reqId, pending] of pendingLeaseRequests) {
      clearTimeout(pending.holdTimer);
      // Keep requestTimer, mark reset and let the caller exit early; the
      // entry stays in pendingLeaseRequests to catch a late grant and
      // release it
      pending.reset = true;
      try {
        pending.resolve({ leaseId: null, grantedBytes: 0, reason: "reset" });
      } catch {}
    }

    for (const op of activeOperations) {
      try {
        op.cancel("reset");
      } catch {}
    }
    // Note: never call activeOperations.clear() directly or force counts to
    // zero! Every running operation must remove itself from activeOperations
    // in its own finally block, keeping lifecycle counts real and preventing
    // an old finally from decrementing a new operation's count.
  }

  function settleSniffLease(leaseId, actualBytes) {
    try {
      if (!leaseId) return;
      global.postMessage(
        {
          type: SETTLE_LEASE_TYPE,
          leaseId,
          actualBytes: Math.max(0, actualBytes),
        },
        "*",
      );
    } catch {}
  }

  function releaseSniffLease(leaseId, reason = "aborted") {
    try {
      if (!leaseId) return;
      global.postMessage(
        {
          type: RELEASE_LEASE_TYPE,
          leaseId,
          reason,
        },
        "*",
      );
    } catch {}
  }

  // ===== Pure helpers (exported for unit testing) =====

  /// Detect an HLS/DASH manifest from the leading bytes of a response body.
  /// Skips whitespace and a BOM before matching. Returns "hls" | "dash" | null.
  function sniffManifestMagic(text) {
    if (!text) return null;
    let head = String(text);
    if (head.charCodeAt(0) === 0xfeff) head = head.slice(1);
    head = head.trimStart();
    if (head.slice(0, 7).toUpperCase() === "#EXTM3U") return "hls";
    if (head.slice(0, 300).toUpperCase().includes("<MPD")) return "dash";
    return null;
  }

  /// True when the object looks like a JSON DASH manifest: it carries
  /// video[]+audio[] track arrays or a durl[] array whose elements expose
  /// baseURL/url string fields (bilibili playurl-style payloads).
  function looksLikeDashJSONObject(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const hasTrackArray = (key) => {
      const arr = value[key];
      return (
        Array.isArray(arr) &&
        arr.length > 0 &&
        arr.some(
          (item) =>
            item &&
            typeof item === "object" &&
            (typeof item.baseURL === "string" || typeof item.url === "string"),
        )
      );
    };
    return (hasTrackArray("video") && hasTrackArray("audio")) || hasTrackArray("durl");
  }

  /// Deep-scan a parsed JSON value for embedded http(s) media URLs.
  /// Triple budget: depth <= 6, width per level <= 50, total visits <= 2000.
  /// Returns { urls: string[], dashJsonManifest: boolean }.
  function scanJSONForMedia(root, baseURL) {
    const found = new Set();
    let dashJsonManifest = false;
    let visited = 0;

    function visit(value, depth) {
      if (depth > JSON_MAX_DEPTH || visited >= JSON_MAX_FIELDS) return;
      visited += 1;

      if (typeof value === "string") {
        if (value.length > JSON_MAX_STRING_LENGTH || !value.includes("/")) return;
        try {
          const abs = new URL(value, baseURL).href;
          if (isMediaLikeURL(abs)) found.add(abs);
        } catch {
          // Not a URL — ignore.
        }
        return;
      }
      if (Array.isArray(value)) {
        let width = 0;
        for (const item of value) {
          if (width >= JSON_MAX_WIDTH || visited >= JSON_MAX_FIELDS) return;
          width += 1;
          visit(item, depth + 1);
        }
        return;
      }
      if (value && typeof value === "object") {
        if (!dashJsonManifest && looksLikeDashJSONObject(value)) dashJsonManifest = true;
        let width = 0;
        for (const key of Object.keys(value)) {
          if (width >= JSON_MAX_WIDTH || visited >= JSON_MAX_FIELDS) return;
          width += 1;
          visit(value[key], depth + 1);
        }
      }
    }

    try {
      visit(root, 0);
    } catch {
      // Deep-scan failures never surface.
    }
    return { urls: [...found], dashJsonManifest };
  }

  /// Extension pattern OR a media MIME in the ?mime=/?type= query params
  /// (mirrors discovery.isMediaCandidate without depending on it).
  /// Extension checks look at the URL path only: a media address embedded
  /// in query parameters (e.g. a CDN m4s address copied into an analytics
  /// report parameter) is not candidate evidence, avoiding page-wide false
  /// positives from beacon logs.
  function isMediaLikeURL(value) {
    const str = String(value);
    let path = "";
    try {
      path = new URL(str, global.location?.href).pathname;
    } catch {
      path = str.split(/[?#]/u, 1)[0];
    }
    if (mediaPattern.test(path)) return true;
    try {
      const params = new URL(str).searchParams;
      const type = (params.get("mime") || params.get("type") || "").toLowerCase();
      return (
        type.startsWith("video/") ||
        type.startsWith("audio/") ||
        type.includes("mpegurl") ||
        type.includes("dash+xml")
      );
    } catch {
      return false;
    }
  }

  // ===== Report channel =====

  const notifiedKeys = new Set();

  function notify(url, extra = {}) {
    try {
      if (!isHTTPURL(url)) return;
      const key = `${extra.format ?? ""}|${url}`;
      if (notifiedKeys.has(key)) return;
      notifiedKeys.add(key);
      // Bounded memory: downstream content-script dedups anyway.
      if (notifiedKeys.size > 1000) notifiedKeys.clear();
      global.postMessage(
        {
          type: MESSAGE_TYPE,
          url,
          mime: typeof extra.mime === "string" ? extra.mime : "",
          format: typeof extra.format === "string" ? extra.format : "",
          via: extra.via === "magic" ? "magic" : "fetch",
        },
        "*",
      );
    } catch {
      // Reporting must never affect the page.
    }
  }

  function resolveURL(value) {
    if (!value || typeof value !== "string") return "";
    try {
      return new URL(value, global.location?.href).href;
    } catch {
      return "";
    }
  }

  function isHTTPURL(value) {
    try {
      const url = new URL(value);
      return url.protocol === "http:" || url.protocol === "https:";
    } catch {
      return false;
    }
  }

  function isSkippableContentType(contentType) {
    const lower = String(contentType || "").toLowerCase();
    return (
      lower.startsWith("image/") ||
      lower.startsWith("font/") ||
      lower.startsWith("text/css") ||
      lower.includes("javascript")
    );
  }

  function getTierBudget(contentType) {
    const ct = String(contentType || "").toLowerCase();
    if (ct.includes("json")) {
      return TIER_BUDGETS.JSON;
    }
    if (
      ct.includes("xml") ||
      ct.includes("text/plain") ||
      ct.includes("text/html") ||
      !ct
    ) {
      return TIER_BUDGETS.MANIFEST;
    }
    return TIER_BUDGETS.UNKNOWN;
  }

  // ===== Response body sniffing (fetch only) =====

  function inspectFetchResponse(response, requestURL) {
    if (!response || typeof response !== "object") return;
    let contentType = "";
    let contentLength = "";
    try {
      contentType = response.headers?.get?.("content-type") ?? "";
      contentLength = response.headers?.get?.("content-length") ?? "";
    } catch {
      // Header access failed — fall back to URL-only capture.
    }
    const finalURL =
      typeof response.url === "string" && response.url ? response.url : requestURL;
    if (!finalURL) return;
    const ct = String(contentType).toLowerCase();

    // Redirect target may be the real media/manifest URL.
    if (finalURL !== requestURL && isMediaLikeURL(finalURL)) notify(finalURL);

    // Authoritative manifest/media content types — no body read needed.
    if (ct.includes("mpegurl")) {
      notify(finalURL, { format: "hls", mime: "application/vnd.apple.mpegurl", via: "magic" });
      return;
    }
    if (ct.includes("dash+xml")) {
      notify(finalURL, { format: "dash", mime: "application/dash+xml", via: "magic" });
      return;
    }
    if (ct.startsWith("video/") || ct.startsWith("audio/")) {
      notify(finalURL, { mime: ct.split(";")[0].trim() });
      return;
    }

    // Extension-matched URLs were already reported above; bodies of
    // obviously irrelevant types or oversized payloads are skipped.
    if (isMediaLikeURL(finalURL)) return;
    const declared = Number.parseInt(contentLength, 10);
    if (Number.isFinite(declared) && declared > MAX_SNIFF_CONTENT_LENGTH) {
      localMetrics.skippedByType += 1;
      return;
    }
    if (!isHTTPURL(finalURL) || isSkippableContentType(ct)) {
      localMetrics.skippedByType += 1;
      return;
    }

    localMetrics.scheduled += 1;

    // Per-frame concurrency guard (max 2 active sniffs per frame)
    if (activeOperations.size >= MAX_FRAME_CONCURRENT_SNIFFS) {
      localMetrics.skippedByConcurrency += 1;
      return;
    }

    // Synchronously create the readable sniff branch/clone: it must be
    // established before returning the original Response to the page, so
    // the page can consume the original body immediately while the
    // sniffClone stays an independent branch
    let clone = null;
    try {
      if (typeof response.clone !== "function") throw new Error("no clone method");
      clone = response.clone();
    } catch {
      localMetrics.cloneError += 1;
      return;
    }

    readBodyAndSniff(clone, finalURL, ct);
  }

  /// Bounded clone-read with central background lease coordination and strict chunk slicing.
  /// The original response stream is never consumed — only the synchronous clone is read.
  async function readBodyAndSniff(clone, finalURL, contentType) {
    const tierBudget = getTierBudget(contentType);
    let leaseId = null;
    let grantedBytes = 0;
    let reader = null;
    let totalRead = 0;
    let abortReason = "unknown";
    let isOpAborted = false;

    const op = {
      id: generateRequestId(),
      get aborted() {
        return isOpAborted;
      },
      cancel(reason = "aborted") {
        if (isOpAborted) return;
        isOpAborted = true;
        abortReason = reason;
        if (reader) {
          safeCancelStream(reader);
        } else if (clone && clone.body) {
          safeCancelStream(clone.body);
        }
      },
    };

    activeOperations.add(op);
    localMetrics.started += 1;

    try {
      // 1. Request central lease from Background with bounded hold deadline
      const leaseResult = await requestSniffLease(tierBudget.maxBytes, tierBudget.label, op);
      if (op.aborted || !leaseResult || !leaseResult.leaseId || leaseResult.grantedBytes <= 0) {
        if (leaseResult?.leaseId) {
          releaseSniffLease(leaseResult.leaseId, abortReason || "aborted_before_read");
        }
        if (!op.aborted) {
          localMetrics.skippedByBudget += 1;
        }
        return;
      }
      leaseId = leaseResult.leaseId;
      grantedBytes = leaseResult.grantedBytes;

      const body = clone.body;
      if (!body || typeof body.getReader !== "function") {
        localMetrics.readError += 1;
        abortReason = "no_reader";
        return;
      }

      try {
        reader = body.getReader();
        activeReaders.add(reader);
      } catch {
        localMetrics.readError += 1;
        abortReason = "get_reader_failed";
        return;
      }

      const chunks = [];
      const effectiveMaxBytes = Math.min(tierBudget.maxBytes, grantedBytes);
      const readDeadline = Date.now() + TOTAL_SNIFF_READ_TIMEOUT_MS;

      // 2. Strict chunk-sliced read loop with read deadline
      try {
        for (let round = 0; round < tierBudget.maxRounds && totalRead < effectiveMaxBytes; round++) {
          if (op.aborted) {
            abortReason = "aborted_during_read";
            break;
          }

          const remainingTimeMs = readDeadline - Date.now();
          if (remainingTimeMs <= 0) {
            abortReason = "read_timeout";
            break;
          }

          let readTimeoutTimer;
          const readTimeoutPromise = new Promise((_, reject) => {
            readTimeoutTimer = setTimeout(() => {
              reject(new Error("read_timeout"));
            }, Math.min(remainingTimeMs, 1000));
          });

          let readResult;
          try {
            readResult = await Promise.race([reader.read(), readTimeoutPromise]);
          } finally {
            clearTimeout(readTimeoutTimer);
          }

          const { done, value } = readResult;
          if (done) break;
          if (value && value.length > 0) {
            const remaining = effectiveMaxBytes - totalRead;
            if (remaining <= 0) break;

            // Strict slicing to prevent single-chunk overrun
            const chunkToPush = value.length > remaining ? value.subarray(0, remaining) : value;
            chunks.push(chunkToPush);
            totalRead += chunkToPush.length;

            if (value.length > remaining) {
              // Reached limit via chunk slice, stop reading further
              break;
            }

            // Early magic cutoff for manifest tier
            if (tierBudget === TIER_BUDGETS.MANIFEST && totalRead >= 512) {
              try {
                const prefixSample = new TextDecoder().decode(chunks[0].subarray(0, 512));
                if (sniffManifestMagic(prefixSample)) {
                  break; // Early cutoff on positive manifest detection
                }
              } catch {}
            }
          }
        }
      } catch (err) {
        localMetrics.readError += 1;
        abortReason = err?.message === "read_timeout" ? "read_timeout" : "stream_read_error";
      } finally {
        if (reader) {
          activeReaders.delete(reader);
          safeCancelStream(reader);
          reader = null;
        } else if (clone && clone.body) {
          safeCancelStream(clone.body);
        }
      }

      // 3. Decode and sniff text
      if (totalRead > 0 && !op.aborted) {
        let text = "";
        try {
          const buffer = new Uint8Array(totalRead);
          let offset = 0;
          for (const chunk of chunks) {
            buffer.set(chunk, offset);
            offset += chunk.length;
          }
          text = new TextDecoder().decode(buffer);
        } catch {
          localMetrics.parseError += 1;
          abortReason = "decode_error";
          return;
        }

        sniffTextForMedia(text, finalURL, contentType);
      }
    } catch (outerErr) {
      localMetrics.parseError += 1;
      abortReason = "unexpected_error";
    } finally {
      activeOperations.delete(op);
      localMetrics.bytesRead += totalRead;

      // Settle or release lease in Background
      if (leaseId) {
        if (totalRead > 0 && abortReason !== "reset") {
          settleSniffLease(leaseId, totalRead);
          localMetrics.completed += 1;
        } else {
          releaseSniffLease(leaseId, abortReason || "zero_read");
          localMetrics.aborted += 1;
        }
      }
    }
  }

  function sniffTextForMedia(text, url, contentType) {
    try {
      if (!text) return;
      const magic = sniffManifestMagic(text.slice(0, 512));
      if (magic === "hls") {
        notify(url, { format: "hls", mime: "application/vnd.apple.mpegurl", via: "magic" });
        return;
      }
      if (magic === "dash") {
        notify(url, { format: "dash", mime: "application/dash+xml", via: "magic" });
        return;
      }
      // JSON deep scan only for JSON responses (budget enforced inside).
      if (!String(contentType || "").toLowerCase().includes("json")) return;
      let root;
      try {
        root = JSON.parse(text);
      } catch {
        localMetrics.parseError += 1;
        return;
      }
      const { urls, dashJsonManifest } = scanJSONForMedia(root, url);
      if (dashJsonManifest) notify(url, { format: "dash-json", via: "magic" });
      for (const found of urls) notify(found, { via: "magic" });
    } catch {
      localMetrics.parseError += 1;
    }
  }

  // ===== 抖音 aweme/detail 预加载捕获 =====
  // 抖音精选的 feed 路由在页面加载时预加载详情数据（含视频直链），弹窗
  // 打开后不再发请求：候选合成只能依赖这份响应（shared/douyin-detail-
  // cache.js 的解析逻辑与此处保持 verbatim 同步，双方都无法共享模块）。
  const DOUYIN_DETAIL_RE = /aweme\/v1\/web\/aweme\/detail\//i;
  const DOUYIN_DETAIL_MESSAGE = "macidm.douyin.detail";

  function parseDouyinDetailPayload(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > 4 * 1024 * 1024) return null;
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      return null;
    }
    const aweme = json?.aweme_detail ?? json;
    const video = aweme?.video;
    if (!aweme?.aweme_id || !video) return null;
    const seen = new Set();
    const urls = [];
    const push = (addr) => {
      const url = addr?.url_list?.find((candidate) => /^https?:/i.test(candidate));
      const size = addr?.data_size;
      if (!url || seen.has(url)) return;
      seen.add(url);
      urls.push({ url, size: Number.isSafeInteger(size) && size > 0 ? size : null });
    };
    push(video.play_addr);
    const rates = Array.isArray(video.bit_rate) ? video.bit_rate : [];
    for (const rate of rates) {
      push(rate?.play_addr);
      if (urls.length >= 8) break;
    }
    if (urls.length === 0) return null;
    const durationMs = Number(aweme.duration);
    return {
      awemeId: String(aweme.aweme_id),
      desc: String(aweme.desc ?? ""),
      duration: Number.isFinite(durationMs) && durationMs > 0 ? durationMs / 1000 : null,
      urls,
    };
  }

  function postDouyinDetail(parsed) {
    const postFn = typeof global.postMessage === "function"
      ? global.postMessage
      : (typeof window !== "undefined" && typeof window.postMessage === "function" ? window.postMessage : null);
    if (!postFn) return;
    postFn({ type: DOUYIN_DETAIL_MESSAGE, ...parsed }, "*");
  }

  function captureDouyinDetail(response) {
    if (!response || typeof response.clone !== "function") return;
    response.clone().text().then((text) => {
      const parsed = parseDouyinDetailPayload(text);
      if (parsed) postDouyinDetail(parsed);
    }).catch(() => {});
  }

  // ===== fetch patch =====

  try {
    const originalFetch = typeof global.fetch === "function" ? global.fetch : null;
    if (originalFetch) {
      global.fetch = function macIDMFetch(...args) {
        let requestURL = "";
        try {
          const target = args[0];
          if (typeof target === "string") requestURL = resolveURL(target);
          else if (typeof URL === "function" && target instanceof URL) requestURL = target.href;
          else if (target && typeof target.url === "string") requestURL = target.url;
        } catch {
          // URL extraction is best-effort.
        }
        try {
          if (requestURL && isMediaLikeURL(requestURL)) notify(requestURL);
        } catch {
          // Sniffing must never abort the page's request.
        }
        // Arguments pass through untouched; rejections propagate unchanged.
        return originalFetch.apply(this, args).then((response) => {
          try {
            inspectFetchResponse(response, requestURL);
          } catch {
            // Never disturb the original response.
          }
          try {
            if (requestURL && DOUYIN_DETAIL_RE.test(requestURL)) {
              captureDouyinDetail(response);
            }
          } catch {
            // Never disturb the original response.
          }
          return response;
        });
      };
    }
  } catch {
    // Patch conflict with page-defined globals: degrade silently.
  }

  // ===== XHR patch (URL capture only — the response body is never read) =====

  try {
    const XHR = global.XMLHttpRequest;
    const prototype = XHR?.prototype;
    const originalOpen = prototype?.open;
    const originalSend = prototype?.send;
    if (prototype && typeof originalOpen === "function" && typeof originalSend === "function") {
      prototype.open = function macIDMXHROpen(method, url, ...rest) {
        try {
          let raw = "";
          if (typeof url === "string") raw = url;
          else if (url && typeof url.href === "string") raw = url.href;
          this.__macidmURL = resolveURL(raw);
        } catch {
          // Sniffing must never abort the page's request.
        }
        // Original arguments pass through untouched.
        return originalOpen.apply(this, [method, url, ...rest]);
      };
      prototype.send = function macIDMXHRSend(...args) {
        try {
          const captured = this.__macidmURL;
          if (captured && isMediaLikeURL(captured)) notify(captured);
          if (captured && DOUYIN_DETAIL_RE.test(captured)) {
            // XHR 通道：detail 响应体较小（<4MB）。页面的 XHR 可能设置
            // responseType="json"/"arraybuffer"，responseText 会直接抛错——
            // 按实际 responseType 取 response 再序列化。
            this.addEventListener("load", () => {
              try {
                let text = null;
                if (!this.responseType || this.responseType === "text") {
                  text = this.responseText;
                } else if (this.responseType === "json") {
                  text = this.response ? JSON.stringify(this.response) : null;
                } else if (this.responseType === "arraybuffer" && this.response) {
                  text = new TextDecoder().decode(new Uint8Array(this.response));
                }
                if (!text) return;
                const parsed = parseDouyinDetailPayload(text);
                if (parsed) postDouyinDetail(parsed);
              } catch {
                // Never disturb the page.
              }
            });
          }
        } catch {
          // Sniffing must never abort the page's request.
        }
        return originalSend.apply(this, args);
      };
    }
  } catch {
    // Patch conflict: degrade silently.
  }

  function getMetrics() {
    return {
      ...localMetrics,
      activeFrameSniffCount: activeOperations.size,
      pendingRequestsCount: pendingLeaseRequests.size,
      activeReadersCount: activeReaders.size,
    };
  }

  function resetMetrics() {
    for (const k of Object.keys(localMetrics)) {
      localMetrics[k] = 0;
    }
  }

  // Pure-function surface for unit tests (assignment guarded: a page may
  // have defined the same global; never let that break our installation).
  try {
    global.MacIDMFetchInterceptor = Object.freeze({
      MESSAGE_TYPE,
      REQUEST_LEASE_TYPE,
      GRANT_LEASE_TYPE,
      SETTLE_LEASE_TYPE,
      RELEASE_LEASE_TYPE,
      RESET_STATE_TYPE,
      TIER_BUDGETS,
      MAX_FRAME_CONCURRENT_SNIFFS,
      MAX_PAGE_SNIFF_BUDGET,
      DEFAULT_PAGE_SNIFF_BUDGET,
      LEASE_REQUEST_TIMEOUT_MS,
      CLONE_HOLD_DEADLINE_MS,
      TOTAL_SNIFF_READ_TIMEOUT_MS,
      requestSniffLease,
      settleSniffLease,
      releaseSniffLease,
      inspectFetchResponse,
      readBodyAndSniff,
      sniffManifestMagic,
      looksLikeDashJSONObject,
      scanJSONForMedia,
      isMediaLikeURL,
      getMetrics,
      resetMetrics,
      cancelAllActiveReaders,
    });
  } catch {
    // ignore
  }
})(globalThis);
