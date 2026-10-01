import Foundation

/// Read-only access to the app bundle's build metadata. The single source
/// for the marketing version, so every reporter of the app version
/// (browser bridge payloads, update checks, monitor state) reads the same
/// Info.plist value written by `scripts/build-debug-app.sh` instead of a
/// hardcoded literal that drifts on the next release bump.
enum AppBuildInfo {
    /// `CFBundleShortVersionString` (e.g. "1.0.2"), or nil outside a real
    /// app bundle (plain SwiftPM runs, test hosts).
    static var marketingVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
