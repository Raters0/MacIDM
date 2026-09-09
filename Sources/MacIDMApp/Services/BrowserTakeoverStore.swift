import Darwin
import Foundation

struct BrowserTakeoverStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    private let ephemeralBackend: InMemoryBrowserTakeoverStore?

    init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.ephemeralBackend = nil
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func ephemeral() -> BrowserTakeoverStore {
        BrowserTakeoverStore(ephemeralBackend: InMemoryBrowserTakeoverStore())
    }

    private init(ephemeralBackend: InMemoryBrowserTakeoverStore) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacIDM-ephemeral", isDirectory: true)
        fileManager = .default
        self.ephemeralBackend = ephemeralBackend
    }

    func load() throws -> [BrowserTakeoverRecord] {
        if let ephemeralBackend { return ephemeralBackend.load() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BrowserTakeoverRecord].self, from: Data(contentsOf: fileURL))
    }

    func save(_ records: [BrowserTakeoverRecord]) throws {
        if let ephemeralBackend {
            ephemeralBackend.save(records)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    func loadAbandoned() throws -> [AbandonedBrowserTakeover] {
        if let ephemeralBackend { return ephemeralBackend.loadAbandoned() }
        guard fileManager.fileExists(atPath: abandonedFileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [AbandonedBrowserTakeover].self,
            from: Data(contentsOf: abandonedFileURL)
        )
    }

    func saveAbandoned(_ records: [AbandonedBrowserTakeover]) throws {
        if let ephemeralBackend {
            ephemeralBackend.saveAbandoned(records)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: abandonedFileURL, options: .atomic)
    }

    func reserve(path: URL) throws {
        if let ephemeralBackend {
            try ephemeralBackend.reserve(path: path.path)
            return
        }
        let descriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw BrowserTakeoverError.destinationReserved }
            throw BrowserTakeoverError.reservationFailed
        }
        Darwin.close(descriptor)
    }

    func release(path: String) {
        guard path.hasSuffix(".macidm.takeover") else { return }
        if let ephemeralBackend {
            ephemeralBackend.release(path: path)
            return
        }
        try? fileManager.removeItem(atPath: path)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("browser-takeovers.json")
    }

    private var abandonedFileURL: URL {
        directory.appendingPathComponent("abandoned-browser-takeovers.json")
    }
}

private final class InMemoryBrowserTakeoverStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [BrowserTakeoverRecord] = []
    private var abandonedRecords: [AbandonedBrowserTakeover] = []
    private var reservations: Set<String> = []

    func load() -> [BrowserTakeoverRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func save(_ records: [BrowserTakeoverRecord]) {
        lock.lock()
        self.records = records
        lock.unlock()
    }

    func loadAbandoned() -> [AbandonedBrowserTakeover] {
        lock.lock()
        defer { lock.unlock() }
        return abandonedRecords
    }

    func saveAbandoned(_ records: [AbandonedBrowserTakeover]) {
        lock.lock()
        abandonedRecords = records
        lock.unlock()
    }

    func reserve(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if !reservations.insert(path).inserted {
            throw BrowserTakeoverError.destinationReserved
        }
    }

    func release(path: String) {
        lock.lock()
        reservations.remove(path)
        lock.unlock()
    }
}

enum BrowserTakeoverError: LocalizedError {
    case destinationReserved
    case reservationFailed
    case contextUnsupported
    case invalidToken
    case takeoverNotFound
    case invalidState
    case abandoned

    var errorDescription: String? {
        switch self {
        case .destinationReserved:
            String(localized: "目标文件已被另一个接管任务预留。")
        case .reservationFailed:
            String(localized: "无法预留下载临时目标。")
        case .contextUnsupported:
            String(localized: "当前版本尚不能安全传递此下载所需的鉴权上下文。")
        case .invalidToken:
            String(localized: "浏览器接管令牌无效或已使用。")
        case .takeoverNotFound:
            String(localized: "找不到对应的浏览器接管记录。")
        case .invalidState:
            String(localized: "浏览器接管状态不允许当前操作。")
        case .abandoned:
            String(localized: "该浏览器接管请求已被放弃，请使用新的请求标识重新提交。")
        }
    }
}
