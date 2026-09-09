import Foundation

enum DisplayFormatting {
    private static func byteFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }

    static func byteCount(_ value: Int64?) -> String {
        guard let value else { return String(localized: "未知") }
        return byteFormatter().string(fromByteCount: value)
    }

    static func speed(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        return "\(byteFormatter().string(fromByteCount: Int64(value)))/s"
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let totalSeconds = Int(value.rounded(.up))
        if totalSeconds >= 3_600 {
            return String(format: "%d:%02d:%02d", totalSeconds / 3_600, (totalSeconds / 60) % 60, totalSeconds % 60)
        }
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
