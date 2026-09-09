import CryptoKit
import Darwin
import Foundation

final class RandomAccessSink: @unchecked Sendable {
    let fileDescriptor: Int32
    let totalSize: Int64?

    init(url: URL, totalSize: Int64?, create: Bool) throws {
        if create, let totalSize, totalSize > 0 {
            try FileSupport.ensureAvailableCapacity(at: url, bytes: totalSize)
        }
        let flags = O_RDWR | (create ? (O_CREAT | O_EXCL) : 0) | O_NOFOLLOW
        fileDescriptor = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        self.totalSize = totalSize
        if create, let totalSize, ftruncate(fileDescriptor, totalSize) != 0 {
            let message = String(cString: strerror(errno))
            close(fileDescriptor)
            throw IDMError.storageError(message)
        }
    }

    deinit { close(fileDescriptor) }

    func write(_ data: Data, at offset: Int64, limit: Int64) throws {
        guard offset >= 0, offset <= limit,
            Int64(data.count) <= limit - offset,
            totalSize.map({ limit <= $0 }) ?? true
        else { throw IDMError.responseTooLong }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = pwrite(
                    fileDescriptor,
                    base.advanced(by: written),
                    buffer.count - written,
                    off_t(offset + Int64(written))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw IDMError.storageError(String(cString: strerror(errno)))
                }
                if result == 0 { throw IDMError.storageError("pwrite returned zero") }
                written += result
            }
        }
    }

    func synchronize() throws {
        guard fsync(fileDescriptor) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
    }

    func truncate(to size: Int64) throws {
        guard size >= 0, totalSize.map({ size <= $0 }) ?? true else {
            throw IDMError.responseTooLong
        }
        guard ftruncate(fileDescriptor, off_t(size)) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
    }

    func identity() throws -> FileIdentity {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

struct FileIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum FileSupport {
    /// ftruncate on APFS may create a sparse file without reserving all
    /// physical blocks. Check the destination volume before creating a known
    /// sized temporary so an avoidable ENOSPC arrives before a task appears
    /// to have started. Resource values are advisory; writes still handle a
    /// later ENOSPC and transition the task to storageError.
    static func ensureAvailableCapacity(at url: URL, bytes: Int64) throws {
        guard bytes > 0 else { return }
        let directory = url.deletingLastPathComponent()
        guard
            let values = try? directory.resourceValues(
                forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey,
                    .volumeAvailableCapacityKey,
                ]
            )
        else { return }
        let available =
            values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < bytes {
            throw IDMError.storageError("目标卷可用空间不足")
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize {
            return Int64(size)
        }
        let attr = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let sizeNum = attr[.size] as? NSNumber else {
            throw IDMError.storageError("无法获取文件大小: \(url.path)")
        }
        return sizeNum.int64Value
    }

    static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        guard let aData = a.data(using: .utf8), let bData = b.data(using: .utf8) else {
            return false
        }
        guard aData.count == bData.count else { return false }
        var result: UInt8 = 0
        for (byteA, byteB) in zip(aData, bData) {
            result |= byteA ^ byteB
        }
        return result == 0
    }

    static func exclusivePublish(
        from: URL,
        to: URL,
        synchronizeParentDirectory: Bool = true
    ) throws {
        guard renameatx_np(AT_FDCWD, from.path, AT_FDCWD, to.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw IDMError.filenameConflict(to.path) }
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        if synchronizeParentDirectory {
            syncDirectory(to.deletingLastPathComponent())
        }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp.\(UUID().uuidString)")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }

        var isOpen = true
        var isPublished = false
        defer {
            if isOpen { close(descriptor) }
            if !isPublished { unlink(temporary.path) }
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw IDMError.storageError(String(cString: strerror(errno)))
                }
                if result == 0 { throw IDMError.storageError("write returned zero") }
                offset += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        guard close(descriptor) == 0 else {
            isOpen = false
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        isOpen = false
        guard rename(temporary.path, url.path) == 0 else {
            throw IDMError.storageError(String(cString: strerror(errno)))
        }
        isPublished = true
        syncDirectory(url.deletingLastPathComponent())
    }

    private nonisolated static let syncGate = SyncGate()

    /// Directory fsync is a best-effort durability hint after rename.
    /// Certain directory implementations (notably iCloud-synced folders
    /// under heavy sync load) can block `open()` on the directory itself
    /// for minutes; that must never stall the download pipeline. The sync
    /// therefore runs on a utility thread with a hard timeout, skips when a
    /// previous sync is still in flight, and never throws: the published
    /// file was already fsynced before rename, and sidecar payloads are
    /// checksum-protected, so a lost directory sync degrades at worst to a
    /// re-download after a crash.
    static func syncDirectory(_ url: URL) {
        guard syncGate.enter() else { return }
        let path = url.path
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let descriptor = open(path, O_RDONLY | O_DIRECTORY)
            if descriptor >= 0 {
                _ = fsync(descriptor)
                close(descriptor)
            }
            syncGate.leave()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    /// Single-flight gate: at most one directory sync may be in progress.
    private final class SyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = false

        func enter() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if inFlight { return false }
            inFlight = true
            return true
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            inFlight = false
        }
    }
}

func isCancellationOrPauseError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let idm = error as? IDMError {
        switch idm {
        case .cancelled, .paused:
            return true
        default:
            break
        }
    }
    if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}
