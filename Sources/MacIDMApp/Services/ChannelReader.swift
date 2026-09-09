import Darwin
import Foundation

/// Unified output-channel read helper: `read(2)` results
/// must never be misclassified. `EINTR` retries in place; a real read error
/// surfaces as a diagnosable channel failure instead of masquerading as EOF;
/// only a zero-length read is EOF.
enum ChannelReader {
    enum ReadOutcome: Equatable, Sendable {
        /// Bytes available in the buffer.
        case bytes(Int)
        /// All write ends closed.
        case endOfFile
        /// A read error other than EINTR; carries the errno for diagnostics.
        /// A channel failure must be recorded as a diagnosable error, never
        /// masquerading as a normal EOF.
        case channelFailure(Int32)
    }

    /// One read attempt against `fileDescriptor`. The `systemRead` seam lets
    /// tests inject a single `EINTR` (or other errno) deterministically.
    static func read(
        fileDescriptor: Int32,
        buffer: UnsafeMutableRawPointer,
        count: Int,
        systemRead: (Int32, UnsafeMutableRawPointer, Int) -> Int = { fd, buf, n in
            Darwin.read(fd, buf, n)
        }
    ) -> ReadOutcome {
        while true {
            let result = systemRead(fileDescriptor, buffer, count)
            if result > 0 { return .bytes(result) }
            if result == 0 { return .endOfFile }
            if errno == EINTR { continue }
            return .channelFailure(errno)
        }
    }
}
