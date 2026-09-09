import SwiftUI

/// First-run checklist: Chrome present → Native Host registered → extension
/// loaded. Every step is skippable; the sheet is always dismissible.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var refreshID = 0
    @State private var installMessage: String?

    private let installer = NativeHostInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎使用 MacIDM")
                    .font(.title2.bold())
                Text("三步完成浏览器接管配置，之后 Chrome 的下载会自动交给 MacIDM。")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    stepRow(
                        number: 1,
                        title: "安装 Google Chrome",
                        done: installer.isChromeInstalled,
                        detail: installer.isChromeInstalled ? "已检测到 Chrome" : "未检测到 Chrome，可先跳过"
                    )

                    Divider()

                    stepRow(
                        number: 2,
                        title: "注册 Native Host",
                        done: installer.isHostRegistered,
                        detail: installer.isHostRegistered ? "已注册到 Chrome" : "让 Chrome 能与 MacIDM 通信"
                    ) {
                        if !installer.isHostRegistered {
                            Button("一键注册") {
                                do {
                                    try installer.install()
                                    installMessage = String(localized: "注册成功")
                                    refreshID += 1
                                } catch {
                                    installMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(FlatHoverButtonStyle(prominent: true))
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            stepBadge(number: 3, done: false)
                            Text("加载 Chrome 扩展")
                                .font(.headline)
                        }
                        Text(
                            "在 Chrome 打开 chrome://extensions → 开启「开发者模式」→「加载已解压的扩展程序」→ 选择本项目的 BrowserExtension/chrome 目录。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("复制扩展目录路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    installer.extensionSourcePath,
                                    forType: .string
                                )
                            }
                            .controlSize(.small)
                            if installer.isChromeInstalled {
                                Button("打开 Chrome") {
                                    installer.openChrome()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if let installMessage {
                Text(installMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("桥接状态：\(model.browserBridgeStatus.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("跳过") {
                    complete()
                }
                Button("完成") {
                    complete()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(FlatHoverButtonStyle(prominent: true))
            }
        }
        .buttonStyle(FlatHoverButtonStyle())
        .padding(24)
        .frame(width: 560)
        .id(refreshID)
    }

    private func complete() {
        model.settings.hasCompletedOnboarding = true
        dismiss()
    }

    private func stepRow(
        number: Int,
        title: LocalizedStringKey,
        done: Bool,
        detail: LocalizedStringKey,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            stepBadge(number: number, done: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    private func stepBadge(number: Int, done: Bool) -> some View {
        Group {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
            } else {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.secondary))
            }
        }
        .frame(width: 22, height: 22)
    }
}
