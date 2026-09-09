import Foundation

struct CLILogs {
    static func run(follow: Bool, lines: Int) -> Int32 {
        let logURL = AppStatusPaths.logURL
        let rotatedURL = AppStatusPaths.rotatedLogURL

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            print("App 日志文件不存在")
            return 1
        }

        let lastLines = readLastLines(active: logURL, rotated: rotatedURL, max: lines)
        for line in lastLines {
            print(line)
        }

        guard follow else { return 0 }

        return tailFile(url: logURL, rotated: rotatedURL, startOffset: fileSize(logURL))
    }

    private static func tailFile(url: URL, rotated: URL, startOffset: Int64) -> Int32 {
        var lastOffset = startOffset
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            let currentSize = fileSize(url)
            if currentSize > lastOffset {
                if let data = readRange(url: url, from: lastOffset, to: currentSize) {
                    FileHandle.standardOutput.write(data)
                }
                lastOffset = currentSize
            } else if currentSize < lastOffset {
                let recent = readLastLines(active: url, rotated: rotated, max: 20)
                for line in recent {
                    print(line)
                }
                lastOffset = fileSize(url)
            }
        }
    }

    private static func readLastLines(active: URL, rotated: URL, max: Int) -> [String] {
        var lines: [String] = []
        let activeText = (try? String(contentsOf: active, encoding: .utf8)) ?? ""
        let activeLines = activeText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if activeLines.count < max {
            let rotatedText = (try? String(contentsOf: rotated, encoding: .utf8)) ?? ""
            let rotatedLines = rotatedText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines = rotatedLines + activeLines
        } else {
            lines = activeLines
        }
        return Array(lines.suffix(max))
    }

    private static func readRange(url: URL, from start: Int64, to end: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(start))
        return handle.readData(ofLength: Int(end - start))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
