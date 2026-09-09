import CryptoKit
import Foundation

public enum HLSDownloadUnitKind: String, Codable, Equatable, Sendable {
    case initialization
    case media
}

/// A transient unit for one initialization segment or media segment.
///
/// The unit deliberately is not Codable. Segment and key URLs may contain
/// signed query values and must not enter ordinary task JSON or sidecars.
public struct HLSDownloadUnit: Equatable, Sendable {
    public let index: Int
    public let kind: HLSDownloadUnitKind
    public let url: URL
    public let duration: Double?
    public let byteRange: HLSByteRange?
    public let encryptionKey: HLSEncryptionKey?
    public let mediaSequence: Int64?
    public let isDiscontinuity: Bool

    public init(
        index: Int,
        kind: HLSDownloadUnitKind,
        url: URL,
        duration: Double? = nil,
        byteRange: HLSByteRange? = nil,
        encryptionKey: HLSEncryptionKey? = nil,
        mediaSequence: Int64? = nil,
        isDiscontinuity: Bool = false
    ) {
        self.index = index
        self.kind = kind
        self.url = url
        self.duration = duration
        self.byteRange = byteRange
        self.encryptionKey = encryptionKey
        self.mediaSequence = mediaSequence
        self.isDiscontinuity = isDiscontinuity
    }
}

public enum HLSResumeError: Error, Equatable, Sendable {
    case taskChanged
    case playlistChanged
    case unitChanged(Int)
    case invalidCheckpoint(Int)
    case unsupportedFormat(Int)
}

extension HLSResumeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .taskChanged: "HLS resume task identity changed"
        case .playlistChanged: "HLS playlist identity changed"
        case .unitChanged(let index): "HLS resume unit changed at index \(index)"
        case .invalidCheckpoint(let index): "HLS resume checkpoint is invalid at index \(index)"
        case .unsupportedFormat(let version): "Unsupported HLS resume format: \(version)"
        }
    }
}

public struct HLSDownloadPlan: Equatable, Sendable {
    public let playlistURL: URL
    public let mediaSequence: Int64
    public let isVideoOnDemand: Bool
    public let totalDuration: Double
    public let units: [HLSDownloadUnit]

    public init(
        playlistURL: URL,
        mediaSequence: Int64,
        isVideoOnDemand: Bool,
        totalDuration: Double,
        units: [HLSDownloadUnit]
    ) {
        self.playlistURL = playlistURL
        self.mediaSequence = mediaSequence
        self.isVideoOnDemand = isVideoOnDemand
        self.totalDuration = totalDuration
        self.units = units
    }

    /// A non-reversible identity used to bind a resume record to the current plan.
    /// The digest is safe to persist; raw playlist, segment, and key URLs are not.
    public var fingerprint: String {
        HLSIdentityFingerprint.plan(self)
    }
}

public struct HLSDownloadPlanner: Sendable {
    public init() {}

    public func makePlan(
        _ playlist: HLSMediaPlaylist,
        playlistURL: URL
    ) throws -> HLSDownloadPlan {
        guard playlist.isVideoOnDemand else {
            throw IDMError.unsupportedScheme
        }
        var units: [HLSDownloadUnit] = []
        if let initialization = playlist.initializationSegment {
            units.append(
                HLSDownloadUnit(
                    index: 0,
                    kind: .initialization,
                    url: initialization.url,
                    byteRange: initialization.byteRange,
                    encryptionKey: initialization.encryptionKey
                ))
        }
        let firstMediaIndex = units.count
        for (offset, segment) in playlist.segments.enumerated() {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSParserError.invalidNumber(String(segment.duration))
            }
            let sequenceOffset = Int64(offset)
            guard playlist.mediaSequence <= Int64.max - sequenceOffset else {
                throw HLSParserError.invalidNumber(String(playlist.mediaSequence))
            }
            units.append(
                HLSDownloadUnit(
                    index: firstMediaIndex + offset,
                    kind: .media,
                    url: segment.url,
                    duration: segment.duration,
                    byteRange: segment.byteRange,
                    encryptionKey: segment.encryptionKey,
                    mediaSequence: playlist.mediaSequence + sequenceOffset,
                    isDiscontinuity: segment.isDiscontinuity
                ))
        }
        guard !units.isEmpty else { throw HLSParserError.emptyPlaylist }
        let totalDuration = playlist.segments.reduce(0) { $0 + $1.duration }
        guard totalDuration.isFinite else {
            throw HLSParserError.invalidNumber(String(totalDuration))
        }
        return HLSDownloadPlan(
            playlistURL: playlistURL,
            mediaSequence: playlist.mediaSequence,
            isVideoOnDemand: playlist.isVideoOnDemand,
            totalDuration: totalDuration,
            units: units
        )
    }
}

public struct HLSUnitCheckpoint: Equatable, Sendable {
    public let unitIndex: Int
    public let unit: HLSDownloadUnit
    public var receivedBytes: Int64
    public var completed: Bool

    public init(
        unitIndex: Int,
        unit: HLSDownloadUnit,
        receivedBytes: Int64 = 0,
        completed: Bool = false
    ) {
        self.unitIndex = unitIndex
        self.unit = unit
        self.receivedBytes = receivedBytes
        self.completed = completed
    }
}

/// The only HLS resume data allowed to cross a persistence boundary.
///
/// It contains one-way fingerprints rather than playlist, segment, or key URLs.
public struct HLSResumeUnitRecord: Codable, Equatable, Sendable {
    public let unitIndex: Int
    public let fingerprint: String
    public var receivedBytes: Int64
    public var completed: Bool

    public init(
        unitIndex: Int,
        fingerprint: String,
        receivedBytes: Int64 = 0,
        completed: Bool = false
    ) {
        self.unitIndex = unitIndex
        self.fingerprint = fingerprint
        self.receivedBytes = receivedBytes
        self.completed = completed
    }
}

public struct HLSResumeRecord: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let taskID: UUID
    public let planFingerprint: String
    public let fileIdentity: HLSResumeFileIdentity?
    public var units: [HLSResumeUnitRecord]

    public init(
        formatVersion: Int = 1,
        taskID: UUID,
        planFingerprint: String,
        fileIdentity: HLSResumeFileIdentity? = nil,
        units: [HLSResumeUnitRecord]
    ) {
        self.formatVersion = formatVersion
        self.taskID = taskID
        self.planFingerprint = planFingerprint
        self.fileIdentity = fileIdentity
        self.units = units
    }
}

public struct HLSResumeFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct HLSResumeState: Equatable, Sendable {
    public let formatVersion: Int
    public let taskID: UUID
    public let plan: HLSDownloadPlan
    public var units: [HLSUnitCheckpoint]

    public init(formatVersion: Int = 1, taskID: UUID, plan: HLSDownloadPlan) {
        self.formatVersion = formatVersion
        self.taskID = taskID
        self.plan = plan
        self.units = plan.units.map {
            HLSUnitCheckpoint(unitIndex: $0.index, unit: $0)
        }
    }

    public init(record: HLSResumeRecord, plan: HLSDownloadPlan) throws {
        guard record.formatVersion == 1 else {
            throw HLSResumeError.unsupportedFormat(record.formatVersion)
        }
        guard record.planFingerprint == plan.fingerprint,
            record.units.count == plan.units.count
        else {
            throw HLSResumeError.playlistChanged
        }
        var checkpoints: [HLSUnitCheckpoint] = []
        var sawIncomplete = false
        for (unit, recordUnit) in zip(plan.units, record.units) {
            guard recordUnit.unitIndex == unit.index,
                recordUnit.fingerprint == HLSIdentityFingerprint.unit(unit),
                recordUnit.receivedBytes >= 0,
                !recordUnit.completed || recordUnit.receivedBytes > 0 || unit.byteRange?.length == 0
            else {
                throw HLSResumeError.unitChanged(unit.index)
            }
            if recordUnit.completed {
                guard !sawIncomplete else {
                    throw HLSResumeError.invalidCheckpoint(unit.index)
                }
            } else {
                sawIncomplete = true
            }
            checkpoints.append(
                HLSUnitCheckpoint(
                    unitIndex: unit.index,
                    unit: unit,
                    receivedBytes: recordUnit.receivedBytes,
                    completed: recordUnit.completed
                ))
        }
        self.formatVersion = record.formatVersion
        self.taskID = record.taskID
        self.plan = plan
        self.units = checkpoints
    }

    public func record(fileIdentity: HLSResumeFileIdentity? = nil) -> HLSResumeRecord {
        HLSResumeRecord(
            formatVersion: formatVersion,
            taskID: taskID,
            planFingerprint: plan.fingerprint,
            fileIdentity: fileIdentity,
            units: units.map {
                HLSResumeUnitRecord(
                    unitIndex: $0.unitIndex,
                    fingerprint: HLSIdentityFingerprint.unit($0.unit),
                    receivedBytes: $0.receivedBytes,
                    completed: $0.completed
                )
            })
    }

    public mutating func markCompleted(unitIndex: Int, receivedBytes: Int64) throws {
        guard let index = units.firstIndex(where: { $0.unitIndex == unitIndex }) else {
            throw HLSResumeError.invalidCheckpoint(unitIndex)
        }
        guard receivedBytes >= 0 else {
            throw HLSResumeError.invalidCheckpoint(unitIndex)
        }
        units[index].receivedBytes = receivedBytes
        units[index].completed = true
    }

    public func validatingCompatibility(
        taskID: UUID,
        plan: HLSDownloadPlan
    ) throws {
        guard self.taskID == taskID else { throw HLSResumeError.taskChanged }
        guard self.plan.playlistURL == plan.playlistURL,
            self.plan.mediaSequence == plan.mediaSequence,
            self.plan.isVideoOnDemand == plan.isVideoOnDemand,
            self.plan.units.count == plan.units.count
        else {
            throw HLSResumeError.playlistChanged
        }
        guard units.count == plan.units.count else {
            throw HLSResumeError.playlistChanged
        }
        var sawIncomplete = false
        for (old, current) in zip(units, plan.units) {
            guard old.unitIndex == current.index, old.unit == current else {
                throw HLSResumeError.unitChanged(current.index)
            }
            guard old.receivedBytes >= 0,
                (!old.completed || old.receivedBytes > 0 || old.unit.byteRange?.length == 0)
            else {
                throw HLSResumeError.invalidCheckpoint(old.unitIndex)
            }
            if old.completed {
                guard !sawIncomplete else {
                    throw HLSResumeError.invalidCheckpoint(old.unitIndex)
                }
            } else {
                sawIncomplete = true
            }
        }
        guard self.plan.fingerprint == plan.fingerprint else {
            throw HLSResumeError.playlistChanged
        }
    }
}

private enum HLSIdentityFingerprint {
    static func plan(_ plan: HLSDownloadPlan) -> String {
        let units = plan.units.map(unit).joined(separator: "\n")
        return digest(
            "playlist=\(plan.playlistURL.absoluteString)\nsequence=\(plan.mediaSequence)\nvod=\(plan.isVideoOnDemand)\nduration=\(plan.totalDuration)\n\(units)"
        )
    }

    static func unit(_ unit: HLSDownloadUnit) -> String {
        let duration = unit.duration.map { String($0) } ?? ""
        let range = unit.byteRange.map { "\($0.length):\($0.offset)" } ?? ""
        let mediaSequence = unit.mediaSequence.map { String($0) } ?? ""
        let key =
            unit.encryptionKey.map { key in
                "\(key.url.absoluteString)|\(key.iv ?? "")"
            } ?? ""
        return digest(
            [
                "index=\(unit.index)",
                "kind=\(unit.kind.rawValue)",
                "url=\(unit.url.absoluteString)",
                "duration=\(duration)",
                "range=\(range)",
                "mediaSequence=\(mediaSequence)",
                "discontinuity=\(unit.isDiscontinuity)",
                "key=\(key)",
            ].joined(separator: "\u{1f}"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
