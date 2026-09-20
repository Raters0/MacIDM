import { createRequest, ProtocolError } from "../shared/protocol.js";
import { filenameFromDownload, isHttpURL } from "../shared/validation.js";
import { t } from "../shared/i18n-access.js";
import {
  INTERACTIVE_TIMEOUT_MS,
  INSPECT_TIMEOUT_MS,
  INSPECT_YOUTUBE_TIMEOUT_MS,
} from "../shared/constants.js";

export class ExplicitEnqueueClient {
  constructor({ nativeClient, profileIDProvider, requestContextProvider }) {
    this.nativeClient = nativeClient;
    this.profileIDProvider = profileIDProvider;
    this.requestContextProvider = requestContextProvider;
  }

  async enqueue({
    url,
    referrer,
    tabId,
    mediaKind,
    mime,
    filenameHint,
    filenameHintSource,
    pageTitle,
    interactive = false,
    operationID = crypto.randomUUID(),
    pairVideoUrl,
    pairAudioUrl,
    pairCid,
    pairNote,
    duration,
    estimatedSize,
  }) {
    if (!isHttpURL(url)) throw new ProtocolError("INVALID_MESSAGE", t("enqueue.httpOnly"));
    const item = { url, referrer };
    // Naming trust model (technical spec §8.1): only a caller-supplied hint
    // keeps its declared provenance; a hint this module derives from the URL
    // tail is always "urlPath", and unknown values degrade to "urlPath".
    const allowedHintSources = new Set(["browserResolved", "titleDerived", "urlPath"]);
    const payload = {
      url,
      filenameHint: filenameHint || filenameFromDownload(item),
      filenameHintSource: filenameHint && allowedHintSources.has(filenameHintSource)
        ? filenameHintSource
        : "urlPath",
    };
    if (interactive) payload.interactive = true;
    if (typeof mime === "string" && mime.trim()) payload.mime = mime.trim().slice(0, 256);
    if (typeof pageTitle === "string" && pageTitle.trim()) {
      payload.pageTitle = pageTitle.trim().slice(0, 300);
    }
    if (mediaKind === "hls" || mediaKind === "dash" || mediaKind === "youtube" || isHttpURL(pairAudioUrl)) {
      payload.mediaKind = mediaKind === "youtube" ? "youtube" : (isHttpURL(pairAudioUrl) ? "dash" : mediaKind);
    }
    if (isHttpURL(referrer)) payload.referrer = referrer;
    if (Number.isInteger(tabId) && tabId >= 0) payload.tabId = tabId;
    // m4s DASH-pair metadata (S2): the App can construct a DASH-pair task
    // from {video, audio} URLs after M1 lands; older Apps ignore these.
    if (isHttpURL(pairVideoUrl)) payload.pairVideoUrl = pairVideoUrl;
    if (isHttpURL(pairAudioUrl)) payload.pairAudioUrl = pairAudioUrl;
    if (typeof pairCid === "string" && pairCid) payload.pairCid = pairCid.slice(0, 32);
    if (typeof pairNote === "string" && pairNote) payload.pairNote = pairNote.slice(0, 120);
    if (Number.isFinite(duration) && duration > 0) payload.duration = duration;
    if (Number.isSafeInteger(estimatedSize) && estimatedSize >= 0) {
      payload.estimatedSize = Math.min(estimatedSize, Number.MAX_SAFE_INTEGER);
    }
    const requestContext = await this.requestContextProvider(item);
    if (requestContext && Object.keys(requestContext).length > 0) {
      payload.requestContext = requestContext;
    }

    const profileID = await this.profileIDProvider();
    const baseIdempotencyKey = `${profileID}:explicit-${operationID}`;
    // Interactive requests show a confirmation window in the App. We still
    // allow one retry on APP_START_TIMEOUT because the Host waits only 5s
    // for a cold-starting App, which may not be enough on a slow machine.
    // The retry is safe: if the first request never reached the App (host
    // couldn't connect), no confirmation window was shown, so the retry
    // won't create a duplicate. If the first request DID reach the App and
    // the App responded with a non-retryable error (APP_REJECTED),
    // sendWithRetry throws immediately without retrying.
    const response = await this.sendWithRetry(
      (attempt) => createRequest(
        "download.enqueue",
        attempt === 0 ? baseIdempotencyKey : `${baseIdempotencyKey}:r${attempt}`,
        payload,
      ),
      interactive ? 2 : 3,
      interactive,
    );
    if (interactive) {
      if (response.type !== "media.downloadRequested") {
        throw new ProtocolError("INVALID_MESSAGE", t("enqueue.confirmNotOpened"));
      }
      return response.payload ?? {};
    }
    if (response.type !== "download.accepted" || typeof response.payload?.taskId !== "string") {
      throw new ProtocolError("INVALID_MESSAGE", t("enqueue.taskNotConfirmed"));
    }
    return response.payload;
  }

  /// `userInitiated` tells the Host whether this inspection came from a
  /// surface the user opened themselves (Popup, overlay panel). Only such a
  /// request may wake an App the user deliberately quit; the flag defaults to
  /// false so a future background caller cannot resurrect it by accident.
  async inspect({
    url,
    referrer,
    tabId,
    mediaKind = "hls",
    userInitiated = false,
    operationID = crypto.randomUUID(),
  }) {
    if (!isHttpURL(url)) throw new ProtocolError("INVALID_MESSAGE", t("enqueue.httpOnlyMedia"));
    if (mediaKind !== "hls" && mediaKind !== "dash" && mediaKind !== "youtube") {
      throw new ProtocolError("INVALID_MESSAGE", t("enqueue.mediaKindsOnly"));
    }
    const item = { url, referrer };
    const payload = { url, mediaKind };
    if (userInitiated === true) payload.userInitiated = true;
    if (isHttpURL(referrer)) payload.referrer = referrer;
    if (Number.isInteger(tabId) && tabId >= 0) payload.tabId = tabId;
    const requestContext = await this.requestContextProvider(item);
    if (requestContext && Object.keys(requestContext).length > 0) {
      payload.requestContext = requestContext;
    }
    const profileID = await this.profileIDProvider();
    const baseInspectKey = `${profileID}:media-inspect-${operationID}`;
    let response;
    try {
      // Non-YouTube inspection (HLS/DASH/Bilibili) should complete in 1-3
      // seconds; a single attempt with a 15s ceiling is enough. YouTube
      // inspection via yt-dlp can take much longer, so allow 2 retries.
      const isYouTube = mediaKind === "youtube";
      response = await this.sendWithRetry(
        (attempt) => createRequest(
          "media.inspect",
          attempt === 0 ? baseInspectKey : `${baseInspectKey}:r${attempt}`,
          payload,
        ),
        isYouTube ? 2 : 1,
        false,
        isYouTube ? INSPECT_YOUTUBE_TIMEOUT_MS : INSPECT_TIMEOUT_MS,
      );
    } catch (error) {
      if (error instanceof ProtocolError && (error.code === "APP_REJECTED" || error.code === "INVALID_MESSAGE")) {
        throw new ProtocolError(
          error.code,
          t("enqueue.qualityParseRetry"),
          error.retryable,
        );
      }
      throw error;
    }
    if (response.type !== "media.inspected" || !Array.isArray(response.payload?.variants)) {
      throw new ProtocolError("INVALID_MESSAGE", t("enqueue.noCandidates"));
    }
    return response.payload;
  }

  async sendWithRetry(requestFactory, attempts = 3, interactive = false, timeoutMs) {
    let lastError;
    const resolvedTimeout = timeoutMs ?? (interactive ? INTERACTIVE_TIMEOUT_MS : undefined);
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      try {
        const request = requestFactory(attempt);
        return await this.nativeClient.send(request, resolvedTimeout);
      } catch (error) {
        lastError = error;
        if (error?.retryable !== true) throw error;
        if (attempt + 1 < attempts) {
          // APP_START_TIMEOUT means the Host launched the App but it did not
          // finish cold-starting within the Host's 5s window. Give it a
          // longer delay before retrying — the App is already starting, we
          // just need to wait for it to become reachable. Other retryable
          // errors use the default exponential backoff.
          const delay = error?.code === "APP_START_TIMEOUT"
            ? 2_500
            : Math.min(1_000, 100 * 2 ** attempt);
          await new Promise((resolve) => setTimeout(resolve, delay));
        }
      }
    }
    throw lastError;
  }
}
