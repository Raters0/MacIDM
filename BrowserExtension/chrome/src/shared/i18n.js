// MacIDM extension i18n core. Loaded as a classic script (content scripts,
// popup, download-all pages) and also imported as a module by the service
// worker — it has no `export` statements, so it executes identically in both
// modes and installs `globalThis.MacIDMI18n`.
//
// Load-order invariant: this file must load before locale catalogs
// (locale-zh-cn.js / locale-en.js), which must load before any consumer.
// The manifest content_scripts order, the page <script> order, and the
// service-worker import order all enforce this. Tests must import
// i18n-access.js before importing modules that translate.
//
// Adding a language: create `locale-<id>.js`, register it below in
// SUPPORTED_LANGUAGES, and wire it into manifest.json + popup.html +
// download-all.html + i18n-access.js. No other call sites change:
// system-language matching derives from the registered ids, and the
// parity test picks up the new catalog automatically.
(function installMacIDMI18n(global) {
  if (global.MacIDMI18n) return;

  // Single registration point for every supported language. Labels are
  // intentionally not translated — each language is shown in its own name.
  const SUPPORTED_LANGUAGES = Object.freeze([
    Object.freeze({ id: "zh-CN", label: "简体中文" }),
    Object.freeze({ id: "en", label: "English" }),
  ]);
  const DEFAULT_LANGUAGE = "zh-CN";
  const SYSTEM = "system";
  // Mirrors STORAGE_SETTINGS_KEY in constants.js; classic scripts cannot
  // import ES modules, so the key is duplicated deliberately here.
  const STORAGE_SETTINGS_KEY = "settings";

  const locales = new Map();
  const listeners = new Set();
  let languageChoice = SYSTEM; // persisted user choice ("system" or locale id)
  let currentLanguage = DEFAULT_LANGUAGE;

  // Locales that registered before the core was installed (defensive; load
  // order normally prevents this).
  for (const [id, messages] of global.MacIDMPendingLocales ?? []) {
    locales.set(id, messages);
  }
  delete global.MacIDMPendingLocales;

  function registerLocale(id, messages) {
    if (!id || !messages || typeof messages !== "object") return;
    locales.set(id, Object.freeze({ ...messages }));
  }

  // Data-driven from SUPPORTED_LANGUAGES so a newly registered language
  // participates without editing this function. Exact tag match wins;
  // otherwise the primary subtag prefix matches ("zh-Hant" -> "zh-CN",
  // "en-GB" -> "en").
  function matchSupported(tag) {
    const normalized = String(tag ?? "").toLowerCase().replace("_", "-");
    if (!normalized) return null;
    for (const { id } of SUPPORTED_LANGUAGES) {
      if (normalized === id.toLowerCase()) return id;
    }
    for (const { id } of SUPPORTED_LANGUAGES) {
      const prefix = id.toLowerCase().split("-")[0];
      if (normalized === prefix || normalized.startsWith(prefix + "-")) return id;
    }
    return null;
  }

  function browserLanguage() {
    const candidates = [
      global.navigator?.language,
      ...(Array.isArray(global.navigator?.languages) ? global.navigator.languages : []),
    ];
    for (const candidate of candidates) {
      const matched = matchSupported(candidate);
      if (matched) return matched;
    }
    return null;
  }

  function resolveLanguage() {
    if (languageChoice !== SYSTEM && locales.has(languageChoice)) return languageChoice;
    return browserLanguage() ?? DEFAULT_LANGUAGE;
  }

  // Synchronous lookup: current language → default language → key. The
  // zh-CN catalog is the source of truth, so a missing translation still
  // shows readable copy instead of a raw key.
  function t(key, params) {
    const template = locales.get(currentLanguage)?.[key] ?? locales.get(DEFAULT_LANGUAGE)?.[key];
    if (template == null) return key;
    if (!params) return template;
    return template.replace(/\{(\w+)\}/gu, (token, name) =>
      name in params ? String(params[name]) : token,
    );
  }

  function notify() {
    for (const listener of [...listeners]) {
      try {
        listener(currentLanguage);
      } catch {
        // A failing listener must not break other subscribers.
      }
    }
  }

  function applyChoice(choice) {
    const next = choice === SYSTEM || locales.has(choice) ? choice : SYSTEM;
    languageChoice = next;
    const resolved = resolveLanguage();
    if (resolved !== currentLanguage) {
      currentLanguage = resolved;
      notify();
    }
  }

  function storageAvailable() {
    try {
      return typeof chrome !== "undefined" && !!chrome.storage?.local;
    } catch {
      return false;
    }
  }

  async function init() {
    if (!storageAvailable()) {
      applyChoice(languageChoice);
      return;
    }
    try {
      const stored = await chrome.storage.local.get(STORAGE_SETTINGS_KEY);
      const choice = stored?.[STORAGE_SETTINGS_KEY]?.language;
      applyChoice(typeof choice === "string" ? choice : SYSTEM);
    } catch {
      applyChoice(SYSTEM);
    }
    try {
      chrome.storage.onChanged?.addListener((changes, area) => {
        if (area !== "local") return;
        const next = changes?.[STORAGE_SETTINGS_KEY]?.newValue?.language;
        if (typeof next !== "string") return;
        applyChoice(next);
      });
    } catch {
      // Extension context invalidated; nothing to observe.
    }
  }

  // choice: "system" or a supported locale id. Persists to storage.local
  // (shared settings object) and applies immediately in this context; other
  // contexts pick the change up via the storage.onChanged listener.
  async function setLanguage(choice) {
    if (choice !== SYSTEM && !locales.has(choice)) {
      throw new Error(`Unsupported language: ${choice}`);
    }
    if (storageAvailable()) {
      const stored = await chrome.storage.local.get(STORAGE_SETTINGS_KEY);
      const settings = { ...(stored?.[STORAGE_SETTINGS_KEY] ?? {}) };
      settings.language = choice;
      await chrome.storage.local.set({ [STORAGE_SETTINGS_KEY]: settings });
    }
    applyChoice(choice);
  }

  function onChange(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  global.MacIDMI18n = Object.freeze({
    registerLocale,
    t,
    init,
    setLanguage,
    onChange,
    currentLanguage: () => currentLanguage,
    languageChoice: () => languageChoice,
    supportedLanguages: () => SUPPORTED_LANGUAGES.map((entry) => ({ ...entry })),
    // Copy of a registered catalog; used by the locale parity test.
    messagesFor: (id) => ({ ...(locales.get(id) ?? {}) }),
    SYSTEM_CHOICE: SYSTEM,
  });
})(globalThis);
