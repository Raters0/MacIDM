import Foundation
import os

/// Resource limits and budget configuration for media download tasks and the global buffer pool.
public enum DownloadResourceLimits {
    /// Hard safety cap on the total size of a single media unit (segment / initialization
    /// segment), fixed at 128 MB.
    /// Note: this value is protocol defense against malicious unbounded responses exhausting
    /// disk/IO; it is not adjusted by autoTune.
    public static let maximumMediaUnitBytes: Int64 = 128 * 1024 * 1024

    /// Safety cap on manifest / playlist index file size (2 MB).
    public static let maximumManifestBytes: Int64 = 2 * 1024 * 1024

    /// Safety cap on encryption key / auxiliary metadata size (512 KB).
    public static let maximumKeyBytes: Int64 = 512 * 1024

    private struct State {
        var maximumBufferedResourceBytes: Int64 = 128 * 1024 * 1024
        var maximumTaskBufferedResourceBytes: Int64 = 32 * 1024 * 1024
        var maximumMediaInFlightRequests = 4
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Global media memory buffer budget pool capacity (default 128 MB; adjustable from
    /// 16 MB to 512 MB via autoTune or manually).
    /// Note: actual in-flight memory usage is governed by ``MediaBufferBudget``.
    public static var maximumBufferedResourceBytes: Int64 {
        state.withLock { $0.maximumBufferedResourceBytes }
    }

    /// Default memory buffer budget for a single media task (default 32 MB; adjustable
    /// from 4 MB to 128 MB).
    public static var maximumTaskBufferedResourceBytes: Int64 {
        state.withLock { $0.maximumTaskBufferedResourceBytes }
    }

    /// Maximum concurrent network requests per media task (HLS/DASH, default 4;
    /// adjustable from 1 to 16).
    public static var maximumMediaInFlightRequests: Int {
        state.withLock { $0.maximumMediaInFlightRequests }
    }

    /// Adjusts resource limits at runtime.
    public static func configure(
        maximumBufferedBytes: Int64? = nil,
        maximumTaskBufferedBytes: Int64? = nil,
        maximumInFlightRequests: Int? = nil
    ) {
        let newGlobalCapacity: Int64?
        if let bytes = maximumBufferedBytes {
            newGlobalCapacity = max(16 * 1024 * 1024, min(512 * 1024 * 1024, bytes))
        } else {
            newGlobalCapacity = nil
        }
        let globalCap = newGlobalCapacity
        state.withLock { current in
            if let clamped = globalCap {
                current.maximumBufferedResourceBytes = clamped
            }
            if let taskBytes = maximumTaskBufferedBytes {
                current.maximumTaskBufferedResourceBytes = max(
                    4 * 1024 * 1024, min(128 * 1024 * 1024, taskBytes))
            }
            if let requests = maximumInFlightRequests {
                current.maximumMediaInFlightRequests = max(1, min(16, requests))
            }
        }
        if let globalCap {
            GlobalMediaBufferBudget.configure(capacity: globalCap)
        }
    }

    /// Auto-tunes limits from the system's physical memory.
    public static func autoTune() {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let gigabytes = Double(physicalMemory) / (1024 * 1024 * 1024)
        let tunedGlobalBytes: Int64
        let tunedTaskBytes: Int64
        if gigabytes <= 4 {
            tunedGlobalBytes = 64 * 1024 * 1024
            tunedTaskBytes = 16 * 1024 * 1024
        } else if gigabytes >= 16 {
            tunedGlobalBytes = 256 * 1024 * 1024
            tunedTaskBytes = 64 * 1024 * 1024
        } else {
            let fraction = (gigabytes - 4) / 12
            let megabytes = 64 + (256 - 64) * fraction
            tunedGlobalBytes = Int64(megabytes * 1024 * 1024)
            tunedTaskBytes = Int64((16 + (64 - 16) * fraction) * 1024 * 1024)
        }
        configure(
            maximumBufferedBytes: tunedGlobalBytes,
            maximumTaskBufferedBytes: tunedTaskBytes
        )
    }
}
