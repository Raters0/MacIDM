import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// In-app log viewer that displays the last 500 lines from the AppLogger log
/// file with level and category filtering, export, and clear functionality.
struct LogViewerView: View {
    @State private var logText: String = ""
    @State private var levelFilter: LevelFilter = .all
    @State private var categoryFilter: CategoryFilter = .all
    @State private var searchText: String = ""
    @State private var showingClearConfirmation = false
    /// Keeps the view pinned to the newest entry while logs stream in; the
    /// "jump to bottom" button re-enables it after the user scrolled up to read.
    @State private var autoFollow = true

    private static let bottomAnchorID = "log-bottom-anchor"

    private enum LevelFilter: String, CaseIterable, Hashable {
        case all
        case info
        case warning
        case error

        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .info: String(localized: "信息")
            case .warning: String(localized: "警告")
            case .error: String(localized: "错误")
            }
        }
    }

    private enum CategoryFilter: String, CaseIterable, Hashable {
        case all
        case download
        case engine
        case bridge
        case browser
        case youtube
        case bilibili
        case ui
        case system

        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .download: String(localized: "下载")
            case .engine: String(localized: "引擎")
            case .bridge: String(localized: "桥接")
            case .browser: String(localized: "浏览器")
            case .youtube: "YouTube"
            case .bilibili: "Bilibili"
            case .ui: String(localized: "界面")
            case .system: String(localized: "系统")
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                filterBar(proxy: proxy)
                Divider()
                logContent
            }
            .onAppear {
                refreshLog()
                scrollToBottom(proxy: proxy)
            }
            .onReceive(
                Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            ) { _ in
                refreshLog()
                if autoFollow {
                    scrollToBottom(proxy: proxy)
                }
            }
            .alert("清除日志", isPresented: $showingClearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    AppLogger.shared.clearLog()
                    refreshLog()
                }
            } message: {
                Text("此操作将清空所有日志记录，不可撤销。")
            }
        }
    }

    /// Scrolls after the next layout pass so freshly appended lines are
    /// already part of the scroll content when the jump happens.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(nil) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    // MARK: - Filter bar

    private func filterBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("级别")
                    .fixedSize()
                Picker("", selection: $levelFilter) {
                    ForEach(LevelFilter.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
                .pointerCursorOnHover()
            }

            HStack(spacing: 6) {
                Text("分类")
                    .fixedSize()
                Picker("", selection: $categoryFilter) {
                    ForEach(CategoryFilter.allCases, id: \.self) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .pointerCursorOnHover()
            }

            logSearchField

            if !searchText.isEmpty {
                Text("\(filteredLines.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("自动跟随", isOn: $autoFollow)
                .toggleStyle(.checkbox)
                .pointerCursorOnHover()
                // Never let the row squeeze the auto-follow label into a
                // truncated form: the search field absorbs the width pressure
                // instead.
                .fixedSize()
                .help("日志更新时自动滚动到最新一条")

            // Icon-only actions: the labeled versions wrapped or truncated
            // (e.g. the jump-to-bottom and export-log labels) once the sheet
            // width shrank. Tooltips keep the names discoverable without
            // stealing horizontal space.
            Button {
                autoFollow = true
                scrollToBottom(proxy: proxy)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .frame(minWidth: 18)
            }
            .help("到底部：跳转到最新一条日志并恢复自动跟随")

            Button {
                refreshLog()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 18)
            }
            .help("刷新日志")

            Button {
                exportLog()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 18)
            }
            .help("导出日志…")

            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 18)
            }
            .help("清除日志…")
        }
        .buttonStyle(FlatHoverButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Mirrors the main window's compact search field so filtering reads as
    /// the same interaction in both task and log lists.
    private var logSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索关键词", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 190, height: 28)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
        )
        .help("按关键词过滤日志内容（不区分大小写）")
    }

    // MARK: - Log content

    @ViewBuilder
    private var logContent: some View {
        let lines = filteredLines
        if lines.isEmpty {
            VStack {
                Spacer()
                Text("暂无日志记录")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(colorForLine(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.vertical, 4)
            }
            .background(LightScrollerConfigurator())
        }
    }

    // MARK: - Filtering

    private var filteredLines: [String] {
        let allLines =
            logText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return allLines.filter { line in
            if !keyword.isEmpty,
                !line.localizedCaseInsensitiveContains(keyword)
            {
                return false
            }
            guard let (level, category) = parseLogLine(line) else { return true }
            let levelOK = levelFilter == .all || level == levelFilter.rawValue
            let categoryOK = categoryFilter == .all || category == categoryFilter.rawValue
            return levelOK && categoryOK
        }
    }

    /// Extracts the level and category raw values from a structured log line.
    /// Expected format: `timestamp [level] [category] message`
    private func parseLogLine(_ line: String) -> (level: String, category: String)? {
        let parts = line.split(separator: "]", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        // parts[0] = "timestamp [level", parts[1] = " [category", parts[2] = " message"
        let levelPart = parts[0]
        let categoryPart = parts[1]
        guard let levelBracket = levelPart.lastIndex(of: "[") else { return nil }
        let level = String(levelPart[levelPart.index(after: levelBracket)...])
        let trimmedCategory = categoryPart.trimmingCharacters(in: .whitespaces)
        guard let categoryBracket = trimmedCategory.firstIndex(of: "[") else {
            return nil
        }
        let category = String(trimmedCategory[trimmedCategory.index(after: categoryBracket)...])
        return (level, category)
    }

    private func colorForLine(_ line: String) -> Color {
        if line.contains("[error]") { return AppTheme.danger }
        if line.contains("[warning]") { return AppTheme.warning }
        if line.contains("[debug]") { return .secondary }
        return .primary
    }

    // MARK: - Actions

    private func refreshLog() {
        logText = AppLogger.shared.readLog(maxLines: 500)
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出日志")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "macidm-\(formatter.string(from: Date())).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = AppLogger.shared.readFullLog()
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
