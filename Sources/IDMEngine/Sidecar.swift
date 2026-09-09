import CryptoKit
import Foundation

struct SegmentCheckpoint: Codable, Hashable, Sendable {
    let index: Int
    let start: Int64
    /// Mutable so a coordinator-driven split can shrink the parent's
    /// committed range when a synthetic child takes over the tail.
    var endExclusive: Int64
    var nextUncommittedOffset: Int64
}

struct SidecarPayload: Codable, Sendable {
    let formatVersion: Int
    let taskID: UUID
    let fileIdentity: FileIdentity
    let totalSize: Int64
    let resourceIdentity: ResourceIdentity
    var segments: [SegmentCheckpoint]
    let generation: Int
    var phase: String
}

private struct SidecarEnvelope: Codable {
    let payload: SidecarPayload
    let checksum: String
}

enum SidecarStore {
    static func read(from url: URL) throws -> SidecarPayload {
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(SidecarEnvelope.self, from: data)
        let payloadData = try canonicalData(envelope.payload)
        guard digest(payloadData) == envelope.checksum else { throw IDMError.sidecarCorrupt }
        guard envelope.payload.formatVersion == 1 else { throw IDMError.sidecarCorrupt }
        return envelope.payload
    }

    static func write(_ payload: SidecarPayload, to url: URL) throws {
        let payloadData = try canonicalData(payload)
        let envelope = SidecarEnvelope(payload: payload, checksum: digest(payloadData))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try FileSupport.atomicWrite(data, to: url)
    }

    private static func canonicalData(_ payload: SidecarPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
