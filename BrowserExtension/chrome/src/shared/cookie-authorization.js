// Per-site cookie authorization ledger: chrome.permissions.contains cannot
// express per-site cookie authorization — "cookies" is an extension-level API
// permission (global once granted), and the manifest's host_permissions
// already cover every http(s) origin, so the origins parameter returns true
// for any page. The real per-site authorization state lives in this ledger
// (chrome.storage.local): successful authorization writes the origin, and the
// Popup status row, the overlay authorization entry, and request-context's
// cookie-attachment decision all query it here.
export const AUTHORIZED_ORIGINS_KEY = "authorizedOrigins"; // Legacy read-only ledger.
const originKey = (origin) => "authorizedOrigin:" + origin;

export function normalizeHttpOrigin(value) {
  try {
    const url = new URL(String(value ?? ""));
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}

export async function readAuthorizedOrigins(storage) {
  try {
    const result = await storage.local.get(null);
    const legacy = result?.[AUTHORIZED_ORIGINS_KEY];
    const origins = Array.isArray(legacy) ? legacy.filter(entry => typeof entry === "string") : [];
    for (const [key, value] of Object.entries(result ?? {})) {
      if (key.startsWith("authorizedOrigin:") && value === true) origins.push(key.slice("authorizedOrigin:".length));
    }
    return [...new Set(origins)];
  } catch {
    return [];
  }
}

export async function addAuthorizedOrigin(storage, origin) {
  const normalized = normalizeHttpOrigin(origin);
  if (!normalized) return false;
  // Distinct keys make concurrent writes from separate extension windows commute.
  await storage.local.set({ [originKey(normalized)]: true });
  return true;
}

// Ledger hit + the "cookies" API permission still present: the user may
// revoke that permission alone from chrome://extensions, in which case ledger
// entries count as invalid — the UI must not show "authorized" while cookies
// cannot be read.
export async function isOriginAuthorized(browser, origin) {
  const normalized = normalizeHttpOrigin(origin);
  if (!normalized) return false;
  try {
    const cookiesGranted = await browser.permissions.contains({ permissions: ["cookies"] });
    if (cookiesGranted !== true) return false;
  } catch {
    return false;
  }
  try {
    const current = await browser.storage.local.get(originKey(normalized));
    if (current?.[originKey(normalized)] === true) return true;
    const legacy = await browser.storage.local.get(AUTHORIZED_ORIGINS_KEY);
    return Array.isArray(legacy?.[AUTHORIZED_ORIGINS_KEY]) && legacy[AUTHORIZED_ORIGINS_KEY].includes(normalized);
  } catch {
    return false;
  }
}
