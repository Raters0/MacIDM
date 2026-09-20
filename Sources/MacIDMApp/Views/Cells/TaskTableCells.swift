import IDMEngine
import SwiftUI

/// Unified family of table cell components for the main task list (AI
/// handover doc §5.4).
///
/// Contains presentation-only leaf views such as SpeedCell, StatusCell, SizeCell,
/// DurationCell, ProgressCell, TaskNameCell, StatusLabel, and StatusBarView,
/// keeping the main-window layout decoupled from pure presentation logic.

/// Speed cell driven by the row's live model (see `TaskTableSynchronizer`).
struct SpeedCell: View {
    let task: AppTask
    @ObservedObject var live: TaskLiveModel

    private var transferComplete: Bool {
        live.status == .running
            && (live.totalBytes.map { live.receivedBytes >= $0 && $0 > 0 } ?? false)
    }

    var body: some View {
        let averageSpeed = live.averageSpeed ?? task.averageSpeed
        if live.status == .completed, let avg = averageSpeed, avg > 0 {
            Text(DisplayFormatting.speed(avg))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("平均速度：\(DisplayFormatting.speed(avg))（仅统计实际传输时间）")
                .accessibilityLabel("平均速度 \(DisplayFormatting.speed(avg))")
        } else if live.status == .verifying {
            Text("校验中…")
                .foregroundStyle(.secondary)
        } else if transferComplete {
            Text("收尾中…")
                .foregroundStyle(.secondary)
        } else if live.status == .running && live.bytesPerSecond == 0 {
            if task.browserSubmissionType == "youtube.extractor" && live.receivedBytes == 0 {
                Text("解析视频中…")
                    .foregroundStyle(.secondary)
            } else {
                Text("连接中…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(DisplayFormatting.speed(live.bytesPerSecond))
                .monospacedDigit()
        }
    }
}

/// Status cell driven by the row's live model.
struct StatusCell: View {
    @ObservedObject var live: TaskLiveModel

    var body: some View {
        HStack(spacing: 4) {
            if live.status == .completed && live.fileMissing {
                Label("文件已丢失", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(WarningColor())
                    .help("下载已完成，但原始文件已删除或移动")
            } else {
                StatusLabel(status: live.status)
            }
            if live.fileMissing && live.status != .completed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(WarningColor())
                    .help("原始文件已从下载目录中删除或移动")
            }
        }
    }
}

/// Size cell driven by the row's live model so a total discovered mid-run
/// shows up without reloading the table.
struct SizeCell: View {
    @ObservedObject var live: TaskLiveModel

    var body: some View {
        Text(DisplayFormatting.byteCount(live.totalBytes))
            .monospacedDigit()
    }
}

/// Displays total download duration off the shared ``DurationClock``; only
/// these cells re-render on each tick, never the whole Table.
struct DurationCell: View {
    let task: AppTask
    @ObservedObject var live: TaskLiveModel
    @ObservedObject var clock: DurationClock

    private var currentDuration: TimeInterval {
        if live.status.isTerminal, let total = live.totalDuration ?? task.totalDuration {
            return total
        }
        let anchor = task.startedAt ?? task.createdAt
        if !live.status.isActive {
            return max(0, task.updatedAt.timeIntervalSince(anchor))
        }
        return max(0, clock.now.timeIntervalSince(anchor))
    }

    var body: some View {
        Text(DisplayFormatting.duration(currentDuration))
            .monospacedDigit()
    }
}

/// Common full-cell layout contract for every table column.
struct TableCellLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Cached table data snapshot shared with the leaf view.
final class TaskSnapshotBox {
    var rowsSignature: [TaskTableAppearance.RowKey] = []
    var sortSignature: [String] = []
    var snapshot: [AppTask] = []
}

/// Progress cell driven by the row's live model.
struct ProgressCell: View {
    @ObservedObject var live: TaskLiveModel

    var body: some View {
        if live.status == .completed {
            Text("已完成")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !live.status.showsTransferProgress {
            Text(DisplayFormatting.byteCount(live.receivedBytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("已传输字节；任务尚未完成")
        } else {
            HStack(spacing: 2) {
                ProgressTrackBar(fraction: live.fractionCompleted, height: 4)
                Text(trailingText)
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var trailingText: String {
        if hasKnownTotal {
            return live.fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
        }
        return live.status.isActive
            ? DisplayFormatting.byteCount(live.receivedBytes)
            : "0%"
    }

    private var hasKnownTotal: Bool {
        (live.totalBytes ?? 0) > 0 || live.status == .completed
    }
}

struct TaskNameCell: View {
    let task: AppTask
    var redacted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.category.systemImage)
                .foregroundStyle(task.fileMissing ? AnyShapeStyle(DangerColor()) : AnyShapeStyle(Color.secondary))
            Text(task.displayName(redacted: redacted))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(task.fileMissing ? AnyShapeStyle(DangerColor()) : AnyShapeStyle(Color.primary))
        }
        .help(redacted ? task.jobID : "\(task.filename) · 任务ID: \(task.jobID)")
    }
}

/// Adaptive danger color: red normally, soft pink (#FFB8B8) on selected rows.
struct DangerColor: ShapeStyle {
    func resolve(in env: EnvironmentValues) -> some ShapeStyle {
        if #available(macOS 14.0, *), env.backgroundProminence == .increased {
            return AnyShapeStyle(Color(red: 1.0, green: 0.722, blue: 0.722))
        }
        return AnyShapeStyle(AppTheme.danger)
    }
}

/// Adaptive warning color: amber normally, soft gold (#FFE0A8) on selected rows.
struct WarningColor: ShapeStyle {
    func resolve(in env: EnvironmentValues) -> some ShapeStyle {
        if #available(macOS 14.0, *), env.backgroundProminence == .increased {
            return AnyShapeStyle(Color(red: 1.0, green: 0.878, blue: 0.659))
        }
        return AnyShapeStyle(AppTheme.warning)
    }
}

struct StatusLabel: View {
    let status: AppTaskStatus

    var body: some View {
        Label(status.title, systemImage: systemImage)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var systemImage: String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed, .storageError, .filenameConflict, .needsRestart, .takeoverConflict:
            "exclamationmark.triangle.fill"
        case .takeoverPending: "network"
        case .paused: "pause.circle.fill"
        case .cancelled: "xmark.circle"
        case .queued: "clock"
        case .probing: "antenna.radiowaves.left.and.right"
        default: "arrow.down.circle.fill"
        }
    }

    private var color: TaskStatusColor { TaskStatusColor(status: status) }
}

private struct TaskStatusColor: ShapeStyle {
    let status: AppTaskStatus

    func resolve(in env: EnvironmentValues) -> some ShapeStyle {
        if #available(macOS 14.0, *), env.backgroundProminence == .increased {
            return AnyShapeStyle(Color.primary)
        }
        return AnyShapeStyle(AppTheme.statusColor(for: status))
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)

            HStack(spacing: 16) {
                Text("活动任务 \(model.filteredActiveCount)/\(model.filteredTasks.count)")
                    .help("当前筛选下活动任务数 / 任务总数")
                if model.fileMissingCount > 0 {
                    Label("\(model.fileMissingCount) 个文件已丢失", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.warning)
                }
                if let progress = model.globalProgress {
                    Label(
                        progress.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "chart.pie"
                    )
                    .help("全部活动任务的加权总进度")
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("总速度")
                    Text(DisplayFormatting.speed(model.aggregateSpeed))
                        .monospacedDigit()
                }
                .help("当前活动任务的总下载速度")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.bar)
        }
    }
}
