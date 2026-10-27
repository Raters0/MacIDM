import SwiftUI

struct DetailColumnView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let task = model.selectedTask {
            TaskDetailView(task: task)
                .environmentObject(model)
                // Distinct identity per task: switching the selection must
                // replace the detail view outright, never animate one task's
                // progress bars into another task's values.
                .id(task.id)
        } else {
            EmptyStateView(
                title: "选择一个任务查看详情",
                systemImage: "sidebar.right",
                description: "支持 ⌘/⇧ 多选进行批量操作"
            )
        }
    }
}
