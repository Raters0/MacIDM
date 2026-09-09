import Foundation

enum CLIError: Error {
    case usage(String)
    case taskNotFound
}

struct CLIArguments {
    enum Command {
        case add(String, URL?, Int, String?, Bool)
        case inspect(String, String?)
        case status(UUID?)
        case pause(UUID)
        case resume(UUID)
        case cancel(UUID)
        case remove(UUID, Bool)
        case run(UUID)
        case watch(TimeInterval)
        case logs(Bool, Int)
        case appStatus
        case help
    }

    let command: Command
    let json: Bool
    let stateDirectory: URL

    init(_ raw: [String]) throws {
        var values = raw
        json = try Self.takeFlag("--json", from: &values)
        let defaultState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacIDM/cli", isDirectory: true)
        stateDirectory = URL(
            fileURLWithPath: try Self.takeValue("--state-dir", from: &values) ?? defaultState.path
        )
        guard let verb = values.first else {
            command = .help
            return
        }
        values.removeFirst()
        switch verb {
        case "add":
            guard !values.isEmpty else { throw CLIError.usage("add requires a URL") }
            command = .add(
                try Self.takePositionalURL(&values, verb: "add"),
                try Self.takeValue("--output", from: &values).map { URL(fileURLWithPath: $0) },
                try Self.takeParallel(from: &values),
                try Self.takeValue("--sha256", from: &values),
                try Self.takeFlag("--foreground", from: &values))
            guard values.isEmpty else { throw CLIError.usage("Unknown add option: \(values[0])") }
        case "inspect":
            guard !values.isEmpty else { throw CLIError.usage("inspect requires a URL") }
            let url = try Self.takePositionalURL(&values, verb: "inspect")
            let mediaKind = try Self.takeValue("--media-kind", from: &values)
            if let mediaKind, !["hls", "dash", "youtube", "http"].contains(mediaKind) {
                throw CLIError.usage("--media-kind must be one of: hls, dash, youtube, http")
            }
            guard values.isEmpty else { throw CLIError.usage("Unknown inspect option: \(values[0])") }
            command = .inspect(url, mediaKind)
        case "status":
            guard values.count <= 1 else {
                throw CLIError.usage("status accepts at most one task ID")
            }
            command = .status(try values.first.map(Self.parseUUID))
        case "pause":
            command = .pause(try Self.requiredID(values, verb))
        case "resume":
            command = .resume(try Self.requiredID(values, verb))
        case "cancel":
            command = .cancel(try Self.requiredID(values, verb))
        case "remove":
            let deleteFile = try Self.takeFlag("--delete-file", from: &values)
            command = .remove(try Self.requiredID(values, verb), deleteFile)
        case "_run":
            command = .run(try Self.requiredID(values, verb))
        case "watch":
            let intervalValue = try Self.takeValue("--interval", from: &values) ?? "1.0"
            guard let interval = Double(intervalValue), interval > 0 else {
                throw CLIError.usage("--interval must be a positive number of seconds")
            }
            guard values.isEmpty else { throw CLIError.usage("Unknown watch option: \(values[0])") }
            command = .watch(interval)
        case "logs":
            let follow = try Self.takeFlag("--follow", from: &values)
            let linesValue = try Self.takeValue("--lines", from: &values) ?? "50"
            guard let lines = Int(linesValue), lines > 0 else {
                throw CLIError.usage("--lines must be a positive integer")
            }
            guard values.isEmpty else { throw CLIError.usage("Unknown logs option: \(values[0])") }
            command = .logs(follow, lines)
        case "app-status":
            guard values.isEmpty else { throw CLIError.usage("app-status takes no arguments") }
            command = .appStatus
        case "help", "--help", "-h":
            command = .help
        default:
            throw CLIError.usage("Unknown command: \(verb)")
        }
    }

    static let usage = """
        Usage:
          macidm add <URL> [--output <file>] [--parallel 1...64] [--sha256 <hex>] [--foreground]
            Signed/query URLs are never persisted; use --foreground for a one-process download.
          macidm inspect <URL> [--media-kind hls|dash|youtube|http]
            Parse media variants without downloading. Auto-detects kind from URL if omitted.
          macidm status [task-id]
          macidm pause <task-id>
          macidm resume <task-id>
          macidm cancel <task-id>
          macidm remove <task-id> [--delete-file]
            Delete a CLI task record (terminal tasks only). --delete-file also
            removes the downloaded file and partial artifacts.
          macidm watch [--interval <seconds>]
            Live TUI monitoring of App state. Press Ctrl+C to exit.
          macidm logs [--follow] [--lines <n>]
            Show recent App logs. Use --follow to tail in real time.
          macidm app-status
            Show a one-shot snapshot of the App's state.

        Global options:
          --json                 Emit machine-readable JSON
          --state-dir <path>     Override CLI state directory
        """

    private static func takePositionalURL(_ values: inout [String], verb: String) throws -> String {
        let token = values.removeFirst()
        // URL(string:) accepts "--output", so an option-looking token must be
        // rejected before it can be mistaken for a positional URL.
        guard !token.hasPrefix("-") else {
            throw CLIError.usage("\(verb) requires a URL (option \(token) needs a value)")
        }
        return token
    }

    private static func takeParallel(from values: inout [String]) throws -> Int {
        let parallelValue = try Self.takeValue("--parallel", from: &values) ?? "8"
        guard let parallel = Int(parallelValue), (1...64).contains(parallel) else {
            throw CLIError.usage("--parallel must be an integer between 1 and 64")
        }
        return parallel
    }

    private static func requiredID(_ values: [String], _ verb: String) throws -> UUID {
        guard values.count == 1 else { throw CLIError.usage("\(verb) requires one task ID") }
        return try parseUUID(values[0])
    }

    private static func parseUUID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw CLIError.usage("Invalid task ID") }
        return id
    }

    private static func takeFlag(_ flag: String, from values: inout [String]) throws -> Bool {
        guard let index = values.firstIndex(of: flag) else { return false }
        values.remove(at: index)
        guard !values.contains(flag) else { throw CLIError.usage("Duplicate option: \(flag)") }
        return true
    }

    private static func takeValue(_ option: String, from values: inout [String]) throws -> String? {
        guard let index = values.firstIndex(of: option) else { return nil }
        guard values.indices.contains(index + 1) else {
            throw CLIError.usage("\(option) requires a value")
        }
        values.remove(at: index)
        let value = values.remove(at: index)
        guard !values.contains(option) else { throw CLIError.usage("Duplicate option: \(option)") }
        return value
    }
}
