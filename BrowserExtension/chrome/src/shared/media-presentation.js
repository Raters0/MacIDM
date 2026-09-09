// BrowserExtension/chrome/src/shared/media-presentation.js
//
// Pure-data shared module: DOM-free pure functions shared by the Popup and
// the overlay panel. Covers candidateKey, snapshotKey, videoIdOf, YouTube
// inspection stage copy mapping, formatting, and variant size estimation.
//
// The Popup and the overlay keep their own DOM, focus, ARIA, Shadow DOM,
// and open state.
(function installMacIDMMediaPresentation(global) {
  if (global.MacIDMMediaPresentation) return;

  function candidateKey(candidate) {
    if (candidate?.siteAdapter === "youtube") {
      return global.MacIDMYouTubeFormats?.youTubeStateKey?.(candidate.url) ?? candidate.url ?? "";
    }
    return candidate?.url ?? "";
  }

  function snapshotKey(snapshot) {
    return snapshot?.videoId ? `youtube:${snapshot.videoId}` : snapshot?.pageUrl ?? "";
  }

  function videoIdOf(url) {
    return global.MacIDMYouTubeFormats?.videoIdFromPageURL?.(url) ?? "";
  }

  function youTubeStageText(snapshot, t = (k) => k) {
    if (!snapshot || !snapshot.mayComplete) return null;
    switch (snapshot.stage) {
      case "discovered":
      case "pageInspecting":
        return t("youtube.stagePageInspecting");
      case "pageWaitingForStableData":
        return t("youtube.stageWaiting");
      case "pagePartial":
        return t("youtube.stageCollecting");
      case "fallbackInspecting":
        return t("youtube.stageFallback");
      default:
        return null;
    }
  }

  function formatBytes(value) {
    return global.MacIDMMediaUtils?.formatBytes?.(value) ?? null;
  }

  function formatDuration(seconds) {
    return global.MacIDMMediaUtils?.formatDuration?.(seconds) ?? null;
  }

  function estimatedSizeForVariant(variant) {
    if (!variant) return null;
    const directSize = Number.isSafeInteger(variant.estimatedSize) && variant.estimatedSize >= 0
      ? variant.estimatedSize
      : null;
    const estimateFn = global.MacIDMMediaUtils?.estimateVariantSize;
    const estimatedSize = directSize ?? (estimateFn ? estimateFn(variant) : null);
    return Number.isSafeInteger(estimatedSize) && estimatedSize >= 0 ? estimatedSize : null;
  }

  function defaultHasVariantInfo(variant) {
    if (!variant) return false;
    const labelFn = global.MacIDMMediaUtils?.variantDisplayLabel;
    if (typeof labelFn === "function") {
      return (labelFn(variant) ?? "").trim() !== "";
    }
    return Boolean(variant.label || variant.height || variant.resolution || variant.format);
  }

  // Variants are display-ordered from highest quality downward. Only label
  // the main-row estimate as "highest spec" when a meaningful variant itself has
  // an estimate; never show a lower spec's size under a higher-spec label,
  // and return null if no meaningful variant matches.
  function estimateCandidateSize(candidate, youTubeInspections, hasVariantInfoPredicate = defaultHasVariantInfo) {
    if (!candidate) return null;
    const key = candidateKey(candidate);
    const snapshot = youTubeInspections instanceof Map
      ? youTubeInspections.get(key)
      : youTubeInspections?.[key];
    const variants = candidate.siteAdapter === "youtube"
      ? (snapshot?.variants ?? candidate.variants)
      : candidate.variants;
    if (!Array.isArray(variants) || variants.length === 0) return null;
    const predicate = typeof hasVariantInfoPredicate === "function" ? hasVariantInfoPredicate : defaultHasVariantInfo;
    const primaryVariant = variants.find(predicate);
    return primaryVariant ? estimatedSizeForVariant(primaryVariant) : null;
  }

  const api = Object.freeze({
    candidateKey,
    snapshotKey,
    videoIdOf,
    youTubeStageText,
    formatBytes,
    formatDuration,
    estimatedSizeForVariant,
    hasVariantInfo: defaultHasVariantInfo,
    estimateCandidateSize,
  });

  global.MacIDMMediaPresentation = api;

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
