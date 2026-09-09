import Foundation

/// Owns pair resume artifacts. Metadata contains digests, never signed URLs.
struct DASHPairCheckpoint {
    struct Track: Codable {
        let size: Int64
        let digest: String
    }
    struct Record: Codable {
        let version: Int
        let videoIdentity: String
        let audioIdentity: String
        var completed: [String: Track]
    }
    let directory: URL
    private var record: Record
    private var metadataURL: URL { directory.appendingPathComponent("checkpoint.json") }

    init(directory: URL, videoURL: URL, audioURL: URL) throws {
        self.directory = directory
        let video = resourceLocatorString(videoURL)
        let audio = resourceLocatorString(audioURL)
        let metadata = directory.appendingPathComponent("checkpoint.json")
        let loaded = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: metadata))
        if let loaded, loaded.version == 1, loaded.videoIdentity == video, loaded.audioIdentity == audio {
            record = loaded
        } else {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            record = Record(version: 1, videoIdentity: video, audioIdentity: audio, completed: [:])
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try persist()
    }

    mutating func existingTrack(at url: URL) throws -> DownloadResult? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let track = record.completed[url.lastPathComponent], track.size > 0,
            let actual = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
            actual.int64Value == track.size,
            (try? FileSupport.sha256(url: url)) == track.digest
        {
            return DownloadResult(
                destination: url, byteCount: track.size, sha256: track.digest,
                usedParallelRequests: 0, resumed: true, verification: "pair-track-checksum")
        }
        try FileManager.default.removeItem(at: url)
        record.completed[url.lastPathComponent] = nil
        try persist()
        return nil
    }

    mutating func recordCompleted(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw IDMError.responseTooShort }
        record.completed[url.lastPathComponent] = Track(size: size, digest: try FileSupport.sha256(url: url))
        try persist()
    }

    private func persist() throws {
        try FileSupport.atomicWrite(JSONEncoder().encode(record), to: metadataURL)
    }
}
