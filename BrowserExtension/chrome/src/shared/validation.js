export function isHttpURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function filenameFromDownload(item) {
  const candidates = [
    item.filename?.split(/[\\/]/).pop(),
    (() => {
      try {
        return new URL(item.finalUrl || item.url).pathname.split("/").pop();
      } catch {
        return null;
      }
    })(),
  ];
  for (const candidate of candidates) {
    let decoded;
    try {
      decoded = decodeURIComponent(candidate || "");
    } catch {
      decoded = candidate || "";
    }
    if (
      !decoded ||
      decoded === "." ||
      decoded === ".." ||
      decoded.toLowerCase() === "download" ||
      /[\\/\u0000-\u001f\u007f]/u.test(decoded)
    ) continue;
    if (new TextEncoder().encode(decoded).byteLength <= 255) return decoded;
  }
  return "download";
}

export function siteHost(value) {
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    return "";
  }
}

export function normalizeSettings(value, defaults) {
  const source = value && typeof value === "object" ? value : {};
  const extensions = Array.isArray(source.extensions)
    ? source.extensions.filter((item) => typeof item === "string" && /^[a-z0-9]{1,12}$/u.test(item))
    : defaults.extensions;
  const sites = (key) =>
    Array.isArray(source[key])
      ? source[key].filter((item) => typeof item === "string" && /^[a-z0-9.-]+$/u.test(item))
      : defaults[key];
  return {
    takeoverEnabled: source.takeoverEnabled !== false,
    takeoverAllDownloads: source.takeoverAllDownloads !== false,
    minimumBytes:
      Number.isSafeInteger(source.minimumBytes) && source.minimumBytes >= 0
        ? source.minimumBytes
        : defaults.minimumBytes,
    takeoverUnknownSize: source.takeoverUnknownSize === true,
    extensions,
    allowedSites: sites("allowedSites"),
    blockedSites: sites("blockedSites"),
  };
}
