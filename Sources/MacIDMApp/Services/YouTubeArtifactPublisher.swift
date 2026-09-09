import Foundation

/// Extracts and validates the target media artifact produced by yt-dlp.
enum YouTubeArtifactPublisher {
    /// Scans the working directory for the most recently modified valid video artifact,
    /// filtering out .part temp files.
    static func producedMedia(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        let allowedExtensions = Set(["mp4", "m4v", "webm", "mkv", "mov"])
        return
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ))?
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !$0.lastPathComponent.hasSuffix(".part") }
            .sorted { left, right in
                let leftDate =
                    (try? left.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate)
                    ?? .distantPast
                let rightDate =
                    (try? right.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate)
                    ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }
}
