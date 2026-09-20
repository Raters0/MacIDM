import AppKit
import ObjectiveC
import SwiftUI

/// Swaps the cursor to a pointing hand while hovering an interactive
/// element. macOS keeps the arrow over SwiftUI buttons by default, which
/// made the flat hover styling read as decorative rather than clickable.
struct PointerCursorOnHover: ViewModifier {
    let isEnabled: Bool
    @Environment(\.isEnabled) private var environmentIsEnabled
    @State private var isPointerInside = false

    private var shouldShowPointer: Bool {
        isEnabled && environmentIsEnabled
    }

    func body(content: Content) -> some View {
        content
            // `onHover` only reports enter/exit. A control can rebuild while
            // the pointer remains inside it (notably when the appearance
            // segmented picker changes the whole window's color scheme), so
            // the replacement view never receives a fresh enter event.
            // Continuous hover reasserts the correct cursor on pointer moves
            // and after native controls reset their cursor during a click.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isPointerInside { isPointerInside = true }
                    updateCursor(shouldPoint: shouldShowPointer)
                case .ended:
                    isPointerInside = false
                    updateCursor(shouldPoint: false)
                }
            }
            .onChange(of: shouldShowPointer) { enabled in
                if isPointerInside { updateCursor(shouldPoint: enabled) }
            }
            .onDisappear {
                if isPointerInside { updateCursor(shouldPoint: false) }
            }
    }

    private func updateCursor(shouldPoint: Bool) {
        // Do not use the global NSCursor push/pop stack here. SwiftUI may
        // discard and recreate a hovered modifier during a state change,
        // leaving the old view unable to balance its push. `set()` is
        // idempotent and describes the cursor required by the current event.
        (shouldPoint ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

extension View {
    func pointerCursorOnHover(isEnabled: Bool = true) -> some View {
        modifier(PointerCursorOnHover(isEnabled: isEnabled))
    }
}

/// macOS 26+ draws window chrome out of glass materials: a window built
/// with the newer SDK no longer gets the legacy opaque white surface but a
/// translucent grey one, which broke the flat light-mode look (grey app
/// background under white cards). Paint an explicit surface under the
/// whole window content — pure white in light mode, the system material
/// in dark — so cards and hairlines keep their contrast regardless of the
/// system's default window material.
struct AppWindowSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            colorScheme == .dark
                ? Color(nsColor: .windowBackgroundColor)
                : Color.white
        )
    }
}

extension View {
    func appWindowSurface() -> some View { modifier(AppWindowSurface()) }
}

/// macOS 26/27 SDK 下详情列 ScrollView 的内容延伸到统一 toolbar 之下，
/// 顶部区段（标题/总进度）被遮挡且滚不出来；给滚动内容显式顶部边距。
/// 旧 SDK 无 contentMargins 行为，保持原样。
struct ScrollTopMargin: ViewModifier {
    var top: CGFloat = 24

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.contentMargins(.top, top, for: .scrollContent)
        } else {
            content
        }
    }
}

extension View {
    func scrollTopMargin(_ top: CGFloat = 24) -> some View {
        modifier(ScrollTopMargin(top: top))
    }
}

extension AppTheme {
    /// Dynamic NSWindow surface for hand-built AppKit windows (new-download
    /// confirmation, countdown): white in light mode, the system window
    /// material in dark. Hand-built windows under the macOS 26+ SDK inherit
    /// the grey glass default, which clashed with the light theme.
    static let windowSurfaceNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : .white
    }
}

/// One source of truth for every scrollbar in the app. Configures the
/// system overlay scroller — thin, semi-transparent, auto-hiding, and
/// draggable — so the entire app shares one consistent look without custom
/// drawing. The overlay scroller floats over content without reserving a
/// gutter and appears only while scrolling or while the pointer hovers.
/// Apply-once per view instance: even no-op setter calls can invalidate
/// AppKit layout, and re-applying on every SwiftUI update (each frame of a
/// split-view divider drag) made the window jitter. The "configured" marker
/// is an associated object, so it lives and dies with the NSScrollView
/// instance; a view destroyed and recreated by SwiftUI is configured again.
@MainActor
enum AppScrollerStyle {
    private static var configuredMarkerKey: UInt8 = 0

    static func apply(to scrollView: NSScrollView) {
        let wasConfigured =
            objc_getAssociatedObject(scrollView, &configuredMarkerKey) != nil
        // Self-healing: AppKit can reset the style after us (system
        // preference is "always show scroll bars", screen changes), so a
        // previously marked view whose style drifted gets re-applied
        // instead of being skipped forever.
        if wasConfigured, scrollView.scrollerStyle == .overlay {
            return
        }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        if !wasConfigured {
            objc_setAssociatedObject(
                scrollView, &configuredMarkerKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// SwiftUI owns the underlying NSScrollViews, so configure their AppKit
/// scrollers after the hierarchy has been attached to a window. Walking the
/// window's content view catches every NSScrollView — including
/// lazily-created ones in the detail panel, sheets, and popovers. The walk
/// runs on EVERY updateNSView (i.e. every SwiftUI re-render) with no
/// coalescing: `AppScrollerStyle.apply` is idempotent per scroll view (it
/// marks instances it has configured), so a walk over already-configured
/// views is a pure tree traversal. The previous 250 ms coalescing window
/// let freshly-recreated scrollers show the system-default legacy style
/// (thick, always visible, when the user's system preference is "always
/// show scroll bars") for up to a quarter second — the visible "thick bar
/// flashes then disappears" on detail-panel switches and settings sheets,
/// and a persistent thick bar on the task table after moving the window to
/// an external display. Window moves and screen-parameter changes also
/// trigger an immediate re-walk because AppKit can recreate scrollers when
/// a window changes screens. Attach this once per hosting window (main
/// window root, each sheet, each standalone window).
struct LightScrollerConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.window = nsView.window
        context.coordinator.walkIfNeeded(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init() {
            let center = NotificationCenter.default
            // AppKit may recreate scrollers when the window moves between
            // screens (backing changes). Re-walk immediately so the fresh
            // scrollers never linger in the legacy style.
            observers.append(
                center.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rewalk() }
                })
            observers.append(
                center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rewalk() }
                })
            // When the system scroll-bar preference flips mid-run ("Always"
            // ⇄ "When scrolling" ⇄ "Automatic", mouse plugged/unplugged),
            // AppKit can restyle existing scrollers to legacy. Re-apply our
            // overlay style immediately — the same re-force React Native
            // macOS performs on NSPreferredScrollerStyleDidChange.
            observers.append(
                center.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.rewalk()
                    }
                })
        }

        func walkIfNeeded(from view: NSView, attempt: Int = 0) {
            guard let root = view.window?.contentView else {
                // The background NSView is typically NOT yet attached to
                // its window when SwiftUI first calls updateNSView, and for
                // static content (a settings sheet that stops re-rendering)
                // no further updateNSView may ever arrive. Retry on the next
                // run-loop turns until the hierarchy is ready — removing
                // this retry left freshly created scroll views permanently
                // unconfigured (thick legacy scrollers).
                if attempt < 10 {
                    DispatchQueue.main.async {
                        self.walkIfNeeded(from: view, attempt: attempt + 1)
                    }
                }
                return
            }
            Self.applyToScrollViews(in: root)
        }

        func rewalk() {
            guard let root = window?.contentView else { return }
            Self.applyToScrollViews(in: root)
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private static func applyToScrollViews(in root: NSView) {
            scrollViews(in: root).forEach(AppScrollerStyle.apply)
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var result = (view as? NSScrollView).map { [$0] } ?? []
            for subview in view.subviews {
                result.append(contentsOf: scrollViews(in: subview))
            }
            return result
        }
    }
}

/// Settings and detail actions share the same flat hover language. Applying
/// this style at the settings root also covers buttons added by future rows.
/// `prominent` renders the app's single filled treatment — the brand accent
/// — reserved for the primary action of a surface; everything else stays a
/// quiet hairline box so primary buttons read as the exception, not the norm.
struct FlatHoverButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        FlatHoverButtonLabel(configuration: configuration, prominent: prominent)
    }
}

private struct FlatHoverButtonLabel: View {
    let configuration: FlatHoverButtonStyle.Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            // Hairline buttons echo the "Open file" affordance: hover lifts
            // the label (text and unstyled icons) to the brand accent on
            // top of the faint fill. Labels carrying their own explicit
            // style keep it.
            .foregroundStyle(labelColor)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .strokeBorder(outline, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .pointerCursorOnHover(isEnabled: isEnabled)
            .onHover { isHovering = $0 }
    }

    private var labelColor: Color {
        if prominent { return Color.white }
        return isHovering || configuration.isPressed ? AppTheme.accent : Color.primary
    }

    private var fill: Color {
        if prominent {
            return AppTheme.accent.opacity(
                configuration.isPressed ? 0.75 : isHovering ? 0.88 : 1
            )
        }
        return configuration.isPressed
            ? Color.primary.opacity(0.09)
            : isHovering ? Color.primary.opacity(0.05) : Color.clear
    }

    /// Prominent buttons carry their identity in the fill; a hairline
    /// outline would only fight it.
    private var outline: Color {
        prominent
            ? Color.clear
            : Color.primary.opacity(configuration.isPressed ? 0.20 : 0.12)
    }
}

/// Central design tokens for the MacIDM UI: a flat, line-first look with a
/// youthful but desaturated palette. Every view pulls semantic colors from
/// here instead of raw `.blue`/`.green`/`.red`, so the app stays consistent
/// and the palette can evolve in one place.
enum AppTheme {
    /// Brand accent: a soft indigo that reads modern in light and dark mode
    /// without the saturated system-blue heaviness. Also drives the system
    /// selection highlight (via the app-wide `.tint`), the sidebar filter
    /// selection, the "Open file" hover color, and the download progress
    /// bar tint — one color for every interactive/accent surface.
    static let accent = Color(red: 0.357, green: 0.424, blue: 0.941)

    /// Shared navigation/list selection treatment. Keeping both surfaces on
    /// the same token makes a selected task read like the selected sidebar
    /// filter without covering status text or progress colors.
    static let selectionFill = accent.opacity(0.10)
    static let selectionOutline = accent.opacity(0.25)

    /// Positive terminal states (completed, verified).
    static let success = Color(red: 0.22, green: 0.67, blue: 0.47)
    /// Failures and destructive warnings.
    static let danger = Color(red: 0.88, green: 0.32, blue: 0.34)
    /// Paused / needs-attention states.
    static let warning = Color(red: 0.85, green: 0.58, blue: 0.20)

    /// Small radii only — the look is flat and linear, not bubbly.
    static let cornerRadius: CGFloat = 6
    static let cardRadius: CGFloat = 8

    /// Hairline separators are the primary section boundary instead of
    /// filled card backgrounds.
    static var hairline: some ShapeStyle {
        Color.primary.opacity(0.08)
    }

    /// Major window boundaries need more contrast than card-internal
    /// hairlines. `primary` keeps the separator white in dark mode and dark
    /// in light mode while remaining quieter than text.
    static var structuralHairline: some ShapeStyle {
        Color.primary.opacity(0.18)
    }

    /// Status color mapping shared by the table cells and the detail panel.
    static func statusColor(for status: AppTaskStatus) -> Color {
        switch status {
        case .completed: success
        case .failed, .storageError, .filenameConflict, .needsRestart, .takeoverConflict: danger
        case .takeoverPending: accent
        case .paused: warning
        case .cancelled: .secondary
        case .probing: .secondary
        default: accent
        }
    }

    /// Harmonious mid-saturation palette for per-segment progress blocks.
    static let segmentPalette: [Color] = [
        Color(red: 0.357, green: 0.424, blue: 0.941),  // indigo
        Color(red: 0.20, green: 0.72, blue: 0.66),  // teal
        Color(red: 0.60, green: 0.42, blue: 0.94),  // violet
        Color(red: 0.94, green: 0.47, blue: 0.36),  // coral
        Color(red: 0.29, green: 0.64, blue: 0.91),  // sky
        Color(red: 0.88, green: 0.40, blue: 0.60),  // rose
        Color(red: 0.44, green: 0.70, blue: 0.34),  // leaf
        Color(red: 0.91, green: 0.64, blue: 0.24),  // amber
    ]
}
