import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifiable wrapper so the cookie-paste sheet can be driven by an
/// optional domain string.
struct CookiePasteDomain: Identifiable {
    let domain: String
    var id: String { domain }
}

struct MainWindowView: View {
    private enum ColumnLayout {
        static let sidebarWidth: CGFloat = 232
        /// The sidebar column is user-resizable between these bounds: the
        /// minimum keeps filter labels and counts readable, the maximum
        /// stops it from crowding out the task list.
        static let sidebarMinimumWidth: CGFloat = 200
        static let sidebarMaximumWidth: CGFloat = 340
        static let listMinimumWidth: CGFloat = 540
        static let listIdealWidth: CGFloat = 780
        /// Keeps the three completed-task actions on one line — their labels
        /// scale down slightly at this width — without letting the detail
        /// column dominate a wide restored window.
        static let detailMinimumWidth: CGFloat = 320
        static let detailIdealWidth: CGFloat = 400
        static let detailMaximumWidth: CGFloat = 520
        static let dividerWidth: CGFloat = 1

        static func resolvedSidebarWidth(_ proposedWidth: CGFloat) -> CGFloat {
            let finiteProposal = proposedWidth.isFinite ? proposedWidth : sidebarWidth
            return min(max(finiteProposal, sidebarMinimumWidth), sidebarMaximumWidth)
        }

        static func resolvedDetailWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat)
            -> CGFloat
        {
            let finiteProposal = proposedWidth.isFinite ? proposedWidth : detailIdealWidth
            let availableMaximum = max(
                detailMinimumWidth,
                availableWidth - listMinimumWidth - dividerWidth
            )
            return min(
                max(finiteProposal, detailMinimumWidth),
                min(detailMaximumWidth, availableMaximum)
            )
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var activeSheet: ActiveSheet?
    @State private var isConfirmingRemoval = false
    @State private var pendingRemovalIDs: Set<UUID> = []
    /// 「彻底删除」的二次确认：文件不可恢复，所以是唯一需要二次确认的
    /// 常规删除选项。
    @State private var pendingPermanentFileDeletion: Set<UUID> = []
    @AppStorage("mainDetailColumnWidthV1") private var storedDetailColumnWidth = Double(
        ColumnLayout.detailIdealWidth
    )
    @AppStorage("mainSidebarWidthV1") private var storedSidebarWidth = Double(
        ColumnLayout.sidebarWidth
    )
    @AppStorage("mainSidebarVisibleV1") private var isSidebarVisible = true
    @AppStorage("mainDetailColumnVisibleV1") private var isDetailColumnVisible = true
    @GestureState private var detailDividerTranslation: CGFloat = 0
    @GestureState private var sidebarDividerTranslation: CGFloat = 0

    // New-download confirmations always open in standalone windows (see
    // DownloadDraftWindowManager), so the main window only keeps truly
    // app-level sheets. The task detail lives in the third split column.
    private enum ActiveSheet: Identifiable, Equatable {
        case onboarding

        var id: String {
            switch self {
            case .onboarding: "onboarding"
            }
        }
    }

    /// The three hand-rolled columns behind one flat, hairline-divided
    /// surface. NavigationSplitView would be the natural structure here,
    /// but on macOS 26 its sidebar column renders as a floating Liquid
    /// Glass panel inset from the window edges, and no public API flattens
    /// it. Extracted from `body` so the compiler type-checks the layout
    /// and the modifier chain as separate expressions.
    private var windowColumns: some View {
        VStack(spacing: 0) {
            // Titlebar separator: macOS does not reliably keep the system
            // titlebar separator visible during window resize. Draw our own
            // hairline at the top of the content area instead.
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)

            HStack(spacing: 0) {
                if isSidebarVisible {
                    VStack(spacing: 0) {
                        // No extra top hairline here: the full-width hairline
                        // above this HStack already crosses the sidebar, and
                        // stacking two made the line look thicker than the
                        // rest of the window's rules.
                        SidebarView()
                    }
                    // Live drag width: stored + translation (the divider is
                    // on the sidebar's right edge, so dragging right widens),
                    // rounded to whole points for stable text layout.
                    .frame(
                        width: ColumnLayout.resolvedSidebarWidth(
                            CGFloat(storedSidebarWidth) + sidebarDividerTranslation
                        ).rounded()
                    )

                    sidebarDivider
                }

                GeometryReader { geometry in
                    let availableWidth = geometry.size.width
                    // Rounded to whole points: fractional live widths make
                    // text re-wrap oscillate between adjacent breakpoints
                    // while dragging, which reads as jitter.
                    let detailWidth = ColumnLayout.resolvedDetailWidth(
                        CGFloat(storedDetailColumnWidth) - detailDividerTranslation,
                        availableWidth: availableWidth
                    ).rounded()

                    HStack(spacing: 0) {
                        downloadListColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        if isDetailColumnVisible {
                            detailDivider(availableWidth: availableWidth)

                            DetailColumnView()
                                .frame(width: detailWidth)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        windowBehaviors(windowColumns)
            .appWindowSurface()
    }

    /// Sheets, alerts, and window-level event wiring. Kept behind a function
    /// boundary so the compiler type-checks the layout, the toolbar chain,
    /// and this behavior chain as separate expressions.
    private func windowBehaviors(_ content: some View) -> some View {
        content
            .onDrop(
                of: [UTType.url.identifier, UTType.plainText.identifier],
                isTargeted: nil,
                perform: model.importDroppedItems
            )
            .background(LightScrollerConfigurator())
            // Flat titlebar controls (leading: actions, trailing: search +
            // detail toggle) installed via NSTitlebarAccessoryViewController.
            // See TitlebarAccessoryToolbar for why `.toolbar` is not used.
            .background(
                TitlebarAccessoryToolbar(
                    model: model,
                    searchText: $model.searchText,
                    isSidebarVisible: $isSidebarVisible,
                    isDetailColumnVisible: $isDetailColumnVisible,
                    canResume: { canResumeSelection },
                    canPause: { canPauseSelection },
                    canCancel: { canCancelSelection },
                    canRemove: { canRemoveSelection },
                    onAdd: { model.presentNewDownload(draft: nil) },
                    onResume: {
                        for id in model.selectedTaskIDs { model.resume(id) }
                    },
                    onPause: {
                        for id in model.selectedTaskIDs { model.pause(id) }
                    },
                    onCancel: {
                        for id in model.selectedTaskIDs { model.cancel(id) }
                    },
                    onRequestRemoval: { requestRemoval(ids: model.selectedTaskIDs) },
                    onPresentSettings: { SettingsWindowPresenter.shared.show(model: model) },
                    isColumnVisible: { id in
                        !model.settings.hiddenTableColumns.contains(id)
                    },
                    toggleColumn: { id in
                        var hidden = model.settings.hiddenTableColumns
                        if let index = hidden.firstIndex(of: id) {
                            hidden.remove(at: index)
                        } else {
                            guard id != "filename" else { return }
                            hidden.append(id)
                        }
                        model.settings.hiddenTableColumns = hidden
                    }
                )
            )
            .sheet(
                item: $activeSheet
            ) { sheet in
                switch sheet {
                case .onboarding:
                    OnboardingView()
                        .environmentObject(model)
                }
            }
            .alert(item: $model.presentedError) { error in
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .alert(
                item: Binding(
                    get: { model.ytdlpManager.alert },
                    set: { model.ytdlpManager.alert = $0 }
                )
            ) { alert in
                switch alert {
                case .installRequired:
                    Alert(
                        title: Text("需要 yt-dlp 组件"),
                        message: Text("YouTube 视频下载依赖 yt-dlp。MacIDM 可以自动下载官方版本并安装到应用目录，或你也可以手动执行 brew install yt-dlp。"),
                        primaryButton: .default(Text("自动安装")) {
                            Task { await model.ytdlpManager.install() }
                        },
                        secondaryButton: .cancel(Text("稍后"))
                    )
                case .updateRecommended(_, let reason):
                    networkOrIntegrityAlert(reason: reason)
                case .installFailed(let message):
                    Alert(
                        title: Text("安装失败"),
                        message: Text("\(message)\n\n你也可以手动执行：\nbrew install yt-dlp"),
                        dismissButton: .default(Text("好"))
                    )
                case .updateFailed(let message):
                    Alert(
                        title: Text("更新失败"),
                        message: Text("\(message)\n\n你也可以稍后在设置 → yt-dlp 中重试，或手动下载官方版本。"),
                        dismissButton: .default(Text("好"))
                    )
                case .updateSucceeded(let version):
                    Alert(
                        title: Text("更新成功"),
                        message: Text("yt-dlp 已更新到版本 \(version)。你可以重新尝试下载。"),
                        dismissButton: .default(Text("好"))
                    )
                }
            }
            .sheet(
                isPresented: Binding(
                    get: {
                        model.ytdlpManager.installProgress != nil
                            && !model.ytdlpManager.isInstallProgressHidden
                    },
                    set: { shown in
                        if !shown { model.ytdlpManager.isInstallProgressHidden = true }
                    }
                )
            ) {
                YTDlpInstallProgressSheet(model: model)
            }
            .confirmationDialog(
                "删除选中的 \(pendingRemovalIDs.count) 个任务？",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("仅删除记录", role: .destructive) {
                    for id in pendingRemovalIDs { model.remove(id) }
                    pendingRemovalIDs.removeAll()
                }
                Button("移到废纸篓", role: .destructive) {
                    for id in pendingRemovalIDs {
                        model.remove(id, fileRemoval: .moveToTrash)
                    }
                    pendingRemovalIDs.removeAll()
                }
                Button("彻底删除", role: .destructive) {
                    for id in pendingRemovalIDs {
                        model.remove(id, fileRemoval: .deletePermanently)
                    }
                    pendingRemovalIDs.removeAll()
                }
                Button("取消", role: .cancel) {
                    pendingRemovalIDs.removeAll()
                }
            }
            .confirmationDialog(
                "彻底删除 \(pendingPermanentFileDeletion.count) 个文件？",
                isPresented: Binding(
                    get: { !pendingPermanentFileDeletion.isEmpty },
                    set: { if !$0 { pendingPermanentFileDeletion.removeAll() } }
                ),
                titleVisibility: .visible
            ) {
                Button("彻底删除", role: .destructive) {
                    for id in pendingPermanentFileDeletion {
                        model.remove(id, fileRemoval: .deletePermanently)
                    }
                    pendingPermanentFileDeletion.removeAll()
                }
                Button("取消", role: .cancel) {
                    pendingPermanentFileDeletion.removeAll()
                }
            } message: {
                Text("文件将被立即删除，不可恢复。")
            }
            .onAppear {
                // Startup layout diagnostics: the sidebar has once rendered
                // as a blank column right after launch and recovered by
                // itself; without a persisted snapshot of the resolved
                // layout inputs at first frame there is no evidence to
                // correlate a recurrence against.
                AppLogger.shared.info(
                    .ui,
                    "main window first layout: sidebarVisible=\(isSidebarVisible)"
                        + " sidebarWidth=\(storedSidebarWidth)"
                        + " detailVisible=\(isDetailColumnVisible)"
                        + " detailWidth=\(storedDetailColumnWidth)"
                        + " filter=\(String(describing: model.sidebarFilter))"
                )
                if !model.settings.hasCompletedOnboarding, activeSheet == nil {
                    activeSheet = .onboarding
                }
            }
            .onChange(of: model.settings.hasCompletedOnboarding) { completed in
                if !completed {
                    activeSheet = .onboarding
                }
            }
            .onChange(of: model.isDetailColumnRequested) { requested in
                // revealDetailColumn() raises the flag for one runloop pass
                // (⌘I / view details); only the false→true edge carries meaning.
                if requested {
                    isDetailColumnVisible = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macIDMCreateDownload)) { note in
                // Drag-and-drop and clipboard detection post plain URLs; every
                // confirmation opens its own window, never a main-window sheet.
                if let draft = note.object as? DownloadDraft {
                    model.presentNewDownload(draft: draft)
                } else if let url = note.object as? String, let draft = DownloadDraft(urlString: url) {
                    model.presentNewDownload(draft: draft)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macIDMRequestRemoval)) { _ in
                requestRemoval(ids: model.selectedTaskIDs)
            }
            .onReceive(NotificationCenter.default.publisher(for: .macIDMRequestSettings)) { _ in
                SettingsWindowPresenter.shared.show(model: model)
            }
    }

    /// The native HSplitView chooses a new allocation from its ideal sizes on
    /// each window reconstruction and does not create a stable autosave key in
    /// this app. Keep the detail width explicit instead: 400 pt on first use,
    /// live while dragging, and persisted only when the gesture completes.
    private func detailDivider(availableWidth: CGFloat) -> some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: ColumnLayout.dividerWidth)
            // Preserve a one-pixel visual divider while providing a forgiving
            // drag target on both sides of it. The gesture tracks in the
            // GLOBAL coordinate space: in .local space the divider itself
            // moves with the drag, so the reported translation got
            // compensated by the view's own movement (width changed at half
            // the cursor speed with a stuttering catch-up loop).
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($detailDividerTranslation) { value, state, _ in
                                state = value.translation.width
                            }
                            .onEnded { value in
                                let visibleWidth = ColumnLayout.resolvedDetailWidth(
                                    CGFloat(storedDetailColumnWidth),
                                    availableWidth: availableWidth
                                )
                                storedDetailColumnWidth = Double(
                                    ColumnLayout.resolvedDetailWidth(
                                        visibleWidth - value.translation.width,
                                        availableWidth: availableWidth
                                    ))
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            NSCursor.resizeLeftRight.set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
            }
    }

    /// Resizable right edge of the filter sidebar: same hairline look and
    /// forgiving hit target as the detail divider, mirrored drag sign (the
    /// divider sits on the sidebar's right, so positive translation widens).
    /// Clamped to [sidebarMinimumWidth, sidebarMaximumWidth]. Global
    /// coordinate space for the same self-movement reason as the detail
    /// divider.
    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: ColumnLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($sidebarDividerTranslation) { value, state, _ in
                                state = value.translation.width
                            }
                            .onEnded { value in
                                storedSidebarWidth = Double(
                                    ColumnLayout.resolvedSidebarWidth(
                                        CGFloat(storedSidebarWidth) + value.translation.width
                                    ))
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            NSCursor.resizeLeftRight.set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
            }
    }

    /// Value-compared structural token for the task table (see
    /// `TaskTableView`): re-computed on every parent render, but the table
    /// leaf only re-renders when this actually changes (Equatable). Progress,
    /// speed, and status never appear here — they flow through the per-row
    /// live models.
    private var taskTableAppearance: TaskTableAppearance {
        TaskTableAppearance(
            rows: model.filteredTasks.map { .init(id: $0.id, filename: $0.filename) },
            hiddenColumns: model.settings.hiddenTableColumns,
            redactFilenames: model.settings.redactFilenames,
            tasksEmpty: model.tasks.isEmpty
        )
    }

    private var downloadListColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskTableView(
                model: model,
                synchronizer: model.tableSynchronizer,
                appearance: taskTableAppearance,
                requestPermanentFileDeletion: { requestPermanentFileDeletion(ids: $0) }
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.filteredTasks.map(\.id)) { ids in
                // Selections pointing at rows filtered out of the current
                // view (sidebar switch, search) are pruned at the model
                // level; `selectTasks` pushes the pruned set straight into
                // the table's binding.
                let stale = model.selectedTaskIDs.subtracting(ids)
                guard !stale.isEmpty else { return }
                model.selectTasks(model.selectedTaskIDs.subtracting(stale))
            }
            StatusBarView()
        }
        .alert(
            item: Binding(
                get: { model.sessionAlert },
                set: { newValue in
                    if newValue == nil {
                        model.handleSessionAlertBindingDismissal()
                    }
                }
            )
        ) { alert in
            sessionGuidanceAlert(alert)
        }
        .sheet(
            isPresented: Binding(
                get: { model.cookiePasteDomain != nil },
                set: { shown in
                    if !shown { model.requestDismissCookiePasteSheet() }
                }
            ),
            onDismiss: {
                model.cookiePasteSheetDidDismiss()
            }
        ) {
            CookiePasteSheet(
                domain: model.cookiePasteDomain ?? "",
                retryTaskID: model.cookiePasteRetryTaskID
            )
            .environmentObject(model)
        }
    }

    private func requestRemoval(ids: Set<UUID>? = nil) {
        let targetIDs = ids ?? model.selectedTaskIDs
        guard !targetIDs.isEmpty else { return }
        // Running tasks are removable too: confirming stops them first, so a
        // mixed selection deletes everything in one step. Terminal CLI records
        // are removable as well — the App deletes the mirror row together with
        // the authoritative CLI record (technical-spec §3.1.6).
        let targetTasks = model.tasks.filter {
            targetIDs.contains($0.id) && $0.isRemovableFromApp
        }
        guard !targetTasks.isEmpty else { return }
        // 极简三选弹窗：说明文字已砍掉，选项本身就是语义。
        pendingRemovalIDs = Set(targetTasks.map(\.id))
        isConfirmingRemoval = true
    }

    /// 「彻底删除」的二次确认入口。
    private func requestPermanentFileDeletion(ids: Set<UUID>) {
        let targetTasks = model.tasks.filter {
            ids.contains($0.id) && $0.isRemovableFromApp
        }
        guard !targetTasks.isEmpty else { return }
        pendingPermanentFileDeletion = Set(targetTasks.map(\.id))
    }

    private func updateReasonText(_ reason: YTDlpManager.UpdateReason) -> String {
        switch reason {
        case .youtubeProtocolChange:
            String(
                localized:
                    "YouTube 可能更新了播放协议，当前版本的 yt-dlp 无法解析。更新 yt-dlp 通常可以解决此问题。"
            )
        case .versionOutdated:
            String(localized: "yt-dlp 版本较旧，建议更新以支持最新的 YouTube 协议。")
        case .genericFailure:
            String(localized: "YouTube 下载失败，更新 yt-dlp 可能有助于解决此问题。")
        case .networkFailed:
            String(localized: "无法连接 GitHub 检查 yt-dlp 版本。")
        case .integrityMismatch:
            String(localized: "yt-dlp 文件可能已损坏。")
        }
    }

    /// Builds the appropriate alert for `.networkFailed` and
    /// `.integrityMismatch` update reasons, falling through to the
    /// generic update-recommended dialog for all other cases.
    private func networkOrIntegrityAlert(
        reason: YTDlpManager.UpdateReason
    ) -> Alert {
        switch reason {
        case .networkFailed:
            let hasProxy = model.settings.proxyEnabled
            let lines = [
                String(localized: "无法连接 GitHub 检查 yt-dlp 版本。"),
                hasProxy
                    ? String(
                        localized: "已尝试通过你配置的代理连接，仍然失败——请检查代理服务本身是否可用。"
                    )
                    : String(
                        localized: "请检查网络连通性；若访问 GitHub 需要代理，请先在设置中配置代理。"
                    ),
                "",
                String(localized: "你也可以手动下载最新版："),
                "1. curl -L -o ~/Downloads/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos",
                "2. chmod +x ~/Downloads/yt-dlp",
                "3. mv ~/Downloads/yt-dlp ~/Library/Application\\ Support/MacIDM/yt-dlp",
            ]
            return Alert(
                title: Text("无法检查 yt-dlp 版本"),
                message: Text(lines.joined(separator: "\n")),
                primaryButton: .default(Text("直连重试")) {
                    Task { await model.ytdlpManager.checkForUpdatesDirectConnection() }
                },
                secondaryButton: .default(Text("按当前配置重试")) {
                    Task { await model.ytdlpManager.checkForUpdates() }
                }
            )
        case .integrityMismatch(let local, let expected):
            let localShort = String(local.prefix(16))
            let expectedShort = String(expected.prefix(16))
            let msg =
                String(localized: "yt-dlp 版本已是最新，但文件 SHA-256 不匹配：")
                + "\n" + String(localized: "本地: \(localShort)…")
                + "\n" + String(localized: "预期: \(expectedShort)…")
                + "\n\n" + String(localized: "建议重新下载以修复完整性。")
            return Alert(
                title: Text("yt-dlp 文件可能已损坏"),
                message: Text(msg),
                primaryButton: .default(Text("重新下载")) {
                    Task { await model.ytdlpManager.update() }
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        default:
            return Alert(
                title: Text("建议更新 yt-dlp"),
                message: Text(updateReasonText(reason)),
                primaryButton: .default(Text("一键更新")) {
                    Task { await model.ytdlpManager.update() }
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        }
    }

    /// Guidance alert for authentication-class failures: explains the two
    /// ways to provide a site session (Chrome extension capture is
    /// recommended; manual cookie paste is the fallback).
    private func sessionGuidanceAlert(_ alert: AppModel.SessionAlert) -> Alert {
        let title =
            alert.expired
            ? String(localized: "站点登录状态可能已过期")
            : String(localized: "需要登录该站点")
        let message = [
            String(localized: "站点 \(alert.domain) 的下载因登录态缺失或失效被拒绝。"),
            "",
            String(localized: "解决方法："),
            String(
                localized: "1. 推荐：在 Chrome 中登录该站点，通过 MacIDM 插件重新提交下载（自动携带会话）；"
            ),
            String(localized: "2. 手动：从浏览器开发者工具复制 Cookie 后粘贴到 MacIDM。"),
            "",
            String(localized: "如需删除该站点已存会话，请到设置 → 站点会话中操作。"),
        ].joined(separator: "\n")
        return Alert(
            title: Text(title),
            message: Text(message),
            primaryButton: .default(Text("粘贴 Cookie")) {
                model.requestManualCookiePaste(domain: alert.domain, retryTaskID: alert.taskID)
            },
            secondaryButton: .cancel(Text("稍后"))
        )
    }

    private var selection: [AppTask] {
        model.selectedTasks
    }

    // Multi-selection operations use "at least one applicable" semantics:
    // a mixed selection (e.g. one running task among completed ones) keeps
    // the buttons enabled and the action applies to the applicable subset,
    // instead of silently disabling every control.
    private var canResumeSelection: Bool {
        selection.contains {
            !$0.isCLIManaged
                && [.paused, .failed, .needsRestart, .storageError, .cancelled].contains(
                    $0.status)
        }
    }

    private var canPauseSelection: Bool {
        selection.contains {
            !$0.isCLIManaged && [.queued, .probing, .running, .verifying].contains($0.status)
        }
    }

    private var canCancelSelection: Bool {
        selection.contains {
            !$0.isCLIManaged
                && [
                    .queued, .probing, .running, .pausing, .verifying, .paused, .failed,
                    .needsRestart, .takeoverPending, .takeoverConflict, .filenameConflict,
                ].contains($0.status)
        }
    }

    private var canRemoveSelection: Bool {
        selection.contains { !$0.isCLIManaged }
    }
}
