// YouTube feed-preview identity cache (chrome-extension-spec §5.8).
//
// The floating hover-preview player (`ytd-video-preview` → `#inline-preview-player`)
// is mounted at the app level, outside every card, and its DOM carries no
// video identity: the card link is not an ancestor and the preview's own
// `#media-container-link` has no href. The identity therefore arrives from the
// MAIN-world player bridge (videoId + title only, never a signed media URL)
// and this module holds it for exactly as long as that preview player is live,
// so a list/homepage hover card can be attributed like a Bilibili preview card.
//
// Fail-closed rules:
// - Only youtube.com hosts, and only while a preview <video> is actually
//   playing a blob source (the host element stays mounted after playback
//   stops, and the same player is reused for the next hovered card).
// - No time-based grace: an identity that outlived its own playback would
//   label another video's player. A live preview that is not identified yet
//   simply has no row until the bridge answers (the content script asks for an
//   immediate reread), and the cache is cleared on every SPA transition.
(function installYouTubePreviewIdentity(global) {
  if (global.MacIDMYouTubePreview) return;

  const MAX_TITLE = 200;
  const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{5,}$/u;
  let entry = null;

  function isYouTubeHost(value) {
    try {
      const host = new URL(String(value ?? "")).hostname.toLowerCase().replace(/^www\./u, "");
      return host === "youtube.com" || host.endsWith(".youtube.com");
    } catch {
      return false;
    }
  }

  /// Canonical watch URL for a videoId: the same shape the App's YouTube
  /// extractor accepts, and the identity key the adapter row is scoped by.
  function watchURLForVideoID(videoId) {
    return VIDEO_ID_PATTERN.test(String(videoId ?? ""))
      ? `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}`
      : null;
  }

  // DOM-only liveness, readable from the ISOLATED world: YouTube empties the
  // preview element's src and drops its readyState when the hover ends, while
  // `ytd-video-preview` itself stays in the document.
  function hasLivePreviewPlayer(doc) {
    try {
      const video = doc?.querySelector?.("ytd-video-preview video");
      if (!video || Number(video.readyState) < 1) return false;
      const source = video.currentSrc || video.getAttribute?.("src") || "";
      return String(source).startsWith("blob:");
    } catch {
      return false;
    }
  }

  /// Accept one bridge payload. Returns true when the stored identity changed
  /// (the caller forces a candidate re-publish); a repeated identical payload
  /// is a no-op.
  function store(payload) {
    const videoId = typeof payload?.videoId === "string" ? payload.videoId.trim() : "";
    if (!VIDEO_ID_PATTERN.test(videoId)) return false;
    const title = typeof payload?.title === "string"
      ? payload.title.replace(/\s+/gu, " ").trim().slice(0, MAX_TITLE)
      : "";
    const previous = entry;
    entry = { videoId, title };
    return !previous || previous.videoId !== videoId || previous.title !== title;
  }

  /// The live preview identity, or null. `livePlayer` lets the caller supply
  /// its own liveness answer (unit tests, or a document this module cannot
  /// see); it defaults to a DOM read of `doc`.
  function current(doc, pageURL, options = {}) {
    if (!entry) return null;
    const href = String(pageURL ?? doc?.location?.href ?? "");
    if (!isYouTubeHost(href)) return null;
    const live = typeof options.livePlayer === "boolean"
      ? options.livePlayer
      : hasLivePreviewPlayer(doc);
    if (!live) return null;
    const url = watchURLForVideoID(entry.videoId);
    if (!url) return null;
    return { siteAdapter: "youtube", videoId: entry.videoId, pageURL: url, title: entry.title };
  }

  /// Preview identities for candidate coalescing: at most one, because YouTube
  /// mounts a single shared preview player.
  function identities(doc, pageURL, options = {}) {
    const identity = current(doc, pageURL, options);
    return identity ? [identity] : [];
  }

  function clear() {
    entry = null;
  }

  global.MacIDMYouTubePreview = Object.freeze({
    store,
    current,
    identities,
    clear,
    hasLivePreviewPlayer,
    watchURLForVideoID,
  });
})(globalThis);
