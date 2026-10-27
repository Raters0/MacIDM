import AppKit
import SwiftUI

/// Uses the approved monochrome bear artwork instead of a generic download
/// symbol. Marking the bitmap as a template lets macOS tint it correctly on
/// light, dark and tinted menu bars.
struct MenuBarIconLabel: View {
    private static let image: NSImage = {
        guard
            let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            return NSImage(
                systemSymbolName: "arrow.down.circle.fill",
                accessibilityDescription: "MacIDM"
            ) ?? NSImage()
        }
        image.isTemplate = true
        image.size = NSSize(width: 21, height: 12)
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.template)
            .accessibilityLabel("MacIDM")
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel

    /// One dynamic color for both the SwiftUI content and the AppKit window
    /// behind it, so the two can never resolve to different shades.
    static let surfaceNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.985, alpha: 1)
    }

    private var surfaceColor: Color { Color(nsColor: Self.surfaceNSColor) }

    var body: some View {
        if #available(macOS 15.0, *) {
            panelContent.containerBackground(surfaceColor, for: .window)
        } else {
            panelContent.background(surfaceColor)
        }
    }

    private var panelContent: some View {
        VStack(spacing: 16) {
            header
            activityOverview
            actions
            if case .updateAvailable(let latest) = model.updateEngine.state {
                updateBanner(latest: latest)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 320)
        // MenuBarExtra can retain its material even when a window container
        // background is supplied. Paint an opaque surface behind the content
        // as well, extending through the hosting view's safe area.
        .background(surfaceColor.ignoresSafeArea())
        .background(MenuBarPanelWindowConfigurator())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacIDM")
                    .font(.system(size: 14, weight: .semibold))
                Text(activitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.activeCount > 0 {
                Text(DisplayFormatting.speed(model.aggregateSpeed))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var activityOverview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                metric(title: "活动", value: model.activeCount, color: AppTheme.accent)
                metricDivider
                metric(title: "排队", value: queuedCount, color: .secondary)
                metricDivider
                metric(title: "已暂停", value: pausedCount, color: AppTheme.warning)
            }

            Divider()

            if let progress = model.globalProgress, model.activeCount > 0 {
                VStack(spacing: 6) {
                    HStack {
                        Text("总进度")
                        Spacer()
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                    Text("当前没有正在下载的任务")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            panelButton("添加下载", systemImage: "plus", tint: AppTheme.accent, prominent: true) {
                model.presentNewDownload(draft: nil)
            }

            HStack(spacing: 8) {
                panelButton("暂停全部", systemImage: "pause.fill", tint: AppTheme.warning) {
                    pauseAll()
                }
                .disabled(!canPauseAny)

                panelButton("继续全部", systemImage: "play.fill", tint: AppTheme.success) {
                    resumeAll()
                }
                .disabled(!canResumeAny)
            }

            Button {
                NotificationCenter.default.post(name: .macIDMRequestMainWindow, object: nil)
            } label: {
                HStack {
                    Label("打开 MacIDM", systemImage: "macwindow")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarPanelButtonStyle(tint: AppTheme.accent, showsIdleBackground: false))
        }
    }

    /// New-release banner from the app update check. Only appears when a
    /// check found a newer release; clicking opens Sparkle's update window
    /// (release notes and Install) inside the app.
    private func updateBanner(latest: String) -> some View {
        Button {
            model.updateEngine.checkForUpdates()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                Text("发现新版本 \(latest)")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            MenuBarPanelButtonStyle(
                tint: AppTheme.warning, showsIdleBackground: false, restForeground: AppTheme.warning
            )
        )
        .help("查看更新内容并安装")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.browserBridgeStatus.isAvailable ? AppTheme.success : AppTheme.warning)
                .frame(width: 6, height: 6)
            Text("Chrome 接管：\(model.browserBridgeStatus.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
            .buttonStyle(
                MenuBarPanelButtonStyle(
                    tint: AppTheme.accent, showsIdleBackground: false, restForeground: .secondary
                )
            )
            .help("退出 MacIDM")
            .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }

    private func metric(title: LocalizedStringKey, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func panelButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .buttonStyle(MenuBarPanelButtonStyle(tint: tint, prominent: prominent))
    }

    private var activitySummary: String {
        if model.activeCount > 0 {
            return String(localized: "\(model.activeCount) 个任务正在处理")
        }
        if queuedCount > 0 {
            return String(localized: "\(queuedCount) 个任务等待下载")
        }
        return String(localized: "下载管理器已就绪")
    }

    private var queuedCount: Int {
        model.tasks.count { !$0.isCLIManaged && $0.status == .queued }
    }

    private var pausedCount: Int {
        model.tasks.count { !$0.isCLIManaged && $0.status == .paused }
    }

    private var canPauseAny: Bool {
        model.tasks.contains {
            !$0.isCLIManaged && [.queued, .probing, .running, .verifying].contains($0.status)
        }
    }

    private var canResumeAny: Bool {
        model.tasks.contains {
            !$0.isCLIManaged
                && [.paused, .failed, .needsRestart, .storageError].contains($0.status)
        }
    }

    private func pauseAll() {
        for task in model.tasks
        where !task.isCLIManaged && [.queued, .probing, .running, .verifying].contains(task.status) {
            model.pause(task.id)
        }
    }

    private func resumeAll() {
        for task in model.tasks
        where !task.isCLIManaged
            && [.paused, .failed, .needsRestart, .storageError].contains(task.status)
        {
            model.resume(task.id)
        }
    }
}

private struct MenuBarPanelButtonStyle: ButtonStyle {
    let tint: Color
    var prominent = false
    var showsIdleBackground = true
    /// Rest foreground for quiet controls such as the footer quit button;
    /// nil keeps the standard primary label color.
    var restForeground: Color?

    func makeBody(configuration: Configuration) -> some View {
        MenuBarPanelButtonLabel(
            configuration: configuration, tint: tint, prominent: prominent,
            showsIdleBackground: showsIdleBackground, restForeground: restForeground
        )
    }
}

private struct MenuBarPanelButtonLabel: View {
    let configuration: MenuBarPanelButtonStyle.Configuration
    let tint: Color
    let prominent: Bool
    let showsIdleBackground: Bool
    var restForeground: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background(
                prominent
                    ? tint.opacity(configuration.isPressed ? 0.75 : isHovering ? 0.9 : 1)
                    : Color.primary.opacity(
                        configuration.isPressed ? 0.09 : isHovering ? 0.055 : showsIdleBackground ? 0.035 : 0
                    ),
                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Rectangle())
            .pointerCursorOnHover(isEnabled: isEnabled)
            .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        if prominent { return .white }
        if isHovering && isEnabled { return tint }
        return restForeground ?? .primary
    }
}

/// Under the macOS 26 SDK the MenuBarExtra window paints its own layers
/// outside the hosted content: a glass strip above it and the default white
/// window background below it, framing the panel with two mismatched bands.
/// SwiftUI backgrounds cannot reach those areas, so paint the window itself
/// with the panel surface and hide the system backdrops around the content.
private struct MenuBarPanelWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AttachmentView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { Self.configure(window) }
    }

    /// Configures synchronously when attached, before the first display.
    private final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MenuBarPanelWindowConfigurator.configure(window) }
        }
    }

    @MainActor
    static func configure(_ window: NSWindow) {
        window.backgroundColor = MenuBarContentView.surfaceNSColor
        window.titlebarSeparatorStyle = .none
        guard let content = window.contentView, let frameView = content.superview else { return }
        hideBackdrops(in: frameView, keeping: content)
    }

    /// Hides material views that do not host the panel content. A backdrop
    /// that contains the content must stay visible, and the content's own
    /// subtree is never touched.
    @MainActor
    private static func hideBackdrops(in view: NSView, keeping content: NSView) {
        for subview in view.subviews where subview !== content {
            if !content.isDescendant(of: subview), isBackdrop(subview) {
                subview.isHidden = true
            } else {
                hideBackdrops(in: subview, keeping: content)
            }
        }
    }

    @MainActor
    private static func isBackdrop(_ view: NSView) -> Bool {
        view is NSVisualEffectView || String(describing: type(of: view)).contains("GlassEffect")
    }
}
