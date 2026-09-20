import { DEFAULT_SETTINGS } from "../shared/constants.js";
import { filenameFromDownload, normalizeSettings, siteHost } from "../shared/validation.js";

/// True only for HTTP methods that carry a request body, which a GET replay
/// would lose (form data, signed payload, CSRF token). HEAD/OPTIONS/GET are
/// bodyless and safely replayable, so they must NOT be treated as non-replayable
/// — otherwise a player's HEAD probe of a media URL would suppress takeover of
/// the real GET download of that same URL.
export function isBodyCarryingMethod(method) {
  const upper = String(method || "").toUpperCase();
  return upper === "POST" || upper === "PUT" || upper === "PATCH" || upper === "DELETE";
}

export function shouldTakeover(item, storedSettings, explicit = false) {
  const settings = normalizeSettings(storedSettings, DEFAULT_SETTINGS);
  if (!settings.takeoverEnabled && !explicit) return { takeOver: false, reason: "disabled" };
  if (explicit) return { takeOver: true, reason: "explicit" };

  const host = siteHost(item.finalUrl || item.url);
  if (settings.blockedSites.includes(host)) return { takeOver: false, reason: "site-blocked" };

  // When takeoverAllDownloads is enabled (default), take over every download
  // that isn't on the blocked list, regardless of file type or site. This
  // makes MacIDM behave like IDM — always intercept when the extension is on.
  if (settings.takeoverAllDownloads) {
    return { takeOver: true, reason: "takeover-all" };
  }

  const siteAllowed = settings.allowedSites.includes(host);
  const filename = filenameFromDownload(item);
  const extension = filename.includes(".") ? filename.split(".").pop().toLowerCase() : "";
  if (!siteAllowed && !settings.extensions.includes(extension)) {
    return { takeOver: false, reason: "file-type" };
  }

  const size = Number.isSafeInteger(item.totalBytes) && item.totalBytes >= 0 ? item.totalBytes : null;
  if (size === null || size === 0) {
    return settings.takeoverUnknownSize
      ? { takeOver: true, reason: "unknown-size-enabled" }
      : { takeOver: false, reason: "unknown-size" };
  }
  if (size < settings.minimumBytes) return { takeOver: false, reason: "below-threshold" };
  return { takeOver: true, reason: siteAllowed ? "site-allowed" : "matched" };
}
