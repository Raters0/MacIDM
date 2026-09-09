// File-category classification shared by Popup, overlay and download-all.
// The extension table mirrors the App's DownloadCategory(filename:) in
// Sources/MacIDMApp/Models/AppTask.swift — keep both lists aligned when
// either changes (there: extensionsByCategory equivalents live in the
// `init(filename:mimeType:)` switch plus `categoryForMIMEType`, same file).
// Classification is extension-first with a MIME fallback, so extension-less
// CDN URLs still land in the right category.
(function installCategoryUtils(global) {
  const CATEGORIES = ["archive", "document", "image", "audio", "video", "application", "other"];

  const extensionsByCategory = {
    archive: [
      "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz",
      "zst", "lz4", "lzma", "cab", "arj", "lzh", "wim", "esd", "egg", "alz",
    ],
    document: [
      "pdf", "doc", "docx", "xls", "xlsx", "xlsb", "ppt", "pptx",
      "txt", "md", "epub", "csv", "rtf", "odt", "ods", "odp",
      "pages", "numbers", "key", "mobi", "azw", "azw3", "djvu",
      "chm", "tex", "wps", "json", "xml", "yaml", "html",
    ],
    image: [
      "jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "bmp",
      "tiff", "tif", "ico", "avif", "jxl", "raw", "cr2", "nef",
      "arw", "dng", "orf", "psd", "ai", "eps",
    ],
    audio: [
      "mp3", "aac", "flac", "wav", "m4a", "ogg", "opus", "wma",
      "aiff", "aif", "ape", "dts", "ac3", "m4b", "amr", "mid",
      "midi", "dsf", "dff",
    ],
    video: [
      "mp4", "mov", "mkv", "webm", "avi", "m4v", "flv", "mpg",
      "mpeg", "wmv", "ts", "m2ts", "mts", "vob", "3gp", "ogv", "rmvb", "mxf",
    ],
    application: [
      "dmg", "pkg", "app", "exe", "msi", "msix", "appx", "apk",
      "aab", "xapk", "ipa", "deb", "rpm", "iso", "appimage",
      "flatpak", "snap", "jar", "crx", "xpi", "vsix",
    ],
  };
  const categoryByExtension = new Map();
  for (const [category, extensions] of Object.entries(extensionsByCategory)) {
    for (const ext of extensions) categoryByExtension.set(ext, category);
  }

  const mimeByCategory = {
    archive: [
      "application/zip", "application/x-rar-compressed", "application/vnd.rar",
      "application/x-7z-compressed", "application/x-tar", "application/gzip",
      "application/x-bzip2", "application/x-xz", "application/zstd",
      "application/x-zstd", "application/x-lz4", "application/x-lzma",
    ],
    document: [
      "application/pdf", "application/msword",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/vnd.ms-excel",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "application/vnd.ms-powerpoint",
      "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "text/plain", "text/markdown", "text/csv", "application/epub+zip",
      "application/vnd.apple.pages", "application/vnd.apple.numbers",
      "application/vnd.apple.keynote", "application/x-mobipocket-ebook",
      "application/vnd.amazon.mobi8-ebook", "application/vnd.ms-htmlhelp",
      "application/x-tex", "application/json", "application/xml",
      "text/xml", "text/yaml", "text/html",
    ],
    application: [
      "application/vnd.android.package-archive", "application/x-apple-diskimage",
      "application/x-msdownload", "application/x-msi",
      "application/vnd.debian.binary-package", "application/x-rpm",
      "application/x-diskcopy",
    ],
  };
  const categoryByMIME = new Map();
  for (const [category, mimes] of Object.entries(mimeByCategory)) {
    for (const mime of mimes) categoryByMIME.set(mime, category);
  }

  function extensionOf(value) {
    if (typeof value !== "string" || !value) return "";
    let pathname = value;
    try {
      pathname = new URL(value).pathname;
    } catch { /* treat as a plain filename */ }
    const name = decodeURIComponent(pathname.split("/").pop() || "");
    const dot = name.lastIndexOf(".");
    if (dot <= 0 || dot === name.length - 1) return "";
    return name.slice(dot + 1).toLowerCase();
  }

  function normalizeMIME(value) {
    return String(value || "").toLowerCase().split(";")[0].trim();
  }

  /// Extension-first classification; MIME decides when the extension is not
  /// recognized. Returns one of CATEGORIES, never null.
  function categoryFor(nameOrURL, mime = "") {
    const byExtension = categoryByExtension.get(extensionOf(nameOrURL));
    if (byExtension) return byExtension;
    const type = normalizeMIME(mime);
    if (type.startsWith("image/")) return "image";
    if (type.startsWith("audio/")) return "audio";
    if (type.startsWith("video/")) return "video";
    return categoryByMIME.get(type) || "other";
  }

  /// Classifies a sniffed media candidate. Streaming manifests and site
  /// adapters are video by definition regardless of filename/MIME.
  function categoryForCandidate(candidate) {
    if (!candidate) return "other";
    if (candidate.format === "hls" || candidate.format === "dash" || candidate.siteAdapter) {
      return "video";
    }
    return categoryFor(candidate.filenameHint || candidate.url || "", candidate.mime);
  }

  // Inline SVG silhouettes matching the App's SF Symbols choices
  // (archivebox / doc / photo / music.note / film / shippingbox / tray),
  // drawn on a 16×16 stroke grid and colored via currentColor.
  const iconPaths = {
    archive:
      '<rect x="1.5" y="2" width="13" height="3.5" rx="1"/>' +
      '<path d="M3 5.5v7A1.5 1.5 0 0 0 4.5 14h7a1.5 1.5 0 0 0 1.5-1.5v-7"/>' +
      '<path d="M6.25 8.5h3.5"/>',
    document:
      '<path d="M4.5 1.5h4.5L13 5.5V13.5a1 1 0 0 1-1 1H4.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1Z"/>' +
      '<path d="M9 1.5v4h4"/>' +
      '<path d="M5.75 9h4.5M5.75 11.5h4.5"/>',
    image:
      '<rect x="1.75" y="2.5" width="12.5" height="11" rx="1.5"/>' +
      '<circle cx="5.4" cy="6.1" r="1.15"/>' +
      '<path d="M2.5 12.2l3-3 2.3 2.3 2.9-3 3.5 3.5"/>',
    audio:
      '<path d="M7.4 12.1V3l5.1-1.1v3l-5.1 1.1"/>' +
      '<circle cx="5.5" cy="12.1" r="1.9"/>',
    video:
      '<rect x="2" y="2" width="12" height="12" rx="1.5"/>' +
      '<path d="M5.2 2v12M10.8 2v12"/>' +
      '<path d="M2 5.7h3.2M2 10.3h3.2M10.8 5.7H14M10.8 10.3H14"/>',
    application:
      '<path d="M8 1.75 13.75 4.5v7L8 14.25 2.25 11.5v-7L8 1.75Z"/>' +
      '<path d="M2.25 4.5 8 7.25 13.75 4.5M8 7.25v7"/>',
    other:
      '<path d="M2 9.25 3.6 3.25h8.8L14 9.25v3.25a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V9.25Z"/>' +
      '<path d="M2 9.25h3.5l1 1.5h3l1-1.5H14"/>',
  };

  /// Standalone SVG markup for a category icon. `size` is CSS pixels; the
  /// color follows `currentColor` so callers control it via CSS.
  function categoryIconSVG(category, size = 16) {
    const paths = iconPaths[category] || iconPaths.other;
    return (
      `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" ` +
      `stroke="currentColor" stroke-width="1.3" stroke-linecap="round" ` +
      `stroke-linejoin="round" aria-hidden="true">${paths}</svg>`
    );
  }

  /// i18n key for the category's localized display name (e.g. "Archive").
  function categoryLabelKey(category) {
    const safe = CATEGORIES.includes(category) ? category : "other";
    return `common.category.${safe}`;
  }

  global.MacIDMCategory = Object.freeze({
    CATEGORIES: Object.freeze([...CATEGORIES]),
    categoryFor,
    categoryForCandidate,
    categoryIconSVG,
    categoryLabelKey,
  });
})(globalThis);
