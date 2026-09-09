import { addAuthorizedOrigin } from "../shared/cookie-authorization.js";
import { t, i18n, hydrateDocument } from "../shared/i18n-access.js";

// Pure, unit-testable core: the permission-request shape and the authorize
// round-trip, kept independent of the DOM/chrome page wiring below so tests
// can drive them with stubs (no document required).

export function isHttpOrigin(value) {
  try {
    const url = new URL(String(value ?? ""));
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function permissionRequestFor(origin) {
  return { permissions: ["cookies"], origins: [`${origin}/*`] };
}

// Requests the per-site cookies permission (must run in this extension page,
// under a user gesture), records the origin in the authorization ledger on
// success, and reports the outcome to the service worker, which closes this
// window on success and tells the originating tab to re-parse.
export async function authorizeSiteCookies({ origin, tabId, permissions, runtime, storage }) {
  if (!isHttpOrigin(origin)) return { granted: false, reason: "invalidOrigin" };
  let granted = false;
  try {
    granted = (await permissions.request(permissionRequestFor(origin))) === true;
  } catch {
    return { granted: false, reason: "requestFailed" };
  }
  if (granted && storage) {
    try {
      await addAuthorizedOrigin(storage, origin);
    } catch {
      return { granted: false, reason: "requestFailed" };
    }
  }
  try {
    await runtime.sendMessage({
      type: "authorize.done",
      granted,
      tabId: Number.isInteger(tabId) ? tabId : null,
    });
  } catch {
    // The service worker may have been evicted; the overlay re-queries the
    // permission state on its next sync, so a lost notification is harmless.
  }
  return { granted, reason: granted ? null : "denied" };
}

// ---- page wiring (browser only) ----

function readParams() {
  const params = new URLSearchParams(globalThis.window?.location?.search ?? "");
  const rawTabId = Number(params.get("tabId"));
  return {
    origin: params.get("origin") ?? "",
    tabId: Number.isInteger(rawTabId) ? rawTabId : null,
  };
}

async function initialize() {
  await i18n.init();
  hydrateDocument();
  const { origin, tabId } = readParams();
  const originEl = document.querySelector("#authorize-origin");
  const grantButton = document.querySelector("#authorize-grant");
  const statusEl = document.querySelector("#authorize-status");
  if (originEl) originEl.textContent = origin;
  // A missing/non-http origin must not request an empty permission scope.
  if (!isHttpOrigin(origin)) {
    if (grantButton) grantButton.disabled = true;
    if (statusEl) statusEl.textContent = t("authorize.failed");
    return;
  }
  let inFlight = false;
  grantButton?.addEventListener("click", async () => {
    if (inFlight) return;
    inFlight = true;
    grantButton.disabled = true;
    const result = await authorizeSiteCookies({
      origin,
      tabId,
      permissions: chrome.permissions,
      runtime: chrome.runtime,
      storage: chrome.storage,
    });
    if (result.reason === "requestFailed") {
      if (statusEl) statusEl.textContent = t("authorize.failed");
      grantButton.disabled = false;
      inFlight = false;
      return;
    }
    if (result.granted) {
      if (statusEl) statusEl.textContent = t("authorize.granted");
      globalThis.window?.close?.();
      return;
    }
    // Denied: keep the window open so the message stays readable; the service
    // worker does not auto-close on a denial.
    if (statusEl) statusEl.textContent = t("authorize.denied");
    grantButton.disabled = false;
    inFlight = false;
  });
}

// Only auto-run inside the real extension page; node unit tests import the
// pure helpers above without a DOM present.
if (typeof document !== "undefined" && typeof chrome !== "undefined" && !!chrome?.permissions) {
  initialize();
}
