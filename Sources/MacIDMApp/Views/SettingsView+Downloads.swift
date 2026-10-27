import AppKit
import IDMEngine
import SwiftUI

extension SettingsView {
    /// Launch-at-login toggle. Unlike a plain `toggleRow`, this one calls
    /// `SMAppService.register/unregister` and surfaces errors inline (e.g.
    /// "app not in /Applications" during development, or the user denied
    /// the system prompt so the state is `.requiresApproval`).
    var launchAtLoginRow: some View {
        let manager = model.launchAtLoginManager
        let isOn = Binding<Bool>(
            get: {
                manager.state == .enabled || manager.state == .requiresApproval
            },
            set: { newValue in
                launchAtLoginError = manager.setEnabled(newValue)
            }
        )
        return settingRow(
            "开机自启动",
            description: launchAtLoginDescription(for: manager.state),
            controlColumnWidth: SettingsMetrics.compactControlColumn
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .accessibilityLabel("开机自启动")
                    .pointerCursorOnHover()
                if let error = launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    func launchAtLoginDescription(for state: LaunchAtLoginManager.State) -> LocalizedStringKey {
        switch state {
        case .enabled:
            return "登录时自动启动 MacIDM 并常驻菜单栏。"
        case .requiresApproval:
            return "已注册但被系统阻止；请在“系统设置 → 通用 → 登录项”中重新启用。"
        case .disabled:
            return "登录时自动启动 MacIDM 并常驻菜单栏。"
        case .unavailable(let reason):
            return LocalizedStringKey(reason)
        }
    }

    // MARK: - Sections

    var downloadSection: some View {
        settingsSection("下载") {
            settingRow("每个任务最大并行请求") {
                Stepper(value: $settings.maximumParallelRequests, in: 1...64) {
                    Text("\(settings.maximumParallelRequests)")
                        .monospacedDigit()
                }
                .pointerCursorOnHover()
            }
            rowDivider
            settingRow("同时下载任务数") {
                Stepper(value: $settings.simultaneousDownloads, in: 1...10) {
                    Text("\(settings.simultaneousDownloads)")
                        .monospacedDigit()
                }
                .pointerCursorOnHover()
            }
            rowDivider
            settingRow("全局限速") {
                HStack(spacing: 6) {
                    TextField(
                        "不限",
                        value: $settings.speedLimitKBps,
                        format: .number
                    )
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    Text("KB/s（0 为不限）")
                        .foregroundStyle(.secondary)
                }
            }
            rowDivider
            toggleRow("新任务自动开始下载", isOn: $settings.autoStartDownloads)
            rowDivider
            toggleRow(
                "按分类保存到子文件夹",
                description: "新任务会按文件类型保存到 video、audio、document 等子文件夹；不会移动已有文件。",
                isOn: $settings.organizeByCategory
            )
            rowDivider
            settingRow("默认保存位置") {
                HStack {
                    Text(settings.downloadDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择…", action: chooseDirectory)
                }
            }
        }
    }

    var categoryPathsSection: some View {
        settingsSection("分类保存路径") {
            ForEach(DownloadCategory.allCases, id: \.self) { category in
                settingRow(LocalizedStringKey(category.title)) {
                    HStack {
                        Text(
                            settings.categoryPaths[category.rawValue]
                                ?? String(localized: "使用默认")
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        Button("选择…") {
                            chooseCategoryDirectory(for: category)
                        }
                        if settings.categoryPaths[category.rawValue] != nil {
                            Button("清除") {
                                settings.categoryPaths.removeValue(
                                    forKey: category.rawValue
                                )
                            }
                        }
                    }
                }
                if category != DownloadCategory.allCases.last {
                    rowDivider
                }
            }
        } footer: {
            Text("为特定分类指定独立的保存路径；留空则使用默认位置或子文件夹规则。")
        }
    }

    var notificationSection: some View {
        settingsSection("通知") {
            toggleRow("下载完成时播放提示音", isOn: $settings.notificationSoundsEnabled)
            rowDivider
            settingRow(
                "全部下载完成后",
                description: "全部任务结束后弹出倒计时确认窗，可随时取消；睡眠或关机需要系统授权。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Picker("", selection: $settings.completionAction) {
                    ForEach(SystemCompletionAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("全部下载完成后")
                .pointerCursorOnHover()
                .foregroundStyle(
                    activeColorScheme == .dark ? Color.white : Color.primary
                )
                // NSPopUpButton caches its title/arrow appearance. Recreate
                // it when the in-app theme changes instead of retaining the
                // light-mode black foreground in a dark settings sheet.
                .id("completion-action-\(settings.colorScheme.rawValue)")
            }
        }
    }

    var appearanceSection: some View {
        settingsSection("主题") {
            HStack(spacing: 12) {
                ForEach(AppColorScheme.allCases) { scheme in
                    Button {
                        settings.colorScheme = scheme
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: themeSymbol(scheme))
                                .font(.system(size: 26, weight: .light))
                                .frame(height: 44)
                            Text(scheme.title)
                                .font(.body.weight(.medium))
                            Image(systemName: settings.colorScheme == scheme ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.colorScheme == scheme ? AppTheme.accent : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            settings.colorScheme == scheme ? AppTheme.accent.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scheme.title)
                    .accessibilityAddTraits(settings.colorScheme == scheme ? .isSelected : [])
                }
            }
            .padding(.vertical, 12)
        }
    }

    func themeSymbol(_ scheme: AppColorScheme) -> String {
        switch scheme {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

}
