// YouTube MAIN-world player data bridge (chrome-extension-spec §5.8).
//
// DOM-element JS properties (ytd-watch-flexy.playerData) and
// window.ytInitialPlayerResponse only exist in the MAIN world; ISOLATED
// world content scripts cannot read them, which is why earlier reads kept
// returning noPlayerData. This bridge runs in the MAIN world, extracts only
// the bounded fields quality parsing needs (never signed media URLs), and
// hands them to the ISOLATED world via window.postMessage.
//
// Security constraints:
// - Only youtube.com watch surfaces are matched (manifest), top frame only.
// - The payload is bounded (field whitelist, format count and string caps).
// - Signed media URLs / signatureCipher are never read or forwarded.
// - Publishing is change-driven plus a low-frequency poll fallback; requests
//   from the content script trigger an immediate re-read.
// - The feed-preview identity is published only while that preview player is
//   live, and carries the videoId plus a length-capped title — no format list
//   and no media URL.
(function installMacIDMYouTubePlayerBridge(global) {
  if (global.__macIDMYouTubePlayerBridgeInstalled) return;
  global.__macIDMYouTubePlayerBridgeInstalled = true;

  const DATA_TYPE = "macidm.youTubePlayerData";
  const REQUEST_TYPE = "macidm.requestYouTubePlayerData";
  // Feed-preview identity (list/home/channel pages and a watch page's related
  // list): the floating preview player lives outside every card, so the card's
  // adapter identity can only come from this read.
  const PREVIEW_DATA_TYPE = "macidm.youTubePreviewIdentity";
  const PREVIEW_REQUEST_TYPE = "macidm.requestYouTubePreviewIdentity";
  const MAX_FORMATS = 150;
  const MAX_STRING = 500;
  const POLL_MS = 1_000;

  function clipString(value) {
    return typeof value === "string" && value ? value.slice(0, MAX_STRING) : undefined;
  }

  function clipNumber(value) {
    return Number.isFinite(value) ? value : undefined;
  }

  function expectedVideoID() {
    try {
      // Same rules as the shared module's videoIdFromPageURL (§4.3):
      // /watch?v=, /shorts/<id>, /live/<id>; a stale player response must
      // never leak into the new page.
      const isValidID = (id) => /^[A-Za-z0-9_-]{5,}$/.test(id || "");
      const pathname = global.location?.pathname ?? "";
      if (pathname === "/watch") {
        const v = new URLSearchParams(global.location.search).get("v");
        return isValidID(v) ? v : null;
      }
      const match = pathname.match(/^\/(?:shorts|live)\/([^/]+)/);
      if (match && isValidID(match[1])) return match[1];
    } catch {
      // fall through
    }
    return null;
  }

  // Candidate player responses in trust order: the live watch component
  // first (survives SPA navigation), then the app-level getter, then the
  // initial response which goes stale after SPA navigation.
  // Identity may only come from the unified parsing rules for the current
  // URL (chrome-extension-spec §5.8): home/search and other non-single-video
  // pages that yield no videoId must fail closed — components left over
  // after SPA navigation such as ytd-watch-flexy.playerData must not be
  // read, selected, or published; the bridge stays silent on non-video
  // pages, and old state is cleared by the content script's unified
  // navigation entry, so no empty snapshot needs publishing.
  function readPlayerResponse() {
    try {
      const expectedID = expectedVideoID();
      if (!expectedID) return null;
      const candidates = [];
      const flexy = document.querySelector("ytd-watch-flexy");
      if (flexy && flexy.playerData && typeof flexy.playerData === "object") {
        candidates.push(flexy.playerData);
      }
      const app = document.querySelector("ytd-app");
      if (app && typeof app.getPlayerResponse === "function") {
        try {
          const pr = app.getPlayerResponse();
          if (pr && typeof pr === "object") candidates.push(pr);
        } catch {
          // Player not ready yet.
        }
      }
      if (global.ytInitialPlayerResponse && typeof global.ytInitialPlayerResponse === "object") {
        candidates.push(global.ytInitialPlayerResponse);
      }
      for (const pr of candidates) {
        const id = pr?.videoDetails?.videoId;
        if (typeof id !== "string" || !id) continue;
        // SPA race: never hand the previous video's data to the new URL.
        if (id !== expectedID) continue;
        return pr;
      }
    } catch {
      // Fall through: structured no-data on the content-script side.
    }
    return null;
  }

  // Field whitelist extraction: quality parsing needs format metadata only.
  // url/signatureCipher/cipher are deliberately absent from this shape.
  // title is length-capped attribution evidence (chrome-extension-spec §5.8): it
  // comes from a player response that already passed the videoId check and
  // lets the content script confirm the new page's title; signed media
  // URLs, cipher and other unapproved fields are still never forwarded.
  function pickFormat(format) {
    if (!format || typeof format !== "object") return null;
    return {
      itag: clipNumber(format.itag),
      width: clipNumber(format.width),
      height: clipNumber(format.height),
      bitrate: clipNumber(format.bitrate),
      fps: clipNumber(format.fps),
      approxDurationMs: clipNumber(format.approxDurationMs),
      contentLength:
        typeof format.contentLength === "string"
          ? format.contentLength.slice(0, 32)
          : undefined,
      mimeType: clipString(format.mimeType),
    };
  }

  /// Stable business payload: contains no timestamps and is the sole input
  /// to the dedupe fingerprint (chrome-extension-spec §5.8). capturedAt is appended
  /// only after publishing is confirmed needed and must not take part in
  /// the fingerprint — otherwise every poll would change it, dedupe would
  /// be defeated, and a steady page would still resend the full snapshot
  /// every second.
  function extractPayload(pr) {
    const details = pr?.videoDetails ?? {};
    const streaming = pr?.streamingData ?? {};
    const pickList = (list) =>
      (Array.isArray(list) ? list : [])
        .map(pickFormat)
        .filter(Boolean)
        .slice(0, MAX_FORMATS);
    return {
      videoId: String(details.videoId).slice(0, 32),
      videoDetails: {
        videoId: String(details.videoId).slice(0, 32),
        title: clipString(details.title),
        lengthSeconds: clipString(details.lengthSeconds),
        isLive: details.isLive === true || details.isLive === false ? details.isLive : undefined,
        isUpcomingLive:
          details.isUpcomingLive === true || details.isUpcomingLive === false
            ? details.isUpcomingLive
            : undefined,
        isLiveContent:
          details.isLiveContent === true || details.isLiveContent === false
            ? details.isLiveContent
            : undefined,
      },
      streamingData: {
        formats: pickList(streaming.formats),
        adaptiveFormats: pickList(streaming.adaptiveFormats),
      },
    };
  }

  let lastFingerprint = "";
  let lastPreviewFingerprint = "";
  let requestScheduled = false;

  function publish(force = false) {
    try {
      const pr = readPlayerResponse();
      if (!pr) return;
      const payload = extractPayload(pr);
      // Change-driven publishing: the fingerprint covers only the stable
      // business fields (never capturedAt), so steady pages stay silent
      // even as time advances, while SPA navigation, a new videoId, late
      // format delivery and live-status changes all publish promptly.
      const fingerprint = JSON.stringify(payload);
      if (!force && fingerprint === lastFingerprint) return;
      lastFingerprint = fingerprint;
      payload.capturedAt = Date.now();
      global.postMessage({ type: DATA_TYPE, payload }, "*");
    } catch {
      // Structured silence: the content script treats absence as
      // noPlayerData and keeps its bounded fallback path.
    }
  }

  function schedulePublish() {
    if (requestScheduled) return;
    requestScheduled = true;
    global.setTimeout(() => {
      requestScheduled = false;
      publish();
      publishPreview();
    }, 120);
  }

  /// The floating hover-preview player's identity. Only a preview that is
  /// actually playing a blob source counts: `ytd-video-preview` stays mounted
  /// after the hover ends, and a stale videoId must never label another card.
  /// Payload is the bounded identity only — never a signed media URL.
  function readPreviewIdentity() {
    try {
      const host = document.querySelector("ytd-video-preview");
      if (!host || typeof host.querySelector !== "function") return null;
      const video = host.querySelector("video");
      if (!video || Number(video.readyState) < 1) return null;
      const source = video.currentSrc || video.getAttribute?.("src") || "";
      if (typeof source !== "string" || !source.startsWith("blob:")) return null;
      const player = host.querySelector("#inline-preview-player")
        || host.querySelector(".html5-video-player");
      if (!player || typeof player.getVideoData !== "function") return null;
      const data = player.getVideoData();
      const videoId = typeof data?.video_id === "string" ? data.video_id.trim() : "";
      // Same identity rule as the shared module (§4.5): reject a missing or
      // malformed id instead of publishing a row the App cannot resolve.
      if (!/^[A-Za-z0-9_-]{5,}$/.test(videoId)) return null;
      return { videoId, title: clipString(data?.title) };
    } catch {
      // Structured silence: the content script keeps the previous identity
      // within its grace window and then drops the preview row.
      return null;
    }
  }

  function publishPreview() {
    try {
      const identity = readPreviewIdentity();
      if (!identity) return;
      const fingerprint = JSON.stringify(identity);
      if (fingerprint === lastPreviewFingerprint) return;
      lastPreviewFingerprint = fingerprint;
      global.postMessage(
        { type: PREVIEW_DATA_TYPE, payload: { ...identity, capturedAt: Date.now() } },
        "*",
      );
    } catch {
      // Ignore: a failed read must never break the page's own player.
    }
  }

  // YouTube fires these custom events on SPA navigation / player updates;
  // the bounded poll below covers versions and states where they are absent.
  for (const eventName of ["yt-navigate-finish", "yt-page-data-updated", "yt-player-updated"]) {
    try {
      document.addEventListener(eventName, () => {
        // The content script drops its preview identity on a real transition;
        // forgetting the fingerprint lets the same video republish afterwards.
        lastPreviewFingerprint = "";
        schedulePublish();
      });
    } catch {
      // Event unavailable; polling still covers it.
    }
  }

  global.addEventListener("message", (event) => {
    try {
      if (!event || event.source !== global) return;
      const type = event.data?.type;
      if (type !== REQUEST_TYPE && type !== PREVIEW_REQUEST_TYPE) return;
      schedulePublish();
      if (type === PREVIEW_REQUEST_TYPE) publishPreview();
    } catch {
      // Ignore malformed requests.
    }
  });

  global.setInterval(() => {
    publish();
    publishPreview();
  }, POLL_MS);
  schedulePublish();
})(globalThis);
