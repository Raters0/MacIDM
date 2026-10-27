import Foundation

/// Coverage rules for segmented checkpoints, checked from one source at
/// both trust boundaries.
///
/// The dynamic split protocol mutates the sidecar concurrently with worker
/// commits. Resume validates the tiling before trusting any committed
/// bytes; publication additionally requires every segment to have committed
/// to its end before the artifact may be handed to the user. A published
/// file with an unowned byte range is silently corrupt — the temporary file
/// is preallocated to the full size, so an orphaned tail reads as zeros
/// while the size check still passes (measured defect: 14 stressed runs
/// published 8 corrupt files as "completed").
enum SegmentCoverage {
    /// Resume semantics: the segments tile `[0, total)` exactly and each
    /// segment's committed offset lies within its own range. Partially
    /// committed segments are expected — they are the resume boundaries.
    static func isValidResumeLayout(_ segments: [SegmentCheckpoint], total: Int64) -> Bool {
        let sorted = segments.sorted { $0.start < $1.start }
        var cursor: Int64 = 0
        for segment in sorted {
            guard segment.start == cursor, segment.endExclusive > segment.start,
                segment.nextUncommittedOffset >= segment.start,
                segment.nextUncommittedOffset <= segment.endExclusive
            else { return false }
            cursor = segment.endExclusive
        }
        return cursor == total
    }

    /// Publish semantics: a valid resume layout *and* every segment
    /// committed to its end. Anything less means some byte range was never
    /// downloaded (for example a split whose child was never scheduled), and
    /// the artifact must fail loudly instead of publishing a file with
    /// holes. Callers throw a retryable `sidecarCorrupt` here so the normal
    /// route re-enters and resumes exactly the uncommitted ranges.
    static func isFullyCommitted(_ segments: [SegmentCheckpoint], total: Int64) -> Bool {
        guard isValidResumeLayout(segments, total: total) else { return false }
        return segments.allSatisfy { $0.nextUncommittedOffset == $0.endExclusive }
    }
}
