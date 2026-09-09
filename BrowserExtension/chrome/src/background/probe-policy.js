// Auto-probe admission policy for media candidates.
//
// A size probe is an extra request the extension makes on a page's behalf.
// Before this policy, a page could get the extension to issue a credentialed,
// redirect-following request to any URL it chose: MAIN World candidates were
// trusted and every probe carried cookies. This module replaces that trust with
// a boundary — a URL may only be probed automatically when the network stack
// already saw this tab request it, and only when the address that evidence
// points at is a public one.
//
// The peer-address proof only holds when the browser connects directly. Measured
// on Chromium behind a system HTTP proxy (Clash, V2Ray, Surge on 127.0.0.1), `ip`
// reports the proxy for every response, so a public site and a genuinely local
// target become indistinguishable. peerAddressIsInformative is how the policy
// separates "the target is private" from "a local proxy is in the path".
//
// Everything here is pure so the rules are unit-testable without a browser.

/** How long observed request evidence stays usable for an automatic probe. */
export const PROBE_EVIDENCE_TTL_MS = 2 * 60 * 1000;

/** Hostnames that are never public, regardless of what they resolve to. */
const RESERVED_HOST_SUFFIXES = [
  ".localhost",
  ".local",
  ".internal",
  ".localdomain",
  ".home.arpa",
  ".onion",
  ".test",
];

/** IPv4 blocks an automatic probe must never touch. */
const BLOCKED_IPV4_RANGES = [
  { base: "0.0.0.0", bits: 8 },
  { base: "10.0.0.0", bits: 8 },
  { base: "100.64.0.0", bits: 10 },
  { base: "127.0.0.0", bits: 8 },
  { base: "169.254.0.0", bits: 16 },
  { base: "172.16.0.0", bits: 12 },
  { base: "192.0.0.0", bits: 24 },
  { base: "192.0.2.0", bits: 24 },
  { base: "192.168.0.0", bits: 16 },
  { base: "198.51.100.0", bits: 24 },
  { base: "203.0.113.0", bits: 24 },
  { base: "224.0.0.0", bits: 4 },
  { base: "240.0.0.0", bits: 4 },
];

// ------------------------------------------------------------- address parsing

function parseIPv4Part(part) {
  if (!part) return null;
  if (/^0[xX][0-9a-fA-F]+$/.test(part)) return Number.parseInt(part.slice(2), 16);
  // A leading zero is octal to inet_aton, so `010` means 8, not 10.
  if (/^0[0-7]+$/.test(part)) return Number.parseInt(part.slice(1), 8);
  if (/^[0-9]+$/.test(part)) return Number.parseInt(part, 10);
  return null;
}

/**
 * Normalizes any inet_aton-compatible IPv4 spelling to dotted-quad text, so
 * `127.1`, `0x7f.0.0.1`, `0177.0.0.1` and `2130706433` all read as loopback
 * instead of slipping through as an unrecognized host. Returns null when the
 * value is not an IPv4 literal.
 */
export function parseIPv4(hostname) {
  if (typeof hostname !== "string" || hostname.length === 0) return null;
  if (!/^[0-9A-Fa-fxX.]+$/.test(hostname)) return null;
  const parts = hostname.split(".");
  if (parts.length > 4) return null;
  const values = [];
  for (const part of parts) {
    const value = parseIPv4Part(part);
    if (value === null || !Number.isSafeInteger(value)) return null;
    values.push(value);
  }
  const leading = values.slice(0, -1);
  if (leading.some((value) => value > 255)) return null;
  const tailBytes = 4 - leading.length;
  const tail = values[values.length - 1];
  if (tail >= 256 ** tailBytes) return null;
  const octets = [...leading];
  for (let shift = tailBytes - 1; shift >= 0; shift -= 1) {
    octets.push(Math.floor(tail / 256 ** shift) % 256);
  }
  return octets.join(".");
}

function ipv4ToNumber(dotted) {
  const octets = dotted.split(".").map(Number);
  return ((octets[0] * 256 + octets[1]) * 256 + octets[2]) * 256 + octets[3];
}

function parseIPv6Group(value) {
  if (!/^[0-9a-fA-F]{1,4}$/.test(value)) return null;
  return Number.parseInt(value, 16);
}

/**
 * Expands an IPv6 literal — with optional brackets and an optional embedded
 * IPv4 tail — into eight 16-bit groups, or null when it is not IPv6.
 */
export function parseIPv6(hostname) {
  if (typeof hostname !== "string" || hostname.length === 0) return null;
  let address = hostname.toLowerCase();
  if (address.startsWith("[") && address.endsWith("]")) {
    address = address.slice(1, -1);
  }
  if (!address.includes(":")) return null;

  const lastColon = address.lastIndexOf(":");
  const tail = address.slice(lastColon + 1);
  if (tail.includes(".")) {
    const dotted = parseIPv4(tail);
    if (!dotted) return null;
    const octets = dotted.split(".").map(Number);
    const high = octets[0] * 256 + octets[1];
    const low = octets[2] * 256 + octets[3];
    address = `${address.slice(0, lastColon + 1)}${high.toString(16)}:${low.toString(16)}`;
  }

  const compressed = address.split("::");
  if (compressed.length > 2) return null;
  const groups = [];
  if (compressed.length === 2) {
    for (const part of compressed[0].split(":")) {
      if (part === "") continue;
      const group = parseIPv6Group(part);
      if (group === null) return null;
      groups.push(group);
    }
    const trailing = [];
    for (const part of compressed[1].split(":")) {
      if (part === "") continue;
      const group = parseIPv6Group(part);
      if (group === null) return null;
      trailing.push(group);
    }
    const padding = 8 - groups.length - trailing.length;
    if (padding < 1) return null;
    groups.push(...new Array(padding).fill(0), ...trailing);
  } else {
    for (const part of address.split(":")) {
      const group = parseIPv6Group(part);
      if (group === null) return null;
      groups.push(group);
    }
    if (groups.length !== 8) return null;
  }
  return groups;
}

function isPrivateIPv4(dotted) {
  const address = ipv4ToNumber(dotted);
  for (const range of BLOCKED_IPV4_RANGES) {
    const mask = (0xffffffff << (32 - range.bits)) >>> 0;
    if ((address & mask) === (ipv4ToNumber(range.base) & mask)) return true;
  }
  return false;
}

function isPrivateIPv6(groups) {
  const [first, second, third, fourth, fifth, sixth, seventh, eighth] = groups;
  if (first === 0 && second === 0 && third === 0 && fourth === 0 && fifth === 0) {
    // `::`, `::1`, IPv4-compatible and IPv4-mapped forms all reduce to their
    // trailing IPv4 address, which 0.0.0.0/8 rejects for `::` and `::1`.
    if (sixth === 0 || sixth === 0xffff) {
      return isPrivateIPv4(
        [
          (seventh >> 8) & 0xff,
          seventh & 0xff,
          (eighth >> 8) & 0xff,
          eighth & 0xff,
        ].join("."),
      );
    }
  }
  if (first === 0) return true;
  if ((first & 0xffc0) === 0xfe80) return true; // link-local
  if ((first & 0xfe00) === 0xfc00) return true; // unique local
  if ((first & 0xff00) === 0xff00) return true; // multicast
  return false;
}

/**
 * True when `hostname` is an IP literal that must never receive an automatic
 * probe — in any accepted spelling — or a reserved hostname.
 */
export function isPrivateAddress(hostname) {
  if (typeof hostname !== "string" || hostname.length === 0) return true;
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (host === "localhost" || RESERVED_HOST_SUFFIXES.some((suffix) => host.endsWith(suffix))) {
    return true;
  }
  const v6 = parseIPv6(hostname);
  if (v6) return isPrivateIPv6(v6);
  const v4 = parseIPv4(hostname);
  if (v4) return isPrivateIPv4(v4);
  return false;
}

/** True when an address from request evidence points at a public host. */
export function isPublicAddress(address) {
  if (typeof address !== "string" || address.trim() === "") return false;
  return !isPrivateAddress(address.trim());
}

function isLoopbackIPv4(dotted) {
  return dotted.split(".")[0] === "127";
}

function isLoopbackIPv6(groups) {
  const [first, second, third, fourth, fifth, sixth, seventh, eighth] = groups;
  if (first || second || third || fourth || fifth) return false;
  if (sixth !== 0 && sixth !== 0xffff) return false;
  if (sixth === 0 && seventh === 0 && eighth === 1) return true; // `::1`
  return isLoopbackIPv4(
    [(seventh >> 8) & 0xff, seventh & 0xff, (eighth >> 8) & 0xff, eighth & 0xff].join("."),
  );
}

/**
 * True when an address is loopback. Chrome reports the *proxy* as the peer when
 * a local proxy is configured, so a loopback peer means the address describes a
 * hop on this machine rather than the download target.
 */
export function isLoopbackAddress(hostname) {
  if (typeof hostname !== "string" || hostname.length === 0) return false;
  const host = hostname.trim().toLowerCase().replace(/\.$/, "");
  if (host === "localhost") return true;
  const v6 = parseIPv6(host);
  if (v6) return isLoopbackIPv6(v6);
  const v4 = parseIPv4(host);
  return v4 ? isLoopbackIPv4(v4) : false;
}

function originOf(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.origin;
  } catch {
    return null;
  }
}

// -------------------------------------------------------------- evidence ledger

/**
 * Keeps the request evidence that authorizes an automatic probe, scoped to the
 * tab and the document generation that produced it. A probe may only reuse
 * evidence recorded for the same tab under the same generation, so navigating —
 * even to the same URL — retires every outstanding authorization.
 *
 * It also notes, per tab, whether any peer address was public, which is how the
 * policy tells a direct connection from a local proxy. That note is one flag per
 * tab and keeps no URL or address text of its own.
 *
 * The per-document bookkeeping for attempts lives here for the same reason: a
 * refusal or an exhausted retry budget keyed by URL alone followed that URL into
 * other tabs and other documents, where it suppressed a probe that had every
 * right to run and left the row showing "probing" forever. Retries therefore
 * restart for each document — a CDN that refused one page may answer the next.
 */
export class ProbeEvidenceLedger {
  #entries = new Map();
  #generations = new Map();
  #publicPeer = new Set();
  #declined = new Set();
  #failures = new Map();
  #ttlMs;
  #limit;
  #now;

  constructor({ ttlMs = PROBE_EVIDENCE_TTL_MS, limit = 1000, now = () => Date.now() } = {}) {
    this.#ttlMs = ttlMs;
    this.#limit = limit;
    this.#now = now;
  }

  generationOf(tabId) {
    return this.#generations.get(tabId) ?? 0;
  }

  /**
   * Notes the peer address of any response `tabId` received, not just media
   * ones. A single public peer proves the browser is connecting directly, so
   * `ip` can be read as the target's address.
   */
  observePeer({ tabId, url, ip }) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    if (!originOf(url)) return false;
    if (typeof ip !== "string" || !isPublicAddress(ip)) return false;
    this.#publicPeer.add(tabId);
    return true;
  }

  /**
   * False when every peer this tab saw was loopback while public hostnames were
   * being requested — the signature of a local HTTP proxy answering as the peer.
   * In that case `ip` describes the proxy and proves nothing about the target.
   */
  peerAddressIsInformative(tabId) {
    return this.#publicPeer.has(tabId);
  }

  /** Records that `tabId` requested `url`, together with the peer address. */
  record({ tabId, url, ip, frameId, documentId }) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    if (!originOf(url)) return false;
    this.#entries.set(this.#key(tabId, url), {
      url,
      tabId,
      generation: this.generationOf(tabId),
      observedAt: this.#now(),
      ip: typeof ip === "string" && ip.length > 0 ? ip : null,
      frameId: Number.isInteger(frameId) ? frameId : null,
      documentId: typeof documentId === "string" && documentId ? documentId : null,
    });
    while (this.#entries.size > this.#limit) {
      const oldest = this.#entries.keys().next().value;
      if (oldest === undefined) break;
      this.#entries.delete(oldest);
    }
    return true;
  }

  evidenceFor(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return null;
    const key = this.#key(tabId, url);
    const entry = this.#entries.get(key);
    if (!entry) return null;
    if (entry.generation !== this.generationOf(tabId)) {
      this.#entries.delete(key);
      return null;
    }
    if (this.#now() - entry.observedAt > this.#ttlMs) {
      this.#entries.delete(key);
      return null;
    }
    return entry;
  }

  /** Notes that this document was refused an automatic probe for `url`. */
  markDeclined(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    this.#declined.add(this.#key(tabId, url));
    return true;
  }

  wasDeclined(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    return this.#declined.has(this.#key(tabId, url));
  }

  clearDeclined(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    return this.#declined.delete(this.#key(tabId, url));
  }

  /** Counts one failed probe attempt for `url` and returns the new total. */
  recordFailure(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return 0;
    const key = this.#key(tabId, url);
    const attempts = (this.#failures.get(key) ?? 0) + 1;
    this.#failures.set(key, attempts);
    return attempts;
  }

  failureCount(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return 0;
    return this.#failures.get(this.#key(tabId, url)) ?? 0;
  }

  clearFailures(url, { tabId } = {}) {
    if (!Number.isInteger(tabId) || tabId < 0) return false;
    return this.#failures.delete(this.#key(tabId, url));
  }

  /** Called on navigation: retires this document's evidence and pending probes. */
  handleTabNavigated(tabId) {
    if (!Number.isInteger(tabId) || tabId < 0) return;
    this.#generations.set(tabId, this.generationOf(tabId) + 1);
    this.#dropTab(tabId);
  }

  handleTabRemoved(tabId) {
    this.#generations.delete(tabId);
    this.#dropTab(tabId);
  }

  #dropTab(tabId) {
    this.#publicPeer.delete(tabId);
    const prefix = `${tabId}\u0000`;
    for (const key of [...this.#declined]) {
      if (key.startsWith(prefix)) this.#declined.delete(key);
    }
    for (const key of [...this.#failures.keys()]) {
      if (key.startsWith(prefix)) this.#failures.delete(key);
    }
    for (const [key, entry] of [...this.#entries]) {
      if (entry.tabId === tabId) this.#entries.delete(key);
    }
  }

  #key(tabId, url) {
    return `${tabId}\u0000${url}`;
  }
}

// --------------------------------------------------------------- admission rule

/**
 * Decides whether a candidate may receive an automatic size probe.
 *
 * `probeable` carries the existing shape filter (already-sized, manifests and
 * site adapters never qualify) so this stays the single place that answers the
 * question. `peerAddressInformative` defaults to true, i.e. the strict reading
 * where a non-public peer proves a private target; the caller clears it only
 * when a local proxy made every peer address loopback. `reason` is a stable code
 * for tests; it never echoes the candidate URL, which may carry signed query
 * parameters.
 */
export function decideAutoProbe({
  candidate,
  evidence,
  pageURL,
  probeable,
  peerAddressInformative = true,
}) {
  const url = typeof candidate?.url === "string" ? candidate.url : "";
  if (!url) return { allowed: false, reason: "missing_url" };
  const origin = originOf(url);
  if (!origin) return { allowed: false, reason: "not_http" };
  if (!probeable) return { allowed: false, reason: "not_probeable" };

  let host;
  try {
    host = new URL(url).hostname;
  } catch {
    return { allowed: false, reason: "unparseable" };
  }
  if (isPrivateAddress(host)) return { allowed: false, reason: "private_target" };

  // Unobserved candidates are exactly what page script can forge, so they are
  // shown with an unknown size rather than fetched.
  if (!evidence) return { allowed: false, reason: "unobserved" };

  if (evidence.ip) {
    if (isPublicAddress(evidence.ip)) return { allowed: true, reason: "observed_public" };
    // Measured on Chromium: with a system HTTP proxy the peer is the proxy for
    // every response, so loopback here means "answered locally on this machine",
    // not "the target is local". The weaker proof that remains is that this tab
    // really requested this URL in this document, the URL's own host is not a
    // private literal, and the request stays anonymous, redirect-free and
    // bounded. A hostname that resolves to a private address cannot be ruled out
    // in this tier — the proxy is the one connecting, so no extension-side check
    // could have prevented that request either.
    if (!peerAddressInformative && isLoopbackAddress(evidence.ip)) {
      return { allowed: true, reason: "observed_via_proxy" };
    }
    return { allowed: false, reason: "private_target" };
  }
  // Without a peer address a hostname that resolves privately cannot be ruled
  // out. Same-origin is still safe: the page could read that response itself,
  // so an anonymous probe discloses nothing new.
  if (originOf(pageURL) === origin) return { allowed: true, reason: "same_origin" };
  return { allowed: false, reason: "no_address_evidence" };
}

/**
 * Validates the probe request context and Referer gate (strict fail-closed).
 *
 * Criteria:
 * 1. generation must match the tab's current latest generation;
 * 2. pageUrl must be a non-empty, valid http(s) URL;
 * 3. referer must be a non-empty string exactly equal to pageUrl.
 *
 * Any empty referer, mismatched URL, pseudo-scheme, or generation mismatch
 * is rejected fail-closed.
 */
export function isProbeContextValid({ currentGen, taskGen, pageUrl, referer }) {
  if (typeof currentGen === "number" && typeof taskGen === "number" && currentGen !== taskGen) {
    return false;
  }
  if (typeof pageUrl !== "string" || !pageUrl) return false;
  if (!originOf(pageUrl)) return false;
  if (typeof referer !== "string" || !referer) return false;
  if (referer !== pageUrl) return false;
  return true;
}
