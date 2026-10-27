import Foundation
import IDMEngine

enum CLIOutput {
    static func taskDictionary(_ task: StoredTask) -> [String: Any] {
        var value: [String: Any] = [
            "id": task.id.uuidString.lowercased(),
            "url": redactedURL(task.url),
            "destination": task.destination,
            "status": task.status.rawValue,
            "receivedBytes": task.receivedBytes,
            "parallelRequests": task.parallelRequests,
        ]
        if let total = task.totalBytes {
            value["totalBytes"] = total
        }
        if let sha256 = task.sha256 {
            value["sha256"] = sha256
        }
        if let code = task.errorCode {
            value["errorCode"] = code
        }
        if let message = task.errorMessage {
            value["errorMessage"] = message
        }
        return value
    }

    static func emitTask(_ task: StoredTask, json: Bool) {
        if json {
            emitJSON(taskDictionary(task))
        } else {
            print(taskLine(task))
        }
    }

    static func taskLine(_ task: StoredTask) -> String {
        let total = task.totalBytes.map(String.init) ?? "?"
        return
            "\(task.id.uuidString.lowercased())  \(task.status.rawValue)  \(task.receivedBytes)/\(total)  \(task.destination)"
    }

    static func emitJSON(_ object: Any) {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        print(text)
    }

    static func emitError(_ error: Error, json: Bool) {
        let code = errorCode(error)

        let message: String
        if case CLIError.usage(let detail) = error {
            message = detail
        } else {
            message = error.localizedDescription
        }

        if json {
            emitJSON(["status": "error", "code": code, "message": message])
        } else {
            let data = "macidm: \(code): \(message)\n".data(using: .utf8)!
            FileHandle.standardError.write(data)
        }
    }

    static func errorCode(_ error: Error) -> String {
        if let engine = error as? IDMError {
            return engine.code
        }
        if case CLIError.taskNotFound = error {
            return "TASK_NOT_FOUND"
        }
        if error is URLError {
            // Transport failures that reach the CLI as Foundation errors are
            // network problems, not argument mistakes; labeling them
            // USAGE_ERROR sends users and support scripts debugging the
            // command they typed instead of the connection.
            return "NETWORK_ERROR"
        }
        return "USAGE_ERROR"
    }

    static func exitCode(for error: Error) -> Int32 {
        if error is CLIError {
            return 2
        }
        guard let error = error as? IDMError else { return 5 }
        switch error {
        case .filenameConflict:
            return 4
        case .pathNotWritable, .storageError:
            return 6
        case .verificationFailed:
            return 7
        case .paused, .cancelled:
            return 8
        case .invalidURL, .unsupportedScheme, .invalidParallelRequests, .invalidExpectedHash:
            return 2
        default:
            return 5
        }
    }

    private static func redactedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "<invalid-url>" }
        if components.query != nil {
            components.query = "<redacted>"
        }
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "<redacted-url>"
    }
}
