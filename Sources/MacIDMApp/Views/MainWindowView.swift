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
    @State private var isConfirmingPermanentRemoval = false
    @State private var pendingPermanentRemovalIDs: Set<UUID> = []
    @State private var isConfirmingClearHistory = false
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
                Button("删除记录", role: .destructive) {
                    for id in pendingRemovalIDs { model.remove(id) }
                    pendingRemovalIDs.removeAll()
                }
                if model.hasRemovableFiles(pendingRemovalIDs) {
                    Button("删除记录和文件", role: .destructive) {
                        for id in pendingRemovalIDs { model.remove(id, deletingFile: true) }
                        pendingRemovalIDs.removeAll()
                    }
                }
                Button("取消", role: .cancel) {
                    pendingRemovalIDs.removeAll()
                }
            } message: {
                Text(removalDialogMessage)
            }
            .confirmationDialog(
                "清除全部已删除的归档记录？",
                isPresented: $isConfirmingClearHistory,
                titleVisibility: .visible
            ) {
                Button("永久清除", role: .destructive) {
                    model.clearHistory()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅清除已删除的归档记录，此操作不可撤销；仍在列表中的任务不受影响。不会删除本地文件。")
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
                        + " filter=\(model.sidebarFilter)"
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
            .onReceive(NotificationCenter.default.publisher(for: .macIDMRequestClearHistory)) { _ in
                isConfirmingClearHistory = true
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
                requestRemoval: { requestRemoval(ids: $0) },
                requestPermanentRemoval: { requestPermanentRemoval(ids: $0) }
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
        .confirmationDialog(
            "永久删除选中的 \(pendingPermanentRemovalIDs.count) 条历史记录？",
            isPresented: $isConfirmingPermanentRemoval,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                for id in pendingPermanentRemovalIDs { model.permanentlyRemove(id) }
                pendingPermanentRemovalIDs.removeAll()
            }
            Button("取消", role: .cancel) {
                pendingPermanentRemovalIDs.removeAll()
            }
        } message: {
            Text("历史记录将被永久删除，不可恢复。不会删除本地文件。")
        }
    }

    private func requestRemoval(ids: Set<UUID>? = nil) {
        let targetIDs = ids ?? model.selectedTaskIDs
        guard !targetIDs.isEmpty else { return }
        // Running tasks are removable too: confirming stops them first, so a
        // mixed selection deletes everything in one step.
        let targetTasks = model.tasks.filter {
            targetIDs.contains($0.id) && !$0.isCLIManaged
        }
        guard !targetTasks.isEmpty else { return }
        pendingRemovalIDs = Set(targetTasks.map(\.id))
        isConfirmingRemoval = true
    }

    private func requestPermanentRemoval(ids: Set<UUID>) {
        let targetTasks = model.tasks.filter {
            ids.contains($0.id) && $0.isArchived && !$0.isCLIManaged
        }
        guard !targetTasks.isEmpty else { return }
        pendingPermanentRemovalIDs = Set(targetTasks.map(\.id))
        isConfirmingPermanentRemoval = true
    }

    /// Whether the pending removal includes tasks that are still running;
    /// the confirmation message then explains they will be stopped first.
    private var pendingRemovalIncludesActive: Bool {
        model.tasks.contains { pendingRemovalIDs.contains($0.id) && $0.status.isActive }
    }

    private var removalDialogMessage: String {
        let archiveText =
            model.settings.archiveOnDelete
            ? String(localized: "记录将归入历史，可随时从历史中重新下载。")
            : String(localized: "记录将被永久删除，不可恢复。")
        if pendingRemovalIncludesActive {
            return String(localized: "正在下载的任务会先停止，然后删除。") + archiveText
        }
        return archiveText
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

/// Live install/update feedback for yt-dlp: stage, a real progress bar and
/// transferred bytes replace the old single "Processing" alert.
private struct YTDlpInstallProgressSheet: View {
    @ObservedObject var model: AppModel

    private var progress: YTDlpManager.InstallProgress? {
        model.ytdlpManager.installProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(stageTitle)
                .font(.title3.bold())
            if let progress, progress.stage == .downloading {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(AppTheme.accent)
                    HStack {
                        Text(
                            "\(DisplayFormatting.byteCount(progress.receivedBytes)) / \(DisplayFormatting.byteCount(progress.totalBytes))"
                        )
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    ProgressView()
                    Text("已下载 \(DisplayFormatting.byteCount(progress.receivedBytes))，大小未知")
                        .font(.caption)
                }
                if progress.averageSpeed > 0 {
                    Text("速度 \(DisplayFormatting.speed(progress.averageSpeed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let progress, progress.stage == .installing {
                ProgressView()
                Text("下载完成，正在安装并验证……")
                    .font(.caption)
            } else {
                ProgressView()
                Text("正在获取最新版本信息……")
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("后台运行") {
                    model.ytdlpManager.isInstallProgressHidden = true
                }
                .buttonStyle(FlatHoverButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var stageTitle: String {
        switch progress?.stage {
        case .fetchingRelease, nil: "正在准备 yt-dlp"
        case .downloading: "正在下载 yt-dlp"
        case .installing: "正在安装 yt-dlp"
        }
    }
}

private struct DetailColumnView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let task = model.selectedTask {
            TaskDetailView(task: task)
                .environmentObject(model)
                // Distinct identity per task: switching the selection must
                // replace the detail view outright, never animate one task's
                // progress bars into another task's values.
                .id(task.id)
        } else {
            EmptyStateView(
                title: "选择一个任务查看详情",
                systemImage: "sidebar.right",
                description: "支持 ⌘/⇧ 多选进行批量操作"
            )
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingQueue: AppQueue?
    @State private var isConfirmingQueueDeletion: AppQueue?

    /// Custom rows instead of `List`: the system list drew its own
    /// selection highlight on top of the row background (two stacked
    /// "boxes"), and its focus state painted a saturated blue that
    /// swallowed the row icons. Hand-rolled buttons give one calm,
    /// spacious selection treatment. The column drops navigationTitle: the
    /// plain window title bar already carries the MacIDM name, and the
    /// floating glass title area was exactly the look being removed.
    /// Plain `VStack`, never `LazyVStack`: the sidebar materializes zero
    /// rows when its first layout pass runs while the window is being
    /// re-shown from the menu bar (activation policy still transitioning),
    /// and the lazy container never retries on its own — the blank sidebar
    /// bug. ~20 static rows gain nothing from laziness anyway.
    var body: some View {
        let counts = sidebarCounts()
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                filterRow(.all, systemImage: "tray.full", counts: counts)
                filterRow(.active, systemImage: "arrow.down.circle", counts: counts)
                filterRow(.completed, systemImage: "checkmark.circle", counts: counts)
                filterRow(.history, systemImage: "clock.arrow.circlepath", counts: counts)

                sectionHeader("队列")
                queueRow(nil, title: model.mainQueueTitle, isPaused: false, counts: counts)
                ForEach(model.queues) { queue in
                    queueRow(queue.id, title: queue.name, isPaused: queue.isPaused, counts: counts)
                        .contextMenu { queueMenu(queue) }
                }
                Button {
                    createQueue()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 18)
                        Text("新建队列…")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverHighlight())

                sectionHeader("时间")
                filterRow(.today, systemImage: "sun.max", counts: counts)
                filterRow(.yesterday, systemImage: "moon", counts: counts)
                filterRow(.thisWeek, systemImage: "calendar", counts: counts)

                sectionHeader("分类")
                ForEach(DownloadCategory.allCases, id: \.self) { category in
                    filterRow(.category(category), systemImage: category.systemImage, counts: counts)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Bind the scrollbar styling to this ScrollView's own AppKit
            // instance. Sidebar content and task counts load asynchronously,
            // so a window-level startup scan alone can miss a rebuilt view.
            .background(LightScrollerConfigurator())
        }
        .sheet(item: $editingQueue) { queue in
            QueueSettingsSheet(queue: queue)
                .environmentObject(model)
        }
        .alert(
            "删除队列「\(isConfirmingQueueDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { isConfirmingQueueDeletion != nil },
                set: { if !$0 { isConfirmingQueueDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let queue = isConfirmingQueueDeletion {
                    model.deleteQueue(queue.id)
                }
                isConfirmingQueueDeletion = nil
            }
            Button("取消", role: .cancel) {
                isConfirmingQueueDeletion = nil
            }
        } message: {
            Text("队列内的任务会移回主队列，不会删除任何下载文件。")
        }
    }

    private func createQueue() {
        guard
            let name = promptForQueueName(
                title: "新建队列",
                message: "输入队列名称。队列拥有独立的并发上限与可选的定时调度。"
            )
        else { return }
        if let queue = model.addQueue(name: name) {
            model.sidebarFilter = .queue(queue.id)
        }
    }

    @ViewBuilder
    private func queueMenu(_ queue: AppQueue) -> some View {
        if queue.isPaused {
            Button("继续队列") { model.resumeQueue(queue.id) }
        } else {
            Button("暂停队列") { model.pauseQueue(queue.id) }
        }
        Button("队列设置…") { editingQueue = queue }
        Button("重命名…") { renameQueue(queue) }
        Divider()
        Button("删除队列…", role: .destructive) {
            isConfirmingQueueDeletion = queue
        }
    }

    private func renameQueue(_ queue: AppQueue) {
        guard
            let name = promptForQueueName(
                title: "重命名队列",
                message: "输入新的队列名称。",
                initial: queue.name
            )
        else { return }
        model.updateQueue(queue.id) { $0.name = name }
    }

    private func queueRow(
        _ queueID: UUID?,
        title: String,
        isPaused: Bool,
        counts: SidebarCounts
    ) -> some View {
        let filter = SidebarFilter.queue(queueID)
        let isSelected = model.sidebarFilter == filter
        return Button {
            model.sidebarFilter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: queueID == nil ? "tray" : "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                if isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(count(for: filter, in: counts), format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight(isActive: isSelected))
    }

    private func filterRow(
        _ filter: SidebarFilter,
        systemImage: String,
        counts: SidebarCounts
    ) -> some View {
        let isSelected = model.sidebarFilter == filter
        return Button {
            model.sidebarFilter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
                    .frame(width: 18)
                Text(filter.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(count(for: filter, in: counts), format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight(isActive: isSelected))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .padding(.leading, 8)
    }

    /// Soft tint + hairline outline. Deliberately pale: the previous
    /// saturated selection blue made the row icons unreadable.
    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
            .fill(isSelected ? AppTheme.selectionFill : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .strokeBorder(
                        isSelected ? AppTheme.selectionOutline : Color.clear,
                        lineWidth: 1
                    )
            )
    }

    private func count(for filter: SidebarFilter, in counts: SidebarCounts) -> Int {
        switch filter {
        case .queue(let queueID):
            guard let queueID else { return counts.mainQueue }
            return counts.queues[queueID] ?? 0
        default:
            return counts.filters[filter] ?? 0
        }
    }

    /// One pass over the task list feeds every sidebar row. The previous
    /// implementation evaluated a full predicate per row (15 rows × N tasks,
    /// three of them doing Calendar work) on every render — which happens at
    /// download tick frequency.
    private func sidebarCounts() -> SidebarCounts {
        var counts = SidebarCounts()
        let calendar = Calendar.current
        let staticFilters: [SidebarFilter] = [
            .all, .active, .completed, .history, .today, .yesterday, .thisWeek,
        ]
        for task in model.tasks {
            for filter in staticFilters where filter.matches(task, calendar: calendar) {
                counts.filters[filter, default: 0] += 1
            }
            // .category/.queue membership requires !isArchived (AppTask
            // matches); without the guard, archived tasks would inflate
            // these badges forever while the filtered list shrank.
            guard !task.isArchived else { continue }
            counts.filters[.category(task.category), default: 0] += 1
            if !task.isCLIManaged {
                if let queueID = task.queueID {
                    counts.queues[queueID, default: 0] += 1
                } else {
                    counts.mainQueue += 1
                }
            }
        }
        return counts
    }
}

/// Per-render sidebar badge counts, computed in a single pass over
/// `model.tasks` (see `SidebarView.sidebarCounts()`).
struct SidebarCounts {
    var filters: [SidebarFilter: Int] = [:]
    var queues: [UUID: Int] = [:]
    var mainQueue = 0
}

/// Structural inputs for the task table, compared by value. The parent
/// recomputes this on every render (it re-renders at download frequency
/// anyway); the table leaf re-renders ONLY when this token actually
/// changes (see `TaskTableView: Equatable`), which is what keeps progress
/// flushes from touching the table during a rubber-band drag.
struct TaskTableAppearance: Equatable, Sendable {
    struct RowKey: Equatable {
        let id: UUID
        let filename: String
    }

    var rows: [RowKey]
    var hiddenColumns: [String]
    var redactFilenames: Bool
    /// Distinguishes "no tasks at all" from "no tasks match the filter"
    /// for the empty state.
    var tasksEmpty: Bool
}

/// The task table leaf. This view observes NOTHING volatile on purpose:
/// no `@EnvironmentObject` model, no `@StateObject` clock. Progress,
/// speed, and status updates flow into per-row `TaskLiveModel` objects
/// (re-rendering single cells); rows/columns/filters arrive as the
/// Equatable `appearance` token; selection commits flow out through the
/// synchronizer. A body re-evaluation re-applies the selection binding
/// onto the backing NSTableView, which aborts an in-progress rubber-band
/// multi-selection — so during active downloads this body must simply
/// never re-evaluate, structurally, instead of being paused by event
/// monitors mid-gesture.
private struct TaskTableView: View, Equatable {
    /// Plain (unobserved) model reference for menu actions and item
    /// providers — capturing it as a plain `let` does not subscribe this
    /// view to `objectWillChange`.
    let model: AppModel
    let synchronizer: TaskTableSynchronizer
    let appearance: TaskTableAppearance
    let requestRemoval: (Set<UUID>) -> Void
    let requestPermanentRemoval: (Set<UUID>) -> Void

    @State private var sortOrder: [KeyPathComparator<AppTask>] = [
        KeyPathComparator(\AppTask.createdAt, order: .reverse)
    ]
    @State private var tableSelectionIDs: Set<UUID> = []
    /// Cached data snapshot, also a plain class in @State. See
    /// `displayedTasks` for why the SAME array instance must be handed
    /// to the Table while rows/sort are unchanged.
    @State private var snapshotBox = TaskSnapshotBox()

    /// Compared by value through `.equatable()` at the call site: when the
    /// parent re-renders on a progress flush, the freshly built
    /// TaskTableView compares equal and SwiftUI SKIPS this body entirely —
    /// the Table never re-applies its selection binding mid-gesture. The
    /// closures and references above are deliberately excluded (they are
    /// stable across renders); only the value token drives re-renders.
    /// `nonisolated` + Sendable token: the View protocol is MainActor
    /// under the newer SDKs, but an immutable Sendable property is safely
    /// readable from the nonisolated equality required by Equatable.
    nonisolated static func == (lhs: TaskTableView, rhs: TaskTableView) -> Bool {
        lhs.appearance == rhs.appearance
    }

    private func isColumnVisible(_ id: String) -> Bool {
        !appearance.hiddenColumns.contains(id)
    }

    /// Data snapshot derived synchronously in the body, with the RESULT
    /// INSTANCE CACHED by signature. Two failure modes this design avoids:
    /// 1. A `.onChange`-relayed `@State` array can be swallowed
    ///    mid-tracking, leaving the table showing the previous sidebar
    ///    filter's rows — so the snapshot must be rebuilt right here,
    ///    in-body, whenever the signature (rows/sort) changed.
    /// 2. Handing the Table a FRESHLY ALLOCATED array on selection-only
    ///    re-renders makes SwiftUI's Table bridge reload the backing
    ///    NSTableView, which perturbs column layout — the trailing blank
    ///    column that appeared after every click. While the signature is
    ///    unchanged the cached instance is returned, so selection updates
    ///    never trigger a data reload.
    private var displayedTasks: [AppTask] {
        let sortSignature = sortOrder.map { "\($0.keyPath)|\($0.order)" }
        if appearance.rows == snapshotBox.rowsSignature,
            sortSignature == snapshotBox.sortSignature
        {
            return snapshotBox.snapshot
        }
        // Deterministic total order: Swift's sort is not stable, so without
        // the id tie-breaker rows sharing the sort key (e.g. several tasks
        // at 0 B/s) could shuffle relative to each other across reloads.
        // (uuidString, not UUID itself: UUID's Comparable conformance is
        // macOS 14+.)
        // Filename redaction swaps the filename comparator for the Job ID:
        // the column then shows Job IDs only, so sorting by the hidden
        // filename would look arbitrary to the user.
        let effectiveSort: [KeyPathComparator<AppTask>] =
            appearance.redactFilenames
            ? sortOrder.map { comparator in
                comparator.keyPath == \AppTask.filename
                    ? KeyPathComparator(\AppTask.jobID, order: comparator.order)
                    : comparator
            }
            : sortOrder
        let rows = synchronizer.provideRows().sorted(
            using: effectiveSort + [KeyPathComparator(\.id.uuidString)]
        )
        snapshotBox.rowsSignature = appearance.rows
        snapshotBox.sortSignature = sortSignature
        snapshotBox.snapshot = rows
        return rows
    }

    // The column-hiding feature relies on `if`-gated columns inside the Table
    // builder, whose `Optional` conformance to TableColumnContent is only
    // available on macOS 14.4+. Gate the whole Table so macOS 13 users get a
    // fully-functional table with all columns visible, while 14.4+ users keep
    // the per-column show/hide customization.
    /// Filename redaction renames the leading column: it then displays
    /// Job IDs only, and the header must say so (sorting follows, see
    /// `displayedTasks`).
    private var filenameColumnTitle: LocalizedStringKey {
        appearance.redactFilenames ? "任务ID" : "文件名"
    }

    @ViewBuilder
    private var taskTable: some View {
        if #available(macOS 14.4, *) {
            Table(displayedTasks, selection: $tableSelectionIDs, sortOrder: $sortOrder) {
                TableColumn(filenameColumnTitle, value: \.filename) { task in
                    TaskNameCell(
                        task: task,
                        redacted: appearance.redactFilenames
                    )
                    .modifier(TableCellLayout())
                }
                // Resizable: min keeps the column readable, ideal sets the
                // default share; users can drag the divider freely.
                .width(min: 170, ideal: 200)

                if isColumnVisible("size") {
                    TableColumn("大小", value: \.sortSize) { task in
                        SizeCell(live: synchronizer.liveModel(for: task.id))
                            .modifier(TableCellLayout())
                    }
                    .width(min: 70, ideal: 70)
                }

                if isColumnVisible("status") {
                    TableColumn("状态") { task in
                        StatusCell(live: synchronizer.liveModel(for: task.id))
                            .modifier(TableCellLayout())
                    }
                    .width(min: 80, ideal: 95)
                }

                if isColumnVisible("speed") {
                    TableColumn("速度", value: \.sortSpeed) { task in
                        SpeedCell(
                            task: task,
                            live: synchronizer.liveModel(for: task.id)
                        )
                        .modifier(TableCellLayout())
                    }
                    .width(min: 75, ideal: 75)
                }

                if isColumnVisible("duration") {
                    TableColumn("总耗时", value: \.sortDuration) { task in
                        DurationCell(
                            task: task,
                            live: synchronizer.liveModel(for: task.id),
                            clock: synchronizer.clock
                        )
                        .modifier(TableCellLayout())
                    }
                    .width(min: 60, ideal: 60)
                }

                if isColumnVisible("date") {
                    TableColumn("日期", value: \.createdAt) { task in
                        Text(task.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .modifier(TableCellLayout())
                    }
                    .width(min: 100, ideal: 124)
                }

                if isColumnVisible("progress") {
                    TableColumn("进度") { task in
                        ProgressCell(live: synchronizer.liveModel(for: task.id))
                            .modifier(TableCellLayout())
                    }
                    .width(min: 110, ideal: 110)
                }
            }
        } else {
            Table(displayedTasks, selection: $tableSelectionIDs, sortOrder: $sortOrder) {
                TableColumn(filenameColumnTitle, value: \.filename) { task in
                    TaskNameCell(
                        task: task,
                        redacted: appearance.redactFilenames
                    )
                    .modifier(TableCellLayout())
                }
                .width(min: 170, ideal: 200)

                TableColumn("大小", value: \.sortSize) { task in
                    SizeCell(live: synchronizer.liveModel(for: task.id))
                        .modifier(TableCellLayout())
                }
                .width(min: 70, ideal: 70)

                TableColumn("状态") { task in
                    StatusCell(live: synchronizer.liveModel(for: task.id))
                        .modifier(TableCellLayout())
                }
                .width(min: 80, ideal: 95)

                TableColumn("速度", value: \.sortSpeed) { task in
                    SpeedCell(
                        task: task,
                        live: synchronizer.liveModel(for: task.id)
                    )
                    .modifier(TableCellLayout())
                }
                .width(min: 75, ideal: 75)

                TableColumn("总耗时", value: \.sortDuration) { task in
                    DurationCell(
                        task: task,
                        live: synchronizer.liveModel(for: task.id),
                        clock: synchronizer.clock
                    )
                    .modifier(TableCellLayout())
                }
                .width(min: 60, ideal: 60)

                TableColumn("日期", value: \.createdAt) { task in
                    Text(task.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .modifier(TableCellLayout())
                }
                .width(min: 100, ideal: 124)

                TableColumn("进度") { task in
                    ProgressCell(live: synchronizer.liveModel(for: task.id))
                        .modifier(TableCellLayout())
                }
                .width(min: 110, ideal: 110)
            }
        }
    }

    var body: some View {
        Group {
            taskTable.id(appearance.hiddenColumns)
        }
        // One background for every column: the table stops painting its own
        // surface so the AppKit window background shows through, matching the
        // sidebar and detail columns instead of rendering a lighter block.
        .scrollContentBackground(.hidden)
        // Keep the AppKit table and its header at the full list-column width.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Table styling stays entirely at SwiftUI's defaults — overriding
        // the backing NSTableView fights the Table bridge's per-update
        // layout re-assertions. Selection flows through SwiftUI's binding
        // only; the system click semantics are accepted as-is.
        .onChange(of: tableSelectionIDs) { newValue in
            // Outbound only, never echoed back: the table already displays
            // what it committed, and an echo would re-evaluate this body
            // and re-apply the selection binding mid-gesture. During a
            // rubber-band drag the binding streams intermediate selections;
            // the synchronizer forwards them to the model without touching
            // this body.
            synchronizer.commitSelection(newValue)
        }
        .onAppear {
            // Inbound channel for external selections (selectTasks): a
            // direct binding write, never an appearance-token change.
            synchronizer.applyExternalSelection = { ids in
                if tableSelectionIDs != ids {
                    tableSelectionIDs = ids
                }
            }
            if model.selectedTaskIDs != tableSelectionIDs {
                tableSelectionIDs = model.selectedTaskIDs
            }
        }
        .overlay {
            if displayedTasks.isEmpty {
                EmptyStateView(
                    title: appearance.tasksEmpty ? "还没有下载任务" : "没有匹配的任务",
                    systemImage: appearance.tasksEmpty ? "arrow.down.doc" : "magnifyingglass",
                    description: appearance.tasksEmpty ? "点击「添加」或拖入下载链接" : "更改筛选条件或搜索内容"
                )
            }
        }
        .overlay {
            TableHeaderRuleOverlay()
        }
        .taskContextMenu(
            model: model, requestRemoval: requestRemoval,
            requestPermanentRemoval: requestPermanentRemoval
        )
    }
}

private struct TaskContextMenuModifier: ViewModifier {
    /// Plain `let` on purpose: an `@ObservedObject` here would subscribe
    /// the table subtree to the model's 300 ms progress flushes and
    /// re-apply selection mid-gesture. The menu only reads model state
    /// when it opens.
    let model: AppModel
    let requestRemoval: (Set<UUID>) -> Void
    let requestPermanentRemoval: (Set<UUID>) -> Void

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: UUID.self) { selection in
            let tasks = model.tasks.filter { selection.contains($0.id) }
            if !tasks.isEmpty {
                if tasks.allSatisfy(\.isArchived) {
                    archivedMenu(tasks)
                } else {
                    activeMenu(tasks)
                }
            }
        }
    }

    @ViewBuilder
    private func archivedMenu(_ tasks: [AppTask]) -> some View {
        Button("重新下载") { for task in tasks { model.reDownload(task.id) } }
        Divider()
        Button("永久删除…", role: .destructive) {
            requestPermanentRemoval(Set(tasks.map(\.id)))
        }
        .disabled(!tasks.contains { !$0.isCLIManaged })
    }

    @ViewBuilder
    private func activeMenu(_ tasks: [AppTask]) -> some View {
        Button("继续") { for task in tasks { model.resume(task.id) } }
            .disabled(
                !tasks.contains {
                    !$0.isCLIManaged
                        && [.paused, .failed, .needsRestart, .storageError, .cancelled].contains(
                            $0.status)
                }
            )
        Button("暂停") { for task in tasks { model.pause(task.id) } }
            .disabled(
                !tasks.contains {
                    !$0.isCLIManaged && [.queued, .probing, .running, .verifying].contains($0.status)
                }
            )
        Button("取消") { for task in tasks { model.cancel(task.id) } }
            .disabled(
                !tasks.contains {
                    !$0.isCLIManaged
                        && [
                            .queued, .probing, .running, .pausing, .verifying, .paused, .failed,
                            .needsRestart, .takeoverPending, .takeoverConflict, .filenameConflict,
                        ].contains($0.status)
                }
            )
        if tasks.count == 1, let task = tasks.first, task.status == .filenameConflict {
            Button("改名重试…") { retryWithNewFilename(task) }
        }
        Divider()
        if tasks.count == 1, let task = tasks.first {
            Button("打开文件") { model.openFile(task.id) }
                .disabled(task.status != .completed)
            Button("在访达中显示") { model.revealInFinder(task.id) }
                .disabled(task.status != .completed)
            Button("复制文件路径") { model.copyDestinationPath(task.id) }
            Button("查看详情") { model.selectTasks([task.id]) }
        }
        if !model.queues.isEmpty, tasks.contains(where: { !$0.isCLIManaged }) {
            Menu("移动到队列") {
                Button(model.mainQueueTitle) {
                    for task in tasks where !task.isCLIManaged {
                        model.moveTask(task.id, toQueue: nil)
                    }
                }
                ForEach(model.queues) { queue in
                    Button(queue.name) {
                        for task in tasks where !task.isCLIManaged {
                            model.moveTask(task.id, toQueue: queue.id)
                        }
                    }
                }
            }
        }
        Button("移除记录…", role: .destructive) { requestRemoval(Set(tasks.map(\.id))) }
            .disabled(!tasks.contains { !$0.isCLIManaged })
    }

    /// Prompts for a new filename via a native AppKit alert and retries the
    /// conflicting task. NSAlert+NSTextField is used because SwiftUI's Alert
    /// does not support text input on macOS; this keeps the flow contained
    /// without introducing a dedicated sheet state machine.
    private func retryWithNewFilename(_ task: AppTask) {
        let alert = NSAlert()
        alert.messageText = String(localized: "文件名冲突")
        alert.informativeText = String(
            localized: "「\(task.filename)」已存在，请输入一个新的文件名继续下载。"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "继续下载"))
        alert.addButton(withTitle: String(localized: "取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = task.filename
        input.placeholderString = String(localized: "新的文件名")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = input.stringValue
        do {
            try model.retryWithNewFilename(task.id, filename: entered)
        } catch {
            model.presentedError = PresentedError(title: "改名失败", message: error.localizedDescription)
        }
    }
}

private extension View {
    func taskContextMenu(
        model: AppModel, requestRemoval: @escaping (Set<UUID>) -> Void,
        requestPermanentRemoval: @escaping (Set<UUID>) -> Void
    ) -> some View {
        modifier(
            TaskContextMenuModifier(
                model: model, requestRemoval: requestRemoval,
                requestPermanentRemoval: requestPermanentRemoval
            )
        )
    }
}

/// Hover affordance for the flat sidebar rows: plain-style buttons gave
/// zero feedback under the pointer otherwise.
private struct HoverHighlight: ViewModifier {
    var isActive = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(
                        isHovering && !isActive
                            ? Color.primary.opacity(0.05) : Color.clear
                    )
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .pointerCursorOnHover()
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
