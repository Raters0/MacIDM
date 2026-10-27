import AppKit
import IDMEngine
import SwiftUI

extension SettingsView {
    var ytdlpSection: some View {
        settingsSection("yt-dlp（站点解析组件）") {
            settingRow("当前状态") {
                Text(model.ytdlpManager.statusText)
                    .foregroundStyle(.secondary)
            }
            rowDivider
            settingRow("更新检查") {
                HStack(spacing: 8) {
                    if let result = model.ytdlpManager.checkResult {
                        Text(checkResultText(result))
                            .font(.caption)
                            .foregroundStyle(checkResultColor(result))
                    }
                    if model.ytdlpManager.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("检查更新") {
                        Task { await model.ytdlpManager.checkForUpdates() }
                    }
                    .disabled(model.ytdlpManager.isChecking)
                    if case .updateAvailable = model.ytdlpManager.checkResult {
                        Button("立即更新") {
                            Task { await model.ytdlpManager.update() }
                        }
                        .disabled(model.ytdlpManager.isChecking)
                    }
                }
            }
            rowDivider
            toggleRow(
                "启动时自动检查 yt-dlp 更新",
                description: "每天最多检查一次。",
                isOn: $settings.ytdlpAutoCheckUpdates
            )
            if let progress = model.ytdlpManager.installProgress {
                rowDivider
                settingRow("安装进度") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                                .tint(AppTheme.accent)
                                .frame(width: 160)
                            Text(
                                "\(DisplayFormatting.byteCount(progress.receivedBytes)) / \(DisplayFormatting.byteCount(progress.totalBytes))"
                            )
                            .font(.caption)
                            .monospacedDigit()
                        } else {
                            Text("已下载 \(DisplayFormatting.byteCount(progress.receivedBytes))")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
        } footer: {
            Text("yt-dlp 已内置在应用中，用于解析 YouTube 等站点；更新会下载到应用支持目录并优先生效。")
        }
    }

    var generalSection: some View {
        settingsSection("通用") {
            settingRow(
                "语言",
                description: "切换后应用将重新启动。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.languagePreference },
                        set: { newValue in
                            if newValue != settings.languagePreference {
                                pendingLanguage = newValue
                            }
                        }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("语言")
                .fixedSize()
                .pointerCursorOnHover()
            }
            rowDivider
            toggleRow("App 激活时检测剪贴板中的下载链接", isOn: $settings.clipboardAutoDetect)
            rowDivider
            toggleRow(
                "持续监测剪贴板中的下载链接",
                description: "在其他应用里复制下载链接时立即弹出确认窗口，无需切换到本应用；本应用处于前台时不会触发。",
                isOn: $settings.clipboardWatch
            )
            rowDivider
            toggleRow(
                "仅对文件和媒体链接弹出",
                description: "只在复制的是文件、视频/音频或支持的视频网站链接时弹出；复制普通网页链接不打扰。",
                isOn: $settings.clipboardWatchFilesOnly
            )
            .disabled(!settings.clipboardWatch)
            rowDivider
            launchAtLoginRow
            rowDivider
            toggleRow(
                "关闭主窗口后仅保留菜单栏图标",
                description: "隐藏 Dock 图标并继续在后台下载；可从菜单栏重新打开主窗口。",
                isOn: $settings.closeWindowHidesToMenuBar
            )
            rowDivider
            toggleRow(
                "隐藏文件名，仅展示任务ID",
                description: "便于截图或反馈问题时脱敏；磁盘上的文件不受影响。",
                isOn: $settings.redactFilenames
            )
            rowDivider
            settingRow(
                "首次使用引导",
                description: onboardingRowDescription,
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Button("重新显示…") {
                    settings.hasCompletedOnboarding = false
                }
            }
        }
    }

    /// 全局快捷键单独成页：总开关一键停用所有组合键；每个动作一行，行名就是
    /// 它触发的操作；录制框清空即表示该动作不挂任何全局快捷键。注册动作由
    /// AppModel 跟着设置变化即时同步，这里只负责录入与冲突反馈。
    var shortcutsSection: some View {
        settingsSection("快捷键") {
            toggleRow(
                "启用全局快捷键",
                description: "关闭后所有已录制的组合键立即失效。",
                isOn: $settings.globalHotKeyEnabled
            )
            rowDivider
            settingRow(
                "呼出新建下载",
                description: shortcutRowDescription,
                controlColumnWidth: 300
            ) {
                HStack(spacing: 8) {
                    GlobalHotKeyRecorder(combo: $settings.globalHotKeyCombo) { isRecording in
                        model.isGlobalHotKeyRecording = isRecording
                    }
                    Button("清除") {
                        settings.globalHotKeyCombo = nil
                    }
                    .disabled(settings.globalHotKeyCombo == nil)
                    Button("恢复默认") {
                        settings.globalHotKeyCombo = .defaultValue
                    }
                }
            }
        }
    }

    var shortcutRowDescription: LocalizedStringKey {
        if let error = model.globalHotKeyError {
            return LocalizedStringKey(error)
        }
        if settings.globalHotKeyCombo == nil {
            return "未设置组合键，该操作没有全局快捷键。"
        }
        return "在任意应用中按下组合键即可弹出新建下载窗口；剪贴板里是链接时自动填入。点输入框后按组合键录制，Esc 取消。"
    }

    var onboardingRowDescription: LocalizedStringKey {
        if !settings.globalHotKeyEnabled {
            return "全局快捷键已关闭。"
        }
        if let combo = settings.globalHotKeyCombo {
            return "全局快捷键 \(combo.displayString) 可随时呼出新建下载。"
        }
        return "未设置全局快捷键，可在「快捷键」页录制。"
    }

    var diagnosticsSection: some View {
        settingsSection("诊断与日志") {
            settingRow(
                "应用日志",
                description: "下载、引擎与桥接的运行记录。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                HStack(spacing: 8) {
                    Button("查看日志…") {
                        LogWindowPresenter.shared.showAppLog(settings: settings)
                    }
                }
            }
            rowDivider
            settingRow(
                "接管日志",
                description: "浏览器下载接管的判定过程。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                HStack(spacing: 8) {
                    Button("查看接管日志…") {
                        LogWindowPresenter.shared.showTakeoverLog(
                            logURL: model.takeoverLogURL,
                            settings: settings
                        )
                    }
                }
            }
        }
    }

    var aboutSection: some View {
        settingsSection("关于") {
            settingRow("版本") {
                Text(appVersionText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            rowDivider
            updateCheckRow
            rowDivider
            toggleRow(
                "自动检查新版本",
                description: "每天最多联网检查一次；关闭后仅手动检查。",
                isOn: Binding(
                    get: { model.updateEngine.automaticallyChecksForUpdates },
                    set: { model.updateEngine.automaticallyChecksForUpdates = $0 }
                )
            )
            rowDivider
            toggleRow(
                "自动下载并安装更新",
                description: "关闭时每次安装前都会先征求同意。",
                isOn: Binding(
                    get: { model.updateEngine.automaticallyDownloadsUpdates },
                    set: { model.updateEngine.automaticallyDownloadsUpdates = $0 }
                )
            )
            .disabled(!model.updateEngine.automaticallyChecksForUpdates)
            rowDivider
            settingRow("构建时间") {
                Text(buildDateText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let commit = buildCommit, commit != "unknown" {
                rowDivider
                settingRow("构建版本") {
                    Text(commit)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// App self-update (Settings → 关于), powered by Sparkle (technical-spec
    /// §6.1). The check button delegates to Sparkle's standard driver UI;
    /// the status text mirrors the engine state so the outcome stays
    /// visible after Sparkle's dialogs close.
    var updateCheckRow: some View {
        settingRow(
            "软件更新",
            description: "自动检查每天最多一次。",
            controlColumnWidth: SettingsMetrics.mediumControlColumn
        ) {
            HStack(spacing: 8) {
                if let text = updateStatusText(model.updateEngine.state) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(updateStatusColor(model.updateEngine.state))
                }
                Button("检查更新") {
                    model.updateEngine.checkForUpdates()
                }
                if case .updateAvailable(_, let releaseURL) = model.updateEngine.state {
                    Button("查看新版本") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                }
            }
        }
    }

    func updateStatusText(_ state: AppUpdateEngine.State) -> String? {
        switch state {
        case .idle:
            nil
        case .upToDate:
            String(localized: "已是最新")
        case .updateAvailable(let latest, _):
            String(localized: "发现新版本 \(latest)")
        case .failed(let message):
            message
        }
    }

    func updateStatusColor(_ state: AppUpdateEngine.State) -> Color {
        switch state {
        case .idle: Color.secondary
        case .upToDate: AppTheme.success
        case .updateAvailable: AppTheme.warning
        case .failed: AppTheme.danger
        }
    }

    // MARK: - yt-dlp check result helpers

    func checkResultText(_ result: YTDlpManager.CheckResult) -> String {
        switch result {
        case .upToDate(let latest):
            return String(localized: "已是最新（\(latest)）")
        case .updateAvailable(let latest):
            return String(localized: "发现新版本 \(latest)")
        case .failed(let message):
            return message
        }
    }

    func checkResultColor(_ result: YTDlpManager.CheckResult) -> Color {
        switch result {
        case .upToDate: AppTheme.success
        case .updateAvailable: AppTheme.warning
        case .failed: AppTheme.danger
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if panel.runModal() == .OK, let selected = panel.url {
            settings.downloadDirectory = selected.path
        }
    }

    func chooseCategoryDirectory(for category: DownloadCategory) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if panel.runModal() == .OK, let selected = panel.url {
            settings.categoryPaths[category.rawValue] = selected.path
        }
    }

    // MARK: - Build info

    var appVersionText: String {
        let version = AppBuildInfo.marketingVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        // Sparkle needs CFBundleVersion to carry the marketing version, so
        // the two are usually identical and printing both would repeat.
        if let version, let build, build != version {
            return "\(version) (\(build))"
        }
        return version ?? String(localized: "未知")
    }

    var buildDateText: String {
        Bundle.main.object(forInfoDictionaryKey: "MacIDMBuildDate") as? String
            ?? String(localized: "未知")
    }

    var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "MacIDMBuildCommit") as? String
    }
}
