import { t, i18n, hydrateDocument } from "../shared/i18n-access.js";

const PAGE_SIZE = 200;
const keepAlivePort = chrome.runtime.connect({ name: "download-all-selection" });
const scanID = new URL(location.href).searchParams.get("scan");
const pageTitle = document.querySelector("#page-title");
const linksContainer = document.querySelector("#links");
const filterInput = document.querySelector("#filter");
const selectAll = document.querySelector("#select-all");
const submit = document.querySelector("#submit");
const notice = document.querySelector("#notice");
const summary = document.querySelector("#summary");
const previous = document.querySelector("#previous");
const next = document.querySelector("#next");
const pageNumber = document.querySelector("#page-number");

let links = [];
let filtered = [];
let page = 0;
const selected = new Set();

initialize();
window.addEventListener("beforeunload", () => keepAlivePort.disconnect());
// The selection page is the scan's owner: closing or navigating away means
// the signed-URL list must be deleted immediately (chrome-extension-spec §5.5), including
// when the SW was evicted earlier — this message wakes it for the cleanup.
window.addEventListener("pagehide", () => {
  if (!scanID) return;
  try {
    chrome.runtime.sendMessage({ type: "downloadAll.releaseScan", scanID }).catch(() => {});
  } catch {
    // Extension context tearing down with the browser; session storage
    // evaporates with it anyway.
  }
});

async function initialize() {
  await i18n.init();
  hydrateDocument();
  // The tab title is user-visible; keep it translated and refresh it when
  // the language changes elsewhere (popup select, another context).
  document.title = t("downloadAll.browserTitle");
  i18n.onChange(() => {
    hydrateDocument();
    document.title = t("downloadAll.browserTitle");
  });
  const result = await chrome.runtime.sendMessage({ type: "downloadAll.getScan", scanID });
  if (!result?.ok) {
    notice.textContent = result?.message ?? t("downloadAll.expired");
    submit.disabled = true;
    return;
  }
  links = result.links;
  links.forEach((item) => selected.add(item.url));
  pageTitle.textContent = result.title || redactedURL(result.pageUrl);
  applyFilter();
}

filterInput.addEventListener("input", () => {
  page = 0;
  applyFilter();
});

selectAll.addEventListener("change", () => {
  for (const item of currentPageItems()) {
    if (selectAll.checked) selected.add(item.url);
    else selected.delete(item.url);
  }
  render();
});

previous.addEventListener("click", () => {
  page = Math.max(0, page - 1);
  render();
});

next.addEventListener("click", () => {
  page += 1;
  render();
});

submit.addEventListener("click", async () => {
  submit.disabled = true;
  const urls = links.filter((item) => selected.has(item.url)).map((item) => item.url);
  const result = await chrome.runtime.sendMessage({
    type: "downloadAll.submit",
    scanID,
    urls,
  });
  notice.textContent = result?.ok
    ? t("downloadAll.submitted", { count: result.accepted })
    : result?.message ?? t("downloadAll.submitFailed");
  submit.disabled = false;
});

function applyFilter() {
  const query = filterInput.value.trim().toLowerCase();
  filtered = query
    ? links.filter((item) => `${item.text} ${redactedURL(item.url)}`.toLowerCase().includes(query))
    : links;
  render();
}

function currentPageItems() {
  return filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
}

function render() {
  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  page = Math.min(page, pageCount - 1);
  const items = currentPageItems();
  linksContainer.replaceChildren();
  for (const item of items) {
    const row = document.createElement("label");
    row.className = "link-row";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = selected.has(item.url);
    checkbox.addEventListener("change", () => {
      if (checkbox.checked) selected.add(item.url);
      else selected.delete(item.url);
      updateSummary();
    });
    const copy = document.createElement("span");
    copy.className = "link-copy";
    const title = document.createElement("strong");
    title.textContent = item.text || filename(item.url);
    // Category icons match the App's seven categories, so the links page
    // is no longer plain text rows.
    const icon = document.createElement("span");
    icon.className = "link-icon";
    const category = globalThis.MacIDMCategory?.categoryFor?.(item.url) ?? "other";
    icon.innerHTML = globalThis.MacIDMCategory?.categoryIconSVG?.(category, 16) ?? "";
    icon.title = t(globalThis.MacIDMCategory?.categoryLabelKey?.(category) ?? "common.category.other");
    const url = document.createElement("small");
    url.textContent = redactedURL(item.url);
    const meta = document.createElement("small");
    meta.className = "link-meta";
    // Slots only show items that have values; a missing format/size shows
    // no "unknown" placeholder.
    const metaSlots = [];
    const format = formatSlot(item.url);
    if (format !== t("common.unknown")) metaSlots.push(format);
    const size = sizeSlot(item);
    if (size !== t("common.unknown")) metaSlots.push(size);
    meta.textContent = metaSlots.join(" · ");
    copy.append(title, url, meta);
    row.append(checkbox, icon, copy);
    linksContainer.append(row);
  }
  selectAll.checked = items.length > 0 && items.every((item) => selected.has(item.url));
  previous.disabled = page === 0;
  next.disabled = page + 1 >= pageCount;
  pageNumber.textContent = t("downloadAll.pageIndicator", { page: page + 1, total: pageCount });
  updateSummary();
}

function updateSummary() {
  summary.textContent = t("downloadAll.summary", { total: filtered.length, selected: selected.size });
}

// The "format" slot of the four-slot convention: inferred from the URL
// extension (m3u8→HLS, mpd→DASH, other known media extensions shown
// uppercased); shows "unknown" when it cannot be inferred.
function formatSlot(value) {
  const extension = globalThis.MacIDMMediaUtils?.mediaExtension?.(value) || "";
  if (!extension) return t("common.unknown");
  if (extension === "m3u8") return "HLS";
  if (extension === "mpd") return "DASH";
  return extension.toUpperCase();
}

// The "size" slot: uniformly shows "unknown" when the scan result carries
// no size information.
function sizeSlot(item) {
  return globalThis.MacIDMMediaUtils?.formatBytes?.(item?.size) ?? t("common.unknown");
}

function filename(value) {
  try {
    return decodeURIComponent(new URL(value).pathname.split("/").pop() || "download");
  } catch {
    return "download";
  }
}

function redactedURL(value) {
  try {
    const url = new URL(value);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return "<invalid-url>";
  }
}
