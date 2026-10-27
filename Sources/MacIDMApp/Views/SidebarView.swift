import SwiftUI

struct SidebarView: View {
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

                sectionHeader(String(localized: "队列"))
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

                sectionHeader(String(localized: "时间"))
                filterRow(.today, systemImage: "sun.max", counts: counts)
                filterRow(.yesterday, systemImage: "moon", counts: counts)
                filterRow(.thisWeek, systemImage: "calendar", counts: counts)

                sectionHeader(String(localized: "分类"))
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
                title: String(localized: "新建队列"),
                message: String(localized: "输入队列名称。队列拥有独立的并发上限与可选的定时调度。")
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
                title: String(localized: "重命名队列"),
                message: String(localized: "输入新的队列名称。"),
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
            .all, .active, .completed, .today, .yesterday, .thisWeek,
        ]
        for task in model.tasks {
            for filter in staticFilters where filter.matches(task, calendar: calendar) {
                counts.filters[filter, default: 0] += 1
            }
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
