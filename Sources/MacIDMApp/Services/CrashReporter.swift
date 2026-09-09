import Darwin
import Foundation

/// Records fatal events that would otherwise vanish without a trace:
///
/// 1. Signal handler — when the process dies from SIGABRT/SIGTRAP/SIGSEGV/
///    SIGBUS/SIGILL (AppKit constraint crashes surface as SIGTRAP via
///    `+[NSApplication _crashOnException:]`), appends one `[fatal]` line to
///    macidm.log using only async-signal-safe calls (open/write/close), then
///    restores the default disposition and re-raises so the system crash
///    reporter still produces a .ips report.
/// 2. Session marker — a `session-active` file exists for the whole process
///    lifetime. A clean quit removes it in `applicationWillTerminate`; if it
///    is still present at the next launch, the previous session terminated
///    abnormally and a warning is logged.
enum CrashReporter {

    // Written exactly once by `install` before any fatal signal can fire
    // for this session, then read-only from the signal handler afterwards;
    // the lock-free handoff is safe by construction.
    nonisolated(unsafe) private static var logPathBytes: [CChar] = []
    nonisolated(unsafe) private static var fatalPrefixBytes: [UInt8] = []
    nonisolated(unsafe) private static var markerPathBytes: [CChar] = []
    nonisolated(unsafe) private static var markerPath: String = ""

    /// Installs signal handlers and evaluates the previous session's marker.
    /// Call exactly once, as early as possible after launch.
    static func install(logFileURL: URL) {
        logPathBytes = Array(logFileURL.path.utf8CString)
        fatalPrefixBytes = Array("[fatal] [system] crash: signal ".utf8)

        let markerURL = logFileURL.deletingLastPathComponent()
            .appendingPathComponent("session-active")
        markerPathBytes = Array(markerURL.path.utf8CString)
        markerPath = markerURL.path

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: markerURL.path) {
            AppLogger.shared.warning(
                .system,
                "previous session terminated abnormally (session marker was still present at launch)"
            )
        }
        fileManager.createFile(atPath: markerURL.path, contents: Data())

        for sig: Int32 in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL] {
            signal(sig, crashSignalHandler)
        }
    }

    /// Removes the session marker on a clean shutdown so the next launch
    /// does not misreport an abnormal termination.
    static func markCleanShutdown() {
        guard !markerPath.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    // @convention(c) closures must not capture context; all state lives in
    // the static byte buffers prepared by `install`.
    private static let crashSignalHandler: @convention(c) (Int32) -> Void = { sig in
        // Async-signal-safe territory only: no malloc, no ObjC, no locks.
        markerPathBytes.withUnsafeBufferPointer { markerBuf in
            if let base = markerBuf.baseAddress {
                // A fatal signal confirms the abnormal exit; clearing the
                // marker keeps the next launch's detection accurate even if
                // the re-raised signal is intercepted again.
                unlink(base)
            }
        }
        logPathBytes.withUnsafeBufferPointer { pathBuf in
            guard let base = pathBuf.baseAddress else { return }
            let fd = open(base, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 64)
            var count = 0
            for byte in fatalPrefixBytes where count < buffer.count {
                buffer[count] = byte
                count += 1
            }
            // Render the signal number without pulling in printf.
            var digits = [UInt8](repeating: 0, count: 8)
            var digitCount = 0
            var value = Int(sig)
            repeat {
                digits[digitCount] = UInt8(48 + value % 10)
                digitCount += 1
                value /= 10
            } while value > 0 && digitCount < digits.count
            for index in stride(from: digitCount - 1, through: 0, by: -1)
            where count < buffer.count {
                buffer[count] = digits[index]
                count += 1
            }
            if count < buffer.count {
                buffer[count] = UInt8(ascii: "\n")
                count += 1
            }
            buffer.withUnsafeBufferPointer { lineBuf in
                _ = write(fd, lineBuf.baseAddress, count)
            }
            close(fd)
        }
        // Hand back to the default disposition and re-raise so macOS still
        // produces a DiagnosticReports .ips entry.
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
