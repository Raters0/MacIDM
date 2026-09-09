import { MAX_MESSAGE_BYTES, PROTOCOL_VERSION } from "./constants.js";
import { t } from "./i18n-access.js";

export class ProtocolError extends Error {
  constructor(code, message, retryable = false) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
    this.retryable = retryable;
  }
}

export function createRequest(type, idempotencyKey, payload, requestId = crypto.randomUUID()) {
  const request = {
    protocolVersion: PROTOCOL_VERSION,
    requestId,
    idempotencyKey,
    type,
    payload,
  };
  const size = new TextEncoder().encode(JSON.stringify(request)).byteLength;
  if (size > MAX_MESSAGE_BYTES) {
    throw new ProtocolError("MESSAGE_TOO_LARGE", t("protocol.messageTooLarge"));
  }
  return request;
}

export function validateResponse(response, requestId) {
  if (!response || typeof response !== "object") {
    throw new ProtocolError("INVALID_MESSAGE", t("protocol.invalidResponse"));
  }
  if (response.protocolVersion !== PROTOCOL_VERSION) {
    throw new ProtocolError("PROTOCOL_VERSION_MISMATCH", t("protocol.versionMismatch"));
  }
  if (response.requestId !== requestId) {
    throw new ProtocolError("INVALID_MESSAGE", t("protocol.requestMismatch"));
  }
  if (response.status === "error") {
    const code = typeof response.error?.code === "string" ? response.error.code : "APP_REJECTED";
    throw new ProtocolError(
      code,
      safeErrorMessage(code, response.error?.message),
      response.error?.retryable === true,
    );
  }
  if (response.status !== "ok" || typeof response.type !== "string") {
    throw new ProtocolError("INVALID_MESSAGE", t("protocol.missingStatus"));
  }
  return response;
}

// Error code → localized message key. The App's structured media-inspection
// error categories map here to the extension's zh/en copy
// (docs/specifications/chrome-extension-spec.md):
// - login/bot check, cookie-context, tool, network, and no-format errors are
//   no longer collapsed into MEDIA_INVALID;
// - the suppliedMessage argument is always ignored — even when the App-side
//   message is safe, the extension localizes by error code so zh/en stay
//   consistent and raw stderr is never passed through.
export function safeErrorMessage(code, _suppliedMessage) {
  const knownKeys = {
    NATIVE_HOST_NOT_FOUND: "protocol.error.nativeHostNotFound",
    PROTOCOL_VERSION_MISMATCH: "protocol.error.protocolVersionMismatch",
    APP_START_TIMEOUT: "protocol.error.appStartTimeout",
    PERMISSION_REQUIRED: "protocol.error.permissionRequired",
    MEDIA_UNSUPPORTED: "protocol.error.mediaUnsupported",
    MEDIA_INVALID: "protocol.error.mediaInvalid",
    MEDIA_AUTH_REQUIRED: "protocol.error.mediaAuthRequired",
    MEDIA_COOKIE_UNAVAILABLE: "protocol.error.mediaCookieUnavailable",
    MEDIA_TOOL_UNAVAILABLE: "protocol.error.mediaToolUnavailable",
    MEDIA_TOOL_UPDATE_SUGGESTED: "protocol.error.mediaToolUpdateSuggested",
    MEDIA_NETWORK_FAILURE: "protocol.error.mediaNetworkFailure",
    MEDIA_NO_FORMATS: "protocol.error.mediaNoFormats",
    MEDIA_CLEANUP_FAILED: "protocol.error.mediaCleanupFailed",
    TAKEOVER_CONFLICT: "protocol.error.takeoverConflict",
    APP_REJECTED: "protocol.error.appRejected",
  };
  return knownKeys[code] ? t(knownKeys[code]) : t("protocol.takeoverFailedCode", { code });
}
