import AppKit
import Foundation

/// Continuously watches the general pasteboard for a copied HTTP(S) link
/// while the `clipboardWatch` setting is enabled, so a copy in the browser
/// offers the download confirmation without switching to this app (the
/// on-activate detector covers the switch-here case).
///
/// Changes made while this app is active are skipped on purpose: those
/// copies come from our own UI (link rows copy URLs) or are being pasted
/// into our own URL field, and must not re-open the confirmation sheet on
/// top of the user's edit. Detection never starts a download; it only
/// hands the validated string to the model, which posts the
/// create-download notification the confirmation window listens to.
@MainActor
final class ClipboardLinkWatcher {
    private var timer: Timer?
    private var lastChangeCount = 0

    /// Receives the trimmed clipboard string already validated as an
    /// HTTP(S) URL candidate. Wired by the model.
    var onLinkCopied: ((String) -> Void)?
    /// Offer only links that look like a file or a supported media page
    /// (see `isLikelyDownloadLink`), so copying an ordinary web page link
    /// does not open the confirmation window. Mirrors the
    /// `clipboardWatchFilesOnly` setting.
    var filesOnly = true
    /// Whether this app is frontmost. Injectable for tests; `NSApp` is nil
    /// outside a running app context, where nothing can have been copied
    /// from "this app".
    var isAppActive: () -> Bool = { NSApp?.isActive == true }

    func update(enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            // Baseline the current content so enabling never replays a link
            // that was copied before the watch started.
            lastChangeCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    self?.poll()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// One poll step, kept internal for unit tests. Reads the pasteboard only
    /// when its change count moved and this app is not the active one.
    func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        // Consume changes made while this app is active instead of merely
        // deferring them: a link copied from our own UI must not pop the
        // confirmation window once the user switches to another app.
        guard !isAppActive() else { return }
        guard
            let value = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = Self.httpLink(from: value)
        else { return }
        if filesOnly, !Self.isLikelyDownloadLink(url) { return }
        onLinkCopied?(value)
    }

    /// The clipboard string as an HTTP(S) URL with a host, bounded to 2,048
    /// characters; nil for anything else. Shared by every clipboard entry
    /// point (this watch, the on-activate detector, the global hot key).
    nonisolated static func httpLink(from value: String) -> URL? {
        guard value.count <= 2_048,
            let url = URL(string: value),
            url.scheme == "http" || url.scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }

    /// Sites whose page links are themselves downloadable through the
    /// App's media adapters, so they count as media links without a file
    /// extension.
    private static let mediaPageHosts = [
        "youtube.com", "youtu.be", "bilibili.com", "b23.tv", "douyin.com", "x.com", "twitter.com",
    ]

    /// A link worth offering: its path names a known file type (archive,
    /// video, audio, image, document, installer, or an HLS/DASH manifest),
    /// or it points at a supported media site. Plain web pages are not.
    static func isLikelyDownloadLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if mediaPageHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !["html", "htm", "php", "asp", "aspx", "jsp"].contains(ext) else {
            return false
        }
        if ext == "m3u8" || ext == "mpd" { return true }
        return DownloadCategory(filename: url.lastPathComponent) != .other
    }
}
