import Foundation
import IDMEngine

/// All mutable control state for one execution has one owner. Generation
/// survives cleanup so late callbacks can never match a replacement run.
@MainActor
final class AppExecutionRegistry {
    final class Context {
        var task: Task<Void, Never>?
        var control: DownloadControlToken?
        var generation = 0
        var transitionToken: UUID?
        var pendingProgress: (generation: Int, progress: DownloadProgress)?
    }
    private var contexts: [UUID: Context] = [:]
    subscript(id: UUID) -> Context {
        if let value = contexts[id] { return value }
        let value = Context()
        contexts[id] = value
        return value
    }
    var tasks: [Task<Void, Never>] { contexts.values.compactMap(\.task) }
    var controls: [DownloadControlToken] { contexts.values.compactMap(\.control) }
    var pendingProgress: [UUID: (generation: Int, progress: DownloadProgress)] {
        contexts.compactMapValues(\.pendingProgress)
    }
    func clearPendingProgress() {
        for context in contexts.values { context.pendingProgress = nil }
    }
}
