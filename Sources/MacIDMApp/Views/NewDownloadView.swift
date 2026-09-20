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
            _resourceMessage = State(initialValue: adopted.message)
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
    }

    // MARK: - Address section

    private var addressSection: some View {
        FlatSectionCard("地址") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("地址", text: $urlText, prompt: Text("网页或媒体 URL"))
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
    /// instead of rendering "unknown" placeholders.
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
        return HStack(spacing: 14) {
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
                HStack(spacing: 8) {
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
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
                                .textFieldStyle(ClearInputFieldStyle())
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
                                .textFieldStyle(ClearInputFieldStyle())
                        }
                    }

                    if categoryOverride != nil {
                        Toggle("将此路径用于该分类", isOn: $saveCategoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .pointerCursorOnHover()
                    }

                    if let formatConversion = formatConversionDescription {
                        Text(formatConversion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("立即开始下载", isOn: $startImmediately)
                        .font(.callout)
                        .pointerCursorOnHover()
                }
            }

            // Resource-status message sits below the card instead of the
            // fixed footer, so it never competes with the window height and
            // can wrap to multiple lines without clipping the options card.
            if let resourceMessage {
                Label(resourceMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AppTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    /// Explains the format conversion that FFmpeg performs so the user
    /// understands why an HLS (.ts segments) or DASH (.m4s segments) download
    /// ends up as .mp4. Returns nil for HTTP direct downloads where no
    /// container conversion takes place.
    private var formatConversionDescription: String? {
        // YouTube product contract (technical-spec §3.4): the UI picks a
        // quality/codec variant, and yt-dlp + FFmpeg uniformly outputs MP4 in
        // the end; the source variant's container (e.g. VP9's WebM) is not the
        // output container.
        if backend == .youtubeExtractor {
            return String(localized: "源格式: 依所选清晰度/编码 → 输出格式: MP4（FFmpeg 重封装）")
        }
        switch sourceKind {
        case .hls:
            return String(localized: "原始格式: MPEG-TS → 输出格式: MP4（FFmpeg 重封装）")
        case .dash:
            return String(localized: "原始格式: WebM → 输出格式: MP4（FFmpeg 合并）")
        case .http:
            return nil
        }
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
        let message: String
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
            filename: adoptedFilename,
            message: String(localized: "资源信息已由浏览器提供，无需再次探测，确认保存位置和文件名后即可下载。")
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
        if !filenameWasEdited { filename = option.filename }
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
        if !filenameWasEdited {
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
        // the extension's FAB/popup already showed the user. Only a manual
        // edit outranks it.
        let filenameHint = filenameWasEdited ? filename : initialDraft?.filenameHint
        let hintSource: FilenameHintSource =
            filenameWasEdited
            ? .userEdited : (initialDraft?.filenameHintSource ?? .urlPath)
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
                if !filenameWasEdited {
                    filename = options[0].filename
                }
                resourceMessage =
                    options.count > 1
                    ? String(localized: "已找到多个资源，请选择要下载的画质或格式。")
                    : String(localized: "资源已找到，请确认保存位置和文件名。")
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

    private func submit() {
        guard !isSubmitting else { return }
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
                let finalFilename = filenameWasEdited ? enteredFilename : selectedOption.filename
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
