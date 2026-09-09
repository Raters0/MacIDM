import Foundation

/// Why the integrity of a release binary cannot be established. Every case is
/// a hard stop for install and update: the alternative is executing a binary
/// that was never verified, which is the exact failure this gate exists to
/// prevent.
enum YTDlpIntegrityError: LocalizedError, Equatable {
    case checksumFetchFailed
    case checksumEntryMissing
    case checksumEntryAmbiguous
    case checksumHashMalformed
    case binaryHashMismatch

    var errorDescription: String? {
        switch self {
        case .checksumFetchFailed:
            return String(localized: "无法获取 yt-dlp 校验文件，已停止安装。")
        case .checksumEntryMissing:
            return String(localized: "yt-dlp 校验文件中缺少该资产的哈希，已停止安装。")
        case .checksumEntryAmbiguous:
            return String(localized: "yt-dlp 校验文件中该资产的哈希不唯一，已停止安装。")
        case .checksumHashMalformed:
            return String(localized: "yt-dlp 校验文件中的哈希格式非法，已停止安装。")
        case .binaryHashMismatch:
            return String(localized: "下载的 yt-dlp 校验不符（SHA-256 不匹配），已停止安装。")
        }
    }
}

/// Release-integrity policy for the managed yt-dlp binary: where an asset may
/// come from, and how its published checksum is read. Pure functions only, so
/// the fail-closed rules are testable without network access.
///
/// Trust boundary: the asset and its `SHA2-256SUMS` are published by the same
/// GitHub release, so a matching digest proves the bytes arrived uncorrupted
/// and unmodified in transit — it does not prove authorship. If the upstream
/// repository itself is compromised, the checksum will agree with the
/// malicious binary. Closing that gap requires a second trust root, such as
/// signed releases or a signature verified against an independently held key.
enum YTDlpReleaseIntegrity {
    static let assetName = "yt-dlp_macos"
    static let checksumAssetName = "SHA2-256SUMS"

    private static let hexDigits = Set(Array("0123456789abcdefABCDEF".utf8))

    /// Builds the immutable, tag-pinned download URL for one release asset.
    ///
    /// The mutable `latest/download/…` form must never be used here: a
    /// `latest` binary and a `latest` checksum are two separate fetches, so a
    /// release published in between would verify one binary's hash against
    /// another's.
    static func pinnedAssetURL(tag: String, name: String) -> URL? {
        guard let encodedTag = encodedTagSegment(tag), !name.isEmpty else { return nil }
        return URL(
            string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(encodedTag)/\(name)")
    }

    /// Accepts an API-provided asset URL only when it is HTTPS on github.com
    /// and pinned to the very tag that produced it. Anything else falls back to
    /// ``pinnedAssetURL(tag:name:)``.
    static func trustedAssetURL(_ candidate: String, tag: String) -> URL? {
        guard let encodedTag = encodedTagSegment(tag),
            let url = URL(string: candidate),
            url.scheme == "https",
            url.host?.lowercased() == "github.com",
            url.path.contains("/releases/download/\(encodedTag)/")
        else { return nil }
        return url
    }

    /// Strict SHA-256 literal test: exactly 64 ASCII hex digits. A truncated,
    /// padded, or non-hex digest is treated as absent evidence, not as a hint.
    static func isValidSHA256Hex(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        return utf8.count == 64 && utf8.allSatisfy { hexDigits.contains($0) }
    }

    /// Reads the expected digest for `filename` out of a `SHA2-256SUMS` body.
    ///
    /// Expected line shape is `<64-hex><whitespace><filename>`; a line with any
    /// other field count is ignored, because it describes no asset we asked
    /// about. A matching line whose hash is malformed is a hard failure rather
    /// than something to skip — skipping would silently downgrade to
    /// unverified.
    static func parseExpectedSHA256(
        _ text: String,
        filename: String
    ) -> Result<String, YTDlpIntegrityError> {
        guard !filename.isEmpty else { return .failure(.checksumEntryMissing) }
        var matches: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let hash = String(fields[0])
            guard String(fields[1]) == filename else { continue }
            guard isValidSHA256Hex(hash) else { return .failure(.checksumHashMalformed) }
            matches.append(hash.lowercased())
        }
        switch matches.count {
        case 0: return .failure(.checksumEntryMissing)
        case 1: return .success(matches[0])
        default: return .failure(.checksumEntryAmbiguous)
        }
    }

    private static func encodedTagSegment(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }
}
