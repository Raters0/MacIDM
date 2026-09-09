import Foundation

struct CLIAppStatus {
    static func run(json: Bool) -> Int32 {
        guard FileManager.default.fileExists(atPath: AppStatusPaths.statusURL.path) else {
            if json {
                CLIOutput.emitJSON(["error": "App 未运行或未生成状态文件"])
            } else {
                print("App 未运行或未生成状态文件")
            }
            return 1
        }

        guard let data = try? Data(contentsOf: AppStatusPaths.statusURL) else {
            if json {
                CLIOutput.emitJSON(["error": "无法读取状态文件"])
            } else {
                print("无法读取状态文件")
            }
            return 1
        }

        if json {
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        }

        guard let snapshot = try? JSONDecoder().decode(AppStatusSnapshot.self, from: data) else {
            print("无法解析状态文件")
            return 1
        }

        print("MacIDM App Status")
        print("  Version:  \(snapshot.appVersion)")
        print("  Bridge:   \(snapshot.bridgeStatus)")
        if snapshot.ytdlpInstalled {
            print("  yt-dlp:   \(snapshot.ytdlpVersion ?? "installed")")
        } else {
            print("  yt-dlp:   not installed")
        }
        print("  ffmpeg:   \(snapshot.ffmpegAvailable ? "available" : "unavailable")")
        print("  Updated:  \(snapshot.timestamp)")

        if snapshot.tasks.isEmpty {
            print("\nNo tasks.")
        } else {
            print("\nTasks (\(snapshot.tasks.count)):")
            for task in snapshot.tasks {
                let progress = progressPercent(received: task.receivedBytes, total: task.totalBytes)
                let bytes = bytesString(received: task.receivedBytes, total: task.totalBytes)
                let speed = task.speed.map { formatBytes(Int64($0)) + "/s" } ?? "—"
                print("  \(task.status)  \(progress)  \(bytes)  \(speed)")
                print("    \(task.filename)")
                if let error = task.errorMessage, !error.isEmpty {
                    print("    ! \(error)")
                }
            }
        }

        if !snapshot.recentLogs.isEmpty {
            print("\nRecent logs:")
            for line in snapshot.recentLogs.suffix(5) {
                print("  \(line)")
            }
        }

        return 0
    }

    private static func progressPercent(received: Int64, total: Int64?) -> String {
        guard let total, total > 0 else { return "—" }
        let percent = Int(Double(received) / Double(total) * 100)
        return "\(min(percent, 100))%"
    }

    private static func bytesString(received: Int64, total: Int64?) -> String {
        let receivedText = formatBytes(received)
        let totalText = total.map { formatBytes($0) } ?? "?"
        return "\(receivedText) / \(totalText)"
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
