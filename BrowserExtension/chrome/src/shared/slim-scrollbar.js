// Translucent floating scrollbar (shared by the Popup and the sniff overlay):
// hides the native scrollbar (freeing its layout width) and shows a slim bar
// only while actually scrolling, fading out ~0.9s after scrolling stops —
// the same visual semantics as the macOS App's LightScrollerConfigurator
// (auto-hiding overlay scrollbar). The thumb uses position:fixed: it is not
// clipped by the scroll container's overflow and does not move with the
// content; being attached inside the container, it is destroyed along with
// panel rebuilds.
(function installMacIDMSlimScrollbar(global) {
  if (global.__macIDMSlimScrollbarInstalled) return;
  global.__macIDMSlimScrollbarInstalled = true;

  const STYLE_ID = "macidm-slim-scrollbar-style";
  const CONTAINER_CLASS = "macidm-slim-scroll";
  const THUMB_CLASS = "macidm-slim-thumb";
  const VISIBLE_CLASS = THUMB_CLASS + "-visible";
  const STYLE_CSS =
    "." + CONTAINER_CLASS + " { scrollbar-width: none !important; }" +
    "." + CONTAINER_CLASS + "::-webkit-scrollbar { width: 0; height: 0; }" +
    "." + THUMB_CLASS + " {" +
    " position: fixed; z-index: 2147483000; pointer-events: none;" +
    " width: 6px; border-radius: 3px;" +
    " background: rgba(100, 116, 139, 0.45);" +
    " opacity: 0; transition: opacity 0.25s ease; }" +
    "." + VISIBLE_CLASS + " { opacity: 1; }";

  // Pure geometry (unit-testable): returns null (thumb hidden) when there is
  // no overflow or the container is not visible.
  function thumbGeometry({ scrollTop, scrollHeight, clientHeight, rectTop, rectHeight, minThumb = 24 }) {
    if (!(scrollHeight > clientHeight) || !(clientHeight > 0) || !(rectHeight > 0)) return null;
    const height = Math.max(minThumb, Math.round(rectHeight * (clientHeight / scrollHeight)));
    const maxOffset = rectHeight - height;
    if (maxOffset <= 0) return null;
    const progress = Math.min(1, Math.max(0, scrollTop / (scrollHeight - clientHeight)));
    return { top: Math.round(rectTop + maxOffset * progress), height };
  }

  // Styles must be injected into the root node that hosts the container:
  // containers inside a Shadow DOM (e.g. the overlay panel) are not affected
  // by the page's <head> styles.
  function ensureStyles(root, doc) {
    try {
      if (!root) return;
      if (root.getElementById?.(STYLE_ID)) return;
      const style = doc.createElement?.("style");
      if (!style) return;
      style.id = STYLE_ID;
      style.textContent = STYLE_CSS;
      (root === doc ? (doc.head || doc.documentElement || doc) : root).append?.(style);
    } catch {
      // A failed style injection only affects appearance, not functionality.
    }
  }

  // attach(container) → detach(). The thumb is attached to the container's
  // parent, not inside the container: containers like mediaList are fully
  // re-rendered via replaceChildren, which would clear anything inside.
  // fixed positioning is unaffected by the parent's layout. Overlay panel
  // rebuilds are handled by the caller detaching old attachments first.
  function attach(container, options = {}) {
    const doc = container?.ownerDocument;
    if (!doc) return () => {};
    // A container not yet inserted into the DOM has no parent: falling back
    // to attaching inside the container would clip the thumb and scroll it
    // with the content (the overlay panel's backdrop-filter would also hijack
    // the fixed-position containing block), leaving it forever invisible —
    // that is a call-timing error, so simply do not enable.
    const parent = container.parentElement;
    if (!parent) return () => {};
    ensureStyles(container.getRootNode?.() ?? doc, doc);
    container.classList.add(CONTAINER_CLASS);
    const thumb = doc.createElement("div");
    thumb.className = THUMB_CLASS;
    parent.append?.(thumb);

    const idleMs = Number.isFinite(options.idleMs) ? options.idleMs : 900;
    let hideTimer = 0;
    let hasOverflow = false;

    const show = () => {
      if (!hasOverflow) return;
      thumb.classList.add(VISIBLE_CLASS);
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => thumb.classList.remove(VISIBLE_CLASS), idleMs);
    };
    const paint = () => {
      let rect;
      try {
        rect = container.getBoundingClientRect();
      } catch {
        return;
      }
      const geo = thumbGeometry({
        scrollTop: container.scrollTop ?? 0,
        scrollHeight: container.scrollHeight ?? 0,
        clientHeight: container.clientHeight ?? 0,
        rectTop: rect?.top ?? 0,
        rectHeight: rect?.height ?? 0,
      });
      if (!geo) {
        hasOverflow = false;
        thumb.classList.remove(VISIBLE_CLASS);
        thumb.style.display = "none";
        return;
      }
      hasOverflow = true;
      thumb.style.display = "";
      thumb.style.top = geo.top + "px";
      thumb.style.height = geo.height + "px";
      thumb.style.left = Math.round((rect?.right ?? 0) - 8) + "px";
    };
    // The scroll event is already throttled per frame, so repaint
    // synchronously; do not rely on rAF (background tabs suspend it, which
    // would delay the scrollbar's appearance).
    // Note: show only on actual scrolling. mouseenter (hover) used to trigger
    // it too, but the pointer naturally enters the panel/list as it opens,
    // popping the scrollbar before the user has scrolled — that violated the
    // "appears only when scrolling" spec, so it was removed.
    const onScroll = () => {
      paint();
      show();
    };
    const onResize = () => paint();
    container.addEventListener?.("scroll", onScroll, { passive: true });
    global.addEventListener?.("resize", onResize);
    paint();

    return () => {
      clearTimeout(hideTimer);
      container.removeEventListener?.("scroll", onScroll);
      global.removeEventListener?.("resize", onResize);
      thumb.remove?.();
      container.classList.remove?.(CONTAINER_CLASS);
    };
  }

  global.MacIDMSlimScrollbar = Object.freeze({ attach, thumbGeometry });
})(globalThis);
