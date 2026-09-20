import AppKit
import SwiftUI

/// Live-value bridge between `AppModel` and the task table.
///
/// The table view hosting the download list must never re-render at
/// download frequency: a body re-evaluation mid-gesture re-applies the
/// selection binding onto the backing NSTableView, which aborts an
/// in-progress rubber-band multi-selection. Before this bridge existed,
/// every ~300 ms progress flush (via `@EnvironmentObject` model) and every
/// 1 Hz duration tick (via `@StateObject` clock) re-evaluated the table,
/// and no amount of drag-detection patching could keep up.
///
/// The split is:
/// - **Volatile values** (progress, speed, status) flow into per-task
///   `TaskLiveModel` objects. Only the cells observing their row's model
///   re-render; the table body is untouched.
/// - **Structural changes** (rows added/removed/renamed, filter, columns)
///   and **external selection changes** are delivered to the table as one
///   Equatable token (`TaskTableAppearance`) by its parent; the table
///   reloads its data snapshot only when that token changes.
/// - **Selection** flows out through `commitSelection` (no echo back — the
///   table already displays what it committed) and EXTERNAL selections
///   flow in through `applyExternalSelection`, which writes the table's
///   binding directly. Neither direction goes through the Equatable
///   token: a token change re-evaluates the table body, which re-applies
///   the selection binding onto the backing NSTableView mid-gesture and
///   corrupts click handling.
@MainActor
final class TaskTableSynchronizer: ObservableObject {
    /// Per-task live values consumed by the table's cells. Deliberately
    /// plain storage: mutating entries must not fire this object's
    /// `objectWillChange`, or the whole table would re-render.
    private(set) var liveModels: [UUID: TaskLiveModel] = [:]

    /// Shared 1 Hz clock for elapsed-time cells. Cells observe it
    /// directly; owning it here keeps the table view itself free of
    /// `@StateObject` subscriptions.
    let clock = DurationClock()

    // Wiring set once by AppModel after initialization.
    var provideRows: () -> [AppTask] = { [] }
    var seedTask: (UUID) -> AppTask? = { _ in nil }
    var commitSelection: (Set<UUID>) -> Void = { _ in }
    /// Writes an externally originated selection (auto-select on task
    /// creation, context menu, pruning) straight into the table's
    /// binding. Wired by the table on appear; no-op until then.
    var applyExternalSelection: (Set<UUID>) -> Void = { _ in }

    /// Returns (creating and seeding on first access) the live model for a
    /// row. Cell closures call this at render time.
    func liveModel(for id: UUID) -> TaskLiveModel {
        if let existing = liveModels[id] { return existing }
        let model = TaskLiveModel(task: seedTask(id))
        liveModels[id] = model
        return model
    }

    /// Pushes one task's fresh volatile values into its live model. Called
    /// by AppModel after every task mutation (progress flushes, status
    /// transitions, filename changes).
    func updateLive(_ task: AppTask) {
        liveModel(for: task.id).apply(task)
    }

    /// Rebuilds the live-model set after wholesale task-list changes
    /// (restores, removals, history clears): updates survivors and drops
    /// models for tasks that no longer exist.
    func replaceAllLive(_ tasks: [AppTask]) {
        let visible = Set(tasks.map(\.id))
        liveModels = liveModels.filter { visible.contains($0.key) }
        for task in tasks {
            updateLive(task)
        }
    }
}

/// Per-row live values for the task table. `AppTask` is a value type
/// embedded in AppModel's `tasks` array; re-rendering a cell from it would
/// require mutating the array (whole-table reload). Cells instead observe
/// this object, so a progress flush re-renders exactly one cell.
@MainActor
final class TaskLiveModel: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var status: AppTaskStatus = .queued
    @Published private(set) var fileMissing = false
    @Published private(set) var fractionCompleted: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var bytesPerSecond: Double = 0
    /// Set at completion (bytes / active duration). Lives here instead of
    /// only on the table's `AppTask` snapshot because completion updates
    /// flow through `updateLive` while the snapshot only rebuilds on
    /// structural changes — the speed cell must show the average the
    /// moment a task finishes.
    @Published private(set) var averageSpeed: Double?
    /// Same reasoning as `averageSpeed`: the duration cell must show the
    /// recorded total the moment a task finishes, before the next
    /// structural change refreshes the table snapshot.
    @Published private(set) var totalDuration: TimeInterval?

    init(task: AppTask?) {
        id = task?.id ?? UUID()
        if let task { apply(task) }
    }

    func apply(_ task: AppTask) {
        let incoming = task.fractionCompleted
        // 进度条单调不回退：HLS 估算总量会随分段大小波动（甚至短暂 nil），
        // 直接采用新比例会让进度条倒退/归零（曾出现 100%→0% 跳变）。
        // 判据：已完成→1.0；比例增长、或已下载字节倒退（任务重试/重置）
        // →跟随新值；比例下降但字节没退（仅 total 波动）→保持历史进度。
        // 注意：比较用的是旧的 self.receivedBytes，故须在下方赋值之前。
        if task.status == .completed {
            fractionCompleted = 1
        } else if incoming >= fractionCompleted || task.receivedBytes < receivedBytes {
            fractionCompleted = incoming
        }
        status = task.status
        fileMissing = task.fileMissing
        receivedBytes = task.receivedBytes
        totalBytes = task.totalBytes
        bytesPerSecond = task.bytesPerSecond
        averageSpeed = task.averageSpeed
        totalDuration = task.totalDuration
    }
}

/// Shared 1 Hz wall clock. Elapsed-time cells observe it directly so their
/// per-second updates never propagate above cell level.
final class DurationClock: ObservableObject, @unchecked Sendable {
    @Published private(set) var now = Date()
    // Optional so the stored property is initialized before the timer
    // closure captures self.
    private var timer: Timer?

    init() {
        // @unchecked Sendable: the timer fires on the main RunLoop, so the
        // published mutation stays main-thread confined in practice.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        // .common keeps the tick flowing during scroll tracking too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }
}

/// Hand-drawn linear progress track shared by the task table and the task
/// detail column. The system ``ProgressView`` sizes itself from the
/// environment and renders with a different (thicker, permanently visible)
/// appearance on displays with different backing scales; a fixed-height
/// capsule pair renders identically everywhere. On selected table rows
/// (increased background prominence, macOS 14+) the fill switches to the
/// same soft lavender the system control used, so the bar stays legible on
/// the selection tint. Animations stay off so value changes never animate.
struct ProgressTrackBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        if #available(macOS 14.0, *) {
            ProgressTrackBarAdaptive(fraction: fraction, height: height)
        } else {
            ProgressTrackBarCore(fraction: fraction, height: height, tint: AppTheme.accent)
        }
    }
}

/// macOS 13 fallback: always the accent color.
private struct ProgressTrackBarCore: View {
    let fraction: Double
    let height: CGFloat
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: clamped * geometry.size.width)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .animation(nil, value: fraction)
        .transaction { $0.animation = nil }
    }
}

/// macOS 14+: picks the fill color from background prominence — accent
/// normally, soft lavender on selected rows.
@available(macOS 14.0, *)
private struct ProgressTrackBarAdaptive: View {
    let fraction: Double
    let height: CGFloat
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var tint: Color {
        backgroundProminence == .increased
            ? Color(red: 0.784, green: 0.737, blue: 1.0)
            : AppTheme.accent
    }

    var body: some View {
        GeometryReader { geometry in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: clamped * geometry.size.width)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .animation(nil, value: fraction)
        .transaction { $0.animation = nil }
    }
}
