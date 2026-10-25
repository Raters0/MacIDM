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
    /// 智能命名辅助（technical-spec §8.1 语义判断服务）的本地输入态：KEY
    /// 输入框内容（去抖自动落 Keychain）、明文显示开关，以及模型列表 /
    /// 连接测试的界面状态。
    @State private var semanticAPIKey = ""
    @State private var showSemanticKey = false
    @State private var semanticKeySaveTask: Task<Void, Never>?
    @State private var semanticModels: [String]?
    @State private var isFetchingSemanticModels = false
    @State private var isTestingSemanticConnection = false
    @State private var semanticToolMessage: String?
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
    /// Domain whose cookie was just copied; flips that row's ellipsis to a
    /// checkmark for a moment. The cookie value is only read at click time,
    /// never while the list renders.
    @State private var copiedSessionDomain: String?
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
                case .shortcuts:
                    shortcutsSection
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
                    semanticTitleSection
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
    fileprivate func settingsSection<Rows: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        settingsSection(title, rows: rows, footer: { EmptyView() })
    }

    fileprivate func settingsSection<Rows: View>(
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
    fileprivate func settingsSection<Rows: View, Footer: View>(
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

    fileprivate var rowDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 1)
    }

    fileprivate func settingRow<Control: View>(
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

    fileprivate func toggleRow(
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

    private var semanticTitleSection: some View {
        settingsSection("智能命名辅助（实验性）") {
            toggleRow("启用语义判断服务", isOn: $settings.semanticTitleEnabled)
                .onChange(of: settings.semanticTitleEnabled) { enabled in
                    // 首次启用且未填地址：按当前服务商预设填充地址与模型。
                    guard enabled,
                        settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces).isEmpty,
                        let preset = SemanticTitleProviderPreset.preset(id: settings.semanticTitleProvider)
                    else { return }
                    settings.semanticTitleEndpoint = preset.endpoint
                    settings.semanticTitleModel = preset.model
                }
            if settings.semanticTitleEnabled {
                rowDivider
                settingRow("服务商") {
                    Picker("", selection: $settings.semanticTitleProvider) {
                        ForEach(SemanticTitleProviderPreset.all) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .pointerCursorOnHover()
                    .onChange(of: settings.semanticTitleProvider) { raw in
                        // 切换服务商即按预设覆盖地址与模型。
                        if let preset = SemanticTitleProviderPreset.preset(id: raw) {
                            settings.semanticTitleEndpoint = preset.endpoint
                            settings.semanticTitleModel = preset.model
                        }
                    }
                }
                rowDivider
                settingRow("API 地址") {
                    TextField("", text: $settings.semanticTitleEndpoint, prompt: Text("https://…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }
                rowDivider
                settingRow("模型") {
                    semanticAdornedField {
                        TextField(
                            "", text: $settings.semanticTitleModel,
                            prompt: Text("模型 id（可点右侧图标获取列表）")
                        )
                    } adornment: {
                        modelListMenu
                    }
                }
                rowDivider
                settingRow("API KEY") {
                    semanticAdornedField {
                        Group {
                            if showSemanticKey {
                                TextField("", text: $semanticAPIKey)
                            } else {
                                SecureField("", text: $semanticAPIKey)
                            }
                        }
                    } adornment: {
                        Button {
                            showSemanticKey.toggle()
                        } label: {
                            Image(systemName: showSemanticKey ? "eye.slash" : "eye")
                                .font(.system(size: 11, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursorOnHover()
                        .accessibilityLabel(showSemanticKey ? "隐藏 API KEY" : "显示 API KEY")
                    }
                }
                rowDivider
                settingRow("连接测试") {
                    HStack(spacing: 8) {
                        Button("测试连接") {
                            testSemanticConnection()
                        }
                        .disabled(isTestingSemanticConnection)
                        if isTestingSemanticConnection {
                            ProgressView().controlSize(.small)
                        }
                        if let semanticToolMessage {
                            Text(semanticToolMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        } footer: {
            if settings.semanticTitleEnabled {
                if settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("请选择服务商或填写 API 地址。")
                        .foregroundStyle(AppTheme.warning)
                } else if settings.semanticTitleModel.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("请填写模型 id。")
                        .foregroundStyle(AppTheme.warning)
                } else if !hasStoredSemanticKey {
                    Text("在 API KEY 输入框粘贴 KEY（自动保存到本机钥匙串）后生效。")
                        .foregroundStyle(AppTheme.warning)
                } else {
                    Text("确认窗口先按常规规则给出文件名，仲裁结果仅在高置信时覆盖为建议名，用户编辑永远优先。上送内容仅限候选标题字符串与页面标题，不含媒体 URL、Cookie 或其他凭据。")
                }
            } else {
                Text(
                    "开启后选择服务商（自动填充地址与模型）并粘贴 API KEY（只存本机钥匙串，可下拉获取模型列表、测试连接）并粘贴 API KEY（只存本机钥匙串，输入框内的眼睛图标可查看）。关闭或不可用时完全使用本地命名规则。"
                )
            }
        }
        .onAppear {
            if semanticAPIKey.isEmpty,
                let stored = model.semanticTitleKeychainStore
                    .loadPassword(username: SemanticTitleService.keychainAccount)
            {
                semanticAPIKey = stored
            }
        }
        .onChange(of: semanticAPIKey) { newValue in
            // 输入即存（去抖 300ms）：清空即删除，与常见 Agent 产品的 KEY 填写交互一致。
            semanticKeySaveTask?.cancel()
            let keychain = model.semanticTitleKeychainStore
            semanticKeySaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    keychain.delete(username: SemanticTitleService.keychainAccount)
                } else {
                    try? keychain.save(
                        username: SemanticTitleService.keychainAccount,
                        password: trimmed
                    )
                }
            }
        }
    }

    private var hasStoredSemanticKey: Bool {
        model.semanticTitleKeychainStore
            .loadPassword(username: SemanticTitleService.keychainAccount) != nil
    }

    /// 自绘「输入框 + 尾部图标」容器：图标占位是实底（与输入框同底色），
    /// 输入文字到图标前截止，不会从图标下方穿过（透明 overlay 的老问题）。
    /// 视觉对齐系统 `.roundedBorder`：text 背景色 + 分隔线描边。
    private func semanticAdornedField<
        Field: View,
        Adornment: View
    >(
        @ViewBuilder field: () -> Field,
        @ViewBuilder adornment: () -> Adornment
    ) -> some View {
        HStack(spacing: 0) {
            field()
                .textFieldStyle(.plain)
                .padding(.leading, 7)
            adornment()
                .padding(.horizontal, 6)
        }
        .frame(height: 23)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// 「模型」字段内的下拉：首次点开是「获取模型列表」，拉取后变成候选菜单。
    private var modelListMenu: some View {
        Menu {
            if isFetchingSemanticModels {
                Text("正在获取模型列表…")
            } else if let models = semanticModels {
                ForEach(models, id: \.self) { model in
                    Button(model) {
                        settings.semanticTitleModel = model
                    }
                }
                Divider()
                Button("重新获取") {
                    fetchSemanticModels()
                }
            } else {
                Button("获取模型列表") {
                    fetchSemanticModels()
                }
            }
        } label: {
            if isFetchingSemanticModels {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursorOnHover()
    }

    /// 用设置页当前输入值（含未落钥匙串的 KEY）组装请求配置。
    private func liveSemanticConfig() -> SemanticTitleConfig? {
        let endpoint = settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces)
        let apiKey =
            semanticAPIKey.isEmpty
            ? (model.semanticTitleKeychainStore
                .loadPassword(username: SemanticTitleService.keychainAccount) ?? "")
            : semanticAPIKey
        guard !endpoint.isEmpty, !apiKey.isEmpty else { return nil }
        return SemanticTitleConfig(
            format: SemanticTitleFormat(providerID: settings.semanticTitleProvider),
            endpoint: endpoint,
            model: settings.semanticTitleModel.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey
        )
    }

    private func fetchSemanticModels() {
        guard let config = liveSemanticConfig() else {
            semanticToolMessage = "请先填写 API 地址与 KEY"
            return
        }
        isFetchingSemanticModels = true
        Task { @MainActor in
            let result = await model.semanticTitleService.fetchModelList(config: config)
            isFetchingSemanticModels = false
            switch result {
            case .success(let models):
                semanticModels = models
                semanticToolMessage = nil
            case .failure(let detail):
                semanticToolMessage = "获取模型列表失败：\(detail)"
            }
        }
    }

    private func testSemanticConnection() {
        guard let config = liveSemanticConfig() else {
            semanticToolMessage = "请先填写 API 地址与 KEY"
            return
        }
        isTestingSemanticConnection = true
        semanticToolMessage = nil
        Task { @MainActor in
            let result = await model.semanticTitleService.testConnection(config: config)
            isTestingSemanticConnection = false
            switch result {
            case .success(let detail):
                semanticToolMessage = "✓ " + detail
            case .failure(let detail):
                semanticToolMessage = "✗ " + detail
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
            toggleRow("删除后保留历史记录", isOn: $settings.archiveOnDelete)
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
    private var shortcutsSection: some View {
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

    private var shortcutRowDescription: LocalizedStringKey {
        if let error = model.globalHotKeyError {
            return LocalizedStringKey(error)
        }
        if settings.globalHotKeyCombo == nil {
            return "未设置组合键，该操作没有全局快捷键。"
        }
        return "在任意应用中按下组合键即可弹出新建下载窗口；剪贴板里是链接时自动填入。点输入框后按组合键录制，Esc 取消。"
    }

    private var onboardingRowDescription: LocalizedStringKey {
        if !settings.globalHotKeyEnabled {
            return "全局快捷键已关闭。"
        }
        if let combo = settings.globalHotKeyCombo {
            return "全局快捷键 \(combo.displayString) 可随时呼出新建下载。"
        }
        return "未设置全局快捷键，可在「快捷键」页录制。"
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
    private var updateCheckRow: some View {
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

    private func updateStatusText(_ state: AppUpdateEngine.State) -> String? {
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

    private func updateStatusColor(_ state: AppUpdateEngine.State) -> Color {
        switch state {
        case .idle: Color.secondary
        case .upToDate: AppTheme.success
        case .updateAvailable: AppTheme.warning
        case .failed: AppTheme.danger
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
            Button("复制 Cookie") {
                copySessionCookie(for: session)
            }
            Button("更新 Cookie…") {
                pasteDomain = CookiePasteDomain(domain: session.domain)
            }
            Divider()
            Button("删除", role: .destructive) {
                model.sessionStore.remove(domain: session.domain)
            }
        } label: {
            Image(systemName: copiedSessionDomain == session.domain ? "checkmark" : "ellipsis")
                .foregroundStyle(
                    copiedSessionDomain == session.domain ? AppTheme.success : Color.primary
                )
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

    /// Copies the stored cookie header back to the clipboard. The value is
    /// resolved from the secret store when the menu item is clicked; a
    /// session whose credential is gone (Keychain refused or wiped) copies
    /// nothing rather than pasting stale data.
    private func copySessionCookie(for session: StoredSession) {
        guard let cookie = model.sessionStore.cookieHeader(for: session),
            !cookie.isEmpty
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cookie, forType: .string)
        copiedSessionDomain = session.domain
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSessionDomain == session.domain {
                copiedSessionDomain = nil
            }
        }
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
        let version = AppBuildInfo.marketingVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        // Sparkle needs CFBundleVersion to carry the marketing version, so
        // the two are usually identical and printing both would repeat.
        if let version, let build, build != version {
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
