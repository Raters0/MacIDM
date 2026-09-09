import Darwin
import Foundation

struct AppStatusSnapshot: Codable {
    var timestamp: String
    var appVersion: String
    var bridgeStatus: String
    var ytdlpInstalled: Bool
    var ytdlpVersion: String?
    var ffmpegAvailable: Bool
    var tasks: [AppTaskSnapshot]
    var recentLogs: [String]
}

struct AppTaskSnapshot: Codable {
    var id: String
    var status: String
    var filename: String
    var receivedBytes: Int64
    var totalBytes: Int64?
    var speed: Double?
    var category: String?
    var errorMessage: String?
    var backend: String?
    var sourceKind: String?
    var createdAt: String
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

enum AppStatusPaths {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacIDM", isDirectory: true)

    static let statusURL = supportDirectory.appendingPathComponent("status.json")
    static let logURL = supportDirectory.appendingPathComponent("macidm.log")
    static let rotatedLogURL = supportDirectory.appendingPathComponent("macidm.log.1")
}

struct CLIWatch {
    static func run(interval: TimeInterval) -> Int32 {
        let stopFlag = AtomicFlag()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { stopFlag.set() }
        source.resume()

        while !stopFlag.get() {
            renderFrame()
            Thread.sleep(forTimeInterval: interval)
        }

        signal(SIGINT, SIG_DFL)
        writeOut("\n")
        return 0
    }

    private static func renderFrame() {
        writeOut("\u{001B}[2J\u{001B}[H")

        guard FileManager.default.fileExists(atPath: AppStatusPaths.statusURL.path) else {
            writeOut("App 未运行或未生成状态文件\n")
            writeOut("等待 App 启动...\n")
            return
        }

        guard let data = try? Data(contentsOf: AppStatusPaths.statusURL),
            let snapshot = try? JSONDecoder().decode(AppStatusSnapshot.self, from: data)
        else {
            writeOut("无法读取状态文件\n")
            return
        }

        var output = "MacIDM Watch  v\(snapshot.appVersion)\n"
        output += "Bridge: \(snapshot.bridgeStatus)  "
        if snapshot.ytdlpInstalled {
            output += "yt-dlp: \(snapshot.ytdlpVersion ?? "installed")  "
        } else {
            output += "yt-dlp: not installed  "
        }
        output += "ffmpeg: \(snapshot.ffmpegAvailable ? "available" : "unavailable")\n"
        output += "Updated: \(snapshot.timestamp)\n\n"

        if snapshot.tasks.isEmpty {
            output += "No active tasks.\n\n"
        } else {
            output += "Tasks (\(snapshot.tasks.count)):\n"
            let header =
                "  \(pad("Filename", to: 40))  \(pad("Status", to: 13))  "
                + "\(pad("Progress", to: 26))  \(pad("Bytes", to: 22))  Speed\n"
            output += header
            for task in snapshot.tasks {
                let name = truncate(task.filename, to: 40)
                let progress = progressString(received: task.receivedBytes, total: task.totalBytes)
                let bytes = bytesString(received: task.receivedBytes, total: task.totalBytes)
                let speed = task.speed.map { formatSpeed($0) } ?? "—"
                output += "  \(pad(name, to: 40))  \(pad(task.status, to: 13))  "
                output += "\(pad(progress, to: 26))  \(pad(bytes, to: 22))  \(speed)\n"
                if let error = task.errorMessage, !error.isEmpty {
                    output += "    ! \(error)\n"
                }
            }
            output += "\n"
        }

        output += "Recent logs:\n"
        for line in snapshot.recentLogs.suffix(5) {
            output += "  \(line)\n"
        }

        writeOut(output)
    }

    private static func writeOut(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func truncate(_ s: String, to length: Int) -> String {
        if s.count <= length { return s }
        return String(s.prefix(length - 3)) + "..."
    }

    private static func pad(_ s: String, to length: Int) -> String {
        if s.count >= length { return String(s.prefix(length)) }
        return s + String(repeating: " ", count: length - s.count)
    }

    private static func progressString(received: Int64, total: Int64?) -> String {
        let ratio: Double
        if let total, total > 0 {
            ratio = Double(received) / Double(total)
        } else {
            ratio = 0
        }
        let clamped = max(0, min(1, ratio))
        let filled = Int(clamped * 20)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
        let percent = Int(clamped * 100)
        return "[\(bar)] \(String(format: "%3d%%", percent))"
    }

    private static func bytesString(received: Int64, total: Int64?) -> String {
        let receivedText = formatBytes(received)
        let totalText = total.map { formatBytes($0) } ?? "?"
        return "\(receivedText) / \(totalText)"
    }

    private static func formatSpeed(_ speed: Double) -> String {
        formatBytes(Int64(speed)) + "/s"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1_024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var size = value
        var unit = "B"
        for next in units {
            if size < 1_024 { break }
            size /= 1_024
            unit = next
        }
        return size >= 100 ? String(format: "%.0f %@", size, unit) : String(format: "%.1f %@", size, unit)
    }
}
