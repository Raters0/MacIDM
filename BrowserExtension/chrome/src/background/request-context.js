import {
  isOriginAuthorized,
  normalizeHttpOrigin,
} from "../shared/cookie-authorization.js";
import { isHttpURL } from "../shared/validation.js";

const MAX_COOKIE_BYTES = 16 * 1024;
const MAX_REFERER_BYTES = 4096;
const MAX_USER_AGENT_BYTES = 4096;

// Builds the request context plus a cookie diagnostics summary.
// The diagnostics carry only booleans, counts, and byte sizes so the
// cookie relay can be observed in logs without ever exposing cookie
// names, values, or any other credentials (see the public extension specification).
export async function buildRequestContext(item, browser = chrome) {
  const url = item?.finalUrl || item?.url;
  if (!isHttpURL(url)) return { context: null, cookieDiagnostics: null };

  const context = {};
  const cookieDiagnostics = {
    // Whether cookie permission is granted for the page site.
    permissionGranted: false,
    // Total cookies returned by this query.
    cookiesFound: 0,
    // Number of partitioned cookies excluded.
    partitionedExcluded: 0,
    // Whether the serialized result was dropped entirely for exceeding 16 KiB.
    droppedOversize: false,
    // Whether a cookie context was ultimately attached for the App.
    attached: false,
    // Byte size of the attached cookie header.
    cookieBytes: 0,
  };

  // Referer/UA are not sensitive credentials, yet media CDNs (bilibili,
  // YouTube, etc.) 403 without them. Always attach them, decoupled from
  // cookie authorization. Only the explicitly declared page referrer is
  // used — we never synthesize a Referer.
  if (isHttpURL(item?.referrer) && byteLength(item.referrer) <= MAX_REFERER_BYTES) {
    context.referer = item.referrer;
  }
  if (
    typeof navigator !== "undefined" &&
    typeof navigator.userAgent === "string" &&
    byteLength(navigator.userAgent) <= MAX_USER_AGENT_BYTES
  ) {
    context.userAgent = navigator.userAgent;
  }

  // Cookies ARE sensitive. Only attach when the user has explicitly
  // authorized the PAGE origin — what the user authorized is "this website",
  // not the CDN that happens to serve the media bytes. Site-level grant
  // decisions use the chrome.storage ledger
  // (shared/cookie-authorization.js): the origins argument of
  // permissions.contains is made meaningless by global host_permissions and
  // cannot express per-site authorization.
  const pageOrigin = normalizeHttpOrigin(item?.referrer);
  if (pageOrigin) {
    const granted = await isOriginAuthorized(browser, pageOrigin);
    cookieDiagnostics.permissionGranted = granted;
    if (granted) {
      // The permission is granted for the page origin, not for the media CDN.
      // A Bilibili/YouTube player commonly serves bytes from another host;
      // querying that CDN would silently omit the page's login cookies.
      const cookieURL = isHttpURL(item?.referrer) ? item.referrer : url;
      const cookies = await browser.cookies.getAll({ url: cookieURL });
      const serialized = serializeUnpartitionedCookiesDetailed(cookies);
      cookieDiagnostics.cookiesFound = serialized.totalCookies;
      cookieDiagnostics.partitionedExcluded = serialized.partitionedCount;
      cookieDiagnostics.droppedOversize = serialized.droppedOversize;
      if (serialized.value) {
        context.cookie = serialized.value;
        cookieDiagnostics.attached = true;
        cookieDiagnostics.cookieBytes = serialized.bytes;
      }
    }
  }

  return {
    context: Object.keys(context).length > 0 ? context : null,
    cookieDiagnostics,
  };
}

function byteLength(value) {
  return new TextEncoder().encode(value).byteLength;
}

export function serializeUnpartitionedCookies(cookies) {
  return serializeUnpartitionedCookiesDetailed(cookies).value;
}

// Serializes cookies and reports safe statistics alongside the value:
// counts, byte size, and whether the result was dropped for exceeding
// the 16 KiB budget. Never reports cookie names or values.
function serializeUnpartitionedCookiesDetailed(cookies) {
  let partitionedCount = 0;
  const usable = (Array.isArray(cookies) ? cookies : []).filter((cookie) => {
    const safe =
      cookie &&
      typeof cookie.name === "string" &&
      typeof cookie.value === "string" &&
      cookie.partitionKey == null &&
      !/[\r\n;]/u.test(cookie.name) &&
      !/[\r\n]/u.test(cookie.value);
    if (!safe && cookie?.partitionKey != null) partitionedCount += 1;
    return safe;
  });
  const value = usable
    .sort((left, right) => (right.path?.length ?? 0) - (left.path?.length ?? 0))
    .map((cookie) => `${cookie.name}=${cookie.value}`)
    .join("; ");
  const bytes = new TextEncoder().encode(value).byteLength;
  return {
    value: bytes <= MAX_COOKIE_BYTES ? value : "",
    droppedOversize: bytes > MAX_COOKIE_BYTES,
    totalCookies: Array.isArray(cookies) ? cookies.length : 0,
    partitionedCount,
    bytes,
  };
}

export function originPermissionPattern(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? `${url.origin}/*` : null;
  } catch {
    return null;
  }
}
