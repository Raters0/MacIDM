// MacIDM sniff false-positive governance (noise suppression that is
// explainable and reversible). Loaded as a classic script (content scripts,
// popup) and also imported as a module by the service worker — it has no
// `export` statements, so it executes identically in both modes and installs
// `globalThis.MacIDMSniffGovernance`.
//
// Spec: docs/specifications/chrome-extension-spec.md ("false-positive
// suppression / noise threshold configuration") and
// docs/specifications/technical-spec.md §8.4. The criteria are conservative:
// audio with unknown size or duration >10 seconds is not treated as noise;
// site-adapter candidates and full-track m4s are never suppressed; without
// manifest evidence, segments are always kept (prefer keeping noise over
// killing a direct link). Suppression only affects the current page session's
// in-memory candidates and is invoked by the content-script at snapshot
// time; page navigation clears it along with the candidate cache.
(function installMacIDMSniffGovernance(global) {
  if (global.MacIDMSniffGovernance) return;

  // Mirrors DEFAULT_SETTINGS.sniffGovernance in constants.js; classic
  // scripts cannot import ES modules, so the defaults are duplicated
  // deliberately (the unit parity test keeps them in sync).
  const DEFAULT_SNIFF_GOVERNANCE = Object.freeze({
    enabled: true,
    // Generic minimum resource size (added in version 2): known-size
    // candidates below this value are filtered as noise; 0 disables the
    // filter. Unknown-size candidates (most video streams) are never
    // filtered by it.
    minimumMediaBytes: 0,
    audioMinimumBytes: 64 * 1024,
    segmentMaximumBytes: 16 * 1024,
  });

  // Threshold upper bound (safe integers, 0–64 MiB), matching
  // technical-spec §8.4.
  const MAX_THRESHOLD_BYTES = 64 * 1024 * 1024;
  const MAX_SUMMARY_COUNT = 100_000;

  function normalizeThreshold(value, fallback) {
    if (!Number.isSafeInteger(value) || value < 0 || value > MAX_THRESHOLD_BYTES) return fallback;
    return value;
  }

  /// Validates field by field and migrates on read: missing or invalid
  /// fields fall back to defaults. Consumers (service-worker
  /// settingsProvider / content-script / unit tests) must not trust old
  /// chrome.storage values directly.
  function normalizeSniffGovernance(raw) {
    const source = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
    return {
      enabled: typeof source.enabled === "boolean" ? source.enabled : DEFAULT_SNIFF_GOVERNANCE.enabled,
      minimumMediaBytes: normalizeThreshold(
        source.minimumMediaBytes,
        DEFAULT_SNIFF_GOVERNANCE.minimumMediaBytes,
      ),
      audioMinimumBytes: normalizeThreshold(
        source.audioMinimumBytes,
        DEFAULT_SNIFF_GOVERNANCE.audioMinimumBytes,
      ),
      segmentMaximumBytes: normalizeThreshold(
        source.segmentMaximumBytes,
        DEFAULT_SNIFF_GOVERNANCE.segmentMaximumBytes,
      ),
    };
  }

  function hostOf(value) {
    try {
      return new URL(value).hostname.toLowerCase();
    } catch {
      return "";
    }
  }

  /// `init`/`bootstrap` initialization segments: the filename stem contains
  /// a standalone init/bootstrap token (`init.mp4`, `0-init.m4s`,
  /// `bootstrap_1.mp4`). Prefix words like `initial.mp4` do not count — the
  /// criterion is conservative to avoid killing direct links.
  function isInitOrBootstrapName(candidate) {
    try {
      const filename = decodeURIComponent(
        new URL(candidate.url).pathname.split("/").pop() ?? "",
      );
      const stem = filename.replace(/\.[a-z0-9]{1,8}$/iu, "");
      return /(?:^|[-_.])(?:init|bootstrap)(?:[-_.]|$)/iu.test(stem);
    } catch {
      return false;
    }
  }

  /// Full-track m4s (`{cid}-1-{formatId}.m4s`) from DASH sites such as
  /// Bilibili are the source of paired (m4s-pair) candidates and are never
  /// suppressed, no matter how small.
  function isM4STrackCandidate(candidate) {
    try {
      const filename = decodeURIComponent(
        new URL(candidate.url).pathname.split("/").pop() ?? "",
      );
      return /^\d+-1-\d+\.m4s$/iu.test(filename);
    } catch {
      return false;
    }
  }

  function isManifestCandidate(candidate) {
    return candidate?.format === "hls" || candidate?.format === "dash"
      || candidate?.format === "dash-json";
  }

  function segmentExtensionOf(candidate) {
    const fromField = String(candidate?.fileExtension ?? "").toLowerCase().split("/")[0];
    if (/^[a-z0-9]{1,8}$/u.test(fromField)) return fromField;
    try {
      const filename = decodeURIComponent(
        new URL(candidate.url).pathname.split("/").pop() ?? "",
      ).toLowerCase();
      const match = filename.match(/\.([a-z0-9]{1,8})$/u);
      return match ? match[1] : "";
    } catch {
      return "";
    }
  }

  /// Diagnostic audio (player feedback sounds and the like): known size
  /// below the threshold and duration not >10 seconds. Audio with unknown
  /// size or duration >10 seconds is kept — prefer keeping noise over
  /// killing a direct link.
  function isDiagnosticAudio(candidate, settings) {
    if (candidate?.format !== "audio") return false;
    const size = candidate.size;
    if (!Number.isSafeInteger(size) || size < 0) return false;
    if (size >= settings.audioMinimumBytes) return false;
    const duration = candidate.duration;
    if (typeof duration === "number" && Number.isFinite(duration) && duration > 10) return false;
    return true;
  }

  /// Generic small resources (version 2): candidates with a known size
  /// below a threshold >0. Unknown-size candidates (most video streams,
  /// whose total size cannot be probed) are never filtered by it.
  function isSmallResource(candidate, settings) {
    if (settings.minimumMediaBytes <= 0) return false;
    const size = candidate?.size;
    if (!Number.isSafeInteger(size) || size < 0) return false;
    return size < settings.minimumMediaBytes;
  }

  /// Noise segments: `init`/`bootstrap` initialization segments, or tiny
  /// segments (m4s/ts/mp2t/mp4) once a same-origin manifest has appeared.
  /// Same-host manifest evidence is required; without it (cross-origin or
  /// same-origin alike) everything is kept.
  function isNoiseSegment(candidate, settings, manifestHosts) {
    if (isM4STrackCandidate(candidate)) return false;
    const host = hostOf(candidate?.url);
    if (!host || !manifestHosts.has(host)) return false;
    if (isInitOrBootstrapName(candidate)) return true;
    const size = candidate.size;
    if (!Number.isSafeInteger(size) || size < 0) return false;
    if (size > settings.segmentMaximumBytes) return false;
    return ["m4s", "ts", "mp2t", "mp4"].includes(segmentExtensionOf(candidate));
  }

  function bump(summary, key) {
    summary[key] = Math.min(summary[key] + 1, MAX_SUMMARY_COUNT);
  }

  /// Applies false-positive suppression to already-normalized candidates.
  /// Returns:
  ///   candidates      — kept candidates (the input array is untouched)
  ///   filteredSummary — redacted count summary with only the three
  ///                     0–100000 count keys diagnosticAudio /
  ///                     streamSegments / smallResources; no URLs or other
  ///                     free text.
  /// When governance is disabled, the input is returned as-is with zero
  /// counts.
  function applySniffGovernance(candidates, rawSettings) {
    const settings = normalizeSniffGovernance(rawSettings);
    const summary = { diagnosticAudio: 0, streamSegments: 0, smallResources: 0 };
    const input = Array.isArray(candidates) ? candidates : [];
    if (!settings.enabled) {
      return { candidates: input.slice(), filteredSummary: summary };
    }
    const manifestHosts = new Set(
      input
        .filter((candidate) => isManifestCandidate(candidate) && !candidate?.siteAdapter)
        .map((candidate) => hostOf(candidate?.url))
        .filter(Boolean),
    );
    const kept = [];
    for (const candidate of input) {
      if (!candidate || typeof candidate.url !== "string") continue;
      // Never suppressed: site-adapter candidates, paired m4s, manifests
      // themselves, blob/MSE placeholders.
      if (candidate.siteAdapter || candidate.pairKind === "m4s-pair") {
        kept.push(candidate);
        continue;
      }
      if (isManifestCandidate(candidate)
        || candidate.url.startsWith("blob:") || candidate.url.startsWith("mse:")) {
        kept.push(candidate);
        continue;
      }
      if (isDiagnosticAudio(candidate, settings)) {
        bump(summary, "diagnosticAudio");
        continue;
      }
      if (isNoiseSegment(candidate, settings, manifestHosts)) {
        bump(summary, "streamSegments");
        continue;
      }
      // The generic small-size threshold runs last: more specific
      // categories (diagnostic audio / noise segments) count first, so a
      // candidate is never classified twice.
      if (isSmallResource(candidate, settings)) {
        bump(summary, "smallResources");
        continue;
      }
      kept.push(candidate);
    }
    return { candidates: kept, filteredSummary: summary };
  }

  global.MacIDMSniffGovernance = Object.freeze({
    DEFAULT_SNIFF_GOVERNANCE,
    normalizeSniffGovernance,
    applySniffGovernance,
  });
})(globalThis);
