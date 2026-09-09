// Module-side entry point for i18n. ES modules (service worker, popup.js,
// download-all.js, unit tests) import this instead of loading the classic
// scripts manually: importing it installs the i18n core and both locale
// catalogs on globalThis, then exposes the translate helper.
import "./i18n.js";
import "./locale-zh-cn.js";
import "./locale-en.js";

export function t(key, params) {
  return globalThis.MacIDMI18n.t(key, params);
}

export const i18n = globalThis.MacIDMI18n;

// Applies message keys to static markup via data attributes:
//   data-i18n             -> textContent
//   data-i18n-title       -> title attribute
//   data-i18n-aria        -> aria-label attribute
//   data-i18n-placeholder -> placeholder attribute
// Call once after i18n.init() and again on every language change.
export function hydrateDocument(doc = document) {
  for (const el of doc.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of doc.querySelectorAll("[data-i18n-title]")) el.title = t(el.dataset.i18nTitle);
  for (const el of doc.querySelectorAll("[data-i18n-aria]")) {
    el.setAttribute("aria-label", t(el.dataset.i18nAria));
  }
  for (const el of doc.querySelectorAll("[data-i18n-placeholder]")) {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  }
  doc.documentElement.lang = globalThis.MacIDMI18n.currentLanguage();
}
