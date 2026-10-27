import AppKit
import XCTest

@testable import MacIDMApp

@MainActor
final class ClipboardLinkWatcherTests: XCTestCase {
    private func setClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func makeWatcher(filesOnly: Bool = false) -> ClipboardLinkWatcher {
        let watcher = ClipboardLinkWatcher()
        watcher.filesOnly = filesOnly
        watcher.isAppActive = { false }
        return watcher
    }

    func testPollOffersHTTPLinkOncePerChange() {
        let watcher = makeWatcher()
        watcher.update(enabled: true)
        defer { watcher.update(enabled: false) }

        var offered: [String] = []
        watcher.onLinkCopied = { offered.append($0) }

        setClipboard("https://example.com/file.zip")
        watcher.poll()
        // Same change count: no repeat offer.
        watcher.poll()

        XCTAssertEqual(offered, ["https://example.com/file.zip"])
    }

    func testPollIgnoresNonLinkContent() {
        let watcher = makeWatcher()
        watcher.update(enabled: true)
        defer { watcher.update(enabled: false) }

        var offered: [String] = []
        watcher.onLinkCopied = { offered.append($0) }

        setClipboard("/Users/example/Downloads/file.zip")
        watcher.poll()
        setClipboard("not a url")
        watcher.poll()
        setClipboard("ftp://example.com/file")
        watcher.poll()

        XCTAssertTrue(offered.isEmpty)
    }

    func testEnablingBaselinesCurrentContentSoHistoryIsNotReplayed() {
        setClipboard("https://example.com/old.bin")
        let watcher = makeWatcher()
        watcher.update(enabled: true)
        defer { watcher.update(enabled: false) }

        var offered: [String] = []
        watcher.onLinkCopied = { offered.append($0) }
        watcher.poll()

        XCTAssertTrue(offered.isEmpty)
    }

    /// Regression: a link copied while MacIDM was frontmost (from its own
    /// UI) used to be offered as soon as the user switched to another app.
    func testCopyMadeWhileActiveIsConsumedNotDeferred() {
        let watcher = makeWatcher()
        var active = true
        watcher.isAppActive = { active }
        watcher.update(enabled: true)
        defer { watcher.update(enabled: false) }

        var offered: [String] = []
        watcher.onLinkCopied = { offered.append($0) }

        setClipboard("https://example.com/copied-in-macidm.zip")
        watcher.poll()
        active = false
        watcher.poll()

        XCTAssertTrue(offered.isEmpty)
    }

    func testFilesOnlyOffersFileAndMediaLinksButNotPlainPages() {
        let watcher = makeWatcher(filesOnly: true)
        watcher.update(enabled: true)
        defer { watcher.update(enabled: false) }

        var offered: [String] = []
        watcher.onLinkCopied = { offered.append($0) }

        for value in [
            "https://example.com/blog/post",
            "https://example.com/index.html",
            "https://example.com/release/app.dmg",
            "https://cdn.example.com/live/master.m3u8",
            "https://www.youtube.com/watch?v=fixture",
        ] {
            setClipboard(value)
            watcher.poll()
        }

        XCTAssertEqual(
            offered,
            [
                "https://example.com/release/app.dmg",
                "https://cdn.example.com/live/master.m3u8",
                "https://www.youtube.com/watch?v=fixture",
            ]
        )
    }
}
