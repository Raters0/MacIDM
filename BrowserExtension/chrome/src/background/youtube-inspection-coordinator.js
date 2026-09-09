// YouTube inspection coordinator (see the public extension specification).
//
// One shared page-inspection state machine per tabId + videoId, owned by the
// service worker. The Popup and the overlay both subscribe to the same
// snapshot stream: opening/closing the Popup never cancels a page-level
// inspection, reopening reads the latest snapshot, and two surfaces opening
// at once produce exactly one in-flight inspection. SPA navigation bumps
// the tab generation so stale results are discarded instead of leaking
// video A's variants into video B.
//
// Stage model (serializable, spec §5.8):
//   discovered → pageInspecting → pageWaitingForStableData / pagePartial
//   → fallbackInspecting → complete / partial / failed / unsupported

// Side-effect import installs globalThis.MacIDMYouTubeFormats (classic
// script shared with content scripts; variant merge/dedup helpers live there).
import "../shared/youtube-format-utils.js";

export const YOUTUBE_INSPECTION_STAGES = Object.freeze({
  discovered: "discovered",
  pageInspecting: "pageInspecting",
  pageWaitingForStableData: "pageWaitingForStableData",
  pagePartial: "pagePartial",
  fallbackInspecting: "fallbackInspecting",
  complete: "complete",
  partial: "partial",
  failed: "failed",
  unsupported: "unsupported",
});

const TERMINAL_STAGES = new Set([
  YOUTUBE_INSPECTION_STAGES.complete,
  YOUTUBE_INSPECTION_STAGES.partial,
  YOUTUBE_INSPECTION_STAGES.failed,
  YOUTUBE_INSPECTION_STAGES.unsupported,
]);

const RETRYABLE_STAGES = new Set([
  YOUTUBE_INSPECTION_STAGES.partial,
  YOUTUBE_INSPECTION_STAGES.failed,
]);

export const YOUTUBE_INSPECTION_DEFAULTS = Object.freeze({
  // Page-phase poll cadence and budget (spec §5.8 thresholds).
  pagePollMs: 1_500,
  pageBudgetMs: 9_000,
  // Stable signal: two identical result sets at least this far apart.
  stableGapMs: 1_200,
  // A terminal snapshot stays fresh this long; afterwards a reopened Popup
  // re-inspects instead of trusting stale data.
  terminalTtlMs: 120_000,
  // In-flight records older than this without any update are presumed lost
  // to service-worker eviction and restart.
  staleInFlightMs: 30_000,
});

export class YouTubeInspectionCoordinator {
  /// Dependencies (all injectable for unit tests):
  /// - requestPageQualities(tabId, message) → content-script round trip
  /// - appInspector({ tabId, url }) → { ok, variants?, message?, timedOut?,
  ///   errorCategory? } App/yt-dlp fallback result
  /// - publish(tabId, snapshot) → fan out to the tab's overlay + the Popup
  /// - now / sleep override wall-clock timing in tests
  constructor({
    requestPageQualities,
    appInspector,
    publish,
    now = () => Date.now(),
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    limits = {},
  }) {
    this.requestPageQualities = requestPageQualities;
    this.appInspector = appInspector;
    this.publish = publish;
    this.now = now;
    this.sleep = sleep;
    this.limits = { ...YOUTUBE_INSPECTION_DEFAULTS, ...limits };
    this.records = new Map(); // `${tabId}:${videoId}` -> record
    this.tabGenerations = new Map(); // tabId -> generation counter
  }

  /// Returns the current snapshot, starting the shared inspection when none
  /// exists (or when `force` restarts a stale/terminal one). Popup and
  /// overlay both call this; only the first caller triggers work.
  ensure({ tabId, url, force = false }) {
    const videoId = this.videoIdFromURL(url);
    if (!videoId || !Number.isInteger(tabId) || tabId < 0) return null;
    const key = this.key(tabId, videoId);
    const now = this.now();
    let record = this.records.get(key);
    // Identity validation: records left over after
    // a generation change or cancellation must not be consumed; a request
    // with the same videoId differing only in query params must get a
    // snapshot consumable for the current URL.
    if (record && !this.alive(record)) {
      this.records.delete(key);
      record = null;
    }
    if (record) {
      // The snapshot's pageUrl must reflect the requesting URL so the
      // presentation layer can consume the current candidate.
      record.url = url;
      if (record.inFlight) {
        if (now - record.lastUpdatedAt > this.limits.staleInFlightMs) {
          // Presumed lost to SW eviction: restart instead of hanging forever.
          record.cancelled = true;
          record = null;
        } else if (force) {
          // Explicit user retry wins over the in-flight run.
          record.cancelled = true;
          record = null;
        } else {
          return this.snapshot(record);
        }
      } else if (
        !force
        && TERMINAL_STAGES.has(record.stage)
        && now - record.lastUpdatedAt <= this.limits.terminalTtlMs
      ) {
        return this.snapshot(record);
      } else {
        record = null;
      }
    }
    if (!record) {
      record = {
        tabId,
        videoId,
        url,
        generation: this.tabGenerations.get(tabId) ?? 0,
        stage: YOUTUBE_INSPECTION_STAGES.discovered,
        source: null,
        variants: [],
        stableRounds: 0,
        safeReason: null,
        message: null,
        inFlight: true,
        cancelled: false,
        startedAt: now,
        lastUpdatedAt: now,
      };
      this.records.set(key, record);
      this.run(record).catch(() => {
        record.inFlight = false;
      });
    }
    return this.snapshot(record);
  }

  /// User-triggered re-parse for partial/failed outcomes (spec §5.3 #6).
  retry({ tabId, url }) {
    return this.ensure({ tabId, url, force: true });
  }

  /// SPA navigation: bump the tab generation and drop records belonging to
  /// other videos. Old in-flight loops observe the generation change and
  /// stop; their results are never published for the new video.
  /// Same videoId with only query-parameter changes is not a generation
  /// change: sync the record's URL and generation to
  /// keep it usable; never leave it in a "kept but alive == false" state.
  handleTabNavigated(tabId, url) {
    if (!Number.isInteger(tabId) || tabId < 0) return;
    const generation = (this.tabGenerations.get(tabId) ?? 0) + 1;
    this.tabGenerations.set(tabId, generation);
    const newVideoId = typeof url === "string" ? this.videoIdFromURL(url) : null;
    for (const [key, record] of this.records) {
      if (record.tabId !== tabId) continue;
      if (newVideoId && record.videoId === newVideoId) {
        record.url = url;
        record.generation = generation;
        continue;
      }
      record.cancelled = true;
      this.records.delete(key);
    }
  }

  handleTabRemoved(tabId) {
    for (const [key, record] of this.records) {
      if (record.tabId === tabId) this.records.delete(key);
    }
    this.tabGenerations.delete(tabId);
  }

  snapshotForURL(tabId, url) {
    const videoId = this.videoIdFromURL(url);
    if (!videoId) return null;
    const record = this.records.get(this.key(tabId, videoId));
    return record ? this.snapshot(record) : null;
  }

  // ---- internals ----

  key(tabId, videoId) {
    return `${tabId}:${videoId}`;
  }

  videoIdFromURL(url) {
    return globalThis.MacIDMYouTubeFormats?.videoIdFromPageURL?.(url) ?? null;
  }

  alive(record) {
    if (record.cancelled) return false;
    if (this.records.get(this.key(record.tabId, record.videoId)) !== record) return false;
    return (this.tabGenerations.get(record.tabId) ?? 0) === record.generation;
  }

  variantSignature(variants) {
    const signatureOf = globalThis.MacIDMYouTubeFormats?.variantSetSignature
      ?? ((list) => JSON.stringify(list));
    return signatureOf(variants ?? []);
  }

  /// Cancellable pacing wait: short steps keep SPA navigation / generation
  /// invalidation responsive, so a fresh page never waits out the previous
  /// video's sleep.
  async restFor(record, ms) {
    const stepMs = 100;
    let waited = 0;
    while (waited < ms && this.alive(record)) {
      const step = Math.min(stepMs, ms - waited);
      await this.sleep(step);
      waited += step;
    }
  }

  snapshot(record) {
    return {
      tabId: record.tabId,
      pageUrl: record.url,
      videoId: record.videoId,
      generation: record.generation,
      stage: record.stage,
      source: record.source,
      variants: record.variants,
      variantCount: record.variants.length,
      stableRounds: record.stableRounds,
      lastUpdatedAt: record.lastUpdatedAt,
      // Terminal snapshots must not still carry mayComplete: true
      // It is derived from "non-terminal and
      // still running".
      mayComplete: record.inFlight && !TERMINAL_STAGES.has(record.stage),
      safeReason: record.safeReason,
      message: record.message,
      retryable: RETRYABLE_STAGES.has(record.stage),
    };
  }

  publishRecord(record) {
    // Results from stale records after an SPA generation change or
    // cancellation must not be published (§9).
    if (!this.alive(record)) return;
    record.lastUpdatedAt = this.now();
    // Only user-visible semantic changes publish: identical snapshots must
    // not retrigger Popup/overlay rebuilds. The
    // signature includes every semantic field that affects the UI: message
    // also participates in dedup and must not change silently outside the
    // signature (§9).
    const signature = [
      record.stage,
      record.source,
      record.safeReason,
      record.message,
      record.variants.length,
      this.variantSignature(record.variants),
    ].join("|");
    if (signature === record.lastPublishedSignature) return;
    record.lastPublishedSignature = signature;
    try {
      this.publish(record.tabId, this.snapshot(record));
    } catch {
      // Publishing is best-effort; the next ensure() still returns state.
    }
  }

  /// Terminal publish (§9): set inFlight = false first; a terminal snapshot
  /// must never be allowed to carry mayComplete: true.
  publishTerminal(record) {
    record.inFlight = false;
    this.publishRecord(record);
  }

  async run(record) {
    try {
      await this.runPagePhase(record);
      if (!this.alive(record) || TERMINAL_STAGES.has(record.stage)) return;
      await this.runFallback(record);
    } catch {
      // Unexpected exceptions must also converge to a terminal stage within
      // bounded time (§9): keep the existing variants, publish partial when
      // any results exist and failed otherwise; safeReason uses a safe
      // internal category and never forwards raw exception text.
      if (this.alive(record) && !TERMINAL_STAGES.has(record.stage)) {
        record.stage = record.variants.length > 0
          ? YOUTUBE_INSPECTION_STAGES.partial
          : YOUTUBE_INSPECTION_STAGES.failed;
        record.safeReason = "internalError";
        record.message = null;
        this.publishTerminal(record);
      }
    } finally {
      record.inFlight = false;
    }
  }

  /// Bounded page observation (spec §5.8): poll the content script every
  /// pagePollMs within pageBudgetMs, publish every newly discovered format
  /// set immediately, and complete on the stable signal (two identical
  /// result sets at least stableGapMs apart). Non-terminal rounds wait a
  /// full pagePollMs between observations — a busy loop here used to
  /// re-render the Popup/overlay thousands of times per seconds.
  async runPagePhase(record) {
    record.stage = YOUTUBE_INSPECTION_STAGES.pageInspecting;
    this.publishRecord(record);
    const merge = globalThis.MacIDMYouTubeFormats?.mergeVariantLists ?? ((a, b) => [...(a ?? []), ...(b ?? [])]);
    const signatureOf = globalThis.MacIDMYouTubeFormats?.variantSetSignature
      ?? ((variants) => JSON.stringify(variants));
    const deadline = this.now() + this.limits.pageBudgetMs;
    let lastSignature = "";
    let lastMatchAt = 0;
    while (this.now() < deadline && this.alive(record)) {
      let pageResult = null;
      try {
        // The coordinator owns the cadence: the content script answers an
        // immediate read instead of blocking for the whole poll interval.
        pageResult = await this.requestPageQualities(record.tabId, {
          type: "macidm.getYouTubeQualities",
          pageUrl: record.url,
          waitMs: 0,
        });
      } catch {
        pageResult = null;
      }
      if (!this.alive(record)) return;
      // A page-identified blocked live phase short-circuits: no long
      // App/yt-dlp fallback for streams that can never download.
      if (pageResult?.ok === false && pageResult.reason === "liveUnsupported") {
        record.stage = YOUTUBE_INSPECTION_STAGES.unsupported;
        record.safeReason = "liveUnsupported";
        this.publishTerminal(record);
        return;
      }
      if (
        pageResult?.ok === true
        && Array.isArray(pageResult.variants)
        && pageResult.variants.length > 0
      ) {
        const before = record.variants.length;
        record.variants = merge(record.variants, pageResult.variants);
        record.source = "page";
        record.safeReason = null;
        const signature = signatureOf(record.variants);
        if (signature === lastSignature) {
          record.stableRounds += 1;
          if (this.now() - lastMatchAt >= this.limits.stableGapMs) {
            record.stage = YOUTUBE_INSPECTION_STAGES.complete;
            this.publishTerminal(record);
            return;
          }
        } else {
          lastSignature = signature;
          lastMatchAt = this.now();
          record.stage = YOUTUBE_INSPECTION_STAGES.pagePartial;
        }
        if (record.variants.length !== before || record.stage === YOUTUBE_INSPECTION_STAGES.pagePartial) {
          this.publishRecord(record);
        }
      } else {
        record.stage = record.variants.length > 0
          ? YOUTUBE_INSPECTION_STAGES.pagePartial
          : YOUTUBE_INSPECTION_STAGES.pageWaitingForStableData;
        if (pageResult?.ok === false && typeof pageResult.reason === "string") {
          record.safeReason = pageResult.reason;
        }
        this.publishRecord(record);
      }
      // Paced wait before the next observation; aborts early when the
      // record is cancelled (SPA navigation / user retry).
      if (this.now() < deadline && this.alive(record)) {
        await this.restFor(record, this.limits.pagePollMs);
      }
    }
  }

  /// One shared App/yt-dlp fallback (spec §5.8 #4–#6). Merges with any page
  /// variants by stable key; keeps partial results on failure instead of
  /// replacing them with a generic network error.
  async runFallback(record) {
    record.stage = YOUTUBE_INSPECTION_STAGES.fallbackInspecting;
    this.publishRecord(record);
    let appResult = null;
    try {
      appResult = await this.appInspector({ tabId: record.tabId, url: record.url });
    } catch (error) {
      appResult = { ok: false, message: String(error?.message ?? "") };
    }
    if (!this.alive(record)) return;
    const merge = globalThis.MacIDMYouTubeFormats?.mergeVariantLists ?? ((a, b) => [...(a ?? []), ...(b ?? [])]);
    if (
      appResult?.ok === true
      && Array.isArray(appResult.variants)
      && appResult.variants.length > 0
    ) {
      const hadPageVariants = record.variants.length > 0;
      record.variants = merge(record.variants, appResult.variants);
      record.source = hadPageVariants ? "merged" : "app-ytdlp";
      record.stage = YOUTUBE_INSPECTION_STAGES.complete;
      record.safeReason = null;
    } else if (record.variants.length > 0) {
      record.stage = YOUTUBE_INSPECTION_STAGES.partial;
      record.safeReason = safeCategoryFromAppResult(appResult);
      record.message = typeof appResult?.message === "string" ? appResult.message : null;
    } else {
      record.stage = YOUTUBE_INSPECTION_STAGES.failed;
      record.safeReason = safeCategoryFromAppResult(appResult);
      record.message = typeof appResult?.message === "string" ? appResult.message : null;
    }
    // All three branches are terminal: set inFlight=false before
    // publishing (§9).
    this.publishTerminal(record);
  }
}

/// Safe error category for the App/yt-dlp fallback outcome (spec §5.4).
/// Internal categories stay distinct; user-facing copy maps them later.
export function safeCategoryFromAppResult(result) {
  if (!result || typeof result !== "object") return "unknown";
  if (result.timedOut === true) return "timeout";
  const category = String(result.errorCategory ?? "");
  if (category) return category;
  return "unknown";
}
