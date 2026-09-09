import XCTest

@testable import MacIDMApp

/// Covers the release-integrity rules that decide whether a downloaded yt-dlp
/// may ever be made executable or run. These are the fail-closed conditions
/// from the supply-chain audit: they must reject every state where the digest
/// is simply not established, instead of treating it as "no evidence needed".
final class YTDlpReleaseIntegrityTests: XCTestCase {

    private let validHash = "a3f5" + String(repeating: "0", count: 59) + "b"
    private let tag = "2026.08.09"

    // MARK: - Asset URL pinning

    func testPinnedAssetURLsBindToTheExactTag() {
        let asset = YTDlpReleaseIntegrity.pinnedAssetURL(
            tag: tag, name: YTDlpReleaseIntegrity.assetName)
        XCTAssertEqual(
            asset?.absoluteString,
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.09/yt-dlp_macos")
        let sums = YTDlpReleaseIntegrity.pinnedAssetURL(
            tag: tag, name: YTDlpReleaseIntegrity.checksumAssetName)
        XCTAssertEqual(
            sums?.absoluteString,
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.09/SHA2-256SUMS")
    }

    func testPinnedAssetURLNeverUsesTheDriftingLatestForm() {
        // A `latest` binary and a `latest` checksum are two fetches; a release
        // published in between would verify one build against another's hash.
        let asset = YTDlpReleaseIntegrity.pinnedAssetURL(tag: tag, name: "yt-dlp_macos")
        XCTAssertFalse(asset?.absoluteString.contains("latest") ?? true)
    }

    func testPinnedAssetURLRejectsEmptyTag() {
        XCTAssertNil(YTDlpReleaseIntegrity.pinnedAssetURL(tag: "  ", name: "yt-dlp_macos"))
        XCTAssertNil(YTDlpReleaseIntegrity.pinnedAssetURL(tag: tag, name: ""))
    }

    func testTrustedAssetURLAcceptsSameTagGitHubDownloadLink() {
        let candidate = "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/yt-dlp_macos"
        XCTAssertEqual(
            YTDlpReleaseIntegrity.trustedAssetURL(candidate, tag: tag)?.absoluteString, candidate)
    }

    func testTrustedAssetURLRejectsLinksFromAnotherRelease() {
        // The API answer must agree with the tag already read, or the asset and
        // checksum could describe two different builds.
        XCTAssertNil(
            YTDlpReleaseIntegrity.trustedAssetURL(
                "https://github.com/yt-dlp/yt-dlp/releases/download/2020.01.01/yt-dlp_macos",
                tag: tag))
    }

    func testTrustedAssetURLRejectsNonGitHubAndPlaintextHosts() {
        let path = "releases/download/\(tag)/yt-dlp_macos"
        XCTAssertNil(
            YTDlpReleaseIntegrity.trustedAssetURL("https://evil.example/\(path)", tag: tag))
        XCTAssertNil(
            YTDlpReleaseIntegrity.trustedAssetURL("http://github.com/\(path)", tag: tag))
        XCTAssertNil(
            YTDlpReleaseIntegrity.trustedAssetURL(
                "https://objects.githubusercontent.com/\(path)", tag: tag))
    }

    func testTrustedAssetURLRejectsHostSuffixLookalikes() {
        XCTAssertNil(
            YTDlpReleaseIntegrity.trustedAssetURL(
                "https://github.com.attacker.example/releases/download/\(tag)/yt-dlp_macos",
                tag: tag))
    }

    // MARK: - Checksum document parsing

    func testParseReturnsLowercasedDigestForMatchingEntry() {
        let text = "\(validHash.uppercased())  \(YTDlpReleaseIntegrity.assetName)\n"
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .success(validHash))
    }

    func testParseIgnoresOtherAssetsAndEmptyLines() {
        let text = """
            \(String(repeating: "b", count: 64))  yt-dlp_windows.exe
            \(String(repeating: "c", count: 64))  yt-dlp_linux

            \(validHash)  \(YTDlpReleaseIntegrity.assetName)
            """
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .success(validHash))
    }

    func testParseHandlesTabSeparatedAndCRLFLines() {
        let text = "\(validHash)\t\(YTDlpReleaseIntegrity.assetName)\r\n"
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .success(validHash))
    }

    func testParseFailsWhenAssetHasNoEntry() {
        // A sums file that simply does not mention the asset proves nothing.
        let text = "\(String(repeating: "a", count: 64))  some_other_asset\n"
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryMissing))
    }

    func testParseFailsOnEmptyDocument() {
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256("", filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryMissing))
    }

    func testParseFailsWhenTargetEntryIsDuplicated() {
        // Two different digests for one asset cannot be resolved by taking the
        // first match; that would let an appended line override the real one.
        let text = """
            \(validHash)  \(YTDlpReleaseIntegrity.assetName)
            \(String(repeating: "9", count: 64))  \(YTDlpReleaseIntegrity.assetName)
            """
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryAmbiguous))
    }

    func testParseFailsWhenDuplicateEntriesAreIdentical() {
        // Even a repeated identical digest is ambiguous input for a security
        // check, so it still stops the install.
        let text = """
            \(validHash)  \(YTDlpReleaseIntegrity.assetName)
            \(validHash)  \(YTDlpReleaseIntegrity.assetName)
            """
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryAmbiguous))
    }

    func testParseFailsWhenDigestIsNotSixtyFourHexDigits() {
        let malformed = [
            String(repeating: "z", count: 64),  // right length, not hex
            String(repeating: "a", count: 63),  // truncated
            String(repeating: "a", count: 65),  // padded
            "a3f5-000000000000000000000000000000000000000000000000000000000b",
        ]
        for hash in malformed {
            let text = "\(hash)  \(YTDlpReleaseIntegrity.assetName)\n"
            XCTAssertEqual(
                YTDlpReleaseIntegrity.parseExpectedSHA256(
                    text, filename: YTDlpReleaseIntegrity.assetName),
                .failure(.checksumHashMalformed),
                "expected \(hash) to be rejected")
        }
    }

    func testParseRejectsMalformedDigestEvenWhenOtherEntriesAreValid() {
        let text = """
            \(String(repeating: "a", count: 64))  other_asset
            \(String(repeating: "z", count: 64))  \(YTDlpReleaseIntegrity.assetName)
            """
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumHashMalformed))
    }

    func testParseIgnoresLinesWithUnexpectedFieldCounts() {
        // A trailing note or a hash with no filename must not be mistaken for
        // this asset's entry.
        let text = """
            \(validHash)  \(YTDlpReleaseIntegrity.assetName) extra
            \(validHash)
            """
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryMissing))
    }

    func testParseRejectsFilenameVariantsThatOnlyLookEquivalent() {
        let text = "\(validHash)  \(YTDlpReleaseIntegrity.assetName).sig\n"
        XCTAssertEqual(
            YTDlpReleaseIntegrity.parseExpectedSHA256(
                text, filename: YTDlpReleaseIntegrity.assetName),
            .failure(.checksumEntryMissing))
    }

    // MARK: - Digest literal validation

    func testIsValidSHA256HexAcceptsBothCases() {
        XCTAssertTrue(YTDlpReleaseIntegrity.isValidSHA256Hex(validHash))
        XCTAssertTrue(YTDlpReleaseIntegrity.isValidSHA256Hex(validHash.uppercased()))
    }

    func testIsValidSHA256HexRejectsNonHexUnicodeAndLengths() {
        XCTAssertFalse(YTDlpReleaseIntegrity.isValidSHA256Hex(""))
        XCTAssertFalse(YTDlpReleaseIntegrity.isValidSHA256Hex(String(repeating: "0", count: 32)))
        XCTAssertFalse(YTDlpReleaseIntegrity.isValidSHA256Hex(String(repeating: "g", count: 64)))
        XCTAssertFalse(
            YTDlpReleaseIntegrity.isValidSHA256Hex(String(repeating: "0", count: 63) + "　"))
    }
}
