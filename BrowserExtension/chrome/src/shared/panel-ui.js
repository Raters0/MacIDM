// Shared panel feedback helpers for the Popup and the media overlay. Both
// surfaces submit candidates to the App confirmation window and report the
// outcome with a transient top-center toast instead of persistent inline
// state ("Sent"/"Submitting…" etc. were removed from the rows). Styles are
// applied inline with light-dark() token values that mirror
// src/shared/tokens.css, because the overlay lives inside a Shadow DOM that
// cannot load the shared stylesheet.
(function installMacIDMPanelUI(global) {
  if (global.__macIDMPanelUIInstalled) return;
  global.__macIDMPanelUIInstalled = true;

  const TOAST_DURATION_MS = 3000;

  // Shows a transient toast at the top-center of `container`. The container
  // must be positioned (relative/absolute) so the toast anchors to it — the
  // Popup passes document.body, the overlay passes its shadow .wrap.
  // kind: "success" | "error"; only the text carries the semantic color,
  // the fill stays the panel's translucent surface (design doc §7).
  // options.maxWidth overrides the default `90%` for containers whose
  // containing block is zero-sized: the overlay's .wrap is a 0×0 anchor
  // around the FAB, so a percentage resolves to 0 and collapses the toast
  // to its padding alone (a ~26px white speck with the text clipped away).
  function showToast(container, message, options = {}) {
    if (!container || !message) return null;
    const doc = container.ownerDocument ?? global.document;
    const kind = options.kind === "error" ? "error" : "success";
    const maxWidth =
      typeof options.maxWidth === "string" && options.maxWidth
        ? options.maxWidth
        : "90%";
    const durationMs = Number.isFinite(options.durationMs) && options.durationMs >= 0
      ? options.durationMs
      : TOAST_DURATION_MS;
    // A new message replaces a still-visible one instead of stacking.
    container.querySelector?.("[data-macidm-toast]")?.remove();
    const toast = doc.createElement("div");
    toast.setAttribute("data-macidm-toast", kind);
    toast.setAttribute("role", "status");
    toast.textContent = message;
    toast.style.cssText = [
      "position:absolute",
      "top:10px",
      "left:50%",
      "transform:translateX(-50%)",
      "max-width:" + maxWidth,
      "overflow:hidden",
      "text-overflow:ellipsis",
      "white-space:nowrap",
      "padding:6px 12px",
      "border-radius:8px",
      "font-size:12px",
      "z-index:10",
      "box-shadow:0 4px 14px rgba(0,0,0,0.16)",
      "background:light-dark(rgba(255,255,255,0.97),rgba(32,35,41,0.97))",
      "border:1px solid light-dark(rgba(15,23,42,0.12),rgba(255,255,255,0.12))",
      kind === "success"
        ? "color:light-dark(#38ab78,#5ecb9a)"
        : "color:light-dark(#e05257,#f0868a)",
    ].join(";");
    container.append(toast);
    global.setTimeout(() => toast.remove(), durationMs);
    return toast;
  }

  global.MacIDMPanelUI = Object.freeze({ showToast, TOAST_DURATION_MS });
})(globalThis);
