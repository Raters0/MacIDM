import AppKit
import IDMEngine
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var activeColorScheme
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// The site session list subscribes separately: the "Saved sites"
    /// section must refresh in place after deleting or pasting sessions;
    /// observing only the model would miss change notifications from the
    /// nested SessionStore.
    @ObservedObject var sessionStore: SessionStore
    @State private var proxyPassword = ""
    @State private var proxyCredentialMessage: String?
    /// Local sheet state for cookie pasting; kept separate from the
    /// model-level `cookiePasteDomain` (used by the main window's failure
    /// alert) so the two presentation anchors never fight.
    @State private var pasteDomain: CookiePasteDomain?
    /// Language picked in the menu but not yet applied; the restart
    /// confirmation gate sits between the Picker and `languagePreference`.
    @State private var pendingLanguage: AppLanguage?
    /// Error message from the last launch-at-login toggle attempt; nil on
    /// success. Surfaced inline under the toggle so the user knows why it
    /// did not stick (e.g. app not in /Applications during development).
    @State private var launchAtLoginError: String?
    /// Site-session list starts collapsed to the most recent domains;
    /// the in-card toggle expands it to the full list.
    @State private var sessionsExpanded = false
    @State private var selectedPage: SettingsPage = .general

    /// Control-column tiers. A single 300pt column for every control left
    /// large transparent gaps next to toggles and short menus while
    /// squeezing the title/description column into early wraps.
    private enum SettingsMetrics {
        static let compactControlColumn: CGFloat = 64
        static let mediumControlColumn: CGFloat = 160
        static let wideControlColumn: CGFloat = 260
        /// Saved-site rows pin the timestamp and the ellipsis menu to fixed
        /// trailing slots; only the domain column flexes, so a row's expiry
        /// note (rendered under the domain) can never shift the date or the
        /// menu between rows.
        static let sessionDateColumn: CGFloat = 124
        static let footerGap: CGFloat = 6
        static let collapsedSessionLimit = 5
    }

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        sessionStore = model.sessionStore
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.symbol)
                    .padding(.vertical, 5)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            .accessibilityLabel("设置分类")
            Divider()
            settingsForm
                .id(selectedPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .appWindowSurface()
    }

    // MARK: - Form scaffolding

    /// Hand-laid flat form instead of `Form { }.formStyle(.grouped)`:
    /// grouped forms draw every section as a filled rounded card, and the
    /// color blocks clashed with the flat, line-first detail-panel look.
    /// Sections are caption titles + rows separated by hairlines.
    private var settingsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selectedPage {
                case .general:
                    generalSection
                    notificationSection
                case .downloads:
                    downloadSection
                    categoryPathsSection
                case .network:
                    proxySection
                case .browser:
                    browserSection
                    sessionControlsSection
                    savedSitesSection
                case .appearance:
                    appearanceSection
                case .advanced:
                    ytdlpSection
                    diagnosticsSection
                    aboutSection
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $pasteDomain) { item in
            CookiePasteSheet(domain: item.domain)
                .environmentObject(model)
        }
        .task {
            await model.ytdlpManager.refreshStatus()
        }
        .buttonStyle(FlatHoverButtonStyle())
        .toggleStyle(.switch)
        .controlSize(.regular)
        .background(LightScrollerConfigurator())
        .alert("切换语言", isPresented: pendingLanguageAlertBinding) {
            Button("立即重启") {
                if let language = pendingLanguage {
                    settings.languagePreference = language
                    LanguageManager.apply(language)
                }
                pendingLanguage = nil
                // Defer past the alert's modal session: terminating from
                // inside the button handler can stall the quit sequence.
                DispatchQueue.main.async {
                    LanguageManager.relaunch()
                }
            }
            Button("取消", role: .cancel) {
                pendingLanguage = nil
            }
        } message: {
            Text("切换显示语言需要重新启动应用；进行中的下载会按任务状态恢复。")
        }
    }

    private var pendingLanguageAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingLanguage != nil },
            set: { if !$0 { pendingLanguage = nil } }
        )
    }

    /// Flat-card section matching the detail panel: a dark prominent
    /// title, then rows inside a hairline-outlined box. Row dividers span
    /// the padded inner width, so they stay inset from the box edges.
    private func settingsSection<Rows: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        settingsSection(title, rows: rows, footer: { EmptyView() })
    }

    private func settingsSection<Rows: View>(
        _ title: LocalizedStringKey,
        titleSuffix: Text?,
        trailingAction: AnyView?,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        settingsSection(
            title,
            titleSuffix: titleSuffix,
            trailingAction: trailingAction,
            rows: rows,
            footer: { EmptyView() }
        )
    }

    /// Section-level explanatory copy lives OUTSIDE the card as a caption
    /// footer (aligned with the card's inner text margin) instead of as a
    /// padded last row inside the card — an in-card caption inherited the
    /// last row's 12pt bottom padding plus its own 8pt top padding and
    /// read as a stray 20pt gap.
    ///
    /// `titleSuffix` keeps compact metadata attached to the section title,
    /// while `trailingAction` reserves the far edge for a section-level
    /// action without turning it into another settings row.
    private func settingsSection<Rows: View, Footer: View>(
        _ title: LocalizedStringKey,
        titleSuffix: Text? = nil,
        trailingAction: AnyView? = nil,
        @ViewBuilder rows: () -> Rows,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                if let titleSuffix {
                    titleSuffix
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let trailingAction {
                    trailingAction
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            footer()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, SettingsMetrics.footerGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 1)
    }

    private func settingRow<Control: View>(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        controlColumnWidth: CGFloat = SettingsMetrics.wideControlColumn,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: description == nil ? .center : .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.primary)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The title/description column wins width disputes so short
            // controls (toggle, single button) hand their unused column
            // space back to the text instead of wrapping captions early.
            .layoutPriority(1)

            Spacer(minLength: 20)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control()
            }
            .frame(width: controlColumnWidth)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        settingRow(
            title,
            description: description,
            controlColumnWidth: SettingsMetrics.compactControlColumn
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .pointerCursorOnHover()
        }
    }

    /// Launch-at-login toggle. Unlike a plain `toggleRow`, this one calls
    /// `SMAppService.register/unregister` and surfaces errors inline (e.g.
    /// "app not in /Applications" during development, or the user denied
    /// the system prompt so the state is `.requiresApproval`).
    private var launchAtLoginRow: some View {
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

    private func launchAtLoginDescription(for state: LaunchAtLoginManager.State) -> LocalizedStringKey {
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

    private var downloadSection: some View {
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

    private var categoryPathsSection: some View {
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

    private var notificationSection: some View {
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

    private var appearanceSection: some View {
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

    private func themeSymbol(_ scheme: AppColorScheme) -> String {
        switch scheme {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var browserSection: some View {
        settingsSection("浏览器") {
            settingRow(
                "Chrome 本地通信",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Label(
                    model.browserBridgeStatus.title,
                    systemImage: model.browserBridgeStatus == .connected
                        ? "checkmark.circle.fill" : "network"
                )
                .foregroundStyle(model.browserBridgeStatus == .connected ? AppTheme.success : Color.secondary)
            }
            if let logURL = model.takeoverLogURL {
                rowDivider
                settingRow(
                    "接管日志",
                    description: "记录浏览器接管的判定过程",
                    controlColumnWidth: SettingsMetrics.mediumControlColumn
                ) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                }
            }
        } footer: {
            if case .failed(let message) = model.browserBridgeStatus {
                Text(message)
                    .foregroundStyle(AppTheme.warning)
            }
        }
    }

    private var ytdlpSection: some View {
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

    private var generalSection: some View {
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
            toggleRow("删除记录时保留到历史（可重新下载）", isOn: $settings.archiveOnDelete)
            rowDivider
            toggleRow("App 激活时检测剪贴板中的下载链接", isOn: $settings.clipboardAutoDetect)
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
                description: "全局快捷键 ⌘⇧N 可随时呼出新建下载。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Button("重新显示…") {
                    settings.hasCompletedOnboarding = false
                }
            }
        }
    }

    private var diagnosticsSection: some View {
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

    private var aboutSection: some View {
        settingsSection("关于") {
            settingRow("版本") {
                Text(appVersionText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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

    // MARK: - Site sessions

    /// Collapsed by default: the most recently updated domains plus any
    /// auth-failed session outside that set (expired sessions must never
    /// be hidden just because they are old). Result keeps the store's
    /// domain ordering so expanding only appends rows in place.
    private var visibleSessions: [StoredSession] {
        let sessions = model.sessionStore.sessions
        guard !sessionsExpanded, sessions.count > SettingsMetrics.collapsedSessionLimit else {
            return sessions
        }
        let recentDomains = Set(
            sessions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(SettingsMetrics.collapsedSessionLimit)
                .map(\.domain)
        )
        let expiredDomains = sessions.filter {
            $0.lastAuthFailureAt != nil && !recentDomains.contains($0.domain)
        }
        let visibleDomains = recentDomains.union(expiredDomains.map(\.domain))
        return sessions.filter { visibleDomains.contains($0.domain) }
    }

    /// Computed from the actual visible set, not `count - limit`: collapsed
    /// rows may exceed the limit when expired domains are force-included.
    private var hiddenSessionCount: Int {
        max(0, model.sessionStore.sessions.count - visibleSessions.count)
    }

    private var showsSessionDisclosure: Bool {
        sessionsExpanded
            ? model.sessionStore.sessions.count > SettingsMetrics.collapsedSessionLimit
            : hiddenSessionCount > 0
    }

    /// Group 1 — the session feature itself: the master toggle and the
    /// manual paste entry point. One intent per row, title + description
    /// on the left, the single most relevant control on the right.
    private var sessionControlsSection: some View {
        settingsSection("站点会话") {
            toggleRow(
                "记住站点登录状态（Cookie）",
                description: "在支持的下载中自动复用已保存的站点登录状态。",
                isOn: $settings.rememberSiteSessions
            )
            rowDivider
            settingRow(
                "手动添加会话",
                description: "为某个站点粘贴并保存 Cookie。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Button("粘贴 Cookie…") {
                    pasteDomain = CookiePasteDomain(domain: "")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        } footer: {
            Text("Cookie 按站点隔离，不会跨站复用。")
        }
    }

    /// Group 2 — the saved objects themselves. The count is secondary text
    /// attached to the title; the destructive bulk action is a compact
    /// title-row control; per-object actions remain in ellipsis menus.
    private var savedSitesSection: some View {
        settingsSection(
            "已保存的站点",
            titleSuffix: Text("（\(model.sessionStore.sessions.count)）").monospacedDigit(),
            trailingAction: AnyView(clearSessionsButton)
        ) {
            if model.sessionStore.sessions.isEmpty {
                Text("尚未保存任何站点会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(visibleSessions.enumerated()), id: \.element.domain) { index, session in
                    if index > 0 { rowDivider }
                    sessionRow(session)
                }
                if showsSessionDisclosure {
                    rowDivider
                    sessionDisclosureRow
                }
            }
        }
    }

    /// Borderless expansion affordance at the end of the visible list.
    /// Deliberately not an outlined button so it never competes with the
    /// paste action or the ellipsis menus.
    private var sessionDisclosureRow: some View {
        Button {
            sessionsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                if sessionsExpanded {
                    Text("收起")
                } else {
                    Text("显示另外 \(hiddenSessionCount) 个站点")
                }
                Image(systemName: sessionsExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DisclosureRowButtonStyle())
        .accessibilityValue(sessionsExpanded ? Text("已展开") : Text("已折叠"))
    }

    private var clearSessionsButton: some View {
        Button {
            model.sessionStore.removeAll()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    model.sessionStore.sessions.isEmpty
                        ? Color.secondary.opacity(0.35) : AppTheme.danger
                )
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.sessionStore.sessions.isEmpty)
        .pointerCursorOnHover()
        .help("删除所有站点的已保存 Cookies")
        .accessibilityLabel("删除所有站点的已保存 Cookies")
    }

    /// One saved site: the domain with its expiry note rendered directly
    /// underneath (the note is the domain's own auxiliary state, not a
    /// peer column), a fixed-width timestamp, and a compact ellipsis menu.
    /// Rows without an expiry note stay single-line — no reserved subtitle
    /// slot; the timestamp and menu stay vertically centered regardless.
    private func sessionRow(_ session: StoredSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.domain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.domain)
                if session.lastAuthFailureAt != nil {
                    Text("可能已过期")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
                if session.scheme == nil {
                    Text("来源协议未确认，重新捕获后才会复用")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
                if model.sessionStore.domainsNeedingReauthorization.contains(session.domain) {
                    Text("未能存入钥匙串，本次运行后需重新粘贴")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Text(
                session.updatedAt,
                format: .dateTime.month().day().hour().minute()
            )
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: SettingsMetrics.sessionDateColumn, alignment: .trailing)

            sessionMenu(for: session)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-site actions behind a compact borderless ellipsis menu — two
    /// outlined buttons per row read as an admin data table, not a
    /// settings list. Identical menu labels across rows keep the right
    /// edges strictly aligned; the accessibility label names the domain so
    /// keyboard/VoiceOver users can tell the menus apart.
    private func sessionMenu(for session: StoredSession) -> some View {
        Menu {
            Button("更新 Cookie…") {
                pasteDomain = CookiePasteDomain(domain: session.domain)
            }
            Divider()
            Button("删除", role: .destructive) {
                model.sessionStore.remove(domain: session.domain)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursorOnHover()
        .accessibilityLabel("管理 \(session.domain) 的站点会话")
        .help("管理站点会话")
    }

    // MARK: - Proxy

    private var proxySection: some View {
        settingsSection("代理") {
            toggleRow("启用下载代理", isOn: $settings.proxyEnabled)
            if settings.proxyEnabled {
                rowDivider
                settingRow("类型") {
                    Picker("", selection: $settings.proxyKind) {
                        Text("HTTP").tag(ProxyKind.http)
                        Text("HTTPS").tag(ProxyKind.https)
                        Text("SOCKS5").tag(ProxyKind.socks5)
                    }
                    .labelsHidden()
                    .accessibilityLabel("代理类型")
                    .frame(width: 180)
                    .pointerCursorOnHover()
                }
                rowDivider
                settingRow("主机") {
                    TextField("", text: $settings.proxyHost, prompt: Text("如 127.0.0.1"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                rowDivider
                settingRow("端口") {
                    Stepper(value: $settings.proxyPort, in: 1...65_535) {
                        Text("\(settings.proxyPort)")
                            .monospacedDigit()
                    }
                    .pointerCursorOnHover()
                }
                rowDivider
                settingRow("用户名（可选）") {
                    TextField("", text: $settings.proxyUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                if !settings.proxyUsername.isEmpty {
                    rowDivider
                    settingRow("密码") {
                        SecureField("", text: $proxyPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    rowDivider
                    settingRow("密码存储") {
                        HStack(spacing: 8) {
                            Button(proxyPassword.isEmpty ? "删除已存密码" : "保存密码到 Keychain") {
                                saveProxyCredential()
                            }
                            .disabled(proxyPassword.isEmpty && !hasStoredProxyPassword)
                            if let message = proxyCredentialMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } footer: {
            if settings.proxyEnabled {
                if settings.proxyConfiguration == nil {
                    Text("当前主机/端口无效，代理未生效。")
                        .foregroundStyle(AppTheme.warning)
                } else {
                    Text("仅支持 HTTP/HTTPS 代理的 Basic 认证；SOCKS5 尽力而为；Digest/NTLM/Kerberos 不支持。")
                }
            }
        }
    }

    private var hasStoredProxyPassword: Bool {
        model.keychainCredentialStore.loadPassword(username: settings.proxyUsername) != nil
    }

    private func saveProxyCredential() {
        let username = settings.proxyUsername
        if proxyPassword.isEmpty {
            model.keychainCredentialStore.delete(username: username)
            proxyCredentialMessage = String(localized: "已删除 Keychain 中的密码。")
            return
        }
        do {
            try model.keychainCredentialStore.save(username: username, password: proxyPassword)
            proxyPassword = ""
            proxyCredentialMessage = String(localized: "密码已存入 Keychain。")
            model.rebuildProxyPolicy()
        } catch {
            proxyCredentialMessage = error.localizedDescription
        }
    }

    // MARK: - yt-dlp check result helpers

    private func checkResultText(_ result: YTDlpManager.CheckResult) -> String {
        switch result {
        case .upToDate(let latest):
            return String(localized: "已是最新（\(latest)）")
        case .updateAvailable(let latest):
            return String(localized: "发现新版本 \(latest)")
        case .failed(let message):
            return message
        }
    }

    private func checkResultColor(_ result: YTDlpManager.CheckResult) -> Color {
        switch result {
        case .upToDate: AppTheme.success
        case .updateAvailable: AppTheme.warning
        case .failed: AppTheme.danger
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        if panel.runModal() == .OK, let selected = panel.url {
            settings.downloadDirectory = selected.path
        }
    }

    private func chooseCategoryDirectory(for category: DownloadCategory) {
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

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build {
            return "\(version) (\(build))"
        }
        return version ?? String(localized: "未知")
    }

    private var buildDateText: String {
        Bundle.main.object(forInfoDictionaryKey: "MacIDMBuildDate") as? String
            ?? String(localized: "未知")
    }

    private var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "MacIDMBuildCommit") as? String
    }
}

/// Borderless hover treatment for the saved-sites disclosure row: no
/// outline, just a faint fill plus an accent-tinted label on hover, so the
/// row reads as a list affordance instead of a peer of the outlined
/// action buttons.
private struct DisclosureRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureRowLabel(configuration: configuration)
    }
}

private struct DisclosureRowLabel: View {
    let configuration: DisclosureRowButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovering || configuration.isPressed ? AppTheme.accent : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering || configuration.isPressed ? 0.04 : 0))
            )
            .contentShape(Rectangle())
            .pointerCursorOnHover()
            .onHover { isHovering = $0 }
    }
}
