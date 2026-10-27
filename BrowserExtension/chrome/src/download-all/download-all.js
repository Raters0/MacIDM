import { t, i18n, hydrateDocument } from "../shared/i18n-access.js";
import { matchesFilterQuery, renderRenames } from "../shared/download-all-tools.js";

const PAGE_SIZE = 200;
const keepAlivePort = chrome.runtime.connect({ name: "download-all-selection" });
const scanID = new URL(location.href).searchParams.get("scan");
const pageTitle = document.querySelector("#page-title");
const linksContainer = document.querySelector("#links");
const filterInput = document.querySelector("#filter");
const renameInput = document.querySelector("#rename");
const renamePreview = document.querySelector("#rename-preview");
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
let pageTitleText = "";
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
  pageTitleText = result.title || redactedURL(result.pageUrl);
  pageTitle.textContent = pageTitleText;
  applyFilter();
}

renameInput.addEventListener("input", updateRenamePreview);

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
  const urls = selectedLinks().map((item) => item.url);
  // A rename template turns every selected link into a user-authored name
  // (naming trust: userEdited). Links that render to nothing usable keep
  // the normal naming path.
  const renames = renameInput.value.trim() ? currentRenames().names : undefined;
  const result = await chrome.runtime.sendMessage({
    type: "downloadAll.submit",
    scanID,
    urls,
    ...(renames && { renames }),
  });
  notice.textContent = result?.ok
    ? t("downloadAll.submitted", { count: result.accepted })
    : result?.message ?? t("downloadAll.submitFailed");
  submit.disabled = false;
});

function applyFilter() {
  const query = filterInput.value;
  // Terms are comma-OR over substring / glob / regex — see
  // shared/download-all-tools.js; an invalid regex term degrades to a
  // substring instead of blanking the list.
  filtered = query.trim()
    ? links.filter((item) =>
        matchesFilterQuery(`${item.text} ${redactedURL(item.url)}`.toLowerCase(), query))
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
  updateRenamePreview();
}

function selectedLinks() {
  return links.filter((item) => selected.has(item.url));
}

function currentRenames() {
  return renderRenames(renameInput.value, selectedLinks(), { pageTitle: pageTitleText });
}

// Live preview of the first rendered name, plus a hint when several files
// would end up with the same name (the App would then append " (1)" etc.).
function updateRenamePreview() {
  if (!renameInput.value.trim()) {
    renamePreview.textContent = "";
    return;
  }
  const { names, duplicates } = currentRenames();
  const first = Object.values(names)[0];
  if (!first) {
    renamePreview.textContent = t("downloadAll.renamePreviewEmpty");
    return;
  }
  const parts = [t("downloadAll.renamePreview", { name: first })];
  if (duplicates > 0) parts.push(t("downloadAll.renameDuplicates", { count: duplicates }));
  renamePreview.textContent = parts.join(" ");
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
