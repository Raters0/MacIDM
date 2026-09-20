import AppKit
import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var model: AppModel
    let task: AppTask
    /// Expansion state for the high-segment-count disclosure; the label is a
    /// full-width button so clicking anywhere on the row toggles it, exactly
    /// like the new-download dialog's advanced options.
    @State private var isSegmentsExpanded = false

    @State private var isTechnicalDetailsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if task.fileMissing && task.status == .completed {
                        fileMissingNotice
                    }
                    if let errorMessage = task.errorMessage, showsErrorPanel {
                        errorPanel(errorMessage)
                    }
                    if task.isCLIManaged {
                        Label("此任务由 macidm CLI 控制，请在终端执行暂停、继续或取消。", systemImage: "terminal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if task.status.showsTransferProgress {
                        section("总进度") {
                            totalProgressContent
                            if task.status == .running {
                                HStack {
                                    Text(DisplayFormatting.speed(task.bytesPerSecond))
                                    Spacer()
                                    if task.bytesPerSecond > 0, let total = task.totalBytes, total > task.receivedBytes
                                    {
                                        Text(
                                            "剩余约 \(DisplayFormatting.duration(Double(total - task.receivedBytes) / task.bytesPerSecond))"
                                        )
                                    }
                                }
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if task.status.isActive && !task.speedHistory.isEmpty {
                        speedSection
                    }
                    section("文件信息") {
                        metadataGrid
                    }
                    DisclosureGroup("技术详情", isExpanded: $isTechnicalDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text("任务ID")
                                Spacer()
                                Text(task.jobID).monospaced().textSelection(.enabled)
                                CopyJobIDButton(jobID: task.jobID)
                            }
                            if task.segments.count > 1 {
                                section(isTrackPair ? "轨道进度" : "分段进度") {
                                    segmentProgressContent
                                }
                            }
                            if !task.status.isActive && !task.speedHistory.isEmpty {
                                speedSection
                            }
                            if let message = task.errorMessage, showsErrorPanel {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("错误详情").font(.callout.weight(.semibold))
                                    Text(message)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if let sha256 = task.sha256 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("SHA-256").foregroundStyle(.secondary)
                                    Text(sha256).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(LightScrollerConfigurator())
        }
    }

    private var speedSection: some View {
        section("下载速度") {
            SpeedHistoryView(samples: task.speedHistory, isFrozen: task.status.freezesSpeedChart)
                .frame(height: 130)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.displayName(redacted: model.settings.redactFilenames))
                .font(.title3.bold())
                .lineLimit(2)
                .textSelection(.enabled)
                .help(task.displayName(redacted: model.settings.redactFilenames))
            HStack {
                StatusLabel(status: task.status)
                Spacer()
                Text(DisplayFormatting.byteCount(task.totalBytes ?? task.receivedBytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            if showsFileActions {
                fileActions
            } else if !task.isCLIManaged {
                HStack(spacing: 12) {
                    if [.queued, .probing, .running, .verifying].contains(task.status) {
                        Button("暂停") { model.pause(task.id) }
                    }
                    if [.paused, .cancelled].contains(task.status) {
                        Button("继续") { model.resume(task.id) }
                    }
                    if [.queued, .probing, .running, .paused].contains(task.status) {
                        Button("取消") { model.cancel(task.id) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section scaffolding

    /// Section styling per the flat-card reference: a prominent dark
    /// title, then the content in a hairline-outlined box with breathing
    /// room; inner dividers stay inset from the box edges.
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.primary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notices and actions

    private var fileMissingNotice: some View {
        Label {
            Text("原始文件已从下载目录中删除或移动")
                .font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.warning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: AppTheme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                .stroke(AppTheme.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private var showsFileActions: Bool {
        task.status == .completed
            || [.failed, .storageError, .needsRestart, .filenameConflict, .takeoverConflict]
                .contains(task.status)
    }

    private var fileActions: some View {
        HStack(spacing: 0) {
            StatsActionButton(title: "打开文件", systemImage: "play.circle") {
                model.openFile(task.id)
            }
            .disabled(!canUseDownloadedFile)

            actionSpacer
            actionSeparator
            actionSpacer

            StatsActionButton(title: "在访达中显示", systemImage: "folder") {
                model.revealInFinder(task.id)
            }
            .disabled(!canUseDownloadedFile)

            actionSpacer
            actionSeparator
            actionSpacer

            StatsActionButton(title: "复制路径", systemImage: "doc.on.doc") {
                model.copyDestinationPath(task.id)
            }
            .disabled(!canUseDownloadedFile)
        }
        .frame(maxWidth: .infinity)
    }

    private var canUseDownloadedFile: Bool {
        task.status == .completed && !task.fileMissing
    }

    private var actionSpacer: some View {
        Spacer(minLength: 8)
    }

    private var actionSeparator: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: 1, height: 24)
    }

    // MARK: - Progress

    @ViewBuilder
    private var totalProgressContent: some View {
        // Shared hand-drawn track (ProgressTrackBar), not the system
        // ProgressView: the system control renders thick with a permanently
        // prominent track on external non-Retina displays. The drawn bar is
        // identical on every display and matches the task table's progress
        // column.
        if (task.totalBytes ?? 0) > 0 || task.status == .completed {
            ProgressTrackBar(fraction: task.fractionCompleted, height: 5)
            HStack {
                Text(
                    "\(DisplayFormatting.byteCount(task.receivedBytes)) / \(DisplayFormatting.byteCount(task.totalBytes))"
                )
                Spacer()
                Text(task.fractionCompleted, format: .percent.precision(.fractionLength(1)))
            }
            .font(.caption)
            .monospacedDigit()
        } else if task.status.isTerminal {
            // The task ended before a total size was ever reported
            // (e.g. a failed yt-dlp run). Show a deterministic 0%
            // bar instead of an indeterminate loader that animates
            // forever on a finished task.
            ProgressTrackBar(fraction: 0, height: 5)
            HStack {
                Text("已下载 \(DisplayFormatting.byteCount(task.receivedBytes))，任务已结束（大小未知）")
                Spacer()
                Text("0%")
            }
            .font(.caption)
            .monospacedDigit()
        } else {
            // Total still unknown (e.g. yt-dlp never reports one): a
            // deterministic empty bar plus the advancing byte counter keeps
            // this panel consistent with the list row. An indeterminate
            // animated bar reads as "already 100%" and misleads.
            ProgressTrackBar(fraction: 0, height: 5)
            HStack {
                Text("已下载 \(DisplayFormatting.byteCount(task.receivedBytes))，大小未知")
                Spacer()
            }
            .font(.caption)
            .monospacedDigit()
        }
    }

    // IDM-style per-segment blocks: each segment gets its own colored bar
    // so parallel progress is visible at a glance. Colors come from the
    // shared desaturated palette instead of raw saturated system hues.
    private static let segmentColors: [Color] = AppTheme.segmentPalette

    /// True when this is a DASH pair (video + audio track) rather than real
    /// parallel segments. Detected by checking for the track labels set by
    /// AppModel when a transient audio URL is present.
    private var isTrackPair: Bool {
        task.segments.count == 2
            && task.segments.contains { $0.label == "视频轨" }
    }

    @ViewBuilder
    private var segmentProgressContent: some View {
        if isTrackPair {
            // DASH pair: show video/audio tracks as distinct cards
            // with clear labels instead of a generic "Segment 1/2".
            VStack(alignment: .leading, spacing: 10) {
                ForEach(task.segments) { segment in
                    trackCard(segment)
                }
            }
        } else if task.segments.count > 8 {
            // High segment count (HLS): show a compact summary
            // with overall progress, expandable to individual segments.
            let completed = task.segments.filter { segment in
                guard let total = segment.totalBytes, total > 0 else { return false }
                return segment.receivedBytes >= total
            }.count
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(completed)/\(task.segments.count) 分段已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(task.fractionCompleted, format: .percent.precision(.fractionLength(1)))
                        .font(.caption)
                        .monospacedDigit()
                }
                // Same hand-drawn track as the total-progress bar above:
                // the system linear ProgressView renders thicker on some
                // displays and breaks the visual consistency.
                ProgressTrackBar(fraction: task.fractionCompleted, height: 5)
                // Custom disclosure instead of DisclosureGroup: on macOS the
                // group's label text is not clickable (only the chevron is),
                // which made this row feel broken next to the new-download
                // dialog's advanced-options disclosure. The whole row now
                // toggles, with the same chevron-rotation animation.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSegmentsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isSegmentsExpanded ? 90 : 0))
                        Text("展开全部分段")
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                if isSegmentsExpanded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(task.segments) { segment in
                            segmentBar(segment, compact: true)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            // Low segment count: show full IDM-style per-segment blocks.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(task.segments) { segment in
                    segmentBar(segment, compact: false)
                }
            }
        }
    }

    /// Displays a DASH track (video or audio) as a labeled card with its
    /// own progress bar and byte counter.
    private func trackCard(_ segment: SegmentSnapshot) -> some View {
        let color = segment.label == "视频轨" ? AppTheme.accent : AppTheme.warning
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(
                    systemName: segment.label == "视频轨"
                        ? "film.fill"
                        : "speaker.wave.2.fill"
                )
                .foregroundStyle(color)
                Text(localizedTrackLabel(segment))
                    .font(.subheadline.bold())
                Spacer()
                Text(segment.fractionCompleted, format: .percent.precision(.fractionLength(1)))
                    .font(.caption)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * segment.fractionCompleted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
            .animation(nil, value: segment.fractionCompleted)
            .transaction { $0.animation = nil }
            Text(
                "\(DisplayFormatting.byteCount(segment.receivedBytes)) / \(DisplayFormatting.byteCount(segment.totalBytes))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(10)
    }

    private func segmentBar(_ segment: SegmentSnapshot, compact: Bool) -> some View {
        let color = Self.segmentColors[segment.index % Self.segmentColors.count]
        return VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack {
                Text(segment.displayLabel)
                Spacer()
                Text(segment.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * segment.fractionCompleted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 4 : 5, maxHeight: compact ? 4 : 5)
            .animation(nil, value: segment.fractionCompleted)
            .transaction { $0.animation = nil }
            if !compact {
                Text(
                    "\(DisplayFormatting.byteCount(segment.receivedBytes)) / \(DisplayFormatting.byteCount(segment.totalBytes))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    // MARK: - Error alert area

    /// Pause and cancel surface as status, not as errors; a leftover
    /// PAUSED/CANCELLED code from older persisted state must stay hidden.
    private var showsErrorPanel: Bool {
        task.errorCode != "PAUSED" && task.errorCode != "CANCELLED"
    }

    private func errorPanel(_ message: String) -> some View {
        let friendly =
            task.errorCode.map { ErrorPresentation.describe(code: $0, fallbackMessage: message) }
            ?? ErrorPresentation.Friendly(title: "下载错误", message: message)
        return VStack(alignment: .leading, spacing: 8) {
            Label(friendly.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.danger)
            Text(friendly.message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Button("查看错误详情") {
                isTechnicalDetailsExpanded = true
            }
            .buttonStyle(.borderless)
            if let recommendation = task.errorRecommendation, !recommendation.isEmpty {
                Text("建议：\(recommendation)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !task.isCLIManaged {
                errorActionButtons
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.danger.opacity(0.05),
            in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.danger.opacity(0.25), lineWidth: 1)
        )
    }

    /// yt-dlp's extractor library covers thousands of sites, so a failed
    /// native transfer is worth one attempt through it. Offered only for
    /// tasks that haven't already run on that backend, with a diagnosis
    /// that plausibly benefits from site-specific extraction logic.
    private var canRetryWithYtdlp: Bool {
        let retryableStatuses: [AppTaskStatus] = [.failed, .needsRestart, .storageError, .paused]
        guard retryableStatuses.contains(task.status),
            task.browserSubmissionType != "youtube.extractor",
            YTDlpManager.isAvailable
        else { return false }
        let fallbackCategories: Set<String> = [
            "resource", "sitePolicy", "server", "media", "unknown",
        ]
        return fallbackCategories.contains(task.errorCategory ?? "unknown")
    }

    /// Context-specific action buttons derived from the stored error
    /// category: retry / paste cookie / resubmit / reduce parallelism.
    /// Styled with the app's flat hairline language instead of the system
    /// bordered control, so they sit quietly inside the danger card.
    @ViewBuilder
    private var errorActionButtons: some View {
        let actions = availableErrorActions
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                ForEach(actions) { action in
                    DetailTextActionButton(title: action.title, action: action.perform)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions) { action in
                    DetailTextActionButton(title: action.title, action: action.perform)
                }
            }
        }
        .padding(.top, 2)
    }

    private var availableErrorActions: [DetailErrorAction] {
        let retryableStatuses: [AppTaskStatus] = [.failed, .needsRestart, .storageError, .paused]
        var actions: [DetailErrorAction] = []
        if retryableStatuses.contains(task.status) {
            actions.append(DetailErrorAction(id: "retry", title: "重试") { model.resume(task.id) })
        }
        if task.errorCategory == "authentication" {
            actions.append(
                DetailErrorAction(id: "cookie", title: "粘贴 Cookie") {
                    model.cookiePasteRetryTaskID = task.id
                    let host =
                        task.pageURL.flatMap { URLComponents(string: $0)?.host }
                        ?? URLComponents(string: task.sourceURL)?.host
                    model.cookiePasteDomain = host ?? ""
                })
        }
        if task.errorCategory == "rateLimit" {
            actions.append(
                DetailErrorAction(id: "parallel", title: "降低并行数重试") {
                    model.reduceParallelismAndRetry(task.id)
                })
        }
        if canRetryWithYtdlp {
            actions.append(
                DetailErrorAction(id: "ytdlp", title: "用 yt-dlp 重试") {
                    model.retryWithYtdlp(task.id)
                })
        }
        if task.errorCode == "NEEDS_REFETCH"
            || (task.errorCategory == "media" && task.pageURL != nil)
        {
            actions.append(
                DetailErrorAction(id: "resubmit", title: "重新提交") {
                    let raw = task.pageURL ?? task.sourceURL
                    if let draft = DownloadDraft(urlString: raw) {
                        model.presentNewDownload(draft: draft)
                    }
                })
        }
        return actions
    }

    // MARK: - Metadata

    /// Metadata rows inside the section box: every entry is separated by a
    /// hairline that spans the padded content width, so the lines stay
    /// inset from the box edges instead of touching them.
    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            if task.pageURL != nil {
                GridRow(alignment: .top) {
                    rowLabel("页面")
                    CompactLinkView(value: task.redactedSourceURL)
                }
                if task.redactedRawSourceURL != task.redactedSourceURL {
                    metadataDivider
                    GridRow(alignment: .top) {
                        rowLabel("来源")
                        CompactLinkView(value: task.redactedRawSourceURL)
                    }
                }
            } else {
                GridRow(alignment: .top) {
                    rowLabel("来源")
                    CompactLinkView(value: task.redactedSourceURL)
                }
            }
            // Filename redaction hides the destination path too: the
            // directory and file name together would re-identify the
            // download the Job ID display is meant to conceal.
            if !model.settings.redactFilenames {
                metadataDivider
                detailRow("保存至", task.destinationPath)
            }
            metadataDivider
            GridRow {
                rowLabel("分类")
                Picker(
                    "分类",
                    selection: Binding(
                        get: { task.categoryOverride?.rawValue ?? "auto" },
                        set: { rawValue in
                            model.setCategory(
                                task.id,
                                category: DownloadCategory(rawValue: rawValue)
                            )
                        }
                    )
                ) {
                    // Preview the pure filename/MIME detection, never the
                    // current override — otherwise the parentheses echo the
                    // user's manual selection instead of what "Auto" would
                    // resolve to.
                    Text(String(localized: "自动（\(task.detectedCategory.title)）")).tag("auto")
                    ForEach(DownloadCategory.allCases, id: \.self) { category in
                        Text(category.title).tag(category.rawValue)
                    }
                }
                .labelsHidden()
                .pointerCursorOnHover()
            }
        }
        .textSelection(.enabled)
    }

    /// Hairline between metadata rows; the box padding keeps both ends
    /// inset from the card border.
    private var metadataDivider: some View {
        GridRow {
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)
                .gridCellColumns(2)
        }
    }

    /// Track labels arrive from the engine as data values (the video-track and
    /// audio-track literals matched in the switch below) and double as
    /// identity markers elsewhere; localize them only at display time so the
    /// comparisons keep working.
    private func localizedTrackLabel(_ segment: SegmentSnapshot) -> String {
        switch segment.label {
        case "视频轨": String(localized: "视频轨")
        case "音频轨": String(localized: "音频轨")
        default: segment.displayLabel
        }
    }

    private func rowLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow(alignment: .top) {
            rowLabel(label)
            Text(value)
                .font(.callout)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

/// Copies the Job ID with a color-only hover affordance. Keeping the hit area
/// larger than the glyph makes it easy to click without drawing a background
/// that competes with the metadata row.
private struct CopyJobIDButton: View {
    let jobID: String
    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(jobID, forType: .string)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                justCopied = false
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(
                    justCopied
                        ? AppTheme.success
                        : isHovering ? AppTheme.accent : Color.secondary
                )
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .onHover { hovering in
            isHovering = hovering
        }
        .help(justCopied ? "已复制" : "复制任务ID（提交问题反馈时使用）")
    }
}

/// Borderless action cell used in the completed-task header row. The label
/// hugs its content; equal flexible spacers around the hairline dividers
/// keep the separators midway between neighboring buttons.
private struct StatsActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                // No horizontal padding: this row is boxless, and the outer
                // buttons' labels must sit flush with the section cards and
                // title below them. (The old boxed design carried inner
                // margins that made the row read as misaligned.)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .pointerCursorOnHover(isEnabled: isEnabled)
        .help(title)
    }

    private var labelColor: Color {
        guard isEnabled else { return .secondary.opacity(0.55) }
        return isHovering ? AppTheme.accent : Color.primary
    }
}

private struct DetailErrorAction: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let perform: () -> Void
}

private struct DetailTextActionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isHovering ? AppTheme.accent : Color.primary)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursorOnHover()
    }
}

/// Speed chart over the real most-recent-120-seconds window (product-spec
/// §4.3). X positions come from the samples' true timestamps against the
/// window's reference instant — never from the array index. The axis shows
/// one fixed, centered window title: the title expresses the chart's fixed
/// capacity, not how much data has accumulated.
///
/// Window reference semantics:
/// - Active tasks: the wall clock drives the right edge; a 1 Hz timeline
///   keeps the view advancing even while speed callbacks are silent, and
///   samples older than 120 s fall out of the window.
/// - Terminal tasks: frozen at the final sample instant, so opening the
///   detail view later still shows the completion snapshot instead of an
///   aged/empty curve.
private struct SpeedHistoryView: View {
    let samples: [SpeedSample]
    let isFrozen: Bool

    var body: some View {
        if isFrozen {
            chart(
                reference: SpeedHistoryPolicy.windowReference(
                    samples: samples,
                    now: Date(),
                    isTerminal: true
                ))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                chart(
                    reference: SpeedHistoryPolicy.windowReference(
                        samples: samples,
                        now: context.date,
                        isTerminal: false
                    ))
            }
        }
    }

    private func chart(reference: Date) -> some View {
        let visible = SpeedHistoryPolicy.windowSamples(samples, reference: reference)
        let values = visible.map(\.bytesPerSecond)
        // Accessibility shares the same visible-window samples as the chart:
        // after silence longer than the window, VoiceOver zeroes out together
        // with the curve and no longer announces old samples outside the
        // window (§5).
        let summary = SpeedHistoryPolicy.visibleSummary(visible)
        let accessibilityText = String(
            localized:
                "下载速度曲线，最近 2 分钟，当前速度 \(formatSpeed(summary.current))，峰值 \(formatSpeed(summary.peak))"
        )
        return GeometryReader { geometry in
            let maximum = max(values.max() ?? 0, 1)
            let yAxisWidth: CGFloat = 52
            let xAxisHeight: CGFloat = 18
            let chartWidth = geometry.size.width - yAxisWidth
            let chartHeight = geometry.size.height - xAxisHeight
            let points = chartPoints(
                visible,
                reference: reference,
                width: chartWidth,
                height: chartHeight,
                maximum: maximum
            )

            HStack(spacing: 0) {
                // Y axis labels
                VStack(alignment: .trailing, spacing: 0) {
                    Text(formatSpeed(maximum))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatSpeed(maximum / 2))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(width: yAxisWidth - 6, height: chartHeight)

                // Chart area
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // Grid lines
                        Path { grid in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = chartHeight * CGFloat(fraction)
                                grid.move(to: CGPoint(x: 0, y: y))
                                grid.addLine(to: CGPoint(x: chartWidth, y: y))
                            }
                        }
                        .stroke(AppTheme.hairline, lineWidth: 1)

                        // Translucent gradient fill under the curve gives the
                        // chart a modern area-chart look instead of a bare
                        // polyline.
                        filledAreaPath(points: points, width: chartWidth, height: chartHeight)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AppTheme.accent.opacity(0.30),
                                        AppTheme.accent.opacity(0.02),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        // Smooth speed curve (Catmull-Rom spline through the
                        // raw samples).
                        smoothCurvePath(through: points, height: chartHeight)
                            .stroke(
                                AppTheme.accent,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                            )

                        // Glowing dot on the latest sample.
                        if let last = points.last {
                            Circle()
                                .fill(AppTheme.accent.opacity(0.22))
                                .frame(width: 9, height: 9)
                                .position(last)
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 4.5, height: 4.5)
                                .position(last)
                        }
                    }
                    .frame(width: chartWidth, height: chartHeight)

                    // X axis: one fixed, centered window title. It states
                    // the chart's capacity — never the accumulated data
                    // span — and carries no dynamic N-second variants.
                    Text(String(localized: "最近 2 分钟"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: chartWidth, height: xAxisHeight)
                }
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    /// X position is proportional to the sample's true age against the
    /// window reference; the reference instant sits at the right edge.
    /// Uneven sampling intervals therefore draw unevenly spaced points
    /// instead of pretending every sample was equally spaced.
    private func chartPoints(
        _ visible: [SpeedSample],
        reference: Date,
        width: CGFloat,
        height: CGFloat,
        maximum: Double
    ) -> [CGPoint] {
        visible.map { sample in
            let age = reference.timeIntervalSince(sample.timestamp)
            let fraction = max(0, min(1, 1 - age / SpeedHistoryPolicy.window))
            let x = width * CGFloat(fraction)
            let y = height * (1 - CGFloat(sample.bytesPerSecond / maximum))
            return CGPoint(x: x, y: y)
        }
    }

    /// Catmull-Rom spline converted to cubic Bézier segments: the curve
    /// passes exactly through every sample but flows smoothly between them.
    /// Control points are clamped vertically so steep spikes never overshoot
    /// the chart bounds.
    private func smoothCurvePath(through points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for index in 1..<points.count {
            let previous2 = points[max(0, index - 2)]
            let previous = points[index - 1]
            let current = points[index]
            let next = points[min(points.count - 1, index + 1)]
            let control1 = CGPoint(
                x: previous.x + (current.x - previous2.x) / 6,
                y: (previous.y + (current.y - previous2.y) / 6).clamped(to: 0...height)
            )
            let control2 = CGPoint(
                x: current.x - (next.x - previous.x) / 6,
                y: (current.y - (next.y - previous.y) / 6).clamped(to: 0...height)
            )
            path.addCurve(to: current, control1: control1, control2: control2)
        }
        return path
    }

    /// The smooth curve closed down to the baseline, used for the gradient
    /// area fill beneath the speed line.
    private func filledAreaPath(
        points: [CGPoint], width: CGFloat, height: CGFloat
    ) -> Path {
        var path = smoothCurvePath(through: points, height: height)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        } else if bytesPerSecond >= 1_024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
