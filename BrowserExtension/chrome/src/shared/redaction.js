import { t } from "./i18n-access.js";

export const SAFE_ERROR_MAX_AGE_MS = 300_000;

export const CONNECTION_HEALTH_ERROR_CODES = new Set([
  "PING_TIMEOUT",
  "NATIVE_HOST_NOT_FOUND",
  "APP_START_TIMEOUT",
  "APP_UNAVAILABLE",
]);

export function safeDiagnostic(error) {
  return {
    code: typeof error?.code === "string" ? error.code : "UNKNOWN_ERROR",
    message: typeof error?.message === "string" ? error.message.replace(/https?:\/\/\S+/gu, "<url>") : t("redaction.takeoverFailed"),
    at: new Date().toISOString(),
  };
}

export function filterRecentSafeError(rawError, nowMs = Date.now(), isConnected = true, maxAgeMs = SAFE_ERROR_MAX_AGE_MS) {
  if (!rawError || typeof rawError !== "object" || typeof rawError.at !== "string") {
    return { keep: false, error: null };
  }
  const errorTime = new Date(rawError.at).getTime();
  if (Number.isNaN(errorTime)) {
    return { keep: false, error: null };
  }
  if (errorTime > nowMs + 1000) {
    return { keep: false, error: null };
  }
  const age = nowMs - errorTime;
  if (age < 0 || age > maxAgeMs) {
    return { keep: false, error: null };
  }
  if (isConnected && CONNECTION_HEALTH_ERROR_CODES.has(rawError.code)) {
    return { keep: false, error: null };
  }
  return { keep: true, error: rawError };
}
