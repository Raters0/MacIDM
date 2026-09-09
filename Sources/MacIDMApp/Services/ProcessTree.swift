import Darwin
import Foundation

/// Process-table utilities for external-tool lifecycle management. yt-dlp
/// spawns its own descendants (e.g. a deno/node runtime for YouTube's JS
/// challenges), so killing only the direct child can leave orphaned
/// processes holding cookies, sockets and CPU after the App already
/// reported failure.
///
/// Termination itself is owned by `ManagedToolSession`, which places every
/// tool execution into a dedicated process group and signals the whole
/// group: group membership survives reparenting, so a
/// root that exits first on SIGTERM cannot hide TERM-resistant descendants.
enum ProcessTree {
    /// `P_ZOMBIE` from <sys/proc.h>; not re-exported by the Darwin overlay.
    private static let processFlagZombie: Int32 = 0x10_0000

    /// Three-state group liveness: "could not read the
    /// process table" and "the group has no members" must stay distinct — a
    /// lifecycle gate that treats `.unknown` as empty can leave live
    /// descendants behind while reporting a clean finish.
    enum GroupState: Equatable, Sendable {
        case live
        case empty
        case unknown
    }

    /// True while the PID refers to a live, non-zombie process.
    static func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return info.kp_proc.p_flag & processFlagZombie == 0
    }

    /// All descendant PIDs of `root` (children, grandchildren, …) found via
    /// a BFS over the kernel process table. The snapshot can race with
    /// process exits; callers treat stale PIDs as harmless (kill fails with
    /// ESRCH and the liveness poll re-checks).
    static func descendants(of root: pid_t) -> [pid_t] {
        guard root > 0 else { return [] }
        guard case .success(let table) = processTable() else { return [] }
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in table {
            childrenByParent[entry.kp_eproc.e_ppid, default: []].append(entry.kp_proc.p_pid)
        }
        var result: [pid_t] = []
        var frontier: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        while !frontier.isEmpty {
            var next: [pid_t] = []
            for pid in frontier {
                for child in childrenByParent[pid] ?? [] where !seen.contains(child) {
                    seen.insert(child)
                    result.append(child)
                    next.append(child)
                }
            }
            frontier = next
        }
        return result
    }

    /// Three-state liveness of `pgid`. Process group
    /// membership is stable across reparenting — unlike descendant chasing
    /// from a root PID, which loses orphans re-attached to launchd once the
    /// root exits first. A process-table read failure is
    /// `.unknown`, never `.empty`: lifecycle gates must keep settling (and
    /// eventually report `cleanupFailed`) instead of assuming the group is
    /// gone.
    static func groupState(_ pgid: pid_t) -> GroupState {
        guard pgid > 0 else { return .empty }
        guard case .success(let table) = processTable() else { return .unknown }
        for entry in table {
            guard entry.kp_eproc.e_pgid == pgid else { continue }
            if entry.kp_proc.p_flag & processFlagZombie == 0 {
                return .live
            }
        }
        return .empty
    }

    /// Convenience for display/test assertions only: "does the group have a
    /// live member?". `.unknown` answers false here — lifecycle gates must
    /// use `groupState` directly so an unreadable table never masquerades as
    /// a verified-empty group.
    static func groupHasLiveMembers(_ pgid: pid_t) -> Bool {
        groupState(pgid) == .live
    }

    /// Kernel process table with bounded ENOMEM retries: the table can grow
    /// between the sizing call and the read, so a single failure must not be
    /// mistaken for "no processes".
    private enum ProcessTableResult {
        case success([kinfo_proc])
        /// errno of the last failed sysctl; never conflated with an empty table.
        case failure(Int32)
    }

    private static func processTable() -> ProcessTableResult {
        var lastError: Int32 = EINVAL
        for attempt in 0..<4 {
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else {
                lastError = errno
                break
            }
            // Pad progressively: each retry tolerates more growth between
            // the sizing call and the real read (sysctl fails with ENOMEM
            // otherwise).
            let capacity = size + (32 + 32 * attempt) * MemoryLayout<kinfo_proc>.stride
            let count = capacity / MemoryLayout<kinfo_proc>.stride
            var table = [kinfo_proc](
                repeating: kinfo_proc(),
                count: count
            )
            var readSize = capacity
            if sysctl(&name, 4, &table, &readSize, nil, 0) == 0 {
                return .success(Array(table.prefix(readSize / MemoryLayout<kinfo_proc>.stride)))
            }
            lastError = errno
            if errno != ENOMEM { break }
        }
        return .failure(lastError)
    }
}
