import AppKit
import Foundation
import IDMEngine

/// JSON/CSV export of the task list (already-redacted URLs only) and JSON
/// re-import as paused tasks for migration between Macs.
struct TaskTransferDocument: Codable {
    struct Entry: Codable {
        let filename: String
        let sourceURL: String
        let destinationPath: String
        let status: String
        let totalBytes: Int64?
        let receivedBytes: Int64
        let createdAt: Date
        // Preserved so HLS/DASH tasks do not collapse to plain HTTP on import.
        // Optional for backward compatibility with v1 exports written before
        // this field existed.
        let sourceKind: String?

        /// Convenience accessor used by the import path; falls back to .http
        /// for legacy entries that have no sourceKind.
        var downloadSourceKind: DownloadSourceKind {
            sourceKind.flatMap(DownloadSourceKind.init(rawValue:)) ?? .http
        }
    }

    let formatVersion: Int
    let exportedAt: Date
    let tasks: [Entry]
}

enum TaskTransfer {
    enum Format: String, CaseIterable, Identifiable {
        case json
        case csv

        var id: String { rawValue }

        var title: String {
            switch self {
            case .json: "JSON"
            case .csv: "CSV"
            }
        }

        var fileExtension: String { rawValue }
    }

    static func document(for tasks: [AppTask]) -> TaskTransferDocument {
        TaskTransferDocument(
            formatVersion: 1,
            exportedAt: Date(),
            tasks: tasks.map {
                .init(
                    filename: $0.filename,
                    sourceURL: $0.redactedSourceURL,
                    destinationPath: $0.destinationPath,
                    status: $0.status.rawValue,
                    totalBytes: $0.totalBytes,
                    receivedBytes: $0.receivedBytes,
                    createdAt: $0.createdAt,
                    sourceKind: $0.sourceKind?.rawValue
                )
            }
        )
    }

    static func jsonData(for tasks: [AppTask]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document(for: tasks))
    }

    static func csvData(for tasks: [AppTask]) -> Data {
        var lines = ["filename,source_url,destination_path,status,total_bytes,received_bytes,created_at,source_kind"]
        let formatter = ISO8601DateFormatter()
        for entry in document(for: tasks).tasks {
            let row = [
                entry.filename,
                entry.sourceURL,
                entry.destinationPath,
                entry.status,
                entry.totalBytes.map(String.init) ?? "",
                String(entry.receivedBytes),
                formatter.string(from: entry.createdAt),
                entry.sourceKind ?? "",
            ]
            .map(escape)
            .joined(separator: ",")
            lines.append(row)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func decodeImport(_ data: Data) throws -> [TaskTransferDocument.Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TaskTransferDocument.self, from: data)
        guard document.formatVersion == 1 else {
            throw TaskTransferError.unsupportedVersion(document.formatVersion)
        }
        return document.tasks
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum TaskTransferError: LocalizedError {
    case unsupportedVersion(Int)
    case noImportableTasks

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "任务导出文件版本 \(version) 不受支持。")
        case .noImportableTasks:
            String(localized: "导出文件中没有可导入的下载任务。")
        }
    }
}
