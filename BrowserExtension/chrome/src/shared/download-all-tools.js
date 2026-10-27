// Pure helpers for the Download All selection page: the filter syntax and
// the rename template. Kept free of DOM and chrome.* dependencies so the
// same code runs in the page and in Node unit tests.
//
// Filter syntax (top level is comma-OR over terms):
//   plain text      — substring match (the historical behavior)
//   * and ?         — glob term (unanchored, like the substring match)
//   /pattern/       — regex term (case-insensitive); a comma inside the
//                     pattern stays inside the term
// An invalid regex term degrades to a substring term instead of breaking
// the whole filter.
//
// Rename template tokens: *pagetitle* *name* *ext* *num* *date*. *num* is
// zero-padded to the width of the selection size (01…12) so renamed files
// sort in order in Finder.

/// Splits the query into terms on top-level commas, keeping commas that
/// belong to an unterminated /regex/ term.
export function parseFilterTerms(query) {
  const text = String(query ?? "").trim();
  if (!text) return [];
  const terms = [];
  let current = "";
  let inRegex = false;
  for (const character of text) {
    if (character === "/" && !inRegex && current.trim() === "") {
      inRegex = true;
      current += character;
      continue;
    }
    if (inRegex && character === "/") {
      inRegex = false;
      current += character;
      continue;
    }
    if (character === "," && !inRegex) {
      terms.push(current.trim());
      current = "";
      continue;
    }
    current += character;
  }
  terms.push(current.trim());
  return terms.filter(Boolean);
}

function globToRegExp(pattern) {
  let source = "";
  for (const character of pattern) {
    if (character === "*") source += ".*";
    else if (character === "?") source += ".";
    else source += character.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  }
  return new RegExp(source, "i");
}

/// Compiles one term into a predicate over the lowercase haystack
/// (`anchor text + redacted URL`).
export function compileFilterTerm(term) {
  let raw = String(term ?? "").trim();
  if (!raw) return null;
  if (raw.length >= 2 && raw.startsWith("/") && raw.endsWith("/")) {
    const body = raw.slice(1, -1);
    if (body) {
      try {
        const expression = new RegExp(body, "i");
        return (haystack) => expression.test(haystack);
      } catch {
        // A typo'd pattern degrades to a substring over its body — without
        // the delimiters, which could never occur in the haystack — so one
        // bad term cannot blank the whole list.
        raw = body;
      }
    }
  }
  if (/[*?]/u.test(raw)) {
    const expression = globToRegExp(raw);
    return (haystack) => expression.test(haystack);
  }
  const needle = raw.toLowerCase();
  return (haystack) => haystack.includes(needle);
}

/// True when the haystack matches any term of the query.
export function matchesFilterQuery(haystack, query) {
  const terms = parseFilterTerms(query);
  if (terms.length === 0) return true;
  return terms.some((term) => compileFilterTerm(term)?.(haystack) === true);
}

function sanitizeNamePart(value) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f/\\:*?"<>|]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim()
    .slice(0, 180);
}

function formatIndex(index, total) {
  const value = Math.max(1, Number.isInteger(index) ? index : 1);
  const width = Number.isInteger(total) && total > 0 ? String(total).length : 1;
  return String(value).padStart(width, "0");
}

/// Renders the template for every selected link, numbering in selection
/// order. Returns `{ names, duplicates }`: `names` maps URL → name (links
/// that render to nothing are omitted), `duplicates` counts names that more
/// than one link would share — a template without *num* usually.
export function renderRenames(template, selectedLinks, { pageTitle = "", date } = {}) {
  const names = {};
  const seen = new Map();
  if (!String(template ?? "").trim()) return { names, duplicates: 0 };
  selectedLinks.forEach((link, position) => {
    const name = applyRenameMask(template, {
      url: link.url,
      pageTitle: link.text || pageTitle,
      index: position + 1,
      total: selectedLinks.length,
      date,
    });
    if (!name) return;
    names[link.url] = name;
    const key = name.toLowerCase();
    seen.set(key, (seen.get(key) ?? 0) + 1);
  });
  let duplicates = 0;
  for (const count of seen.values()) {
    if (count > 1) duplicates += count;
  }
  return { names, duplicates };
}

function urlNameParts(url) {
  try {
    const filename = decodeURIComponent(new URL(url).pathname.split("/").pop() || "");
    const dot = filename.lastIndexOf(".");
    if (dot > 0 && dot < filename.length - 1) {
      return { stem: filename.slice(0, dot), extension: filename.slice(dot + 1).toLowerCase() };
    }
    return { stem: filename || "download", extension: "" };
  } catch {
    return { stem: "download", extension: "" };
  }
}

/// Renders the rename template for one link. Returns null when the template
/// is empty or renders to nothing usable, so the caller keeps the normal
/// naming path. The original extension is re-appended when the rendered
/// name carries no extension of its own — a template without *ext* must
/// not silently strip types.
export function applyRenameMask(template, { url, pageTitle, index, total, date }) {
  const raw = String(template ?? "").trim();
  if (!raw) return null;
  const parts = urlNameParts(url);
  const day = date instanceof Date ? date : new Date();
  const yyyy = String(day.getFullYear());
  const mm = String(day.getMonth() + 1).padStart(2, "0");
  const dd = String(day.getDate()).padStart(2, "0");
  const rendered = raw
    .replaceAll("*pagetitle*", sanitizeNamePart(pageTitle) || "download")
    .replaceAll("*name*", parts.stem || "download")
    .replaceAll("*ext*", parts.extension)
    .replaceAll("*num*", formatIndex(index, total))
    .replaceAll("*date*", `${yyyy}-${mm}-${dd}`);
  const cleaned = sanitizeNamePart(rendered);
  if (!cleaned) return null;
  const looksBare = !/\.[a-z0-9]{1,8}$/iu.test(cleaned);
  if (looksBare && parts.extension) {
    return `${cleaned}.${parts.extension}`;
  }
  return cleaned;
}
