import assert from "node:assert/strict";
import test from "node:test";

import {
  CONNECTION_HEALTH_ERROR_CODES,
  filterRecentSafeError,
  SAFE_ERROR_MAX_AGE_MS,
} from "../../../BrowserExtension/chrome/src/shared/redaction.js";

test("filterRecentSafeError: handles null, undefined and invalid error objects", () => {
  assert.deepEqual(filterRecentSafeError(null), { keep: false, error: null });
  assert.deepEqual(filterRecentSafeError(undefined), { keep: false, error: null });
  assert.deepEqual(filterRecentSafeError("string-error"), { keep: false, error: null });
  assert.deepEqual(filterRecentSafeError({}), { keep: false, error: null });
  assert.deepEqual(filterRecentSafeError({ at: 12345 }), { keep: false, error: null });
});

test("filterRecentSafeError: rejects invalid date strings and far-future timestamps", () => {
  const now = Date.now();
  // Invalid date string
  assert.deepEqual(
    filterRecentSafeError({ code: "ENQUEUE_TIMEOUT", message: "fail", at: "not-a-valid-date" }, now),
    { keep: false, error: null },
  );
  // Timestamp 10 seconds into the future
  const futureIso = new Date(now + 10_000).toISOString();
  assert.deepEqual(
    filterRecentSafeError({ code: "ENQUEUE_TIMEOUT", message: "fail", at: futureIso }, now),
    { keep: false, error: null },
  );
});

test("filterRecentSafeError: expires errors older than TTL (5 minutes / 300s)", () => {
  assert.equal(SAFE_ERROR_MAX_AGE_MS, 300_000);
  const now = Date.now();
  // 301 seconds ago (expired)
  const expiredIso = new Date(now - 301_000).toISOString();
  assert.deepEqual(
    filterRecentSafeError({ code: "ENQUEUE_TIMEOUT", message: "timeout", at: expiredIso }, now),
    { keep: false, error: null },
  );

  // 299 seconds ago (within 5-minute TTL)
  const freshIso = new Date(now - 299_000).toISOString();
  const freshError = { code: "ENQUEUE_TIMEOUT", message: "timeout", at: freshIso };
  assert.deepEqual(
    filterRecentSafeError(freshError, now, true),
    { keep: true, error: freshError },
  );
});

test("filterRecentSafeError: clears connection health errors on connected, but preserves operational errors", () => {
  const now = Date.now();
  const freshIso = new Date(now - 10_000).toISOString();

  // Connection health error codes should be cleared when isConnected is true
  for (const code of CONNECTION_HEALTH_ERROR_CODES) {
    const healthError = { code, message: "host unavailable", at: freshIso };
    assert.deepEqual(
      filterRecentSafeError(healthError, now, true),
      { keep: false, error: null },
      `Expected ${code} to be cleared when isConnected is true`,
    );
    // But kept when isConnected is false (app is truly disconnected)
    assert.deepEqual(
      filterRecentSafeError(healthError, now, false),
      { keep: true, error: healthError },
      `Expected ${code} to be kept when isConnected is false`,
    );
  }

  // Real operational errors (e.g. ENQUEUE_TIMEOUT, INSPECT_TIMEOUT, TAKEOVER_TIMEOUT, REQUEST_TIMEOUT, APP_REJECTED)
  // must be preserved even when isConnected is true so the user is informed of recent action failures!
  const operationalCodes = [
    "ENQUEUE_TIMEOUT",
    "INSPECT_TIMEOUT",
    "TAKEOVER_TIMEOUT",
    "REQUEST_TIMEOUT",
    "APP_REJECTED",
    "INVALID_MESSAGE",
  ];

  for (const code of operationalCodes) {
    const opError = { code, message: "action failed", at: freshIso };
    assert.deepEqual(
      filterRecentSafeError(opError, now, true),
      { keep: true, error: opError },
      `Expected operational error ${code} to be preserved when isConnected is true`,
    );
  }
});
