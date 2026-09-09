import AppKit
import SwiftUI

/// Flat titlebar controls installed as `NSTitlebarAccessoryViewController`s.
///
/// SwiftUI's `.toolbar` was tried first, but on macOS 26 it wraps every item
/// in Liquid Glass and asynchronously reasserts the visible window title —
/// both break the flat, hairline-divided window design. Titlebar accessory
/// views are plain AppKit containers: they share the traffic-light row
/// without any toolbar material, and leave `titleVisibility` untouched.
/// Leading accessory: download controls; trailing accessory: search field
/// and the detail-column visibility toggle.
struct TitlebarAccessoryToolbar: NSViewRepresentable {
    let model: AppModel
    @Binding var searchText: String
    @Binding var isSidebarVisible: Bool
    @Binding var isDetailColumnVisible: Bool
    let canResume: () -> Bool
    let canPause: () -> Bool
    let canCancel: () -> Bool
    let canRemove: () -> Bool
    let onAdd: () -> Void
    let onResume: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRequestRemoval: () -> Void
    let onPresentSettings: () -> Void
    let isColumnVisible: (String) -> Bool
    let toggleColumn: (String) -> Void

    /// Accessory height drives the titlebar height: 46 pt gives the
    /// traffic-light row comfortable vertical breathing room instead of
    /// the cramped default. (Leading/trailing accessories grow the
    /// titlebar to fit.)
    private static let accessoryHeight: CGFloat = 46

    func makeNSView(context: Context) -> AccessoryHostView {
        let host = AccessoryHostView()
        host.leadingFactory = {
            Self.hostingView(
                TitlebarLeadingControls(
                    model: model,
                    isSidebarVisible: $isSidebarVisible,
                    canResume: canResume,
                    canPause: canPause,
                    canCancel: canCancel,
                    canRemove: canRemove,
                    onAdd: onAdd,
                    onResume: onResume,
                    onPause: onPause,
                    onCancel: onCancel,
                    onRequestRemoval: onRequestRemoval,
                    onPresentSettings: onPresentSettings,
                    isColumnVisible: isColumnVisible,
                    toggleColumn: toggleColumn
                )
                .frame(height: Self.accessoryHeight)
            )
        }
        host.trailingFactory = {
            Self.hostingView(
                TitlebarTrailingControls(
                    model: model,
                    searchText: $searchText,
                    isDetailColumnVisible: $isDetailColumnVisible
                )
                .frame(height: Self.accessoryHeight)
            )
        }
        return host
    }

    func updateNSView(_ nsView: AccessoryHostView, context: Context) {
        // The hosted SwiftUI content keeps its own live bindings; accessory
        // controllers are installed exactly once per window.
    }

    private static func hostingView(_ content: some View) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: content)
        // Size the accessory from the SwiftUI content's intrinsic size so
        // the titlebar neither stretches nor clips it.
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        return hosting
    }

    /// Plain NSView that installs the accessory controllers once its window
    /// is known. Accessory views outlive this host, which is only an anchor.
    final class AccessoryHostView: NSView {
        var leadingFactory: (() -> NSView)?
        var trailingFactory: (() -> NSView)?
        private var installed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !installed else { return }
            installed = true

            let leading = NSTitlebarAccessoryViewController()
            leading.layoutAttribute = .leading
            if let view = leadingFactory?() {
                leading.view = view
                window.addTitlebarAccessoryViewController(leading)
            }

            let trailing = NSTitlebarAccessoryViewController()
            trailing.layoutAttribute = .trailing
            if let view = trailingFactory?() {
                trailing.view = view
                window.addTitlebarAccessoryViewController(trailing)
            }
        }
    }
}

/// Bezel-less icon button for the titlebar row. Color-only hover affordance;
/// semantic actions supply success, warning or danger while neutral actions
/// keep the brand accent. Toggle buttons pass `isActive` so the icon stays
/// tinted while the state they control is on.
private struct FlatIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var hoverColor = AppTheme.accent
    var isActive = false
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isEnabled
                        ? (isHovering || isActive ? hoverColor : Color.secondary)
                        : Color.secondary.opacity(0.35)
                )
                .frame(width: 27, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .pointerCursorOnHover()
        .help(title)
    }
}

/// Download controls in the leading titlebar slot, right after the traffic
/// lights. Observation of the model keeps the enablement closures fresh.
private struct TitlebarLeadingControls: View {
    @ObservedObject var model: AppModel
    @Binding var isSidebarVisible: Bool
    let canResume: () -> Bool
    let canPause: () -> Bool
    let canCancel: () -> Bool
    let canRemove: () -> Bool
    let onAdd: () -> Void
    let onResume: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onRequestRemoval: () -> Void
    let onPresentSettings: () -> Void
    let isColumnVisible: (String) -> Bool
    let toggleColumn: (String) -> Void
    @State private var isColumnPopoverShown = false

    var body: some View {
        HStack(spacing: 2) {
            FlatIconButton(
                title: isSidebarVisible ? "隐藏左侧筛选栏" : "显示左侧筛选栏",
                systemImage: "sidebar.leading",
                isActive: isSidebarVisible
            ) {
                isSidebarVisible.toggle()
            }
            FlatIconButton(title: "添加", systemImage: "plus", action: onAdd)
            FlatIconButton(
                title: "继续", systemImage: "play.fill", hoverColor: AppTheme.success,
                isEnabled: canResume(),
                action: onResume
            )
            FlatIconButton(
                title: "暂停", systemImage: "pause.fill", hoverColor: AppTheme.warning,
                isEnabled: canPause(),
                action: onPause
            )
            FlatIconButton(
                title: "取消", systemImage: "xmark", hoverColor: AppTheme.danger,
                isEnabled: canCancel(),
                action: onCancel
            )
            FlatIconButton(
                title: "移除", systemImage: "trash", hoverColor: AppTheme.danger,
                isEnabled: canRemove(),
                action: onRequestRemoval
            )
            FlatIconButton(title: "设置", systemImage: "gearshape", action: onPresentSettings)
            columnPickerButton
        }
        // AppKit parks the leading accessory right after the traffic-light
        // cluster's DEFAULT position. TrafficLightAligner moves the cluster
        // to x = 18 to line up with the sidebar below, which shrinks this
        // gap; the inset restores a spacing that matches the ~16 pt visual
        // rhythm between the icons themselves.
        .padding(.leading, 16)
    }

    private var columnPickerButton: some View {
        FlatIconButton(title: "显示或隐藏列表列", systemImage: "tablecells") {
            isColumnPopoverShown.toggle()
        }
        .popover(isPresented: $isColumnPopoverShown, arrowEdge: .bottom) {
            List {
                ForEach(Self.allColumns, id: \.id) { column in
                    Button {
                        toggleColumn(column.id)
                    } label: {
                        HStack {
                            Image(
                                systemName: isColumnVisible(column.id)
                                    ? "checkmark.square.fill" : "square"
                            )
                            .foregroundStyle(
                                isColumnVisible(column.id)
                                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(column.title)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(column.id == "filename")
                    .pointerCursorOnHover(isEnabled: column.id != "filename")
                }
            }
            .frame(width: 180, height: 240)
        }
    }

    private static let allColumns: [(id: String, title: LocalizedStringKey)] = [
        ("filename", "文件名"), ("size", "大小"), ("status", "状态"),
        ("speed", "速度"), ("duration", "总耗时"), ("date", "日期"), ("progress", "进度"),
    ]
}

/// Search field and the detail-column toggle in the trailing titlebar slot.
/// Bare icon + field, no capsule background — the titlebar stays one flat,
/// uninterrupted surface.
private struct TitlebarTrailingControls: View {
    @ObservedObject var model: AppModel
    @Binding var searchText: String
    @Binding var isDetailColumnVisible: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索任务", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursorOnHover()
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 220)

            FlatIconButton(
                title: isDetailColumnVisible ? "隐藏右侧详情栏" : "显示右侧详情栏",
                systemImage: "sidebar.trailing",
                isActive: isDetailColumnVisible
            ) {
                isDetailColumnVisible.toggle()
            }
        }
        // Trailing accessories sit flush at the titlebar's right edge; the
        // 26 pt inset aligns the toggle icon's right edge with the detail
        // panel's content edge below (matching the traffic-light alignment
        // on the left).
        .padding(.trailing, 26)
    }
}
