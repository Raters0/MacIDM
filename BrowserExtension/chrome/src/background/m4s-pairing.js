// ES-module entry into the same algorithm used by classic content scripts.
import "../shared/i18n-access.js";
import "../shared/media-utils.js";

const media = globalThis.MacIDMMediaUtils;
export const extractM4sInfo = media.extractM4sInfo;
export const isBilibiliPageURL = media.isBilibiliPageURL;

export function applyM4sPairing(payload) {
  if (!payload || !Array.isArray(payload.candidates)) return payload;
  return {
    ...payload,
    candidates: media.coalesceMediaCandidates(payload.candidates, payload.title ?? "", payload.pageUrl ?? ""),
  };
}
