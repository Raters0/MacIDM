export const HOST_NAME = "com.macidm.host";
export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 256 * 1024;
export const NATIVE_TIMEOUT_MS = 15000;
// Interactive requests show a confirmation dialog in the App; the user
// may take well over 15 seconds to review filename and destination.
export const INTERACTIVE_TIMEOUT_MS = 120000;
// YouTube inspection via yt-dlp can take significantly longer — yt-dlp must
// fetch the page, decode player challenges, and enumerate formats.
export const INSPECT_YOUTUBE_TIMEOUT_MS = 90000;
// HLS/DASH/HTTP manifest parsing should complete quickly.
export const INSPECT_TIMEOUT_MS = 15000;
export const MENU_DOWNLOAD_LINK = "macidm-download-link";
export const MENU_DOWNLOAD_ALL = "macidm-download-all";
export const STORAGE_SETTINGS_KEY = "settings";
export const STORAGE_LAST_ERROR_KEY = "lastSafeError";
export const STORAGE_PENDING_KEY = "pendingTakeovers";
export const STORAGE_PROFILE_ID_KEY = "profileInstanceId";

export const DEFAULT_SETTINGS = Object.freeze({
  takeoverEnabled: true,
  // When true, MacIDM takes over every download regardless of file type or
  // site allow-list — the extension is always-on. Individual sites can still
  // be blocked via blockedSites.
  takeoverAllDownloads: true,
  // IDM-style: show a confirmation dialog (filename/path) before starting.
  takeoverInteractive: true,
  minimumBytes: 5 * 1024 * 1024,
  takeoverUnknownSize: false,
  extensions: [
    "zip", "dmg", "iso", "pkg", "pdf", "mp4", "7z", "rar",
    "exe", "msi", "deb", "rpm", "apk", "aab", "xapk",
    "mp3", "m4a", "flac", "wav", "aac", "ogg",
    "mkv", "mov", "avi", "webm", "m4v", "flv",
    "doc", "docx", "xls", "xlsx", "ppt", "pptx",
    "tar", "gz", "bz2", "xz", "tgz",
    "bin", "img", "vmdk", "ova", "qcow2",
  ],
  allowedSites: [],
  blockedSites: [],
  // Sniff false-positive governance (version 2). Thresholds match
  // DEFAULT_SNIFF_GOVERNANCE in shared/sniff-governance.js (classic scripts
  // cannot import ES modules, so the defaults are intentionally duplicated;
  // unit-test parity checks keep them in sync); reads must go through
  // normalizeSniffGovernance, which validates and migrates field by field —
  // never trust stored values directly.
  sniffGovernance: Object.freeze({
    enabled: true,
    minimumMediaBytes: 0,
    audioMinimumBytes: 64 * 1024,
    segmentMaximumBytes: 16 * 1024,
  }),
});
