import Foundation

public enum InputValidator {
    public static func validate(_ request: DownloadRequest) throws {
        let raw = request.url.absoluteString
        guard !raw.isEmpty, raw.utf8.count <= 8_192,
            !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw IDMError.invalidURL }
        guard request.url.user == nil, request.url.password == nil else {
            throw IDMError.invalidURL
        }
        guard let scheme = request.url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { throw IDMError.unsupportedScheme }
        guard (1...64).contains(request.maximumParallelRequests) else {
            throw IDMError.invalidParallelRequests
        }
        if let hash = request.expectedSHA256 {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                throw IDMError.invalidExpectedHash
            }
        }
        if let context = request.requestContext {
            try validateContextValue(context.cookie, maximumBytes: 16_384)
            try validateContextValue(context.referer, maximumBytes: 4_096)
            try validateContextValue(context.userAgent, maximumBytes: 4_096)
            if let referer = context.referer {
                guard let scheme = URL(string: referer)?.scheme?.lowercased(),
                    scheme == "http" || scheme == "https"
                else { throw IDMError.invalidURL }
            }
        }
        let directory = request.destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            FileManager.default.isWritableFile(atPath: directory.path)
        else { throw IDMError.pathNotWritable(directory.path) }
    }

    private static func validateContextValue(_ value: String?, maximumBytes: Int) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw IDMError.invalidURL }
    }

    public static func safeFilename(_ value: String?) -> String {
        let candidate = (value ?? "").split(separator: "/").last.map(String.init) ?? ""
        let scalars = candidate.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7f && $0.value != 0
        }
        var result = String(String.UnicodeScalarView(scalars))
        // Strip leading/trailing whitespace and dots: a leading dot makes the
        // file hidden on macOS, and trailing dots collide with Windows/legacy
        // tooling. Trim repeatedly so ".  ..file.." becomes "file".
        while result.hasPrefix(".") || result.hasPrefix(" ") {
            result.removeFirst()
        }
        while result.hasSuffix(".") || result.hasSuffix(" ") {
            result.removeLast()
        }
        if result.isEmpty || result == "." || result == ".." {
            result = "download"
        }
        while result.utf8.count > 255 {
            result.removeLast()
        }
        return result
    }
}

public struct ParsedContentRange: Equatable, Sendable {
    public let start: Int64
    public let endInclusive: Int64
    public let total: Int64
}

public enum ContentRangeParser {
    public static func parse(_ value: String?) -> ParsedContentRange? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2, rangeAndTotal[1] != "*",
            let total = Int64(rangeAndTotal[1]), total >= 0
        else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
            let start = Int64(bounds[0]), let end = Int64(bounds[1]),
            start >= 0, end >= start, end < total
        else { return nil }
        return ParsedContentRange(start: start, endInclusive: end, total: total)
    }
}

func strongETag(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.lowercased().hasPrefix("w/"), trimmed.hasPrefix("\""),
        trimmed.hasSuffix("\""), trimmed.count >= 2
    else { return nil }
    return trimmed
}
