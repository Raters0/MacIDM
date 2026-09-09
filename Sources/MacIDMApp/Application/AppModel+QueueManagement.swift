import Foundation

extension AppModel {
    static let queueScheduleInterval: UInt64 = 30_000_000_000

    /// The implicit main queue hosts every task without an explicit
    /// `queueID`. It has no persisted row; its concurrency is the global
    /// simultaneous-download setting.
    var mainQueueTitle: String { String(localized: "主队列") }

    func queue(with id: UUID?) -> AppQueue? {
        guard let id else { return nil }
        return queues.first { $0.id == id }
    }

    func tasks(inQueue queueID: UUID?) -> [AppTask] {
        tasks.filter { $0.queueID == queueID && !$0.isCLIManaged }
    }

    // MARK: - CRUD

    func addQueue(name: String, concurrency: Int = 2) -> AppQueue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let queue = AppQueue(name: trimmed, concurrency: concurrency)
        queues.append(queue)
        persistQueues()
        return queue
    }

    func updateQueue(_ id: UUID, body: (inout AppQueue) -> Void) {
        guard let index = queues.firstIndex(where: { $0.id == id }) else { return }
        body(&queues[index])
        persistQueues()
    }

    /// Deletes a queue and returns its tasks to the implicit main queue.
    /// Running tasks keep running; their remaining siblings simply fall
    /// back under the global concurrency cap.
    func deleteQueue(_ id: UUID) {
        guard queues.contains(where: { $0.id == id }) else { return }
        queues.removeAll { $0.id == id }
        for index in tasks.indices where tasks[index].queueID == id {
            tasks[index].queueID = nil
        }
        if case .queue(let selected) = sidebarFilter, selected == id {
            sidebarFilter = .all
        }
        persistQueues()
        tryPersistOrPresentError()
        scheduleQueuedTasks()
    }

    func moveTask(_ taskID: UUID, toQueue queueID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[index].queueID != queueID else { return }
        tasks[index].queueID = queueID
        tryPersistOrPresentError()
        scheduleQueuedTasks()
    }

    // MARK: - Queue pause / resume

    func pauseQueue(_ id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }), !queues[index].isPaused
        else { return }
        queues[index].isPaused = true
        persistQueues()
        for task in tasks(inQueue: id) where task.status.isActive {
            pause(task.id)
        }
    }

    func resumeQueue(_ id: UUID) {
        guard let index = queues.firstIndex(where: { $0.id == id }), queues[index].isPaused
        else { return }
        queues[index].isPaused = false
        persistQueues()
        for task in tasks(inQueue: id) where task.status == .paused {
            resume(task.id)
        }
        scheduleQueuedTasks()
    }

    // MARK: - Scheduling

    /// Periodic driver for queue start/stop windows and the stop-on-empty
    /// auto pause. Runs every ``queueScheduleInterval``; also applied once
    /// at startup so a restart inside a window resumes immediately.
    func startQueueScheduleLoop() {
        queueScheduleTask?.cancel()
        applyQueueSchedules(at: Date())
        queueScheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.queueScheduleInterval)
                guard !Task.isCancelled, let self else { return }
                self.applyQueueSchedules(at: Date())
            }
        }
    }

    /// Edge-triggered schedule evaluation: entering a window resumes a
    /// paused queue; leaving it pauses the queue and its active tasks.
    /// Queues without a schedule (or with scheduling disabled) are left
    /// exactly where the user put them.
    func applyQueueSchedules(at date: Date) {
        var changed = false
        for index in queues.indices where queues[index].scheduleEnabled {
            let shouldBeActive = queues[index].scheduleSaysActive(at: date)
            if shouldBeActive, queues[index].isPaused {
                changed = true
                let id = queues[index].id
                queues[index].isPaused = false
                // Queue names are user-defined text that may carry sensitive
                // content: the ordinary log records only the queue ID.
                AppLogger.shared.info(.system, "queue schedule resumed queue=\(id)")
                for task in tasks(inQueue: id) where task.status == .paused {
                    resume(task.id)
                }
            } else if !shouldBeActive, !queues[index].isPaused {
                changed = true
                let id = queues[index].id
                queues[index].isPaused = true
                AppLogger.shared.info(.system, "queue schedule paused queue=\(id)")
                for task in tasks(inQueue: id) where task.status.isActive {
                    pause(task.id)
                }
            }
        }
        if changed {
            persistQueues()
            scheduleQueuedTasks()
        }
    }

    /// Stop-on-empty: when a queue's last task settles (terminal state or
    /// removal) and nothing is queued behind it, pause the queue so later
    /// additions wait for the user or the next schedule window.
    func settleStopOnEmptyQueues(for taskID: UUID) {
        guard let task = task(with: taskID), let queueID = task.queueID,
            let index = queues.firstIndex(where: { $0.id == queueID }),
            queues[index].stopOnEmpty, !queues[index].isPaused
        else { return }
        let remaining = tasks(inQueue: queueID).filter {
            $0.id != taskID && !$0.status.isTerminal
        }
        guard remaining.isEmpty else { return }
        queues[index].isPaused = true
        persistQueues()
        AppLogger.shared.info(.system, "queue stopped on empty queue=\(queueID)")
    }

    func persistQueues() {
        do {
            try store.saveQueues(queues)
        } catch {
            presentedError = PresentedError(
                title: String(localized: "无法保存队列设置"),
                message: error.localizedDescription
            )
        }
    }
}
