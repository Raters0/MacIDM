import AppKit
import SwiftUI

/// Blocking text prompt used for queue create/rename. NSAlert + NSTextField
/// because SwiftUI's Alert has no text input on macOS; mirrors the existing
/// filename-conflict retry flow.
@MainActor
func promptForQueueName(
    title: String,
    message: String,
    initial: String = ""
) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "好"))
    alert.addButton(withTitle: String(localized: "取消"))
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    input.stringValue = initial
    input.placeholderString = String(localized: "队列名称")
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct QueueSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppQueue

    init(queue: AppQueue) {
        _draft = State(initialValue: queue)
    }

    private static let dayNames: [LocalizedStringKey] = [
        "周一", "周二", "周三", "周四", "周五", "周六", "周日",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("队列设置")
                .font(.headline)

            Form {
                Section("基本") {
                    TextField("名称", text: $draft.name)
                    Stepper(value: $draft.concurrency, in: AppQueue.concurrencyRange) {
                        Text("同时下载数：\(draft.concurrency)")
                    }
                    .pointerCursorOnHover()
                    Picker("顺序", selection: $draft.orderMode) {
                        Text("优先级优先").tag(AppQueue.OrderMode.priority)
                        Text("先来先下").tag(AppQueue.OrderMode.fifo)
                    }
                    .pointerCursorOnHover()
                    Toggle("队列清空后自动暂停", isOn: $draft.stopOnEmpty)
                        .pointerCursorOnHover()
                }
                Section("定时调度") {
                    Toggle("启用定时开始/停止", isOn: $draft.scheduleEnabled)
                        .pointerCursorOnHover()
                    if draft.scheduleEnabled {
                        dayPicker
                        scheduleTimePickers
                        Text("窗口外队列自动暂停；窗口开始时自动继续已暂停的任务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(FlatHoverButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .buttonStyle(FlatHoverButtonStyle())
        .padding(20)
        .frame(width: 460, height: 520)
    }

    private var dayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("重复日")
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let isOn = draft.scheduleDays & (1 << index) != 0
                    Button(Self.dayNames[index]) {
                        if isOn {
                            draft.scheduleDays &= ~(1 << index)
                        } else {
                            draft.scheduleDays |= 1 << index
                        }
                    }
                    .buttonStyle(DayToggleChipStyle(isOn: isOn))
                }
            }
        }
    }

    private var scheduleTimePickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("开始")
                minutePicker(
                    selection: Binding(
                        get: { draft.scheduleStartMinutes },
                        set: { draft.scheduleStartMinutes = $0 }
                    ))
                Spacer()
                Toggle(
                    "定时停止",
                    isOn: Binding(
                        get: { draft.scheduleStopMinutes != nil },
                        set: { draft.scheduleStopMinutes = $0 ? 1439 : nil }
                    )
                )
                .pointerCursorOnHover()
                if let stop = draft.scheduleStopMinutes {
                    minutePicker(
                        selection: Binding(
                            get: { stop },
                            set: { draft.scheduleStopMinutes = $0 }
                        ))
                }
            }
        }
    }

    private func minutePicker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(Array(stride(from: 0, through: 1439, by: 15)), id: \.self) { minutes in
                Text(String(format: "%02d:%02d", minutes / 60, minutes % 60)).tag(minutes)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 96)
        .pointerCursorOnHover()
    }

    private func save() {
        let name = String(
            draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(AppQueue.maximumNameLength)
        )
        model.updateQueue(draft.id) { queue in
            queue.name = name
            queue.concurrency = AppQueue.clampConcurrency(draft.concurrency)
            queue.orderMode = draft.orderMode
            queue.stopOnEmpty = draft.stopOnEmpty
            queue.scheduleEnabled = draft.scheduleEnabled
            queue.scheduleDays = draft.scheduleDays & 0x7F
            queue.scheduleStartMinutes = draft.scheduleStartMinutes
            queue.scheduleStopMinutes = draft.scheduleStopMinutes
        }
        model.applyQueueSchedules(at: Date())
        model.scheduleQueuedTasks()
        dismiss()
    }
}

/// Day-of-week toggle chips: the selected state reuses the shared
/// navigation selection tokens (pale accent fill + hairline outline)
/// instead of the system bordered + tint hack, so the schedule row reads
/// like the sidebar's selected filter.
private struct DayToggleChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(isOn ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(
                        isOn
                            ? AppTheme.selectionFill
                            : configuration.isPressed ? Color.primary.opacity(0.09) : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .strokeBorder(
                        isOn
                            ? AppTheme.selectionOutline
                            : Color.primary.opacity(configuration.isPressed ? 0.20 : 0.12),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
            .pointerCursorOnHover()
    }
}
