import assert from "node:assert/strict";
import test from "node:test";

// Importing the access module installs the i18n core plus both locale
// catalogs on globalThis, mirroring how the extension loads them.
import { t, i18n, hydrateDocument } from "../../../BrowserExtension/chrome/src/shared/i18n-access.js";

function placeholderTokens(template) {
  return [...String(template).matchAll(/\{(\w+)\}/gu)].map((match) => match[1]).sort();
}

test("default language is zh-CN and lookups return the source catalog copy", () => {
  assert.equal(i18n.currentLanguage(), "zh-CN");
  assert.equal(t("popup.hostConnected"), "MacIDM 已连接");
  assert.equal(t("takeover.handedOver"), "已交给 MacIDM 下载");
});

test("placeholders are substituted and unknown keys fall back to the key", () => {
  assert.equal(t("overlay.itemCount", { count: 3 }), "3 项");
  assert.equal(t("popup.resourceCount", { count: 5 }), "5 个资源");
  // Missing params keep the token visible instead of silently dropping it.
  assert.equal(t("overlay.itemCount", {}), "{count} 项");
  assert.equal(t("does.not.exist"), "does.not.exist");
});

test("setLanguage switches catalogs and rejects unsupported languages", async () => {
  await i18n.setLanguage("en");
  assert.equal(i18n.currentLanguage(), "en");
  assert.equal(t("popup.hostConnected"), "MacIDM connected");
  assert.equal(t("overlay.itemCount", { count: 3 }), "3 items");
  await assert.rejects(i18n.setLanguage("fr"), /Unsupported language/u);
  await i18n.setLanguage("zh-CN");
  assert.equal(i18n.currentLanguage(), "zh-CN");
});

test("language change notifies subscribers once per resolved change", async () => {
  const observed = [];
  const unsubscribe = i18n.onChange((language) => observed.push(language));
  await i18n.setLanguage("en");
  // Setting the same resolved language again must not re-notify.
  await i18n.setLanguage("en");
  await i18n.setLanguage("zh-CN");
  unsubscribe();
  assert.deepEqual(observed, ["en", "zh-CN"]);
});

function installFakeStorage(initialSettings) {
  const store = { settings: initialSettings };
  const listeners = [];
  globalThis.chrome = {
    storage: {
      local: {
        async get(key) {
          return key in store ? { [key]: store[key] } : {};
        },
        async set(entries) {
          for (const [key, value] of Object.entries(entries)) {
            const oldValue = store[key];
            store[key] = value;
            for (const listener of listeners) {
              listener({ [key]: { oldValue, newValue: value } }, "local");
            }
          }
        },
      },
      onChanged: { addListener: (listener) => listeners.push(listener) },
    },
  };
  return store;
}

test("init reads the persisted language choice from chrome.storage", async () => {
  installFakeStorage({ language: "en", takeoverEnabled: true });
  await i18n.init();
  assert.equal(i18n.languageChoice(), "en");
  assert.equal(i18n.currentLanguage(), "en");
});

test("setLanguage persists into the shared settings object without clobbering it", async () => {
  const store = installFakeStorage({ language: "en", takeoverEnabled: true });
  await i18n.init();
  await i18n.setLanguage("zh-CN");
  assert.deepEqual(store.settings, { language: "zh-CN", takeoverEnabled: true });
  assert.equal(i18n.currentLanguage(), "zh-CN");
});

test("storage changes from other contexts apply the new language", async () => {
  const store = installFakeStorage({ language: "zh-CN" });
  await i18n.init();
  // Simulate another context (e.g. the popup) writing the setting.
  await chrome.storage.local.set({ settings: { ...store.settings, language: "en" } });
  assert.equal(i18n.currentLanguage(), "en");
  delete globalThis.chrome;
});

test("system choice resolves to a supported language", async () => {
  await i18n.setLanguage("system");
  assert.ok(["zh-CN", "en"].includes(i18n.currentLanguage()));
});

test("every supported language has a registered catalog", () => {
  for (const { id } of i18n.supportedLanguages()) {
    assert.ok(Object.keys(i18n.messagesFor(id)).length > 0, `missing catalog for ${id}`);
  }
});

test("locale catalogs keep full key and placeholder parity", () => {
  // The zh-CN catalog is the source of truth; every other registered
  // language must match it. Iterating supportedLanguages() means a newly
  // added language enters this check automatically.
  const source = i18n.messagesFor("zh-CN");
  for (const { id } of i18n.supportedLanguages()) {
    if (id === "zh-CN") continue;
    const catalog = i18n.messagesFor(id);
    assert.deepEqual(Object.keys(catalog).sort(), Object.keys(source).sort(), `key drift in ${id}`);
    for (const key of Object.keys(source)) {
      assert.deepEqual(
        placeholderTokens(catalog[key]),
        placeholderTokens(source[key]),
        `placeholder mismatch for ${key} in ${id}`,
      );
    }
  }
});

test("hydrateDocument applies data-i18n attributes", () => {
  const text = { dataset: { i18n: "common.retry" }, textContent: "" };
  const titled = { dataset: { i18nTitle: "popup.openApp" }, title: "" };
  const aria = {
    dataset: { i18nAria: "popup.connectionStatus" },
    setAttribute(name, value) { this[name] = value; },
  };
  const placeholder = { dataset: { i18nPlaceholder: "downloadAll.filterPlaceholder" }, placeholder: "" };
  const bySelector = {
    "[data-i18n]": [text],
    "[data-i18n-title]": [titled],
    "[data-i18n-aria]": [aria],
    "[data-i18n-placeholder]": [placeholder],
  };
  const doc = {
    querySelectorAll: (selector) => bySelector[selector] ?? [],
    documentElement: { lang: "" },
  };
  hydrateDocument(doc);
  assert.equal(text.textContent, t("common.retry"));
  assert.equal(titled.title, t("popup.openApp"));
  assert.equal(aria["aria-label"], t("popup.connectionStatus"));
  assert.equal(placeholder.placeholder, t("downloadAll.filterPlaceholder"));
  assert.equal(doc.documentElement.lang, i18n.currentLanguage());
});
