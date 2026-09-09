import AppKit
import Foundation

/// Installs and inspects the Chrome Native Messaging host manifest for the
/// onboarding flow. Mirrors scripts/install-debug-native-host.sh but works
/// inside the app bundle.
struct NativeHostInstaller: Sendable {
    static let extensionID = "obaipbnfoifafgcpekkfkapjifjgbjag"

    private var fileManager: FileManager { .default }

    var chromeSupportDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    var manifestURL: URL {
        chromeSupportDirectory
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("com.macidm.host.json")
    }

    var hostExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macidm-host")
    }

    var isChromeInstalled: Bool {
        let candidates = [
            "/Applications/Google Chrome.app",
            "\(NSHomeDirectory())/Applications/Google Chrome.app",
        ]
        return candidates.contains { fileManager.fileExists(atPath: $0) }
    }

    var isHostRegistered: Bool {
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = manifest["path"] as? String
        else { return false }
        return path == hostExecutableURL.path && fileManager.isExecutableFile(atPath: path)
    }

    var extensionSourcePath: String {
        // Development checkout: <repo>/BrowserExtension/chrome. The bundled
        // app lives in <repo>/.build/debug or ~/Applications, so the path is
        // only a hint — the user picks the folder in chrome://extensions.
        let bundled = Bundle.main.bundleURL
        let repoCheckout =
            bundled
            .deletingLastPathComponent()  // MacOS or ~/Applications
            .deletingLastPathComponent()  // Contents or ~
            .deletingLastPathComponent()  // .app or Applications
        let debugCandidate =
            repoCheckout
            .appendingPathComponent("BrowserExtension/chrome")
        if fileManager.fileExists(atPath: debugCandidate.path) {
            return debugCandidate.path
        }
        return "BrowserExtension/chrome"
    }

    func install() throws {
        guard fileManager.isExecutableFile(atPath: hostExecutableURL.path) else {
            throw NativeHostInstallError.hostMissing(hostExecutableURL.path)
        }
        let manifest: [String: Any] = [
            "name": "com.macidm.host",
            "description": "MacIDM Native Messaging Host",
            "path": hostExecutableURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func openChrome() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

enum NativeHostInstallError: LocalizedError {
    case hostMissing(String)

    var errorDescription: String? {
        switch self {
        case .hostMissing(let path):
            String(localized: "Native Host 可执行文件不存在：\(path)")
        }
    }
}
