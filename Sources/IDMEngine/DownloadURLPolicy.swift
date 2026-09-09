import Foundation

/// Single source of truth for which URLs may be persisted and how they are
/// sanitized before storage. The CLI and the App previously kept two drift-
/// ing copies of this rule: the CLI also treated `#fragment` as transient
/// (rejecting ordinary page anchors), while the App correctly ignored it —
/// fragments never reach the server, so they carry no signature material.
public enum DownloadURLPolicy {
    /// True when the URL carries material that must not be persisted to
    /// disk (query string, inline credentials). A fragment alone is NOT
    /// transient material.
    public static func hasTransientMaterial(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw) else { return false }
        return components.query != nil || components.user != nil || components.password != nil
    }

    /// Strips credentials, query and fragment for at-rest storage. A URL
    /// without a scheme (Foundation's parser is lenient about spaces and
    /// other junk) degrades to a harmless placeholder so scheme-less input
    /// can never be replayed as a signed link.
    public static func redactedForStorage(_ raw: String) -> String {
        guard let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return "https://invalid/"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "\(scheme)://invalid/"
    }
}

/// Single source of truth for the engine's per-task temporary artifact
/// naming. App and CLI previously hard-coded this list twice (plus a copy
/// in tests); a new artifact pattern added on one side only would either
/// leak temp files or misclassify user files during cleanup.
public enum DownloadArtifacts {
    /// Every non-final path a stopped task can leave next to its
    /// destination. `destination` is the task's final output path.
    public static func partialArtifactURLs(destination: URL, taskID: UUID) -> [URL] {
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let idString = taskID.uuidString
        return [
            // HTTP ranged download temp file + sidecar
            directory.appendingPathComponent(".\(name).\(idString).macidm.download"),
            directory.appendingPathComponent(".\(name).\(idString).macidm"),
            // HLS raw input (pre-remux TS)
            directory.appendingPathComponent(".\(idString).macidm.hls-input.ts"),
            // DASH pair working directory (video.m4s + audio.m4s)
            directory.appendingPathComponent(".\(idString).macidm.dash-pair"),
            // YouTube extractor working directory (partial yt-dlp output)
            directory.appendingPathComponent(".\(idString).macidm.youtube"),
        ]
    }
}
