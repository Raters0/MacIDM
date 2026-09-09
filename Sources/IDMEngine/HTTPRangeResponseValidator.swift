import Foundation

/// Shared by header probing and every ranged transfer before accepting bytes.
enum HTTPRangeResponseValidator {
    static func accepts(_ response: HTTPURLResponse, start: Int64, endInclusive: Int64, total: Int64?) -> Bool {
        guard response.statusCode == 206 || response.statusCode == 200,
            normalizedEncoding(response.value(forHTTPHeaderField: "Content-Encoding")) == "identity",
            strongETag(response.value(forHTTPHeaderField: "ETag")) != nil,
            let range = ContentRangeParser.parse(response.value(forHTTPHeaderField: "Content-Range")),
            range.start == start, range.endInclusive == endInclusive,
            total == nil || range.total == total
        else { return false }
        let rawLength = response.value(forHTTPHeaderField: "Content-Length")
        if response.statusCode == 200 || rawLength != nil {
            guard let rawLength, let length = Int64(rawLength), length == endInclusive - start + 1 else {
                return false
            }
        }
        return true
    }
}
