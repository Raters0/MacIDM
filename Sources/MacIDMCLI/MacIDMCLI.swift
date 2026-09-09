import Darwin
import Foundation
import IDMEngine

@main
struct MacIDMCLI {
    static func main() async {
        // When a pipe such as `macidm status | head` closes early, treat it as
        // an ordinary write error rather than dying from SIGPIPE (141).
        signal(SIGPIPE, SIG_IGN)
        // Diagnostic/gating switch: force a direct connection that bypasses
        // the OS proxy (used by the sample gate when the local system proxy
        // is unstable).
        if ProcessInfo.processInfo.environment["MACIDM_FORCE_DIRECT"] == "1" {
            DownloadProxyPolicy.setForceDirect(true)
        }
        do {
            let arguments = try CLIArguments(Array(CommandLine.arguments.dropFirst()))
            exit(try await CLIApplication.execute(arguments))
        } catch {
            CLIOutput.emitError(error, json: CommandLine.arguments.contains("--json"))
            exit(CLIOutput.exitCode(for: error))
        }
    }
}
