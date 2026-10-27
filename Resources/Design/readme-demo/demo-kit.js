// Shared runtime for the README interface previews.
//
// Each page draws one deterministic scene from a time value, so
// scripts/render-readme-demos.sh can render frame N at time N / fps and
// assemble an animated GIF without screen recording. Opening a page in a
// normal browser plays the same timeline in a loop.
//
// The previews are illustrations of the real UI (labelled "interface
// preview" in the README), not recordings: keep their strings in sync with
// the App's Localizable.strings and the extension locale files.

const params = new URLSearchParams(location.search);
export const lang = params.get("lang") === "zh" ? "zh" : "en";
document.documentElement.lang = lang === "zh" ? "zh-Hans" : "en";

/** Picks the string for the current language from a {en, zh} pair. */
export function tr(pair) {
  return typeof pair === "string" ? pair : pair[lang];
}

/** Fills every [data-t] element from the page's string table. */
export function applyStrings(table) {
  for (const node of document.querySelectorAll("[data-t]")) {
    const entry = table[node.dataset.t];
    if (entry) node.textContent = tr(entry);
  }
  for (const node of document.querySelectorAll("[data-t-placeholder]")) {
    const entry = table[node.dataset.tPlaceholder];
    if (entry) node.setAttribute("placeholder", tr(entry));
  }
}

export const clamp = (value, low = 0, high = 1) => Math.min(high, Math.max(low, value));
export const lerp = (from, to, amount) => from + (to - from) * amount;
export const easeInOut = (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
export const easeOut = (x) => 1 - (1 - x) ** 3;

/** Progress of `time` through [start, end], clamped to 0…1. */
export function span(time, start, end) {
  return clamp((time - start) / (end - start));
}

/**
 * Cursor path from keyframes [{t, x, y}]. Between keyframes the cursor
 * moves on an eased curve; before the first and after the last it rests.
 */
export function cursorPath(keys, time) {
  if (time <= keys[0].t) return keys[0];
  for (let index = 1; index < keys.length; index += 1) {
    const previous = keys[index - 1];
    const next = keys[index];
    if (time <= next.t) {
      const amount = easeInOut(span(time, previous.t, next.t));
      return { x: lerp(previous.x, next.x, amount), y: lerp(previous.y, next.y, amount) };
    }
  }
  return keys[keys.length - 1];
}

const cursor = document.createElement("div");
cursor.className = "demo-cursor";
cursor.innerHTML =
  '<svg width="22" height="30" viewBox="0 0 22 30" aria-hidden="true">' +
  '<path d="M2 2 L2 24 L7.5 18.8 L11.6 28 L15.4 26.3 L11.4 17.4 L19 17.4 Z" ' +
  'fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
const ripple = document.createElement("div");
ripple.className = "demo-ripple";

/**
 * Draws the cursor at (x, y) and a click ripple for any click time within
 * the last 0.45 s. `clicks` is a list of times.
 */
export function drawCursor(position, time, clicks = [], visible = true) {
  if (!cursor.isConnected) document.body.append(ripple, cursor);
  cursor.style.opacity = visible ? "1" : "0";
  cursor.style.transform = `translate(${position.x}px, ${position.y}px)`;
  const recent = clicks.find((click) => time >= click && time - click < 0.45);
  if (recent === undefined || !visible) {
    ripple.style.opacity = "0";
    return false;
  }
  const amount = (time - recent) / 0.45;
  ripple.style.opacity = String(0.55 * (1 - amount));
  ripple.style.transform = `translate(${position.x}px, ${position.y}px) scale(${0.4 + amount})`;
  return time - recent < 0.15;
}

/**
 * Registers the scene. The renderer calls window.renderAt(t) per frame and
 * reads window.DEMO for the frame geometry; a plain page view loops it.
 */
export function registerScene({ duration, fps = 10, width, height, render }) {
  window.DEMO = { duration, fps, width, height };
  window.renderAt = (time) => {
    render(time);
    return true;
  };
  // ?static: the renderer drives frames itself; never start the live loop.
  if (params.has("static")) {
    render(0);
    return;
  }
  const started = performance.now();
  const tick = () => {
    render(((performance.now() - started) / 1000) % duration);
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
