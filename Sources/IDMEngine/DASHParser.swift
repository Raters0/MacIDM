import Foundation

public enum DASHParserError: Error, Equatable, Sendable {
    case malformedManifest(String)
    case unsupportedLiveManifest
    case invalidNumber(String)
    case invalidDuration(String)
    case invalidURL(String)
    case missingSegmentTemplate
    case missingMediaTemplate
    case emptyRepresentations
    case segmentLimitExceeded
}

extension DASHParserError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedManifest(let detail): "DASH MPD 格式无效：" + detail
        case .unsupportedLiveManifest: "直播 DASH 暂不支持，MacIDM 只接受静态点播 MPD。"
        case .invalidNumber(let value): "DASH 数字无效：" + value
        case .invalidDuration(let value): "DASH 时长无效：" + value
        case .invalidURL(let value): "DASH URL 无效：" + value
        case .missingSegmentTemplate: "DASH Representation 缺少 SegmentTemplate 或 SegmentList"
        case .missingMediaTemplate: "DASH SegmentTemplate 缺少 media 模板"
        case .emptyRepresentations: "DASH MPD 没有可用 Representation"
        case .segmentLimitExceeded: "DASH 分片数量超过安全上限"
        }
    }
}

public struct DASHByteRange: Equatable, Sendable {
    public let start: Int64
    public let endInclusive: Int64

    public init(start: Int64, endInclusive: Int64) {
        self.start = start
        self.endInclusive = endInclusive
    }

    public var length: Int64 {
        let (diff, oflow1) = endInclusive.subtractingReportingOverflow(start)
        guard !oflow1 else { return 0 }
        let (len, oflow2) = diff.addingReportingOverflow(1)
        guard !oflow2 else { return 0 }
        return len
    }
}

public struct DASHInitializationSegment: Equatable, Sendable {
    public let url: URL
    public let byteRange: DASHByteRange?

    public init(url: URL, byteRange: DASHByteRange? = nil) {
        self.url = url
        self.byteRange = byteRange
    }
}

public struct DASHMediaSegment: Equatable, Sendable {
    public let url: URL
    public let number: Int64
    public let startTime: Int64
    public let duration: Int64
    public let byteRange: DASHByteRange?

    public init(
        url: URL,
        number: Int64,
        startTime: Int64,
        duration: Int64,
        byteRange: DASHByteRange? = nil
    ) {
        self.url = url
        self.number = number
        self.startTime = startTime
        self.duration = duration
        self.byteRange = byteRange
    }
}

public enum DASHContentKind: String, Sendable {
    case video
    case audio
    case unknown
}

public struct DASHRepresentation: Equatable, Sendable {
    public let id: String
    public let bandwidth: Int
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let codecs: String?
    public let contentKind: DASHContentKind
    public let initialization: DASHInitializationSegment?
    public let segments: [DASHMediaSegment]

    public init(
        id: String,
        bandwidth: Int,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil,
        codecs: String? = nil,
        contentKind: DASHContentKind = .unknown,
        initialization: DASHInitializationSegment? = nil,
        segments: [DASHMediaSegment] = []
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.codecs = codecs
        self.contentKind = contentKind
        self.initialization = initialization
        self.segments = segments
    }
}

public struct DASHManifest: Equatable, Sendable {
    public let isStatic: Bool
    public let duration: Double?
    public let representations: [DASHRepresentation]

    public init(isStatic: Bool, duration: Double?, representations: [DASHRepresentation]) {
        self.isStatic = isStatic
        self.duration = duration
        self.representations = representations
    }

    public var videoRepresentations: [DASHRepresentation] {
        representations.filter { $0.contentKind == .video }
    }

    public var audioRepresentations: [DASHRepresentation] {
        representations.filter { $0.contentKind == .audio }
    }
}

public struct DASHParser: Sendable {
    public let maximumManifestBytes: Int
    public let maximumSegmentsPerRepresentation: Int

    public init(
        maximumManifestBytes: Int = 4 * 1024 * 1024,
        maximumSegmentsPerRepresentation: Int = 100_000
    ) {
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumSegmentsPerRepresentation = maximumSegmentsPerRepresentation
    }

    public func parse(_ text: String, baseURL: URL) throws -> DASHManifest {
        guard text.utf8.count <= maximumManifestBytes else {
            throw DASHParserError.malformedManifest("MPD 超过大小限制")
        }
        guard let data = text.data(using: .utf8) else {
            throw DASHParserError.malformedManifest("MPD 不是 UTF-8")
        }
        let root = try DASHXMLNode.parse(data)
        guard root.name == "MPD" else {
            throw DASHParserError.malformedManifest("根元素不是 MPD")
        }
        let type = root.attributes["type"]?.lowercased() ?? "static"
        guard type == "static" else { throw DASHParserError.unsupportedLiveManifest }
        let manifestBase = try resolveBaseURL(root, against: baseURL)
        let duration = try root.attributes["mediaPresentationDuration"].map(parseDuration)
        var representations: [DASHRepresentation] = []
        for period in root.children(named: "Period") {
            let periodBase = try resolveBaseURL(period, against: manifestBase)
            for adaptation in period.children(named: "AdaptationSet") {
                let adaptationBase = try resolveBaseURL(adaptation, against: periodBase)
                let adaptationTemplate = adaptation.firstChild(named: "SegmentTemplate")
                let adaptationList = adaptation.firstChild(named: "SegmentList")
                let adaptationMime = adaptation.attributes["mimeType"]
                let adaptationCodecs = adaptation.attributes["codecs"]
                for representation in adaptation.children(named: "Representation") {
                    let representationBase = try resolveBaseURL(representation, against: adaptationBase)
                    let id = representation.attributes["id"] ?? UUID().uuidString
                    let bandwidth = try parseInt(representation.attributes["bandwidth"] ?? "0")
                    let width = try representation.attributes["width"].map(parseInt)
                    let height = try representation.attributes["height"].map(parseInt)
                    let mimeType = representation.attributes["mimeType"] ?? adaptationMime
                    let codecs = representation.attributes["codecs"] ?? adaptationCodecs
                    let kind = contentKind(
                        contentType: representation.attributes["contentType"] ?? adaptation.attributes["contentType"],
                        mimeType: mimeType
                    )
                    let template = representation.firstChild(named: "SegmentTemplate") ?? adaptationTemplate
                    let list = representation.firstChild(named: "SegmentList") ?? adaptationList
                    let resolved = try makeRepresentation(
                        id: id,
                        bandwidth: bandwidth,
                        width: width,
                        height: height,
                        mimeType: mimeType,
                        codecs: codecs,
                        contentKind: kind,
                        baseURL: representationBase,
                        segmentTemplate: template,
                        segmentList: list,
                        presentationDuration: duration
                    )
                    representations.append(resolved)
                    guard representations.count <= 200 else {
                        throw DASHParserError.segmentLimitExceeded
                    }
                }
            }
        }
        guard !representations.isEmpty else { throw DASHParserError.emptyRepresentations }
        return DASHManifest(isStatic: true, duration: duration, representations: representations)
    }

    private func makeRepresentation(
        id: String,
        bandwidth: Int,
        width: Int?,
        height: Int?,
        mimeType: String?,
        codecs: String?,
        contentKind: DASHContentKind,
        baseURL: URL,
        segmentTemplate: DASHXMLNode?,
        segmentList: DASHXMLNode?,
        presentationDuration: Double?
    ) throws -> DASHRepresentation {
        if let segmentList {
            let initialization = try segmentList.firstChild(named: "Initialization").map {
                // sourceURL may be omitted: the spec states that in this case the
                // initialization segment lives inside the resource that the
                // Representation BaseURL points to, located via byteRange.
                DASHInitializationSegment(
                    url: try resolveURL(
                        $0.attributes["sourceURL"],
                        fallback: baseURL,
                        against: baseURL
                    ),
                    byteRange: try parseRange($0.attributes["range"])
                )
            }
            let segments = try segmentList.children(named: "SegmentURL").enumerated().map { index, node in
                DASHMediaSegment(
                    url: try resolveURL(
                        node.attributes["media"],
                        fallback: baseURL,
                        against: baseURL
                    ),
                    number: Int64(index + 1),
                    startTime: 0,
                    duration: 0,
                    byteRange: try parseRange(node.attributes["mediaRange"])
                )
            }
            guard !segments.isEmpty else { throw DASHParserError.emptyRepresentations }
            return DASHRepresentation(
                id: id,
                bandwidth: bandwidth,
                width: width,
                height: height,
                mimeType: mimeType,
                codecs: codecs,
                contentKind: contentKind,
                initialization: initialization,
                segments: segments
            )
        }
        guard let segmentTemplate else { throw DASHParserError.missingSegmentTemplate }
        let timescale = try parseInt64(segmentTemplate.attributes["timescale"] ?? "1")
        guard timescale > 0 else { throw DASHParserError.invalidNumber("timescale") }
        guard let mediaTemplate = segmentTemplate.attributes["media"] else {
            throw DASHParserError.missingMediaTemplate
        }
        let initialization = try segmentTemplate.attributes["initialization"].map {
            DASHInitializationSegment(
                url: try resolveURL(
                    substitute($0, representationID: id, bandwidth: bandwidth, number: nil, time: nil),
                    against: baseURL
                )
            )
        }
        let startNumber = try parseInt64(segmentTemplate.attributes["startNumber"] ?? "1")
        guard startNumber >= 0 else {
            throw DASHParserError.invalidNumber("startNumber")
        }
        let timeline = segmentTemplate.firstChild(named: "SegmentTimeline")
        let entries = try timelineEntries(
            timeline,
            segmentTemplate: segmentTemplate,
            timescale: timescale,
            presentationDuration: presentationDuration
        )
        let segments: [DASHMediaSegment]
        if !entries.isEmpty {
            segments = try entries.enumerated().map { index, entry in
                let (segNumber, oflow) = startNumber.addingReportingOverflow(Int64(index))
                guard !oflow else { throw DASHParserError.invalidNumber("startNumber") }
                return DASHMediaSegment(
                    url: try resolveURL(
                        substitute(
                            mediaTemplate,
                            representationID: id,
                            bandwidth: bandwidth,
                            number: segNumber,
                            time: entry.startTime
                        ),
                        against: baseURL
                    ),
                    number: segNumber,
                    startTime: entry.startTime,
                    duration: entry.duration
                )
            }
        } else if let durationString = segmentTemplate.attributes["duration"],
            let presentationDuration
        {
            let segmentDuration = try parseInt64(durationString)
            guard segmentDuration > 0 else { throw DASHParserError.invalidNumber(durationString) }
            let rawUnits = (presentationDuration * Double(timescale)).rounded(.up)
            // Double cannot represent Int64.max exactly (it rounds up to 2^63), so the
            // `<= Double(Int64.max)` upper-bound check would admit values that cannot be
            // represented as Int64, and the subsequent non-failing Int64(_:) conversion
            // would trigger a runtime trap instead of throwing an error.
            // Use the failable Int64(exactly:) conversion instead: out-of-range or
            // non-integer values return nil and throw a catchable error; keep the finite
            // and non-negative checks, and never fabricate usable media time via
            // truncation/wrapping/clamping.
            guard rawUnits.isFinite, rawUnits >= 0, let totalUnits = Int64(exactly: rawUnits) else {
                throw DASHParserError.invalidNumber(durationString)
            }
            let count64 = totalUnits / segmentDuration + (totalUnits % segmentDuration == 0 ? 0 : 1)
            guard count64 > 0, count64 <= Int64(maximumSegmentsPerRepresentation) else {
                throw DASHParserError.segmentLimitExceeded
            }
            let count = Int(count64)
            segments = try (0..<count).map { index in
                let (start, startOverflow) = Int64(index).multipliedReportingOverflow(by: segmentDuration)
                guard !startOverflow else { throw DASHParserError.invalidNumber(durationString) }
                let (segNumber, numOverflow) = startNumber.addingReportingOverflow(Int64(index))
                guard !numOverflow else { throw DASHParserError.invalidNumber(durationString) }
                return DASHMediaSegment(
                    url: try resolveURL(
                        substitute(
                            mediaTemplate,
                            representationID: id,
                            bandwidth: bandwidth,
                            number: segNumber,
                            time: start
                        ),
                        against: baseURL
                    ),
                    number: segNumber,
                    startTime: start,
                    duration: min(segmentDuration, totalUnits - start)
                )
            }
        } else {
            throw DASHParserError.malformedManifest("SegmentTemplate 缺少 SegmentTimeline 或 duration")
        }
        guard !segments.isEmpty else { throw DASHParserError.emptyRepresentations }
        return DASHRepresentation(
            id: id,
            bandwidth: bandwidth,
            width: width,
            height: height,
            mimeType: mimeType,
            codecs: codecs,
            contentKind: contentKind,
            initialization: initialization,
            segments: segments
        )
    }

    private func timelineEntries(
        _ timeline: DASHXMLNode?,
        segmentTemplate: DASHXMLNode,
        timescale: Int64,
        presentationDuration: Double?
    ) throws -> [(startTime: Int64, duration: Int64)] {
        guard let timeline else { return [] }
        let nodes = timeline.children(named: "S")
        var entries: [(startTime: Int64, duration: Int64)] = []
        var cursor: Int64 = 0
        let segmentCap = Int64(maximumSegmentsPerRepresentation)
        for (index, node) in nodes.enumerated() {
            let duration = try parseInt64(node.attributes["d"] ?? "0")
            guard duration > 0 else { throw DASHParserError.invalidNumber("S@d") }
            let start = try node.attributes["t"].map(parseInt64) ?? cursor
            guard start >= 0 else { throw DASHParserError.invalidNumber("S@t") }
            let repeatCount = try parseInt64(node.attributes["r"] ?? "0")
            let count: Int64
            if repeatCount >= 0 {
                let (c, oflow) = repeatCount.addingReportingOverflow(1)
                guard !oflow else { throw DASHParserError.segmentLimitExceeded }
                count = c
            } else if let next = nodes.dropFirst(index + 1).first,
                let nextStart = next.attributes["t"].flatMap(Int64.init)
            {
                guard nextStart >= start else {
                    throw DASHParserError.malformedManifest("SegmentTimeline 的 next start 小于 current start")
                }
                let (diff, oflow) = nextStart.subtractingReportingOverflow(start)
                guard !oflow else { throw DASHParserError.invalidNumber("S@t") }
                count = max(1, diff / duration + (diff % duration == 0 ? 0 : 1))
            } else if let presentationDuration {
                let rawTotal = (presentationDuration * Double(timescale)).rounded(.up)
                // Same as the duration-template path: Double(Int64.max) rounds up to 2^63,
                // the upper-bound check would admit unrepresentable values, and the
                // non-failing Int64(_:) conversion would trap. Use the failable
                // Int64(exactly:) conversion and throw a catchable error when out of range.
                guard rawTotal.isFinite, rawTotal >= 0, let total = Int64(exactly: rawTotal) else {
                    throw DASHParserError.invalidDuration("\(presentationDuration)")
                }
                let (diff, oflow) = total.subtractingReportingOverflow(start)
                guard !oflow else { throw DASHParserError.invalidNumber("S@t") }
                let nonNegativeDiff = max(0, diff)
                count = max(1, nonNegativeDiff / duration + (nonNegativeDiff % duration == 0 ? 0 : 1))
            } else {
                throw DASHParserError.malformedManifest("SegmentTimeline 的 r=-1 缺少结束边界")
            }
            guard count >= 1, count <= segmentCap - Int64(entries.count) else {
                throw DASHParserError.segmentLimitExceeded
            }
            for offset in 0..<count {
                let (offsetDuration, oflow1) = offset.multipliedReportingOverflow(by: duration)
                guard !oflow1 else { throw DASHParserError.invalidNumber("S@d") }
                let (startTime, oflow2) = start.addingReportingOverflow(offsetDuration)
                guard !oflow2 else { throw DASHParserError.invalidNumber("S@d") }
                entries.append((startTime: startTime, duration: duration))
            }
            let (countDuration, oflow3) = count.multipliedReportingOverflow(by: duration)
            guard !oflow3 else { throw DASHParserError.invalidNumber("S@d") }
            let (nextCursor, oflow4) = start.addingReportingOverflow(countDuration)
            guard !oflow4 else { throw DASHParserError.invalidNumber("S@d") }
            cursor = nextCursor
        }
        return entries
    }

    private func contentKind(contentType: String?, mimeType: String?) -> DASHContentKind {
        if contentType?.lowercased() == "video" || mimeType?.lowercased().hasPrefix("video/") == true {
            return .video
        }
        if contentType?.lowercased() == "audio" || mimeType?.lowercased().hasPrefix("audio/") == true {
            return .audio
        }
        return .unknown
    }

    private func parseInt(_ value: String) throws -> Int {
        guard let parsed = Int(value) else { throw DASHParserError.invalidNumber(value) }
        return parsed
    }

    private func parseInt64(_ value: String) throws -> Int64 {
        guard let parsed = Int64(value) else { throw DASHParserError.invalidNumber(value) }
        return parsed
    }

    private func parseDuration(_ value: String) throws -> Double {
        guard value.first == "P" else { throw DASHParserError.invalidDuration(value) }
        let remaining = String(value.dropFirst())
        var total = 0.0
        var number = ""
        var inTime = false
        for character in remaining {
            if character == "T" {
                inTime = true
            } else if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let amount = Double(number) else { throw DASHParserError.invalidDuration(value) }
                switch character {
                case "D": total += amount * 86_400
                case "H": total += amount * 3_600
                case "M": total += amount * (inTime ? 60 : 2_592_000)
                case "S": total += amount
                default: throw DASHParserError.invalidDuration(value)
                }
                number.removeAll(keepingCapacity: true)
            }
        }
        guard number.isEmpty, total >= 0, total.isFinite else {
            throw DASHParserError.invalidDuration(value)
        }
        return total
    }

    private func resolveBaseURL(_ node: DASHXMLNode, against base: URL) throws -> URL {
        guard let value = node.firstChild(named: "BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return base }
        return try resolveURL(value, against: base)
    }

    private func resolveURL(_ value: String?, fallback: URL? = nil, against base: URL) throws -> URL {
        if let value, !value.isEmpty {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { throw DASHParserError.invalidURL(value) }
            return url
        }
        guard let fallback,
            let scheme = fallback.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw DASHParserError.invalidURL("") }
        return fallback
    }

    private func parseRange(_ value: String?) throws -> DASHByteRange? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]), start >= 0, end >= start
        else { throw DASHParserError.invalidNumber(value) }
        let (diff, diffOflow) = end.subtractingReportingOverflow(start)
        guard !diffOflow else { throw DASHParserError.invalidNumber(value) }
        let (_, lenOflow) = diff.addingReportingOverflow(1)
        guard !lenOflow else { throw DASHParserError.invalidNumber(value) }
        return DASHByteRange(start: start, endInclusive: end)
    }

    private func substitute(
        _ template: String,
        representationID: String,
        bandwidth: Int,
        number: Int64?,
        time: Int64?
    ) -> String {
        var result = ""
        var cursor = template.startIndex
        while let start = template[cursor...].firstIndex(of: "$"),
            let end = template[template.index(after: start)...].firstIndex(of: "$")
        {
            result += template[cursor..<start]
            let token = String(template[template.index(after: start)..<end])
            if token == "" {
                result += "$"
            } else {
                let pieces = token.split(separator: "%", maxSplits: 1).map(String.init)
                let name = pieces[0]
                let format = pieces.count == 2 ? pieces[1] : nil
                let raw: String
                switch name {
                case "RepresentationID": raw = representationID
                case "Bandwidth": raw = String(bandwidth)
                case "Number": raw = String(number ?? 0)
                case "Time": raw = String(time ?? 0)
                default: raw = ""
                }
                if let format, format.hasPrefix("0"), format.hasSuffix("d"),
                    let width = Int(format.dropFirst().dropLast()),
                    // A hostile %01000000000d$ would otherwise allocate an
                    // unbounded zero run per segment URL.
                    width > 0, width <= 64
                {
                    result += String(repeating: "0", count: max(0, width - raw.count)) + raw
                } else {
                    result += raw
                }
            }
            cursor = template.index(after: end)
        }
        result += template[cursor...]
        return result
    }
}

private final class DASHXMLNode: @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [DASHXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func children(named name: String) -> [DASHXMLNode] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> DASHXMLNode? {
        children.first { $0.name == name }
    }

    static func parse(_ data: Data) throws -> DASHXMLNode {
        let delegate = DASHXMLTreeDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw DASHParserError.malformedManifest(parser.parserError?.localizedDescription ?? "XML 解析失败")
        }
        return root
    }
}

private final class DASHXMLTreeDelegate: NSObject, XMLParserDelegate {
    var root: DASHXMLNode?
    private var stack: [DASHXMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = DASHXMLNode(
            name: elementName.split(separator: ":").last.map(String.init) ?? elementName,
            attributes: attributeDict.reduce(into: [String: String]()) { result, item in
                let key = item.key.split(separator: ":").last.map(String.init) ?? item.key
                result[key] = item.value
            }
        )
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}
