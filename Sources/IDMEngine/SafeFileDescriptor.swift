import Darwin
import Foundation

/// A POSIX-safe file descriptor wrapper.
///
/// Creates files exclusively via `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW` with `0600`
/// (S_IRUSR | S_IWUSR) permissions, preventing symlink hijacking, concurrent overwrites,
/// and unauthorized access.
public final class SafeFileDescriptor: @unchecked Sendable {
    public let rawDescriptor: Int32
    public let path: String
    private let lock = NSLock()
    private var isClosed = false

    /// Creates a file exclusively with O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW and 0600
    /// permissions.
    public init(creatingExclusiveAt url: URL) throws {
        self.path = url.path
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        let fd = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let err = errno
            if err == EEXIST {
                throw IDMError.filenameConflict(url.path)
            }
            throw IDMError.storageError(String(cString: strerror(err)))
        }
        self.rawDescriptor = fd
    }

    deinit {
        closeInternal()
    }

    /// Writes Data to the file descriptor with full large-chunk writes and EINTR retries.
    public func writeAll(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw IDMError.storageError("文件描述符已关闭") }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(rawDescriptor, base.advanced(by: written), buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw IDMError.storageError(String(cString: strerror(errno)))
                }
                if result == 0 {
                    throw IDMError.storageError("write returned zero bytes")
                }
                written += result
            }
        }
    }

    /// Forces the file buffer out to physical storage (fsync).
    public func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        guard fsync(rawDescriptor) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
    }

    /// Closes the underlying file descriptor.
    public func closeFile() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        guard close(rawDescriptor) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
    }

    private func closeInternal() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed {
            isClosed = true
            close(rawDescriptor)
        }
    }
}
