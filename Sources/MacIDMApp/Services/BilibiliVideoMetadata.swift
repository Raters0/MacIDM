import Foundation

/// The bounded view response fields needed to choose one part, decoded without
/// silently converting malformed arrays into an empty default.
struct BilibiliVideoMetadata: Decodable {
    struct Page: Decodable {
        let page: Int
        let cid: Int
    }
    let title: String?
    let aid: Int?
    let cid: Int?
    let pages: [Page]?

    func selectedCID(pageURL: URL) throws -> Int {
        let raw =
            URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value
            ?? "1"
        guard let number = Int(raw), number > 0 else { throw BilibiliPlayurlError.invalidResponse }
        if let pages, !pages.isEmpty {
            guard let selected = pages.first(where: { $0.page == number }), selected.cid > 0 else {
                throw BilibiliPlayurlError.invalidResponse
            }
            return selected.cid
        }
        guard number == 1, let cid, cid > 0 else { throw BilibiliPlayurlError.invalidResponse }
        return cid
    }
}
