import CryptoKit
import Foundation

struct HLSTemporaryPaths: Sendable {
    let directory: URL
    let unitPrefix: String
    let temporary: URL
    let sidecar: URL
    let baseName: String

    func unitTemporary(index: Int) -> URL {
        directory.appendingPathComponent("\(unitPrefix)\(index).macidm.hls.tmp")
    }
}

enum HLSResumeStore {
    private struct Envelope: Codable {
        let record: HLSResumeRecord
        let checksum: String
    }

    static func read(from url: URL) throws -> HLSResumeRecord {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard digest(try canonicalData(envelope.record)) == envelope.checksum else {
            throw IDMError.sidecarCorrupt
        }
        return envelope.record
    }

    static func write(
        _ record: HLSResumeRecord,
        to url: URL,
        synchronizeParentDirectory: Bool = false
    ) throws {
        let envelope = Envelope(record: record, checksum: digest(try canonicalData(record)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
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
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let result = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw IDMError.storageError(String(cString: strerror(errno)))
                    }
                    if result == 0 {
                        throw IDMError.storageError("resume record write returned zero")
                    }
                    offset += result
                }
            }
            guard fsync(descriptor) == 0 else {
                throw IDMError.storageError(String(cString: strerror(errno)))
            }
            close(descriptor)
            isOpen = false
            guard rename(temporary.path, url.path) == 0 else {
                throw IDMError.storageError(String(cString: strerror(errno)))
            }
        } catch {
            if isOpen { close(descriptor) }
            unlink(temporary.path)
            throw error
        }
        if synchronizeParentDirectory {
            FileSupport.syncDirectory(url.deletingLastPathComponent())
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw IDMError.sidecarCorrupt }
        return size.int64Value
    }

    static func fileIdentity(_ url: URL) throws -> HLSResumeFileIdentity {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw IDMError.sidecarCorrupt
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw IDMError.sidecarCorrupt
        }
        return HLSResumeFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func canonicalData(_ record: HLSResumeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
