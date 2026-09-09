import { DEFAULT_SETTINGS } from "../shared/constants.js";
import { filenameFromDownload, normalizeSettings, siteHost } from "../shared/validation.js";

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
