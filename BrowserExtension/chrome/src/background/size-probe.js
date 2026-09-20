// IDM-style active resource probing. Passive observation only sees the
// headers of requests the page actually made; many CDNs stream chunked
// responses without Content-Length, leaving candidates as "size unknown".
// This module issues a HEAD request (falling back to a one-byte Range GET)
// to recover Content-Length and the true MIME type, so the Popup, overlay,
// and download-all pages can show format/resolution/size like IDM does.

const CACHE_TTL_MS = 10 * 60 * 1_000;
const PROBE_TIMEOUT_MS = 8_000;
const MAX_CACHE_ENTRIES = 300;

const probeCache = new Map(); // url -> { size, mime, cdFilename, expiresAt }
const inFlight = new Map(); // url -> Promise<{size, mime} | null>

/**
 * True when a candidate is a direct http(s) resource whose size can be
 * probed. Streaming manifests, site adapters (page URLs), and internal
 * fragments have no single Content-Length and are skipped.
 */
export function isProbeableCandidate(candidate) {
  if (!candidate || typeof candidate.url !== "string") return false;
  if (!/^https?:/i.test(candidate.url)) return false;
  if (candidate.size != null) return false;
  if (candidate.format === "hls" || candidate.format === "dash") return false;
  if (candidate.siteAdapter) return false;
  if (candidate.pairKind === "m4s-fragment" || candidate.pairKind === "stream-segment") {
    return false;
  }
  return true;
}

/**
 * Returns the cached probe result for `url`, or null when absent/expired.
 */
export function cachedProbe(url) {
  const entry = probeCache.get(url);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    probeCache.delete(url);
    return null;
  }
  return { size: entry.size, mime: entry.mime, cdFilename: entry.cdFilename ?? null };
}

/**
 * Direct probe primitive (Stateless & Cancellable).
 * Bypasses global in-flight coalescing and cache to obey caller AbortSignal
 * and caller context isolation keys (SizeProbeScheduler).
 */
export async function fetchProbeDirect(url, { referer, signal, timeoutMs } = {}) {
  if (typeof url !== "string" || !/^https?:/i.test(url)) {
    return null;
  }
  return runProbe(url, { referer, signal, timeoutMs });
}

/**
 * Probes the resource at `url` and resolves with `{ size, mime }` (either
 * field may be null) or null when probing failed.
 */
export function probeResourceSize(url, { referer, signal, timeoutMs } = {}) {
  if (typeof url !== "string" || !/^https?:/i.test(url)) {
    return Promise.resolve(null);
  }
  // When an explicit AbortSignal is provided, bypass singleton in-flight
  // so the request can be cancelled independently.
  if (signal) {
    return runProbe(url, { referer, signal, timeoutMs });
  }
  const cached = cachedProbe(url);
  if (cached) return Promise.resolve(cached);
  const pending = inFlight.get(url);
  if (pending) return pending;

  const run = runProbe(url, { referer, signal, timeoutMs })
    .then((result) => {
      storeProbe(url, result);
      return result;
    })
    .finally(() => {
      inFlight.delete(url);
    });
  inFlight.set(url, run);
  return run;
}

async function runProbe(url, { referer, signal, timeoutMs } = {}) {
  const headers = {};
  if (typeof referer === "string" && referer.length > 0) {
    headers["Referer"] = referer;
  }

  // Strategy 1: HEAD, anonymously. A probe is not a user action, so it carries
  // no cookies: doing otherwise let any page steer the extension into a
  // credentialed cross-site request. CDNs that insist on a session answer 403
  // here and the candidate keeps an unknown size; reaching those sizes needs
  // the explicit user-initiated path, which runs in the App where the target
  // and each redirect hop are shown and validated (see the public extension specification).
  const head = await timedFetch(url, {
    method: "HEAD",
    headers,
    credentials: "omit",
    redirect: "error",
    signal,
    timeoutMs,
  });
  if (head) {
    const size = parseContentLength(head.headers.get("content-length"));
    const mime = normalizeMime(head.headers.get("content-type"));
    const cdFilename = parseContentDispositionFilename(head.headers.get("content-disposition"));
    if (size != null || mime || cdFilename) {
      await discardBody(head);
      if (size != null || cdFilename) return { size, mime, cdFilename };
    } else {
      await discardBody(head);
    }
  }

  // Strategy 2: one-byte anonymous Range GET. A 206 answer carries
  // `Content-Range: bytes 0-0/TOTAL`; servers that ignore Range answer 200
  // with a plain Content-Length. Either reveals the total size.
  const ranged = await timedFetch(url, {
    method: "GET",
    headers: { ...headers, Range: "bytes=0-0" },
    credentials: "omit",
    redirect: "error",
    signal,
    timeoutMs,
  });
  if (!ranged) return null;
  const mime = normalizeMime(ranged.headers.get("content-type"));
  const cdFilename = parseContentDispositionFilename(ranged.headers.get("content-disposition"));
  let size = null;
  if (ranged.status === 206) {
    const match = /\/(\d+)\s*$/.exec(ranged.headers.get("content-range") ?? "");
    if (match) size = Number(match[1]);
  }
  if (size == null) {
    size = parseContentLength(ranged.headers.get("content-length"));
  }
  await discardBody(ranged);
  if (size == null && !mime && !cdFilename) return null;
  return { size: Number.isSafeInteger(size) ? size : null, mime, cdFilename };
}

async function timedFetch(url, { signal, timeoutMs = PROBE_TIMEOUT_MS, ...init } = {}) {
  const timeoutController = new AbortController();
  const timer = setTimeout(() => timeoutController.abort(), timeoutMs);

  let combinedSignal = timeoutController.signal;
  let abortHandler = null;

  if (signal) {
    if (signal.aborted) {
      clearTimeout(timer);
      return null;
    }
    if (typeof AbortSignal.any === "function") {
      combinedSignal = AbortSignal.any([signal, timeoutController.signal]);
    } else {
      abortHandler = () => timeoutController.abort();
      signal.addEventListener("abort", abortHandler, { once: true });
    }
  }

  try {
    const response = await fetch(url, { ...init, signal: combinedSignal });
    // Treat hard errors as unusable so the fallback strategy can run.
    if (response.status >= 400) {
      await discardBody(response);
      return null;
    }
    return response;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
    if (signal && abortHandler) {
      signal.removeEventListener("abort", abortHandler);
    }
  }
}

async function discardBody(response) {
  try {
    await response.body?.cancel();
  } catch {
    // Body cancellation is best-effort.
  }
}

function parseContentLength(value) {
  if (typeof value !== "string") return null;
  const parsed = Number(value.trim());
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
}

function normalizeMime(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.split(";")[0].trim().toLowerCase();
  return trimmed.length > 0 && trimmed.length <= 128 ? trimmed : null;
}

/// Extract the server-authoritative filename from a Content-Disposition
/// header (RFC 6266). Prefers the RFC 5987 `filename*=UTF-8''…` form, then the
/// plain `filename="…"` / `filename=…` form. Returns null when absent.
function parseContentDispositionFilename(value) {
  if (typeof value !== "string" || !value) return null;
  const extended = /filename\*\s*=\s*([^;]+)/iu.exec(value);
  if (extended) {
    const raw = extended[1].trim();
    // form: UTF-8''percent-encoded
    const match = /^[^']*'[^']*'(.+)$/u.exec(raw);
    if (match) {
      try {
        const decoded = decodeURIComponent(match[1].trim());
        if (decoded) return sanitizeFilename(decoded);
      } catch {
        // fall through to the plain form
      }
    }
  }
  const plain = /filename\s*=\s*("([^"]*)"|[^;]+)/iu.exec(value);
  if (plain) {
    const raw = (plain[2] ?? plain[1] ?? "").trim();
    if (raw) return sanitizeFilename(raw);
  }
  return null;
}

function sanitizeFilename(name) {
  const cleaned = String(name).replace(/[\r\n/\\]/gu, " ").trim().slice(0, 255);
  return cleaned.length > 0 ? cleaned : null;
}

function storeProbe(url, result) {
  if (probeCache.size >= MAX_CACHE_ENTRIES) {
    const oldest = probeCache.keys().next().value;
    if (oldest !== undefined) probeCache.delete(oldest);
  }
  probeCache.set(url, {
    size: result?.size ?? null,
    mime: result?.mime ?? null,
    cdFilename: result?.cdFilename ?? null,
    expiresAt: Date.now() + CACHE_TTL_MS,
  });
}
