import Foundation

/// Unified media-variant display label: `{resolution} · {framerate} · {codec family} · {bitrate}`.
/// Fixed slot order; missing slots are skipped and no "unknown" placeholder is shown. Size,
/// container format, and site name never enter the label (they get dedicated UI positions).
/// Raw fields (e.g. codecs) are still passed through unchanged for deduplication and
/// downloading; this formatter only builds the display string.
public enum MediaVariantLabel {
    /// Maps a codecs string to a readable codec-family name (first comma-separated entry).
    /// Unknown codecs return nil; callers should omit the slot instead of showing a FourCC
    /// such as avc1.640033.
    public static func family(forCodecs codecs: String?) -> String? {
        guard let codecs else { return nil }
        let primary =
            codecs.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !primary.isEmpty else { return nil }
        let lower = primary.lowercased()
        if lower.hasPrefix("avc1") { return "H.264" }
        if lower.hasPrefix("hev1") || lower.hasPrefix("hvc1") { return "H.265" }
        if lower.hasPrefix("av01") { return "AV1" }
        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
        if lower.hasPrefix("mp4a") { return "AAC" }
        if lower.hasPrefix("opus") { return "Opus" }
        if lower.hasPrefix("ac-3") || lower.hasPrefix("ac3") { return "AC-3" }
        if lower.hasPrefix("ec-3") || lower.hasPrefix("ec3") { return "E-AC-3" }
        return nil
    }

    /// Resolution slot: standard heights use tier labels (8K/4K/2K/1080P/720P/480P/360P);
    /// non-standard resolutions fall back to `W×H`, height-only uses `{h}p`; returns nil
    /// when there is no size information.
    public static func resolution(width: Int?, height: Int?) -> String? {
        if let width, let height {
            return tier(height: height) ?? "\(width)×\(height)"
        }
        if let height { return "\(height)p" }
        return nil
    }

    /// Bitrate slot: >= 1 Mbps uses Mbps with one decimal place, otherwise integer kbps;
    /// below 1 kbps or invalid input returns nil (avoids "0 kbps" noise).
    public static func bitrate(_ bandwidth: Int?) -> String? {
        guard let bandwidth, bandwidth >= 1000 else { return nil }
        let megabits = Double(bandwidth) / 1_000_000
        return megabits >= 1.0 ? String(format: "%.1f Mbps", megabits) : "\(bandwidth / 1000) kbps"
    }

    /// Joins slots under the unified grammar; returns an empty string when every slot is
    /// missing, leaving the fallback text to the caller.
    public static func format(
        width: Int?,
        height: Int?,
        fps: Double? = nil,
        codecs: String?,
        bandwidth: Int?
    ) -> String {
        var parts: [String] = []
        if let resolution = resolution(width: width, height: height) { parts.append(resolution) }
        if let fps, fps > 0 { parts.append("\(Int(fps.rounded()))fps") }
        if let family = family(forCodecs: codecs) { parts.append(family) }
        if let bitrate = bitrate(bandwidth) { parts.append(bitrate) }
        return parts.joined(separator: " · ")
    }

    private static func tier(height: Int) -> String? {
        if let exact = canonicalTier(height) { return exact }
        // Common encoders pad the height to a multiple of 16; 1088 is really 1080p.
        if height % 16 == 8 { return canonicalTier(height - 8) }
        return nil
    }

    private static func canonicalTier(_ height: Int) -> String? {
        switch height {
        case 4320: "8K"
        case 2160: "4K"
        case 1440: "2K"
        case 1080: "1080P"
        case 720: "720P"
        case 480: "480P"
        case 360: "360P"
        default: nil
        }
    }
}
