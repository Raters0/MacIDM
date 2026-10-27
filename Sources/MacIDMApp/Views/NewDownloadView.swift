import AppKit
import IDMEngine
import SwiftUI

struct NewDownloadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let initialDraft: DownloadDraft?
    @State private var isHandBackHovering = false
    /// Set when the view is hosted in a standalone window instead of a sheet:
    /// SwiftUI's `dismiss` environment only closes sheets, so the window
    /// manager injects its own close action.
    var onClose: (() -> Void)? = nil
    /// Called when the download was successfully created in the model before closing the view.
    var onSubmitSuccess: (() -> Void)? = nil
    /// Fired whenever the form's content height materially changes (options
    /// resolved, disclosure toggled, messages shown), so the hosting window
    /// can re-fit itself up to its ceiling instead of scrolling.
    var onLayoutChange: (() -> Void)? = nil
    @State private var urlText: String
    @State private var destinationDirectory: String
    @State private var filename: String
    @State private var maximumParallelRequests: Int
    @State private var priority = 0
    @State private var expectedSHA256 = ""
    @State private var startImmediately = true
    @State private var sourceKind: DownloadSourceKind
    @State private var requestContext: DownloadRequestContext?
    @State private var pageTitle: String?
    @State private var mimeType: String?
    @State private var backend: DownloadBackend
    @State private var pairAudioURL: URL?
    @State private var pairCID: String?
    @State private var categoryOverride: DownloadCategory?
    @State private var saveCategoryPath = false
    @State private var draftEstimatedSize: Int64?
    @State private var draftDuration: Double?
    /// Mirrors `DownloadDraft.sizeProbed`: the browser takeover hands over
    /// the download's real Content-Length, which the card labels as probed.
    @State private var draftSizeProbed = false
    @State private var resolvedOptions: [DownloadMediaOption] = []
    @State private var selectedOptionID: String?
    @State private var isInspectingResources = false
    /// True while a paired-DASH (m4s) candidate's Content-Lengths are being
    /// probed in the background; the media card shows "probing…" meanwhile.
    @State private var isProbingPairSize = false
    @State private var resourceMessage: String?
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @State private var filenameWasEdited = false
    /// 语义判断服务的仲裁结果（technical-spec §8.1）：高置信采纳后驱动建议
    /// 文件名，提交来源标注为 `.modelJudged`；用户编辑或改地址即作废。
    @State private var semanticDecision: SemanticTitleDecision?
    /// 语义判断服务的执行状态提示（technical-spec §8.1）：执行中 / 已执行
    /// 并采纳 / 已执行但弃权 / 执行失败 / 未执行，常驻确认窗口一行。
    @State private var semanticStatus: SemanticTitleStatus?
    @State private var semanticResolutionStarted = false
    // Monotonic token used to discard stale inspect results: every URL edit
    // bumps this, and an in-flight inspect Task only writes its results back
    // if the generation still matches. Without it, editing the address while
    // a probe is running lets the old URL's results overwrite the new state.
    @State private var inspectGeneration = 0
    @State private var contextLossWarning: String?
    /// Advanced options (site session) beneath the URL field.
    @State private var isAdvancedOptionsExpanded = false
    @State private var isCookiePastePresented = false

    /// The host of the URL currently typed, used to prefill the cookie
    /// paste sheet and to show whether a stored session covers the site.
    private var currentURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil, url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var currentHost: String? {
        currentURL?.host
    }

    init(draft: DownloadDraft? = nil) {
        initialDraft = draft
        let defaultDirectory =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        let draftURL = draft?.url
        let pathExtension = draftURL?.pathExtension ?? ""
        let outputExtension = Self.outputExtension(
            for: draft?.sourceKind ?? .http,
            pathExtension: pathExtension
        )
        let pathName = draftURL?.deletingPathExtension().lastPathComponent.removingPercentEncoding
            .map { "\($0).\(outputExtension)" }
        let draftHint = draft?.filenameHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedName: String
        if (draft?.filenameHintSource ?? .urlPath) != .urlPath,
            let hint = draftHint,
            !DownloadNaming.isGenericFilename(hint)
        {
            // Naming trust model (technical spec §8.1): a browser-resolved or
            // title-derived hint is authoritative and leads the proposal; a
            // URL-tail hint never outranks the page title.
            if URL(fileURLWithPath: hint).pathExtension.isEmpty {
                proposedName = hint + "." + outputExtension
            } else {
                proposedName = hint
            }
        } else if let title = draft?.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            if URL(fileURLWithPath: title).pathExtension.isEmpty {
                proposedName = title + "." + outputExtension
            } else {
                proposedName = title
            }
        } else if let hint = draftHint, !DownloadNaming.isGenericFilename(hint) {
            proposedName = hint
        } else {
            proposedName = (pathExtension.isEmpty ? nil : pathName) ?? "download"
        }
        _urlText = State(initialValue: draftURL?.absoluteString ?? "")
        _destinationDirectory = State(initialValue: defaultDirectory)
        _filename = State(initialValue: InputValidator.safeFilename(proposedName))
        _maximumParallelRequests = State(initialValue: 8)
        _sourceKind = State(initialValue: draft?.sourceKind ?? .http)
        _requestContext = State(initialValue: draft?.requestContext)
        _pageTitle = State(initialValue: draft?.pageTitle)
        _mimeType = State(initialValue: draft?.mimeType)
        _backend = State(initialValue: draft?.backend ?? .native)
        _pairAudioURL = State(initialValue: draft?.pairAudioURL)
        _pairCID = State(initialValue: draft?.pairCID)
        _draftEstimatedSize = State(initialValue: draft?.estimatedSize)
        _draftDuration = State(initialValue: draft?.duration)
        _draftSizeProbed = State(initialValue: draft?.sizeProbed ?? false)
        // Browser-resolved drafts are adopted synchronously here (not in
        // onAppear) so the hosting window measures the form WITH the resource
        // card and opens at the height that shows everything at once.
        if let draft,
            let adopted = Self.browserResolvedAdoption(for: draft, proposedFilename: proposedName)
        {
            _filename = State(initialValue: adopted.filename)
            _resolvedOptions = State(initialValue: [adopted.option])
            _selectedOptionID = State(initialValue: adopted.option.id)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ScrollView keeps the form's ideal height from fighting the
            // hosting window's fixed size: with many media options, the
            // media card and the advanced-options disclosure expanded, the
            // form outgrew the window and crashed AppKit's constraint
            // solver. Scrolling makes the content height unbounded-safe.
            ScrollView {
                // Wireframe layout: each concern lives in its own
                // hairline-outlined section card (FlatSectionCard), the
                // same flat line language as the task detail and settings
                // surfaces.
                VStack(alignment: .leading, spacing: 20) {
                    addressSection
                    resourceSection
                    optionsSection
                }
                .padding(24)
            }
            .background(LightScrollerConfigurator())
            footer
        }
        .frame(minWidth: 620, maxWidth: .infinity)
        // One button language for the whole confirmation surface: flat
        // hairline boxes by default, the prominent accent reserved for the
        // explicitly styled primary actions below.
        .buttonStyle(FlatHoverButtonStyle())
        .onChange(of: resolvedOptions) { _ in onLayoutChange?() }
        .onChange(of: isAdvancedOptionsExpanded) { _ in onLayoutChange?() }
        .onChange(of: validationMessage) { _ in onLayoutChange?() }
        .onChange(of: semanticStatus) { _ in onLayoutChange?() }
        .onAppear {
            destinationDirectory = model.settings.downloadDirectory
            maximumParallelRequests = model.settings.maximumParallelRequests
            startImmediately = model.settings.autoStartDownloads
            // Browser-resolved drafts were already adopted in init (their
            // metadata rides along from the extension); only bare manual
            // URLs still need a resource inspection here.
            if initialDraft?.url != nil, resolvedOptions.isEmpty, !isInspectingResources {
                inspectResources()
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .task {
            // 语义仲裁与资源探测互不阻塞：谁后到谁覆盖建议名（守卫见
            // hasUserOrSemanticName），确认窗口始终可立即操作。
            await resolveSemanticTitle()
        }
    }

    // MARK: - Address section

    private var addressSection: some View {
        FlatSectionCard("地址") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("地址", text: $urlText, prompt: Text("网页或媒体 URL；可一次粘贴多行链接批量创建"), axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(ClearInputFieldStyle())
                    .onSubmit {
                        inspectResources()
                    }
                    .onChange(of: urlText) { newValue in
                        inspectGeneration += 1
                        isInspectingResources = false
                        isProbingPairSize = false
                        resolvedOptions = []
                        selectedOptionID = nil
                        resourceMessage = nil
                        validationMessage = nil
                        // Warn the user that editing a URL handed over from
                        // the browser extension discards the login context
                        // and page title that came with it — without this,
                        // a one-character tweak silently drops the cookies/
                        // Referer and the download later 403s with no clue.
                        if requestContext != nil || pageTitle != nil {
                            contextLossWarning = String(
                                localized:
                                    "修改地址会丢失浏览器带来的登录状态与页面标题，可能导致需要登录的资源下载失败。如需修改，建议在 Chrome 中重新提交。"
                            )
                        } else {
                            contextLossWarning = nil
                        }
                        sourceKind = .http
                        requestContext = nil
                        pageTitle = nil
                        mimeType = nil
                        backend = .native
                        pairAudioURL = nil
                        pairCID = nil
                        semanticDecision = nil
                        // 候选标题随草稿作废：状态行改显「未执行」并注明
                        // 原因，既不静默也不残留过期结论（§8.1 五态提示）。
                        semanticStatus = .notInvoked(
                            reason: String(localized: "地址已修改，原候选标题已失效")
                        )
                        if !filenameWasEdited {
                            filename = "download"
                        }
                        updateFilenameIfAppropriate(from: newValue)
                    }

                // Advanced options: manual site-session entry for URLs that
                // need login but were not submitted through the extension.
                // Stored sessions are picked up automatically at start().
                // A custom disclosure instead of DisclosureGroup: on macOS the
                // group's label text is not clickable (only the chevron is),
                // and its indented content never aligns with the label text.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isAdvancedOptionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isAdvancedOptionsExpanded ? 90 : 0))
                        Text("高级选项")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .sheet(isPresented: $isCookiePastePresented) {
                    CookiePasteSheet(domain: currentHost ?? "")
                        .environmentObject(model)
                }
                if isAdvancedOptionsExpanded {
                    advancedOptionsCard
                }
            }
        }
    }

    /// Expanded advanced-options content in a self-contained card. The card
    /// sits flush with the label's leading edge (no disclosure indent) so
    /// the block reads as fully left-aligned with the rest of the form.
    private var advancedOptionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("粘贴站点 Cookie…") {
                    isCookiePastePresented = true
                }
                if let url = currentURL, let session = model.sessionStore.lookup(url: url) {
                    let host = url.host ?? ""
                    Text(
                        session.lastAuthFailureAt == nil
                            ? "已有 \(host) 的会话"
                            : "已有 \(host) 的会话（可能已过期）"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        session.lastAuthFailureAt == nil
                            ? Color.secondary : AppTheme.warning)
                }
            }
            Text("需要登录的站点：优先用 Chrome 插件提交（自动携带会话）；也可以在此粘贴 Cookie，保存后对该站点的下载自动生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Resource section

    private var resourceSection: some View {
        FlatSectionCard("资源") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        inspectResources()
                    } label: {
                        Label(
                            isInspectingResources ? "正在寻找…" : "寻找资源",
                            systemImage: isInspectingResources ? "hourglass" : "magnifyingglass"
                        )
                    }
                    .buttonStyle(FlatHoverButtonStyle(prominent: true))
                    .disabled(
                        isInspectingResources || isSubmitting
                            || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .pointerCursorOnHover(
                        isEnabled: !isInspectingResources && !isSubmitting
                            && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    if isInspectingResources {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !resolvedOptions.isEmpty {
                        Text("已找到 \(resolvedOptions.count) 个资源")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if resolvedOptions.count > 1 {
                    // The section title already reads "Resources"; the
                    // picker stays label-hidden beneath it.
                    Picker("资源", selection: selectedOptionBinding) {
                        ForEach(resolvedOptions) { option in
                            Text("\(option.label) · \(option.filename)")
                                .tag(Optional(option.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pointerCursorOnHover()
                    .onChange(of: selectedOptionID) { _ in
                        updateSelectionDetails()
                    }
                }

                if let option = selectedMediaOption {
                    mediaCard(for: option)
                }
            }
        }
    }

    /// The resource at a glance: category icon, format tile, size and the
    /// metadata slots that belong to the category. Audio/video show duration
    /// and codec; applications show a platform note; everything else keeps
    /// the second line for its category name. Missing values are omitted
    /// instead of rendering "unknown" placeholders. Deliberately borderless:
    /// the section card already draws the outer frame, and a second stroke
    /// read as a "box in a box" — the content aligns with the button row.
    private func mediaCard(for option: DownloadMediaOption) -> some View {
        let displaySize = option.estimatedSize ?? draftEstimatedSize
        let displayDuration = option.duration ?? draftDuration
        let formatTag = mediaFormatTag(for: option)
        let category =
            categoryOverride
            ?? DownloadCategory(filename: option.filename, mimeType: mimeType)
        // HLS/DASH sizes can only be estimated from bitrate × duration; the
        // YouTube extractor reports filesize_approx. Always add the "approx."
        // prefix so users never mistake the hint for an exact size; a
        // Content-Length probe result (sizeProbed / totalBytes relayed by the
        // browser takeover) is a real value and displays as-is.
        let isEstimatedSize =
            displaySize != nil && !option.sizeProbed && !draftSizeProbed
            && (option.sourceKind == .hls || option.sourceKind == .dash
                || option.backend == .youtubeExtractor)
        let sizeLabel: String
        if let displaySize {
            sizeLabel =
                isEstimatedSize
                ? String(localized: "约 \(DisplayFormatting.byteCount(displaySize))")
                : DisplayFormatting.byteCount(displaySize)
        } else if isProbingPairSize {
            // A paired-DASH probe is in flight: tell the user a size may
            // appear within seconds without any action on their part.
            sizeLabel = String(localized: "探测中…")
        } else {
            sizeLabel = String(localized: "大小未知")
        }
        return HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                if let formatTag {
                    Text(formatTag)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sizeLabel)
                        .font(.headline)
                    Text(option.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let secondLine = mediaCardSecondLine(
                    category: category, duration: displayDuration, encoding: option.encoding
                )
                if !secondLine.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(secondLine.indices, id: \.self) { index in
                            if index > 0 { Text("·") }
                            Text(secondLine[index]).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The category-specific metadata slots beneath the size. Duration only
    /// belongs to audio and video — a plain file takeover (zip, pdf, image…)
    /// must never render "unknown duration".
    private func mediaCardSecondLine(
        category: DownloadCategory, duration: Double?, encoding: String?
    ) -> [String] {
        switch category {
        case .audio, .video:
            var slots: [String] = []
            if let duration { slots.append(String(localized: "时长 \(DisplayFormatting.duration(duration))")) }
            if let encoding, !encoding.isEmpty { slots.append(encoding) }
            return slots
        case .application:
            // The platform note derives from the file extension; fall back to
            // the category name when no platform is recognized.
            if let note = platformNote(for: optionExtension) {
                return [note]
            }
            return [category.title]
        default:
            return [category.title]
        }
    }

    /// The extension of the file currently shown in the card, derived from
    /// the editable filename so the platform note follows user renames.
    private var optionExtension: String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ext.isEmpty
            ? (selectedMediaOption?.filename.split(separator: ".").last.map { String($0).lowercased() } ?? "")
            : ext
    }

    private func platformNote(for ext: String) -> String? {
        switch ext {
        case "dmg", "pkg", "app": return String(localized: "macOS 安装包")
        case "exe", "msi": return String(localized: "Windows 程序")
        case "apk", "aab", "xapk": return String(localized: "Android 应用")
        case "deb", "rpm": return String(localized: "Linux 软件包")
        default: return nil
        }
    }

    // MARK: - Options section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlatSectionCard("下载选项") {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            fieldLabel("分类")
                            Picker("分类", selection: categoryBinding) {
                                Text("自动判断").tag(DownloadCategory?.none)
                                ForEach(DownloadCategory.allCases, id: \.self) { category in
                                    Text(category.title).tag(DownloadCategory?.some(category))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pointerCursorOnHover()
                        }
                        GridRow {
                            fieldLabel("保存至")
                            HStack(spacing: 8) {
                                Text(destinationDirectory)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("选择…", action: chooseDirectory)
                            }
                        }
                        GridRow {
                            fieldLabel("文件名")
                            TextField("文件名", text: filenameBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            fieldLabel("最大并行请求数")
                            Stepper(value: $maximumParallelRequests, in: 1...64) {
                                Text("\(maximumParallelRequests)")
                                    .monospacedDigit()
                            }
                            .pointerCursorOnHover()
                        }
                        GridRow {
                            fieldLabel("队列优先级")
                            Picker("队列优先级", selection: $priority) {
                                Text("高").tag(1)
                                Text("普通").tag(0)
                                Text("低").tag(-1)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pointerCursorOnHover()
                        }
                        GridRow {
                            fieldLabel("预期 SHA-256")
                            TextField("预期 SHA-256", text: $expectedSHA256, prompt: Text("可选"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if categoryOverride != nil {
                        Toggle("将此路径用于该分类", isOn: $saveCategoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .pointerCursorOnHover()
                    }

                    Toggle("立即开始下载", isOn: $startImmediately)
                        .font(.callout)
                        .pointerCursorOnHover()
                }
            }

            // Semantic-status message sits below the card instead of the
            // fixed footer, so it never competes with the window height and
            // can wrap to multiple lines without clipping the options card.
            // The semantic-judgment status keeps its own row (never rides on
            // resourceMessage) so every execution state stays visible.
            if let semanticStatus {
                semanticStatusRow(semanticStatus)
            }
            if let resourceMessage {
                Label(resourceMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 语义判断服务的执行状态行（technical-spec §8.1）：五态各一行，图标与
    /// 色调区分执行中 / 采纳 / 弃权 / 失败 / 未执行，均不阻塞确认窗口。
    @ViewBuilder
    private func semanticStatusRow(_ status: SemanticTitleStatus) -> some View {
        switch status {
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("语义判断服务执行中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .adopted(let confidence):
            semanticStatusLine(
                String(
                    localized:
                        "语义判断服务已执行：已采纳模型返回的标题（置信度 \(Self.percentText(confidence))）。"
                ),
                systemImage: "sparkles",
                color: AppTheme.success
            )
        case .abstained:
            semanticStatusLine(
                String(localized: "语义判断服务已执行：模型未给出可采纳的标题，已沿用常规命名。"),
                systemImage: "info.circle",
                color: .secondary
            )
        case .failed(let detail):
            semanticStatusLine(
                String(localized: "语义判断服务执行失败（\(detail)），已沿用常规命名。"),
                systemImage: "exclamationmark.triangle.fill",
                color: AppTheme.danger
            )
        case .notInvoked(let reason):
            semanticStatusLine(
                String(localized: "语义判断服务未执行：\(reason)。"),
                systemImage: "slash.circle",
                color: .secondary
            )
        }
    }

    private func semanticStatusLine(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func percentText(_ confidence: Double) -> String {
        "\(Int((confidence * 100).rounded()))%"
    }

    // MARK: - Footer

    /// Fixed footer: transient warnings and the action buttons stay pinned
    /// to the window's bottom edge, so the buttons never float mid-window
    /// when the form above is short.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if validationMessage != nil || contextLossWarning != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let validationMessage {
                        HStack(alignment: .top, spacing: 12) {
                            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(AppTheme.danger)
                            Spacer()
                            if fallbackURL != nil {
                                Button("按普通文件下载") {
                                    useDirectURLFallback()
                                }
                                .disabled(isSubmitting || isInspectingResources)
                            }
                        }
                    }

                    if let contextLossWarning {
                        Label(contextLossWarning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.warning)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
            }

            // The divider spans the dialog's full width, unaffected by content
            // padding.
            Divider()

            HStack(alignment: .bottom) {
                Spacer()
                // Browser-takeover confirmations offer a secondary, non-button
                // text action to hand the paused download back to the browser;
                // the primary "取消" now also cancels the browser download.
                // Underlined and bottom-aligned with the buttons; hover lifts
                // it to the brand accent like other flat affordances.
                if isBrowserTakeoverDraft {
                    Button {
                        handBackToBrowser()
                    } label: {
                        Text("改为浏览器直接下载")
                            .font(.callout)
                            .underline()
                            .foregroundStyle(isHandBackHovering ? AppTheme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHandBackHovering = $0 }
                    .pointerCursorOnHover()
                    .disabled(isSubmitting)
                }
                Button("取消") { cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(startImmediately ? "开始下载" : "加入列表") {
                    submit()
                }
                .buttonStyle(FlatHoverButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || resolvedOptions.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// Closes the containing presentation: sheet dismiss for the main-window
    /// flow, injected window close for standalone confirmation windows.
    private func closeView() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// True when this confirmation was opened by a browser takeover, i.e. there
    /// is a paused browser download whose fate the dismissal decides.
    private var isBrowserTakeoverDraft: Bool {
        initialDraft?.takeoverDraftID != nil
    }

    /// Default dismissal: do not take over AND cancel the paused browser
    /// download, so nothing keeps downloading anywhere.
    private func cancelConfirmation() {
        if isBrowserTakeoverDraft {
            model.rememberInteractiveCancelOutcome(
                cancelBrowser: true, for: initialDraft?.takeoverDraftID
            )
        }
        closeView()
    }

    /// Secondary dismissal: do not take over, but let the browser resume and
    /// finish the download it already started.
    private func handBackToBrowser() {
        model.rememberInteractiveCancelOutcome(
            cancelBrowser: false, for: initialDraft?.takeoverDraftID
        )
        closeView()
    }

    private var selectedOptionBinding: Binding<String?> {
        Binding(
            get: { selectedOptionID ?? resolvedOptions.first?.id },
            set: { selectedOptionID = $0 }
        )
    }

    private var selectedMediaOption: DownloadMediaOption? {
        resolvedOptions.first(where: { $0.id == selectedOptionID }) ?? resolvedOptions.first
    }

    private var categoryBinding: Binding<DownloadCategory?> {
        Binding(
            get: { categoryOverride },
            set: { categoryOverride = $0 }
        )
    }

    private var filenameBinding: Binding<String> {
        Binding(
            get: { filename },
            set: {
                filenameWasEdited = true
                filename = $0
            }
        )
    }

    private var fallbackURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else { return nil }
        return url
    }

    /// True when a draft already carries enough browser-provided metadata to
    /// skip a second network probe: the browser saw the real response
    /// headers, so re-probing only adds latency. Bare drafts from manual URL
    /// entry, the clipboard and task re-submission carry none of these
    /// signals and still get inspected. HLS/DASH manifests are excluded —
    /// their variant lists genuinely need parsing.
    private static func isBrowserResolvedDraft(_ draft: DownloadDraft) -> Bool {
        if draft.backend == .youtubeExtractor { return true }
        return draft.sourceKind == .http
            && (draft.filenameHint != nil || draft.mimeType != nil || draft.estimatedSize != nil)
    }

    private struct BrowserResolvedAdoption {
        let option: DownloadMediaOption
        let filename: String
    }

    /// Builds the submittable option for a browser-resolved draft without any
    /// network probe: YouTube variants were picked in the page overlay and
    /// direct files were already identified by the browser download itself.
    /// Returns nil for drafts that still need inspection.
    private static func browserResolvedAdoption(
        for draft: DownloadDraft, proposedFilename: String
    ) -> BrowserResolvedAdoption? {
        guard isBrowserResolvedDraft(draft) else { return nil }
        // Only an authoritative hint (browser-resolved download name or a
        // title-derived synthesized name) may replace the init-computed
        // proposal. A URL-tail hint from a sniffed candidate ("407788-1080p
        // .mp4") carries no authority: the page title the user recognized in
        // the sniff panel stays the proposed filename (technical spec §8.1).
        var adoptedFilename = InputValidator.safeFilename(proposedFilename)
        if draft.backend != .youtubeExtractor,
            draft.filenameHintSource != .urlPath,
            let hint = draft.filenameHint?.trimmingCharacters(in: .whitespacesAndNewlines),
            !DownloadNaming.isGenericFilename(hint)
        {
            adoptedFilename = InputValidator.safeFilename(hint)
        }
        // Hints can lack a real extension entirely (GitHub codeload zips are
        // named after the tag, signed blob URLs end in a UUID): prefer the
        // filename a response-content-disposition query parameter carries,
        // then complete the name from the MIME the browser reported.
        let adoptedExt = URL(fileURLWithPath: adoptedFilename).pathExtension.lowercased()
        if !DownloadNaming.isRealFileExtension(adoptedExt) {
            let cdName = DownloadNaming.filenameFromContentDispositionQuery(of: draft.url)
            if let cdName,
                DownloadNaming.isRealFileExtension(URL(fileURLWithPath: cdName).pathExtension.lowercased())
            {
                adoptedFilename = cdName
            } else if let mimeExtension = DownloadNaming.fileExtensionForMIMEType(draft.mimeType) {
                adoptedFilename = InputValidator.safeFilename(adoptedFilename + "." + mimeExtension)
            }
        }
        // Product contract (technical-spec §3.4): YouTube uniformly outputs
        // MP4 in the end; neither the source variant's container nor any other
        // container suffix carried by the title may become the final filename.
        if draft.backend == .youtubeExtractor {
            let stem = URL(fileURLWithPath: adoptedFilename).deletingPathExtension()
                .lastPathComponent
            adoptedFilename = InputValidator.safeFilename(stem + ".mp4")
        }
        let option = DownloadMediaOption(
            url: draft.url,
            sourceKind: draft.sourceKind,
            filename: adoptedFilename,
            label: draft.backend == .youtubeExtractor
                ? draftedYouTubeLabel(for: draft)
                : String(localized: "直链"),
            requestContext: draft.requestContext,
            pairAudioURL: draft.pairAudioURL,
            pairCID: draft.pairCID,
            backend: draft.backend,
            estimatedSize: draft.estimatedSize,
            duration: draft.duration,
            sizeProbed: draft.sizeProbed
        )
        return BrowserResolvedAdoption(
            option: option,
            filename: adoptedFilename
        )
    }

    /// Reads the resolution the user picked in the browser overlay back out
    /// of the "#height=N" fragment so the card can show which variant the
    /// submission refers to.
    private static func draftedYouTubeLabel(for draft: DownloadDraft) -> String {
        if let fragment = draft.url.fragment, fragment.hasPrefix("height="),
            let height = Int(fragment.dropFirst("height=".count)), height > 0
        {
            return String(localized: "YouTube 视频 · \(height)p")
        }
        return String(localized: "YouTube 视频")
    }

    private func useDirectURLFallback() {
        guard let url = fallbackURL else { return }
        let fallbackName: String
        if filenameWasEdited, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallbackName = InputValidator.safeFilename(filename)
        } else {
            let pathName = url.lastPathComponent.removingPercentEncoding
            fallbackName = InputValidator.safeFilename(
                pathName.flatMap { $0.isEmpty ? nil : $0 } ?? "download"
            )
        }
        let option = DownloadMediaOption(
            url: url,
            sourceKind: .http,
            filename: fallbackName,
            label: String(localized: "普通文件")
        )
        resolvedOptions = [option]
        selectedOptionID = option.id
        sourceKind = .http
        if !hasUserOrSemanticName { filename = option.filename }
        validationMessage = nil
        resourceMessage = String(
            localized: "已选择普通文件下载；如果地址实际是网页，下载结果可能是 HTML。"
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destinationDirectory)
        if panel.runModal() == .OK, let selected = panel.url {
            destinationDirectory = selected.path
        }
    }

    /// 语义标题已采纳时与用户编辑同权：变体切换/重探测/地址编辑不得覆盖它
    /// （technical-spec §8.1；用户编辑仍永远最高优先）。
    private var hasUserOrSemanticName: Bool {
        filenameWasEdited || semanticDecision != nil
    }

    private func resolveSemanticTitle() async {
        guard !semanticResolutionStarted, semanticDecision == nil else { return }
        semanticResolutionStarted = true
        // 未执行同样要给出状态（technical-spec §8.1 五态提示）：无草稿候选、
        // 服务未启用分别注明原因，不再静默无提示。
        guard let draft = initialDraft else {
            semanticStatus = .notInvoked(reason: String(localized: "没有可仲裁的候选标题"))
            return
        }
        guard model.settings.semanticTitleEnabled else {
            semanticStatus = .notInvoked(reason: String(localized: "服务未启用"))
            return
        }
        guard !draft.titleCandidates.isEmpty else {
            semanticStatus = .notInvoked(reason: String(localized: "没有可仲裁的候选标题"))
            return
        }
        let context = SemanticTitleContext(
            cacheKey: draft.url.absoluteString,
            pageHost: draft.url.host,
            pageTitle: draft.pageTitle,
            candidates: draft.titleCandidates
        )
        semanticStatus = .running
        let attempt = await model.semanticTitleService.resolveTitle(context: context)
        // 仲裁期间用户已手改文件名：结果作废，避免覆盖用户输入。
        guard !filenameWasEdited else {
            semanticStatus = .notInvoked(reason: String(localized: "用户已手动命名，仲裁结果未使用"))
            return
        }
        switch attempt.resolution {
        case .adopted:
            guard let decision = attempt.decision else {
                semanticStatus = .abstained
                return
            }
            let outputExtension = Self.outputExtension(
                for: sourceKind,
                pathExtension: URL(fileURLWithPath: decision.title).pathExtension
            )
            var name = decision.title
            if URL(fileURLWithPath: name).pathExtension.isEmpty {
                name = name + "." + outputExtension
            }
            filename = InputValidator.safeFilename(name)
            semanticDecision = decision
            semanticStatus = .adopted(confidence: decision.confidence)
        case .abstained:
            // 模型弃权（none/低置信等）属正常行为：沿用常规命名，状态行说明。
            semanticStatus = .abstained
        case .failed:
            // 服务调用失败（配置/HTTP/网络）：提示一句并可继续手动下载。
            semanticStatus = .failed(attempt.failure ?? String(localized: "未知原因"))
        }
        onLayoutChange?()
    }

    private func updateFilenameIfAppropriate(from value: String) {
        guard !filenameWasEdited,
            DownloadNaming.isGenericFilename(filename),
            let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            !url.pathExtension.isEmpty,
            !url.lastPathComponent.isEmpty
        else { return }
        let outputExtension = Self.outputExtension(
            for: sourceKind,
            pathExtension: url.pathExtension
        )
        let base =
            url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.lastPathComponent
        filename = InputValidator.safeFilename(base + "." + outputExtension)
    }

    private func updateSelectionDetails() {
        guard let selectedOptionID,
            let option = resolvedOptions.first(where: { $0.id == selectedOptionID })
        else { return }
        if !hasUserOrSemanticName {
            filename = option.filename
        }
        sourceKind = option.sourceKind
        if let optionContext = option.requestContext {
            requestContext = optionContext
        }
    }

    private func inspectResources() {
        guard !isInspectingResources, !isSubmitting else { return }
        let enteredURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredURL.isEmpty else { return }

        inspectGeneration += 1
        let generation = inspectGeneration
        resolvedOptions = []
        selectedOptionID = nil
        resourceMessage = nil
        validationMessage = nil
        isInspectingResources = true

        // A paired candidate is already a complete user choice: the video
        // and audio URLs are transient track URLs (Bilibili m4s) or a variant
        // media playlist plus its EXT-X-MEDIA audio rendition (X/HLS).
        // Re-running the generic inspector against them would reject the
        // confirmation sheet before the pair reaches the App — and for HLS it
        // would silently drop the audio track (a media playlist inspects to a
        // single variant without the pair).
        if (sourceKind == .dash || sourceKind == .hls), let pairAudioURL {
            let option = DownloadMediaOption(
                url: URL(string: enteredURL) ?? pairAudioURL,
                sourceKind: sourceKind,
                filename: InputValidator.safeFilename(filename),
                label: sourceKind == .hls
                    ? String(localized: "HLS 音视频")
                    : String(localized: "DASH 音视频"),
                pairAudioURL: pairAudioURL,
                pairCID: pairCID
            )
            resolvedOptions = [option]
            selectedOptionID = option.id
            isInspectingResources = false
            // 资源提示与语义判断状态行并列显示，互不覆盖（§8.1）。
            resourceMessage = String(localized: "已识别音视频，将在下载时自动合并为 MP4。")
            // HLS 的输入是媒体清单：HEAD 只能拿到清单文本大小（几 KB），不是
            // 媒体尺寸。这条提交扩展已随候选上报解析后的估算大小
            // （draft.estimatedSize），直接沿用；DASH m4s 直链仍需探测。
            if sourceKind == .dash {
                probePairSize(videoURL: option.url, audioURL: pairAudioURL, generation: generation)
            } else if let estimated = draftEstimatedSize, estimated > 0 {
                resolvedOptions = [option.withProbedSize(estimated)]
            }
            return
        }

        // Preserve the draft's original hint so re-inspection (Bilibili
        // playurl resolve, HLS parse) names options consistently with what
        // the extension's FAB/popup already showed the user. A manual edit
        // or an adopted semantic title outranks it (technical spec §8.1).
        let filenameHint =
            hasUserOrSemanticName
            ? filename : initialDraft?.filenameHint
        let hintSource: FilenameHintSource =
            filenameWasEdited
            ? .userEdited
            : (semanticDecision != nil
                ? .modelJudged : (initialDraft?.filenameHintSource ?? .urlPath))
        let title = pageTitle
        let context = requestContext
        let declaredMimeType = mimeType
        Task { @MainActor in
            defer {
                if generation == inspectGeneration {
                    isInspectingResources = false
                }
            }
            do {
                let options = try await model.resolveDownloadOptions(
                    urlString: enteredURL,
                    filenameHint: filenameHint,
                    // A name the user typed outranks every automatic source;
                    // re-inspection must not silently revert it to the title.
                    filenameHintSource: hintSource,
                    sourceKind: sourceKind,
                    requestContext: context,
                    pageTitle: title,
                    mimeType: declaredMimeType
                )
                // Discard results from a probe for a URL the user has since
                // edited away from — otherwise the old URL's options overwrite
                // the current state and get submitted by mistake.
                guard generation == inspectGeneration else { return }
                guard !options.isEmpty else {
                    throw WebPageMediaDiscoveryError.noCandidates
                }
                resolvedOptions = options
                selectedOptionID = options[0].id
                sourceKind = options[0].sourceKind
                backend = options[0].backend
                if let optionContext = options[0].requestContext {
                    requestContext = optionContext
                }
                if !hasUserOrSemanticName {
                    filename = options[0].filename
                }
                // 单资源不再提示「资源已找到」——按钮行已显示「已找到 N 个资源」，
                // 复述没有信息量；多资源时说明列表是画质/格式变体，需要用户选择。
                if options.count > 1 {
                    resourceMessage = String(localized: "已找到多个资源，请选择要下载的画质或格式。")
                }
            } catch {
                guard generation == inspectGeneration else { return }
                validationMessage = error.localizedDescription
            }
        }
    }

    /// Paired m4s tracks have no manifest to estimate size from, so probe
    /// both Content-Lengths directly and show their sum. Runs entirely in
    /// the background: the user can submit before it finishes, and a probe
    /// failure simply leaves "size unknown" in place. Both tracks must answer —
    /// a video-only sum would understate the final merged file.
    private func probePairSize(videoURL: URL, audioURL: URL, generation: Int) {
        isProbingPairSize = true
        let context = requestContext
        Task { @MainActor in
            async let videoSize = MediaSizeProbe.probe(videoURL, context: context)
            async let audioSize = MediaSizeProbe.probe(audioURL, context: context)
            let (video, audio) = await (videoSize, audioSize)
            // Discard results for a URL the user has since edited away.
            guard generation == inspectGeneration else { return }
            isProbingPairSize = false
            guard let video, let audio else { return }
            guard let index = resolvedOptions.firstIndex(where: { $0.id == selectedOptionID })
            else { return }
            resolvedOptions[index] = resolvedOptions[index].withProbedSize(video + audio)
        }
    }

    /// Addresses split across lines/whitespace. nil means the field holds a
    /// single address (the normal resource-inspection flow); an empty array
    /// means bulk text was pasted but at least one token is not a valid
    /// HTTP(S) URL, so the caller can explain instead of failing opaquely.
    var pastedBatchAddresses: [URL]? {
        let tokens =
            urlText
            .split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard tokens.count > 1 else { return nil }
        var urls: [URL] = []
        var seen = Set<String>()
        for token in tokens {
            guard let url = URL(string: token),
                url.scheme == "http" || url.scheme == "https",
                url.host != nil
            else { return [] }
            // The same link pasted twice is one download, not two.
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    /// Source kind and file name for one batch address. HLS/DASH manifests
    /// must run through the stream pipeline (a plain HTTP download would
    /// save the playlist text) and publish as MP4. Pure, so `nonisolated`:
    /// the view is main-actor isolated, and tests call this synchronously.
    nonisolated static func batchPlan(for url: URL) -> (sourceKind: DownloadSourceKind, filename: String) {
        let rawName = url.lastPathComponent
        let safeName = InputValidator.safeFilename(rawName.isEmpty ? nil : rawName)
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u":
            return (.hls, DownloadNaming.replacingExtension(of: safeName, with: "mp4"))
        case "mpd":
            return (.dash, DownloadNaming.replacingExtension(of: safeName, with: "mp4"))
        default:
            return (.http, safeName)
        }
    }

    /// Bulk creation for a multi-line paste: every address becomes one task
    /// with the window's current destination, parallelism and start mode.
    /// No per-URL resource inspection or semantic naming — a paste of many
    /// links is a list of direct files, and naming falls back to each URL's
    /// own filename.
    private func submitBatch(_ urls: [URL]) {
        guard !isSubmitting else { return }
        validationMessage = nil
        isSubmitting = true
        let clickDate = Date()
        Task { @MainActor in
            defer { isSubmitting = false }
            for (position, url) in urls.enumerated() {
                let plan = Self.batchPlan(for: url)
                let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
                    .appendingPathComponent(plan.filename)
                do {
                    try model.addDownload(
                        urlString: url.absoluteString,
                        destination: destination,
                        maximumParallelRequests: maximumParallelRequests,
                        expectedSHA256: nil,
                        startImmediately: startImmediately,
                        sourceKind: plan.sourceKind,
                        automaticRename: true,
                        priority: priority,
                        selectionIntent: clickDate
                    )
                } catch {
                    // Keep only the addresses that were not created, so a
                    // second submit cannot duplicate the ones that were.
                    urlText = urls[position...].map(\.absoluteString).joined(separator: "\n")
                    validationMessage = String(
                        localized: "已创建 \(position) 个；「\(plan.filename)」失败：\(error.localizedDescription)。地址栏只保留未创建的链接。"
                    )
                    return
                }
            }
            onSubmitSuccess?()
            closeView()
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        if let batch = pastedBatchAddresses {
            if batch.isEmpty {
                validationMessage = String(
                    localized: "检测到多行批量地址，但其中至少一行不是有效的 http(s) 链接；请逐行检查后重试。"
                )
                return
            }
            submitBatch(batch)
            return
        }
        guard
            let selectedOption = resolvedOptions.first(where: { $0.id == selectedOptionID })
                ?? resolvedOptions.first
        else {
            validationMessage = String(
                localized: "请先点击“寻找资源”，确认资源后再开始下载。"
            )
            return
        }
        validationMessage = nil
        isSubmitting = true
        let enteredFilename = filename
        // Captured at click time (not inside the deferred task) so the model
        // can tell whether the user moved their table selection afterwards;
        // a late auto-select must never steal focus back to the new task.
        let clickDate = Date()
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let finalFilename =
                    filenameWasEdited || semanticDecision != nil
                    ? enteredFilename : selectedOption.filename
                let safeName = InputValidator.safeFilename(finalFilename)
                guard safeName == finalFilename, !finalFilename.isEmpty else {
                    throw NewDownloadValidationError.invalidFilename
                }
                let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
                    .appendingPathComponent(safeName)
                if saveCategoryPath, let category = categoryOverride {
                    model.settings.categoryPaths[category.rawValue] = destinationDirectory
                }
                try model.addDownload(
                    urlString: selectedOption.url.absoluteString,
                    destination: destination,
                    maximumParallelRequests: maximumParallelRequests,
                    expectedSHA256: expectedSHA256,
                    startImmediately: startImmediately,
                    sourceKind: selectedOption.sourceKind,
                    requestContext: requestContext,
                    // Conflicting names always get a " (N)" suffix instead of
                    // an error — even when the user edited the filename — so
                    // a submission never fails just because the name is taken.
                    automaticRename: true,
                    pairAudioURL: selectedOption.pairAudioURL,
                    pairCID: selectedOption.pairCID,
                    backend: selectedOption.backend,
                    priority: priority,
                    estimatedSize: selectedOption.estimatedSize ?? draftEstimatedSize,
                    mediaDuration: selectedOption.duration ?? draftDuration,
                    categoryOverride: categoryOverride,
                    mimeType: mimeType,
                    selectionIntent: clickDate,
                    takeoverDraftID: initialDraft?.takeoverDraftID
                )
                onSubmitSuccess?()
                closeView()
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func mediaFormatTag(for option: DownloadMediaOption) -> String? {
        switch option.sourceKind {
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .http:
            if option.backend == .youtubeExtractor { return "MP4" }
            let ext = option.filename.split(separator: ".").last.map(String.init) ?? ""
            // A version-number tail (the "95" of "v0.8.95") is not a format:
            // only a real file extension is shown as the tag; otherwise the
            // tile keeps just the category icon.
            guard DownloadNaming.isRealFileExtension(ext.lowercased()) else { return nil }
            return ext.uppercased()
        }
    }

    /// Ordinary files keep the URL's own extension (AppImage, apk, zip…);
    /// only extension-less addresses fall back to mp4 — that fallback was
    /// originally meant for extension-less media streams. HLS/DASH manifests
    /// are uniformly remuxed to MP4 by the earlier branch. The predicate is
    /// shared with AppModel so domain suffixes (.io, .tv) are not mistaken
    /// for extensions.
    private static func outputExtension(
        for sourceKind: DownloadSourceKind,
        pathExtension: String
    ) -> String {
        let lowered = pathExtension.lowercased()
        if sourceKind == .hls || sourceKind == .dash
            || ["m3u8", "mpd"].contains(lowered)
        {
            return "mp4"
        }
        return DownloadNaming.isRealFileExtension(lowered) ? lowered : "mp4"
    }
}

/// 确认窗口的语义判断执行状态（technical-spec §8.1）：五态各渲染一行，
/// 不阻塞确认；`notInvoked` 携带未执行原因。
private enum SemanticTitleStatus: Equatable {
    case running
    case adopted(confidence: Double)
    case abstained
    case failed(String)
    case notInvoked(reason: String)
}

/// Input style with an explicit outline: the system `.roundedBorder` is too
/// faint against the form background in light mode. Paints a solid field
/// background and a visible border that adapt to both appearances.
private struct ClearInputFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
            )
    }
}

private enum NewDownloadValidationError: LocalizedError {
    case invalidFilename

    var errorDescription: String? {
        String(localized: "文件名不能为空，且不能包含路径或控制字符。")
    }
}
