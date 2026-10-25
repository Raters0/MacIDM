import Foundation
import IDMEngine
import MacIDMBridge

/// Naming-trust policy for browser takeover payloads (technical spec §8.1,
/// chrome-extension-spec §5.5.1): decouples the hint-provenance and
/// semantic-title arbitration inputs from the AppModel aggregate so the rules
/// can be unit-tested and evolved without touching takeover state.
enum BrowserDownloadNamingPolicy {
    /// Returns `value` when it is a positive size, mirroring the extension's
    /// rule that Chrome's unknown-size markers (0 / -1) are not real sizes.
    static func positiveSize(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Reads the hint provenance from a bridge payload. Missing or unknown
    /// values degrade to `.urlPath` so payloads from older extensions never
    /// gain title-outranking authority (technical spec §8.1).
    static func filenameHintSource(from payload: [String: JSONValue]) -> FilenameHintSource {
        guard let raw = payload["filenameHintSource"]?.stringValue,
            let source = FilenameHintSource(rawValue: raw),
            source != .userEdited
        else { return .urlPath }
        return source
    }

    /// Semantic-title arbitration input (technical spec §8.1). The bridge
    /// validator already bounds the array (≤10 `{text, scope}` entries);
    /// this unpacks it defensively for the confirmation window.
    static func titleCandidates(from payload: [String: JSONValue]) -> [SemanticTitleCandidate] {
        guard case .array(let items) = payload["titleCandidates"] else { return [] }
        return items.compactMap { item in
            guard case .object(let entry) = item,
                let text = entry["text"]?.stringValue
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return nil }
            return SemanticTitleCandidate(
                text: trimmed,
                scope: entry["scope"]?.stringValue == "card" ? "card" : "page"
            )
        }
    }

    /// Hosts used to cross-check a title's trailing brand segment before
    /// stripping it: the resource host and, when present, the referer's host
    /// (the page the user actually submitted from).
    static func pageTitleHosts(url: URL, requestContext: DownloadRequestContext?) -> [String?] {
        let refererHost = requestContext?.referer.flatMap { URL(string: $0)?.host }
        return [url.host, refererHost]
    }
}
