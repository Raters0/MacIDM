import SwiftUI

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
struct TaskTableView: View, Equatable {
    /// Plain (unobserved) model reference for menu actions and item
    /// providers — capturing it as a plain `let` does not subscribe this
    /// view to `objectWillChange`.
    let model: AppModel
    let synchronizer: TaskTableSynchronizer
    let appearance: TaskTableAppearance
    let requestPermanentFileDeletion: (Set<UUID>) -> Void

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
                    .width(min: 80, ideal: 118)
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
                    TableColumn("下载耗时", value: \.sortDuration) { task in
                        DurationCell(
                            task: task,
                            live: synchronizer.liveModel(for: task.id)
                        )
                        .modifier(TableCellLayout())
                    }
                    // Wide enough for the English header "Download time".
                    .width(min: 60, ideal: 96)
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
                .width(min: 80, ideal: 118)

                TableColumn("速度", value: \.sortSpeed) { task in
                    SpeedCell(
                        task: task,
                        live: synchronizer.liveModel(for: task.id)
                    )
                    .modifier(TableCellLayout())
                }
                .width(min: 75, ideal: 75)

                TableColumn("下载耗时", value: \.sortDuration) { task in
                    DurationCell(
                        task: task,
                        live: synchronizer.liveModel(for: task.id)
                    )
                    .modifier(TableCellLayout())
                }
                .width(min: 60, ideal: 96)

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
                    title: appearance.tasksEmpty ? String(localized: "还没有下载任务") : String(localized: "没有匹配的任务"),
                    systemImage: appearance.tasksEmpty ? "arrow.down.doc" : "magnifyingglass",
                    description: appearance.tasksEmpty
                        ? String(localized: "点击「添加」或拖入下载链接") : String(localized: "更改筛选条件或搜索内容")
                )
            }
        }
        .taskContextMenu(
            model: model,
            requestPermanentFileDeletion: requestPermanentFileDeletion
        )
    }
}

struct TaskContextMenuModifier: ViewModifier {
    /// Plain `let` on purpose: an `@ObservedObject` here would subscribe
    /// the table subtree to the model's 300 ms progress flushes and
    /// re-apply selection mid-gesture. The menu only reads model state
    /// when it opens.
    let model: AppModel
    let requestPermanentFileDeletion: (Set<UUID>) -> Void

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: UUID.self) { selection in
            let tasks = model.tasks.filter { selection.contains($0.id) }
            if !tasks.isEmpty {
                activeMenu(tasks)
            }
        }
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
            Button("重新下载") { model.reDownload(task.id) }
                .disabled(task.status != .completed || task.isCLIManaged)
            Button("查看详情") { model.selectTasks([task.id]) }
            Button(rateLimitTitle(for: task)) { promptRateLimit(task) }
                .disabled(task.isCLIManaged)
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
        // 三个删除选项都会把记录从列表移除；仅「彻底删除」需要二次确认，
        // 因为文件不可恢复。
        let removableIDs = Set(
            tasks.filter { $0.isRemovableFromApp }.map(\.id)
        )
        Divider()
        Button("仅删除记录", role: .destructive) {
            for id in removableIDs { model.remove(id) }
        }
        .disabled(removableIDs.isEmpty)
        Button("移到废纸篓", role: .destructive) {
            for id in removableIDs { model.remove(id, fileRemoval: .moveToTrash) }
        }
        .disabled(removableIDs.isEmpty || !model.hasRemovableFiles(removableIDs))
        Button("彻底删除…", role: .destructive) {
            requestPermanentFileDeletion(removableIDs)
        }
        .disabled(removableIDs.isEmpty || !model.hasRemovableFiles(removableIDs))
    }

    private func rateLimitTitle(for task: AppTask) -> String {
        if let limit = task.rateLimitKBps, limit > 0 {
            return String(localized: "限制速度…（当前 \(limit) KB/s）")
        }
        return String(localized: "限制速度…")
    }

    /// Per-task cap prompt in the rename-sheet style: digits-only parse,
    /// 0 or empty clears the cap. The global limit keeps applying in
    /// parallel, so the tighter bound wins.
    private func promptRateLimit(_ task: AppTask) {
        let alert = NSAlert()
        alert.messageText = String(localized: "限制此任务速度")
        alert.informativeText = String(
            localized: "单位 KB/s；输入 0 表示不限速。全局限速仍同时生效，两者取更严者。"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "应用"))
        alert.addButton(withTitle: String(localized: "取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        if let limit = task.rateLimitKBps, limit > 0 {
            input.stringValue = String(limit)
        }
        input.placeholderString = String(localized: "0 = 不限速")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let digits = input.stringValue.filter(\.isNumber)
        guard let value = Int(digits) else { return }
        model.setTaskRateLimit(value, for: task.id)
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
            model.presentedError = PresentedError(title: String(localized: "改名失败"), message: error.localizedDescription)
        }
    }
}

private extension View {
    func taskContextMenu(
        model: AppModel,
        requestPermanentFileDeletion: @escaping (Set<UUID>) -> Void
    ) -> some View {
        modifier(
            TaskContextMenuModifier(
                model: model,
                requestPermanentFileDeletion: requestPermanentFileDeletion
            )
        )
    }
}
