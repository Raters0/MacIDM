import AppKit
import IDMEngine
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) var activeColorScheme
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// The site session list subscribes separately: the "Saved sites"
    /// section must refresh in place after deleting or pasting sessions;
    /// observing only the model would miss change notifications from the
    /// nested SessionStore.
    @ObservedObject var sessionStore: SessionStore
    @State var proxyPassword = ""
    @State var proxyCredentialMessage: String?
    /// 智能命名辅助（technical-spec §8.1 语义判断服务）的本地输入态：KEY
    /// 输入框内容（去抖自动落 Keychain）、明文显示开关，以及模型列表 /
    /// 连接测试的界面状态。
    @State var semanticAPIKey = ""
    @State var showSemanticKey = false
    @State var semanticKeySaveTask: Task<Void, Never>?
    @State var semanticModels: [String]?
    @State var isFetchingSemanticModels = false
    @State var isTestingSemanticConnection = false
    @State var semanticToolMessage: String?
    /// Local sheet state for cookie pasting; kept separate from the
    /// model-level `cookiePasteDomain` (used by the main window's failure
    /// alert) so the two presentation anchors never fight.
    @State var pasteDomain: CookiePasteDomain?
    /// Language picked in the menu but not yet applied; the restart
    /// confirmation gate sits between the Picker and `languagePreference`.
    @State var pendingLanguage: AppLanguage?
    /// Error message from the last launch-at-login toggle attempt; nil on
    /// success. Surfaced inline under the toggle so the user knows why it
    /// did not stick (e.g. app not in /Applications during development).
    @State var launchAtLoginError: String?
    /// Site-session list starts collapsed to the most recent domains;
    /// the in-card toggle expands it to the full list.
    @State var sessionsExpanded = false
    /// Domain whose cookie was just copied; flips that row's ellipsis to a
    /// checkmark for a moment. The cookie value is only read at click time,
    /// never while the list renders.
    @State var copiedSessionDomain: String?
    @State var selectedPage: SettingsPage = .general

    /// Control-column tiers. A single 300pt column for every control left
    /// large transparent gaps next to toggles and short menus while
    /// squeezing the title/description column into early wraps.
    enum SettingsMetrics {
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
    func settingsSection<Rows: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        settingsSection(title, rows: rows, footer: { EmptyView() })
    }

    func settingsSection<Rows: View>(
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
    func settingsSection<Rows: View, Footer: View>(
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

    var rowDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 1)
    }

    func settingRow<Control: View>(
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

    func toggleRow(
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
}
