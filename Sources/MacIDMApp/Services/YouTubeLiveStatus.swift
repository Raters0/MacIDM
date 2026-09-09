import Foundation

/// Maps yt-dlp `-J` top-level live fields to product semantics. The inspection
/// layer (YouTubeMediaInspector) and the execution layer (YouTubeDownloadRunner)
/// share the same classification rules so both reach the same verdict among
/// "currently live / upcoming / replay not ready / ended replay / plain VOD /
/// unknown".
/// Never depends on volatile stderr wording.
struct YouTubeLiveState: Sendable, Equatable {
    let isLive: Bool?
    let wasLive: Bool?
    let liveStatus: String?
}

/// The product supports only VOD and ended replays; currently-live, upcoming,
/// and not-yet-generated replays are blocked in the inspection/execution
/// layers. `.unknown` means fields are missing, contradictory, or an
/// unrecognized enum value: callers must fail closed, never treating it as
/// VOD (round 2 §P1-2).
enum YouTubeLivePhase: String, Sendable, Equatable {
    /// Currently live (`is_live == true` or `live_status == "is_live"`).
    case currentlyLive
    /// Scheduled/upcoming (`live_status == "is_upcoming"`).
    case upcoming
    /// Stream ended but the replay is not generated yet (`live_status == "post_live"` etc.).
    case replayNotReady
    /// Ended replay (`was_live == true` or `live_status == "was_live"`),
    /// handled as a plain video.
    case endedReplay
    /// Plain VOD (`live_status == "not_live"` or an explicitly non-live boolean combination).
    case vod
    /// Fields missing, contradictory, or an unknown `live_status`: must not be allowed through.
    case unknown
}

enum YouTubeLiveClassifier {
    /// Whitelist of `live_status` values yt-dlp has recognized and we allow
    /// through; any string outside the whitelist (including future enum
    /// additions) becomes `.unknown`, fail-closed.
    static let allowedLiveStatusValues: Set<String> = [
        "is_live", "is_upcoming", "post_live", "post_live_will_replay", "was_live", "not_live",
    ]

    /// Field classification rules (table-driven; the inspection and execution
    /// layers share the same sample set):
    /// 1. When `live_status` is whitelisted, it wins;
    /// 2. Boolean fields contradicting `live_status` map to `.unknown`;
    /// 3. Without `live_status`: `is_live == true` → currently live; `was_live == true`
    ///    → ended replay; VOD is allowed only when both `is_live == false` and
    ///    `was_live == false` are explicit;
    /// 4. All fields missing, insufficient booleans such as a lone `is_live: false`,
    ///    or unknown enums all become `.unknown`; neither layer may proceed
    ///    (round 4 R1: a lone is_live:false must no longer pass as VOD).
    static func phase(_ state: YouTubeLiveState) -> YouTubeLivePhase {
        let status = state.liveStatus?.lowercased()

        if let status {
            guard allowedLiveStatusValues.contains(status) else { return .unknown }
            // When a whitelisted status contradicts the boolean flags, treat as
            // unknown — re-checking beats letting it through.
            switch status {
            case "is_live":
                if state.isLive == false { return .unknown }
                return .currentlyLive
            case "is_upcoming":
                if state.isLive == true { return .unknown }
                return .upcoming
            case "post_live", "post_live_will_replay":
                if state.isLive == true { return .unknown }
                return .replayNotReady
            case "was_live":
                if state.isLive == true { return .unknown }
                return .endedReplay
            case "not_live":
                if state.isLive == true { return .unknown }
                return state.wasLive == true ? .endedReplay : .vod
            default:
                return .unknown
            }
        }

        // No `live_status`: rely only on explicit boolean fields; insufficient
        // combinations become unknown.
        if state.isLive == true {
            // Contradicts an explicit replay/ended flag that says "not live".
            return state.wasLive == false ? .unknown : .currentlyLive
        }
        if state.wasLive == true { return .endedReplay }
        // Allow VOD only when both booleans explicitly deny liveness; a lone
        // is_live:false is insufficient.
        if state.isLive == false && state.wasLive == false { return .vod }
        return .unknown
    }

    /// Phases that must not enter a download in this product. `.unknown` is
    /// mapped by the caller to a retryable inspection error
    /// (`YTDLP_LIVE_STATUS_UNKNOWN`), not to "live unsupported".
    static func isBlocked(_ phase: YouTubeLivePhase) -> Bool {
        phase == .currentlyLive || phase == .upcoming || phase == .replayNotReady
    }

    /// Phases allowed to continue downloading: only explicit plain VOD and ended replays.
    static func isAllowed(_ phase: YouTubeLivePhase) -> Bool {
        phase == .vod || phase == .endedReplay
    }
}

/// Minimal model decoding the live fields from the top-level `-J` JSON, shared
/// by the inspection and execution layer probes. All other fields are ignored.
struct YouTubeLiveStateProbe: Decodable, Sendable {
    let isLive: Bool?
    let wasLive: Bool?
    let liveStatus: String?

    enum CodingKeys: String, CodingKey {
        case isLive = "is_live"
        case wasLive = "was_live"
        case liveStatus = "live_status"
    }

    var state: YouTubeLiveState {
        YouTubeLiveState(isLive: isLive, wasLive: wasLive, liveStatus: liveStatus)
    }
}

/// Table-driven live-status samples shared by the inspection and execution
/// layers (round 2 §P1-2 acceptance): both sides' unit tests must assert the
/// same verdict for the same inputs.
enum YouTubeLivePhaseFixtures {
    /// (name, JSON, expected phase).
    static let cases: [(name: String, json: String, expected: YouTubeLivePhase)] = [
        ("currently-live-flag", #"{"is_live": true}"#, .currentlyLive),
        ("currently-live-status", #"{"live_status": "is_live"}"#, .currentlyLive),
        ("upcoming", #"{"live_status": "is_upcoming"}"#, .upcoming),
        ("replay-not-ready", #"{"live_status": "post_live"}"#, .replayNotReady),
        ("replay-will-replay", #"{"live_status": "post_live_will_replay"}"#, .replayNotReady),
        ("ended-replay-status", #"{"live_status": "was_live"}"#, .endedReplay),
        ("ended-replay-flag", #"{"was_live": true}"#, .endedReplay),
        ("vod-status", #"{"live_status": "not_live"}"#, .vod),
        ("vod-explicit-flags", #"{"is_live": false, "was_live": false}"#, .vod),
        ("vod-not-live-was-live", #"{"live_status": "not_live", "was_live": true}"#, .endedReplay),
        ("insufficient-solo-is-live-false", #"{"is_live": false}"#, .unknown),
        ("empty-object", "{}", .unknown),
        ("unknown-status-value", #"{"live_status": "some_future_state"}"#, .unknown),
        ("insufficient-boolean", #"{"was_live": false}"#, .unknown),
        ("contradiction-live-vs-not-live", #"{"is_live": true, "live_status": "not_live"}"#, .unknown),
        ("contradiction-live-vs-was-live", #"{"is_live": true, "was_live": false}"#, .unknown),
        ("contradiction-not-live-vs-live", #"{"is_live": false, "live_status": "is_live"}"#, .unknown),
    ]

    /// Decodes and classifies; a decode failure itself is also unknown
    /// (matching the execution layer's JSON error path).
    static func phase(forJSON json: String) -> YouTubeLivePhase? {
        let data = Data(json.utf8)
        guard let probe = try? JSONDecoder().decode(YouTubeLiveStateProbe.self, from: data) else {
            return nil
        }
        return YouTubeLiveClassifier.phase(probe.state)
    }
}
