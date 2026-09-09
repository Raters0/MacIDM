import Foundation

/// Unified parser for yt-dlp progress output that maintains a multi-track
/// (video/audio/merge) state machine.
enum YTDlpProgressParser {
    struct ProgressSample: Sendable {
        var received: Int64?
        var total: Int64?
        var speed: Double?
        /// True when the total carries yt-dlp's "~" estimate marker.
        var isEstimatedTotal = false
        var percent: Double?
    }

    /// Parses a custom template progress line ("received|total|total_estimate|speed").
    static func parseTemplateLine(_ line: String) -> ProgressSample? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let firstField = String(fields[0])
        let receivedStr =
            firstField.hasPrefix("download:")
            ? String(firstField.dropFirst("download:".count))
            : firstField
        guard let received = Int64(receivedStr), received >= 0 else { return nil }
        let totalStr = String(fields[1])
        let totalAltStr = fields.count >= 3 ? String(fields[2]) : nil
        let total = Int64(totalStr) ?? (totalAltStr.flatMap { Int64($0) })
        let speed = fields.count >= 4 ? Double(String(fields[3])) : nil
        return ProgressSample(received: received, total: total, speed: speed)
    }

    /// Parses a default yt-dlp progress line
    /// ("[download] 12.3% of ~28.53MiB at 499.66KiB/s ETA 00:54").
    static func parseDefaultProgressLine(_ line: String) -> ProgressSample? {
        guard line.contains("[download]"), line.contains("%") else { return nil }

        var speed: Double?
        let speedPattern = #"at\s+(\d+(?:\.\d+)?)(KiB|MiB|GiB|TiB|B)/s"#
        if let speedRegex = try? NSRegularExpression(pattern: speedPattern),
            let speedMatch = speedRegex.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)),
            let valueRange = Range(speedMatch.range(at: 1), in: line),
            let unitRange = Range(speedMatch.range(at: 2), in: line),
            let value = Double(String(line[valueRange]))
        {
            speed = value * byteMultiplier(String(line[unitRange]))
        }

        let pattern = #"(\d+(?:\.\d+)?)%\s+of\s+(~\s*)?(\d+(?:\.\d+)?)(KiB|MiB|GiB|TiB|B)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: line, options: [], range: NSRange(line.startIndex..., in: line))
        else {
            return speed.map { ProgressSample(received: nil, total: nil, speed: $0) }
        }

        func captureGroup(_ index: Int) -> String? {
            guard index < match.numberOfRanges,
                let range = Range(match.range(at: index), in: line)
            else { return nil }
            return String(line[range])
        }

        guard let percentString = captureGroup(1),
            let percent = Double(percentString)
        else {
            return speed.map { ProgressSample(received: nil, total: nil, speed: $0) }
        }

        let isEstimatedTotal = captureGroup(2) != nil
        let sizeValue = Double(captureGroup(3) ?? "") ?? 0
        let unit = captureGroup(4) ?? "B"
        let totalBytes = Int64(sizeValue * byteMultiplier(unit))
        guard totalBytes > 0 else {
            return speed.map { ProgressSample(received: nil, total: nil, speed: $0) }
        }
        let receivedBytes = Int64(Double(totalBytes) * percent / 100.0)

        var sample = ProgressSample(
            received: receivedBytes, total: totalBytes, speed: speed)
        sample.isEstimatedTotal = isEstimatedTotal
        sample.percent = percent
        return sample
    }

    /// Unit conversion multipliers.
    static func byteMultiplier(_ unit: String) -> Double {
        switch unit {
        case "KiB": return 1024
        case "MiB": return 1024 * 1024
        case "GiB": return 1024 * 1024 * 1024
        case "TiB": return 1024 * 1024 * 1024 * 1024
        default: return 1
        }
    }

    /// Computes the staged overall progress fraction.
    static func stagedOverallFraction(
        received: Int64,
        total: Int64?,
        formatIndex: Int,
        highestOverallFraction: inout Double
    ) -> Double? {
        guard let total, total > 0 else { return nil }
        let trackFraction = min(1, max(0, Double(received) / Double(total)))
        let candidate: Double
        switch formatIndex {
        case 0:
            candidate = trackFraction * 0.82
        case 1:
            candidate = 0.82 + trackFraction * 0.16
        default:
            candidate = 0.98 + trackFraction * 0.005
        }
        highestOverallFraction = min(0.985, max(highestOverallFraction, candidate))
        return highestOverallFraction
    }
}
