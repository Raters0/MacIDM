import Foundation

/// Tasks that fail because the destination volume is full are parked as
/// paused with `diskFullErrorCode` instead of failing (the engine's retry
/// budget is seconds, far too short for a user to free space). This watch
/// polls free space while any task is parked and resumes each one once its
/// volume has room for the remaining bytes again. A parked task that the
/// user resumes, pauses, or removes simply stops being watched.
extension AppModel {
    static let diskFullErrorCode = "DISK_FULL"
    static let diskSpaceWatchInterval: UInt64 = 30_000_000_000
    /// Headroom on top of a task's remaining bytes, so a resume does not run
    /// the volume dry again straight away.
    static let diskSpaceResumeMargin: Int64 = 256 * 1_024 * 1_024

    var diskFullParkedTasks: [AppTask] {
        tasks.filter {
            $0.status == .paused && $0.errorCode == Self.diskFullErrorCode && !$0.isCLIManaged
        }
    }

    func startDiskSpaceWatchIfNeeded() {
        guard diskSpaceWatchTask == nil, !diskFullParkedTasks.isEmpty else { return }
        diskSpaceWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.diskSpaceWatchInterval)
                guard !Task.isCancelled, let self else { return }
                if !self.resumeDiskFullTasksWithRoom() { break }
            }
            self?.diskSpaceWatchTask = nil
        }
    }

    /// Resumes parked tasks whose destination has room again. Space is
    /// budgeted per destination directory so two parked tasks are not both
    /// resumed onto room that fits only one. Returns true while any task is
    /// still waiting.
    @discardableResult
    func resumeDiskFullTasksWithRoom(
        availableCapacity: (URL) -> Int64? = AppModel.availableCapacity(at:),
        resumeTask: ((UUID) -> Void)? = nil
    ) -> Bool {
        var budgets: [String: Int64] = [:]
        var stillWaiting = false
        for task in diskFullParkedTasks {
            let directory = URL(fileURLWithPath: task.destinationPath).deletingLastPathComponent()
            guard let available = budgets[directory.path] ?? availableCapacity(directory) else {
                stillWaiting = true
                continue
            }
            let remaining = max(0, (task.totalBytes ?? 0) - task.receivedBytes)
            let needed = remaining + Self.diskSpaceResumeMargin
            // An execution still winding down cannot be restarted yet.
            guard available >= needed, executions[task.id].task == nil else {
                budgets[directory.path] = available
                stillWaiting = true
                continue
            }
            budgets[directory.path] = available - remaining
            if let resumeTask {
                resumeTask(task.id)
            } else {
                resume(task.id)
            }
        }
        return stillWaiting
    }

    nonisolated static func availableCapacity(at directory: URL) -> Int64? {
        guard
            let values = try? directory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
    }
}
