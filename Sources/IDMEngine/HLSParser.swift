import Foundation

public enum HLSParserError: Error, Equatable, Sendable {
    case emptyPlaylist
    case playlistTooLarge
    case invalidAttribute(String)
    case invalidURL(String)
    case invalidNumber(String)
    case malformedTag(String)
    case unsupportedEncryption(String)
    case segmentWithoutDuration
    case missingVariantURL
}

extension HLSParserError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPlaylist: "HLS playlist is empty"
        case .playlistTooLarge: "HLS playlist exceeds the safety limit"
        case .invalidAttribute(let name): "Invalid HLS attribute: \(name)"
        case .invalidURL(let value): "Invalid HLS URL: \(value)"
        case .invalidNumber(let value): "Invalid HLS number: \(value)"
        case .malformedTag(let tag): "Malformed HLS tag: \(tag)"
        case .unsupportedEncryption(let method): "Unsupported HLS encryption method: \(method)"
        case .segmentWithoutDuration: "HLS segment URI has no preceding EXTINF"
        case .missingVariantURL: "HLS variant has no following URI"
        }
    }
}

public struct HLSVariant: Equatable, Sendable {
    public let url: URL
    public let bandwidth: Int
    public let averageBandwidth: Int?
    public let width: Int?
    public let height: Int?
    public let codecs: String?
    public let audioGroup: String?
    public let videoGroup: String?
    public let subtitlesGroup: String?

    public init(
        url: URL,
        bandwidth: Int,
        averageBandwidth: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        codecs: String? = nil,
        audioGroup: String? = nil,
        videoGroup: String? = nil,
        subtitlesGroup: String? = nil
    ) {
        self.url = url
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.width = width
        self.height = height
        self.codecs = codecs
        self.audioGroup = audioGroup
        self.videoGroup = videoGroup
        self.subtitlesGroup = subtitlesGroup
    }
}

public struct HLSMediaGroup: Equatable, Sendable {
    public let type: String
    public let groupID: String
    public let name: String
    public let language: String?
    public let isDefault: Bool
    public let isAutoSelect: Bool
    public let url: URL?

    public init(
        type: String,
        groupID: String,
        name: String,
        language: String? = nil,
        isDefault: Bool = false,
        isAutoSelect: Bool = false,
        url: URL? = nil
    ) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isAutoSelect = isAutoSelect
        self.url = url
    }
}

public struct HLSMasterPlaylist: Equatable, Sendable {
    public let variants: [HLSVariant]
    public let mediaGroups: [HLSMediaGroup]

    public init(variants: [HLSVariant], mediaGroups: [HLSMediaGroup]) {
        self.variants = variants
        self.mediaGroups = mediaGroups
    }
}

public enum HLSAudioRendition {
    /// Resolves the EXT-X-MEDIA audio rendition backing a variant's AUDIO
    /// group (separate-audio HLS masters, e.g. X/Twitter). Prefers DEFAULT
    /// renditions and requires an absolute media playlist URI — renditions
    /// without URI are inline alternates, not downloadable tracks.
    public static func resolve(variant: HLSVariant, in master: HLSMasterPlaylist) -> HLSMediaGroup? {
        guard let groupID = variant.audioGroup else { return nil }
        let candidates = master.mediaGroups.filter {
            $0.type == "AUDIO" && $0.groupID == groupID && $0.url != nil
        }
        return candidates.first(where: { $0.isDefault }) ?? candidates.first
    }
}

public struct HLSByteRange: Equatable, Sendable {
    public let length: Int64
    public let offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }
}

public struct HLSEncryptionKey: Equatable, Sendable {
    public let url: URL
    public let iv: String?

    public init(url: URL, iv: String? = nil) {
        self.url = url
        self.iv = iv
    }
}

public struct HLSInitializationSegment: Equatable, Sendable {
    public let url: URL
    public let byteRange: HLSByteRange?
    public let encryptionKey: HLSEncryptionKey?

    public init(
        url: URL,
        byteRange: HLSByteRange? = nil,
        encryptionKey: HLSEncryptionKey? = nil
    ) {
        self.url = url
        self.byteRange = byteRange
        self.encryptionKey = encryptionKey
    }
}

public struct HLSSegment: Equatable, Sendable {
    public let url: URL
    public let duration: Double
    public let title: String
    public let byteRange: HLSByteRange?
    public let encryptionKey: HLSEncryptionKey?
    public let isDiscontinuity: Bool

    public init(
        url: URL,
        duration: Double,
        title: String,
        byteRange: HLSByteRange? = nil,
        encryptionKey: HLSEncryptionKey? = nil,
        isDiscontinuity: Bool = false
    ) {
        self.url = url
        self.duration = duration
        self.title = title
        self.byteRange = byteRange
        self.encryptionKey = encryptionKey
        self.isDiscontinuity = isDiscontinuity
    }
}

public struct HLSMediaPlaylist: Equatable, Sendable {
    public let targetDuration: Double?
    public let mediaSequence: Int64
    public let playlistType: String?
    public let isEndList: Bool
    public let initializationSegment: HLSInitializationSegment?
    public let segments: [HLSSegment]

    public init(
        targetDuration: Double?,
        mediaSequence: Int64,
        playlistType: String?,
        isEndList: Bool,
        initializationSegment: HLSInitializationSegment?,
        segments: [HLSSegment]
    ) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.playlistType = playlistType
        self.isEndList = isEndList
        self.initializationSegment = initializationSegment
        self.segments = segments
    }

    public var isVideoOnDemand: Bool {
        isEndList || playlistType?.uppercased() == "VOD"
    }
}

public enum HLSPlaylist: Equatable, Sendable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

public struct HLSParser: Sendable {
    public let maximumPlaylistBytes: Int
    public let maximumSegments: Int

    public init(maximumPlaylistBytes: Int = 4 * 1024 * 1024, maximumSegments: Int = 100_000) {
        self.maximumPlaylistBytes = maximumPlaylistBytes
        self.maximumSegments = maximumSegments
    }

    public func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        guard text.utf8.count <= maximumPlaylistBytes else { throw HLSParserError.playlistTooLarge }
        let lines =
            text
            .split(whereSeparator: \.isNewline)
            .map { line in
                var value = String(line)
                if value.first == "\u{FEFF}" { value.removeFirst() }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard lines.contains(where: { $0 == "#EXTM3U" }) else {
            throw HLSParserError.malformedTag("#EXTM3U")
        }
        guard lines.count > 1 else { throw HLSParserError.emptyPlaylist }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") || $0.hasPrefix("#EXT-X-MEDIA:") }) {
            return .master(try parseMaster(lines, baseURL: baseURL))
        }
        return .media(try parseMedia(lines, baseURL: baseURL))
    }

    private func parseMaster(_ lines: [String], baseURL: URL) throws -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var mediaGroups: [HLSMediaGroup] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = try attributes(from: line, tag: "#EXT-X-STREAM-INF")
                guard let bandwidth = int(attributes["BANDWIDTH"]) else {
                    throw HLSParserError.invalidAttribute("BANDWIDTH")
                }
                index += 1
                guard index < lines.count, !lines[index].hasPrefix("#") else {
                    throw HLSParserError.missingVariantURL
                }
                let url = try resolve(lines[index], against: baseURL)
                let resolution = resolution(attributes["RESOLUTION"])
                variants.append(
                    HLSVariant(
                        url: url,
                        bandwidth: bandwidth,
                        averageBandwidth: int(attributes["AVERAGE-BANDWIDTH"]),
                        width: resolution?.width,
                        height: resolution?.height,
                        codecs: attributes["CODECS"],
                        audioGroup: attributes["AUDIO"],
                        videoGroup: attributes["VIDEO"],
                        subtitlesGroup: attributes["SUBTITLES"]
                    ))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = try attributes(from: line, tag: "#EXT-X-MEDIA")
                guard let type = attributes["TYPE"],
                    let groupID = attributes["GROUP-ID"],
                    let name = attributes["NAME"]
                else {
                    throw HLSParserError.invalidAttribute("TYPE/GROUP-ID/NAME")
                }
                mediaGroups.append(
                    HLSMediaGroup(
                        type: type,
                        groupID: groupID,
                        name: name,
                        language: attributes["LANGUAGE"],
                        isDefault: boolean(attributes["DEFAULT"]),
                        isAutoSelect: boolean(attributes["AUTOSELECT"]),
                        url: try optionalURL(attributes["URI"], baseURL: baseURL)
                    ))
            }
            index += 1
        }
        guard !variants.isEmpty || !mediaGroups.isEmpty else {
            throw HLSParserError.emptyPlaylist
        }
        return HLSMasterPlaylist(variants: variants, mediaGroups: mediaGroups)
    }

    private func parseMedia(_ lines: [String], baseURL: URL) throws -> HLSMediaPlaylist {
        var targetDuration: Double?
        var mediaSequence: Int64 = 0
        var playlistType: String?
        var isEndList = false
        var initializationSegment: HLSInitializationSegment?
        var segments: [HLSSegment] = []
        var pendingDuration: Double?
        var pendingTitle = ""
        var pendingByteRange: PendingByteRange?
        var pendingDiscontinuity = false
        var currentKey: HLSEncryptionKey?
        var previousRangeEnd: Int64 = 0
        // RFC 8216: EXT-X-MAP BYTERANGE offsets are relative to the previous
        // map's range, not to media segment ranges.
        var previousMapRangeEnd: Int64 = 0

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = try positiveDouble(value(after: line, tag: "#EXT-X-TARGETDURATION"))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = try nonNegativeInt64(value(after: line, tag: "#EXT-X-MEDIA-SEQUENCE"))
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                let value = value(after: line, tag: "#EXT-X-PLAYLIST-TYPE").uppercased()
                guard value == "VOD" || value == "EVENT" else {
                    throw HLSParserError.invalidAttribute("PLAYLIST-TYPE")
                }
                playlistType = value
            } else if line.hasPrefix("#EXTINF:") {
                let payload = value(after: line, tag: "#EXTINF")
                let pieces = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                pendingDuration = try positiveDouble(String(pieces[0]))
                pendingTitle = pieces.count == 2 ? String(pieces[1]) : ""
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try parseByteRange(value(after: line, tag: "#EXT-X-BYTERANGE"))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try attributes(from: line, tag: "#EXT-X-MAP")
                guard let uri = attributes["URI"] else { throw HLSParserError.invalidAttribute("URI") }
                let byteRange: HLSByteRange?
                if let value = attributes["BYTERANGE"] {
                    let mapRange = try parseByteRange(value).resolved(using: previousMapRangeEnd)
                    previousMapRangeEnd = try advancedRangeEnd(from: mapRange.offset, adding: mapRange.length)
                    byteRange = mapRange
                } else {
                    byteRange = nil
                }
                initializationSegment = HLSInitializationSegment(
                    url: try resolve(uri, against: baseURL),
                    byteRange: byteRange,
                    encryptionKey: currentKey
                )
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = try attributes(from: line, tag: "#EXT-X-KEY")
                guard let method = attributes["METHOD"]?.uppercased() else {
                    throw HLSParserError.invalidAttribute("METHOD")
                }
                if method == "NONE" {
                    currentKey = nil
                } else if method == "AES-128" {
                    guard let uri = attributes["URI"] else { throw HLSParserError.invalidAttribute("URI") }
                    currentKey = HLSEncryptionKey(
                        url: try resolve(uri, against: baseURL),
                        iv: try normalizedIV(attributes["IV"])
                    )
                } else {
                    throw HLSParserError.unsupportedEncryption(method)
                }
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line == "#EXT-X-ENDLIST" {
                isEndList = true
            } else if !line.hasPrefix("#") {
                guard let duration = pendingDuration else { throw HLSParserError.segmentWithoutDuration }
                guard segments.count < maximumSegments else { throw HLSParserError.playlistTooLarge }
                let byteRange = try pendingByteRange?.resolved(using: previousRangeEnd)
                if let byteRange {
                    let (nextEnd, overflow) = byteRange.offset.addingReportingOverflow(byteRange.length)
                    guard !overflow, nextEnd >= 0 else {
                        throw HLSParserError.invalidNumber("\(byteRange.length)@\(byteRange.offset)")
                    }
                    previousRangeEnd = nextEnd
                }
                segments.append(
                    HLSSegment(
                        url: try resolve(line, against: baseURL),
                        duration: duration,
                        title: pendingTitle,
                        byteRange: byteRange,
                        encryptionKey: currentKey,
                        isDiscontinuity: pendingDiscontinuity
                    ))
                pendingDuration = nil
                pendingTitle = ""
                pendingByteRange = nil
                pendingDiscontinuity = false
            }
        }
        guard !segments.isEmpty else { throw HLSParserError.emptyPlaylist }
        guard pendingDuration == nil else { throw HLSParserError.malformedTag("EXTINF") }
        return HLSMediaPlaylist(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            playlistType: playlistType,
            isEndList: isEndList,
            initializationSegment: initializationSegment,
            segments: segments
        )
    }

    private struct PendingByteRange: Sendable {
        let length: Int64
        let offset: Int64?

        func resolved(using previousEnd: Int64) throws -> HLSByteRange {
            guard previousEnd >= 0 else {
                throw HLSParserError.invalidNumber("\(previousEnd)")
            }
            let actualOffset = offset ?? previousEnd
            guard actualOffset >= 0, length > 0 else {
                throw HLSParserError.invalidNumber("\(length)@\(actualOffset)")
            }
            let (end, overflow) = actualOffset.addingReportingOverflow(length)
            guard !overflow, end >= 0 else {
                throw HLSParserError.invalidNumber("\(length)@\(actualOffset)")
            }
            return HLSByteRange(length: length, offset: actualOffset)
        }
    }

    private func parseByteRange(_ value: String) throws -> PendingByteRange {
        let pieces = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard !pieces.isEmpty else { throw HLSParserError.invalidNumber(value) }
        let length = try nonNegativeInt64(pieces[0])
        guard length > 0 else {
            throw HLSParserError.invalidNumber(value)
        }
        let offset: Int64?
        if pieces.count == 2 {
            offset = try nonNegativeInt64(pieces[1])
        } else {
            offset = nil
        }
        return PendingByteRange(length: length, offset: offset)
    }

    private func attributes(from line: String, tag: String) throws -> [String: String] {
        let prefix = tag + ":"
        guard line.hasPrefix(prefix) else { throw HLSParserError.malformedTag(tag) }
        var result: [String: String] = [:]
        var current = ""
        var quoted = false
        var escaped = false
        for character in line.dropFirst(prefix.count) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == "," && !quoted {
                try insertAttribute(current, into: &result)
                current = ""
            } else {
                current.append(character)
            }
        }
        try insertAttribute(current, into: &result)
        return result
    }

    private func insertAttribute(_ item: String, into result: inout [String: String]) throws {
        let pieces = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { throw HLSParserError.invalidAttribute(item) }
        let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "\"", value.last == "\"", value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        guard !name.isEmpty, result[name] == nil else { throw HLSParserError.invalidAttribute(name) }
        result[name] = value
    }

    private func resolve(_ value: String, against baseURL: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw HLSParserError.invalidURL(value) }
        return url
    }

    private func optionalURL(_ value: String?, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        return try resolve(value, against: baseURL)
    }

    private func value(after line: String, tag: String) -> String {
        String(line.dropFirst((tag + ":").count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func int(_ value: String?) -> Int? {
        guard let value, let result = Int(value), result >= 0 else { return nil }
        return result
    }

    /// Advances a BYTERANGE chain cursor. Overflow here means a hostile
    /// playlist declared near-Int64.max ranges; the executor already
    /// defends the same arithmetic, the parser must not trap first.
    private func advancedRangeEnd(from offset: Int64, adding length: Int64) throws -> Int64 {
        let summed = offset.addingReportingOverflow(length)
        guard !summed.overflow else { throw HLSParserError.invalidNumber("\(offset)+\(length)") }
        return summed.partialValue
    }

    private func nonNegativeInt64(_ value: String) throws -> Int64 {
        guard let result = Int64(value), result >= 0 else { throw HLSParserError.invalidNumber(value) }
        return result
    }

    private func positiveDouble(_ value: String) throws -> Double {
        guard let result = Double(value), result.isFinite, result > 0 else {
            throw HLSParserError.invalidNumber(value)
        }
        return result
    }

    private func boolean(_ value: String?) -> Bool {
        value?.uppercased() == "YES"
    }

    private func resolution(_ value: String?) -> (width: Int, height: Int)? {
        guard let value else { return nil }
        let pieces = value.split(separator: "x").map(String.init)
        guard pieces.count == 2, let width = int(pieces[0]), let height = int(pieces[1]), width > 0,
            height > 0
        else { return nil }
        return (width, height)
    }

    private func normalizedIV(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        guard normalized.hasPrefix("0x"), normalized.dropFirst(2).count == 32,
            normalized.dropFirst(2).allSatisfy({ $0.isHexDigit })
        else { throw HLSParserError.invalidAttribute("IV") }
        return normalized
    }
}
