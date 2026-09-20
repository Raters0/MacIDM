import AppKit
import SwiftUI

/// Draws a single consistent hairline across the full width of the task
/// list column at the NSTableHeaderView's bottom edge.
///
/// The native NSTableHeaderView bottom rule can be thicker than the rest
/// of the window's hairlines and may not extend to the scroll view's full
/// width (leaving a gap before the detail divider). This overlay erases
/// the native rule with the window background and redraws a 1-pixel
/// hairline that spans the entire list column — no gap, no patch.
struct TableHeaderRuleOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> RuleView {
        RuleView()
    }

    func updateNSView(_ nsView: RuleView, context: Context) {
        // Deliberately no needsDisplay here: updateNSView fires on every
        // SwiftUI re-render (each frame of a split-divider drag), and each
        // draw walks the window's view tree to find the table header.
        // Redraws are driven by layout() and viewDidMoveToWindow, which are
        // the only events that can move the hairline.
    }

    @MainActor
    final class RuleView: NSView {
        // Resolved once and cached: draw() can fire every frame while the
        // user drags the detail divider (layout changes each frame), and a
        // full view-tree walk per draw contributed to drag jitter.
        private weak var cachedTable: NSTableView?

        // This overlay only draws a decorative hairline. It must never
        // intercept mouse events — otherwise column dragging, sorting,
        // and row selection in the underlying NSTableView stop working.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsDisplay = true
            // The NSTableHeaderView is created lazily by AppKit. Schedule a
            // few redraws at increasing delays to catch its creation without
            // keeping a permanent observer alive.
            for delay in [0.0, 0.1, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    [weak self] in
                    self?.needsDisplay = true
                }
            }
        }

        override func layout() {
            super.layout()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let window,
                let table = resolvedTable(in: window),
                let header = table.headerView
            else { return }

            let headerRect = header.convert(header.bounds, to: self)
            let backingScale = window.backingScaleFactor
            let onePixel = 1 / max(backingScale, 1)

            // The native header rule sits at the header view's bottom edge.
            // In a flipped coordinate system that is headerRect.maxY; in a
            // non-flipped system it is headerRect.minY.
            let y = isFlipped ? headerRect.maxY : headerRect.minY

            // Snap to a pixel boundary so the line renders sharp.
            let snappedY = (y * backingScale).rounded() / backingScale

            // Step 1 — erase the native header rule with the window
            // background so only our consistent hairline remains.
            NSColor.windowBackgroundColor.setFill()
            NSRect(
                x: 0, y: snappedY - onePixel,
                width: bounds.width, height: onePixel * 4
            ).fill()

            // Step 2 — draw the full-width hairline at the same position.
            // NSColor.labelColor maps to SwiftUI's Color.primary.
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            NSRect(
                x: 0, y: snappedY,
                width: bounds.width, height: onePixel
            ).fill()
        }

        /// Reuses the cached table while it stays in the window; falls back
        /// to a tree walk (and refreshes the cache) after the SwiftUI Table
        /// is rebuilt.
        private func resolvedTable(in window: NSWindow) -> NSTableView? {
            if let cached = cachedTable, cached.window === window {
                return cached
            }
            guard let found = Self.findTable(in: window.contentView) else { return nil }
            cachedTable = found
            return found
        }

        private static func findTable(in view: NSView?) -> NSTableView? {
            guard let view else { return nil }
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }
    }
}
