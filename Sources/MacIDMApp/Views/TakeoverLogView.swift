import AppKit
import SwiftUI

/// Read-only viewer for `takeover-log.jsonl`: the bounded audit trail of
/// browser-download takeovers (why a Chrome download was accepted, rejected,
/// timed out, or abandoned). Each line is one JSON event.
struct TakeoverLogView: View {
    let logURL: URL?

    @State private var entries: [TakeoverEntry] = []

    struct TakeoverEntry: Identifiable {
        let id: Int
        let timestamp: String
        let event: String
        let taskID: String?
        let detail: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(
                    "记录浏览器下载接管的判定过程（接受、拒绝、超时、放弃），用于排查接管类问题。最多保留 256 KB。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    load()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                if let logURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }
                }
            }
            .buttonStyle(FlatHoverButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if entries.isEmpty {
                VStack {
                    Spacer()
                    Text(logURL == nil ? "接管日志未启用" : "暂无接管记录")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(LightScrollerConfigurator())
            }
        }
        .onAppear { load() }
    }

    private func entryRow(_ entry: TakeoverEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp)
                .foregroundStyle(.secondary)
            Text(entry.event)
                .foregroundStyle(color(for: entry.event))
            if let taskID = entry.taskID {
                Text(String(taskID.prefix(8)))
                    .foregroundStyle(.secondary)
            }
            Text(entry.detail)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    private func color(for event: String) -> Color {
        if event.contains("reject") || event.contains("fail") || event.contains("timeout") {
            return AppTheme.danger
        }
        if event.contains("abandon") || event.contains("cancel") {
            return AppTheme.warning
        }
        return .primary
    }

    private func load() {
        guard let logURL, let data = try? Data(contentsOf: logURL),
            let text = String(data: data, encoding: .utf8)
        else {
            entries = []
            return
        }
        struct RawEntry: Decodable {
            let timestamp: String
            let event: String
            let taskID: String?
            let detail: String
        }
        var parsed: [TakeoverEntry] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard let entry = try? JSONDecoder().decode(RawEntry.self, from: Data(line.utf8))
            else { continue }
            parsed.append(
                TakeoverEntry(
                    id: index,
                    timestamp: entry.timestamp,
                    event: entry.event,
                    taskID: entry.taskID,
                    detail: entry.detail
                )
            )
        }
        entries = parsed
    }
}
