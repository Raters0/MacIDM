import Foundation
import IDMEngine

/// Recovers a resource's total size from the server without transferring
/// the body. Paired DASH tracks (e.g. Bilibili m4s video + audio) arrive as
/// bare URLs with no manifest to estimate from; probing their
/// Content-Lengths lets the confirmation dialog show a size instead of
/// "size unknown". Mirrors the extension's background size probe: HEAD first,
/// one-byte Range GET as fallback.
enum MediaSizeProbe {
    static let timeout: TimeInterval = 6

    /// Dual-channel diagnostic log; the shared instance by default, tests can
    /// inject an isolated one (round 2 §P2-3).
    nonisolated(unsafe) static var diagnosticLog: DownloadDiagnosticEventLog = .shared

    /// Structured description of a single strategy miss (round 5 P2): distinct
    /// from "the whole probe produced no final result".
    private struct StrategyMiss {
        let strategy: String
        let reason: String
        let statusCode: Int?

        var summaryComponent: String {
            statusCode.map { "\(strategy)=\(reason):\($0)" } ?? "\(strategy)=\(reason)"
        }
    }

    private enum StrategyOutcome {
        case size(Int64)
        case miss(StrategyMiss)
    }

    /// Probes the total size of a URL. Returns nil on any failure — a
    /// missing size is a degraded display, never a blocked submission.
    /// Diagnostic event semantics (round 5 P2): each single strategy miss
    /// records a `sizeProbe.strategyMiss`; only after every strategy fails is
    /// the single final `sizeProbe.noResult` recorded, correlated by the
    /// `probeId` shared by the whole probe; when any strategy succeeds, no
    /// final failure event is emitted.
    static func probe(
        _ url: URL,
        context: DownloadRequestContext? = nil,
        session: URLSession = .shared
    ) async -> Int64? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let probeID = UUID().uuidString
        var misses: [StrategyMiss] = []

        let head = await probeWithHEAD(url, context: context, session: session, probeID: probeID)
        if case .size(let size) = head { return size }
        if case .miss(let miss) = head { misses.append(miss) }

        let ranged = await probeWithRangedGET(
            url, context: context, session: session, probeID: probeID)
        if case .size(let size) = ranged { return size }
        if case .miss(let miss) = ranged { misses.append(miss) }

        logFinalNoResult(url, probeID: probeID, misses: misses)
        return nil
    }

    // MARK: - Strategies

    private static func probeWithHEAD(
        _ url: URL,
        context: DownloadRequestContext?,
        session: URLSession,
        probeID: String
    ) async -> StrategyOutcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        applyHeaders(to: &request, context: context)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return miss(url, strategy: "HEAD", reason: "invalidResponse", statusCode: nil, probeID: probeID)
            }
            // Sharpened status semantics (round 6 P1): HEAD trusts only 200 — only
            // then is Content-Length the full resource length; 206 means the server
            // treated the request as a partial fetch, so its Content-Length is a
            // partial length that must never be used as the total size — record a
            // miss and fall back to Range; other 2xx statuses (201/203/204 etc.)
            // have ambiguous Content-Length semantics and are likewise treated as
            // misses instead of being masked by a broad 200..<300.
            switch http.statusCode {
            case 200:
                guard
                    let size = totalSize(
                        contentLength: http.value(forHTTPHeaderField: "Content-Length"))
                else {
                    return miss(
                        url,
                        strategy: "HEAD",
                        reason: "missingLength",
                        statusCode: http.statusCode,
                        probeID: probeID
                    )
                }
                return .size(size)
            case 206:
                return miss(
                    url,
                    strategy: "HEAD",
                    reason: "unexpectedPartialResponse",
                    statusCode: 206,
                    probeID: probeID
                )
            default:
                return miss(
                    url,
                    strategy: "HEAD",
                    reason: "httpStatus",
                    statusCode: http.statusCode,
                    probeID: probeID
                )
            }
        } catch {
            logFailure(url, error, method: "HEAD", probeID: probeID)
            return .miss(StrategyMiss(strategy: "HEAD", reason: "networkError", statusCode: nil))
        }
    }

    /// A one-byte Range GET covers servers that answer HEAD without
    /// Content-Length: a 206 carries `Content-Range: bytes 0-0/TOTAL`, and
    /// a server that ignores Range answers 200 with a plain Content-Length.
    /// The task is cancelled the moment the headers arrive, so a
    /// Range-ignoring server never streams the whole body at us.
    private static func probeWithRangedGET(
        _ url: URL,
        context: DownloadRequestContext?,
        session: URLSession,
        probeID: String
    ) async -> StrategyOutcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        applyHeaders(to: &request, context: context)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else {
                return miss(url, strategy: "range", reason: "invalidResponse", statusCode: nil, probeID: probeID)
            }
            switch http.statusCode {
            case 206:
                // Round 5 P1: a 206's Content-Length is the body length of this
                // partial response (usually 1 for bytes=0-0) and must never serve as
                // a fallback source for the total resource size; trust only a valid
                // `Content-Range: bytes 0-0/TOTAL`.
                guard let contentRange = http.value(forHTTPHeaderField: "Content-Range") else {
                    return miss(
                        url,
                        strategy: "range",
                        reason: "missingContentRange",
                        statusCode: 206,
                        probeID: probeID
                    )
                }
                // Structured verdict (round 6 P2): validate the unit and range first,
                // then distinguish a legitimate unknown total from an invalid
                // response; only a syntactically and range-correct `bytes 0-0/*` is
                // unknown — any other starred header remains invalid.
                switch parseContentRange(contentRange) {
                case .total(let size):
                    return .size(size)
                case .unknownTotal:
                    return miss(
                        url,
                        strategy: "range",
                        reason: "unknownContentRange",
                        statusCode: 206,
                        probeID: probeID
                    )
                case .invalid:
                    return miss(
                        url,
                        strategy: "range",
                        reason: "invalidContentRange",
                        statusCode: 206,
                        probeID: probeID
                    )
                }
            case 200:
                // Server ignored the Range: a 200's Content-Length is the full
                // response size (behavior unchanged).
                if let size = totalSize(contentLength: http.value(forHTTPHeaderField: "Content-Length")) {
                    return .size(size)
                }
                return miss(url, strategy: "range", reason: "missingLength", statusCode: 200, probeID: probeID)
            default:
                return miss(url, strategy: "range", reason: "httpStatus", statusCode: http.statusCode, probeID: probeID)
            }
        } catch {
            logFailure(url, error, method: "range", probeID: probeID)
            return .miss(StrategyMiss(strategy: "range", reason: "networkError", statusCode: nil))
        }
    }

    /// Records a single strategy miss (`sizeProbe.strategyMiss`) and returns the
    /// corresponding outcome; the ordinary line carries only host, strategy,
    /// reason, and status code — the full URL goes to the private log only, under
    /// the same event ID. probeId is emitted as a structured field, not via free
    /// text summaries (round 6 P2).
    private static func miss(
        _ url: URL,
        strategy: String,
        reason: String,
        statusCode: Int?,
        probeID: String
    ) -> StrategyOutcome {
        logOutcome(url, method: strategy, reason: reason, statusCode: statusCode, probeID: probeID)
        return .miss(StrategyMiss(strategy: strategy, reason: reason, statusCode: statusCode))
    }

    /// Strategy-miss event (introduced in round 4 R4, renamed in round 5 P2):
    /// the name expresses only a single strategy miss, never a whole-probe
    /// failure. internal only so unit tests can drive it directly.
    static func logOutcome(
        _ url: URL,
        method: String,
        reason: String,
        statusCode: Int? = nil,
        probeID: String = ""
    ) {
        let detail =
            statusCode.map { "reason=\(reason) status=\($0)" } ?? "reason=\(reason)"
        diagnosticLog.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "sizeProbe.strategyMiss",
                stage: method,
                taskID: nil,
                backend: nil,
                sourceKind: nil,
                host: url.host,
                errorCode: reason,
                byteCount: nil,
                correlationID: probeID.isEmpty ? nil : probeID,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(url.absoluteString),
                titleFingerprint: nil,
                errorSummary: detail,
                fullURL: url.absoluteString,
                filename: nil,
                destinationPath: nil,
                fullErrorDescription: detail
            ))
    }

    /// Final failure event of the whole probe: recorded once by `probe` only when
    /// every strategy missed; the summary lists each strategy's miss reason and
    /// shares the structured `probeId` with the strategy events (round 5 P2).
    private static func logFinalNoResult(_ url: URL, probeID: String, misses: [StrategyMiss]) {
        let chain = misses.map(\.summaryComponent).joined(separator: " ")
        diagnosticLog.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "sizeProbe.noResult",
                stage: "probe",
                taskID: nil,
                backend: nil,
                sourceKind: nil,
                host: url.host,
                errorCode: "noResult",
                byteCount: nil,
                correlationID: probeID,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(url.absoluteString),
                titleFingerprint: nil,
                errorSummary: chain,
                fullURL: url.absoluteString,
                filename: nil,
                destinationPath: nil,
                fullErrorDescription: chain
            ))
    }

    private static func applyHeaders(to request: inout URLRequest, context: DownloadRequestContext?) {
        guard let context else { return }
        // CDNs like bilivideo's reject or misreport probes without the
        // page Referer the original request carried.
        if let referer = context.referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent = context.userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let cookie = context.cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    /// Privacy (round 2 §P2-3): the ordinary log records only host, probe
    /// strategy, and the sanitized safe summary/stable error code; external
    /// `localizedDescription` must pass unified sanitization first; the full
    /// underlying error and full URL go to the private log only under the same
    /// event ID. Strategy-level transport errors also count as single strategy
    /// misses. The stable reason and probeId are kept independent of free-text
    /// summaries (round 6 P2): when the summary is missing or sanitization
    /// fails, the structured fields still keep `probeId` and
    /// `reason=networkError`; the full description goes to the private log
    /// only. internal only so unit tests can drive it directly.
    static func logFailure(_ url: URL, _ error: Error, method: String, probeID: String = "") {
        let summary = YouTubeOutputSanitizer.sanitizedErrorSummary(error.localizedDescription)
        var detail = "reason=networkError"
        if let summary { detail += " \(summary)" }
        diagnosticLog.record(
            DownloadDiagnosticEvent(
                id: UUID().uuidString,
                timestamp: Date(),
                event: "sizeProbe.strategyMiss",
                stage: method,
                taskID: nil,
                backend: nil,
                sourceKind: nil,
                host: url.host,
                errorCode: DownloadDiagnosticEventLog.errorCode(for: error),
                byteCount: nil,
                correlationID: probeID.isEmpty ? nil : probeID,
                urlExactFingerprint: DiagnosticFingerprint.urlExact(url.absoluteString),
                titleFingerprint: nil,
                errorSummary: detail,
                fullURL: url.absoluteString,
                filename: nil,
                destinationPath: nil,
                fullErrorDescription: error.localizedDescription
            ))
    }

    // MARK: - Header parsing (pure, unit-tested)

    static func totalSize(contentLength: String?) -> Int64? {
        guard let contentLength,
            let value = Int64(contentLength.trimmingCharacters(in: .whitespaces)),
            value > 0
        else { return nil }
        return value
    }

    /// Structured parse result for `Content-Range` (round 6 P2): callers no
    /// longer second-guess via string containment.
    enum ContentRangeOutcome: Equatable {
        /// Syntax and request range both correct, and the total size is known.
        case total(Int64)
        /// Syntax and request range both correct, but the server explicitly
        /// reports an unknown total (`*`).
        case unknownTotal
        /// Invalid response: wrong unit, range inconsistent with `bytes=0-0`,
        /// self-contradictory, or an illegal total size.
        case invalid
    }

    /// Strictly parses `Content-Range` (round 5 P1, round 6 P2): first require
    /// the unit to be `bytes` and the range to match the `bytes=0-0` this probe
    /// sent (`0-0`); only when both unit and range are legal does `*` mean
    /// "the server explicitly reports an unknown total"; any other starred
    /// content stays invalid.
    static func parseContentRange(_ header: String?) -> ContentRangeOutcome {
        guard let header else { return .invalid }
        let parts = header.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return .invalid }
        guard parts[0].lowercased().hasPrefix("bytes ") else { return .invalid }
        let rangeSpec = parts[0].dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let bounds = rangeSpec.split(separator: "-", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard bounds.count == 2,
            let first = Int64(bounds[0]),
            let last = Int64(bounds[1]),
            first >= 0, last >= first,
            first == 0, last == 0
        else { return .invalid }
        let totalPart = parts[1]
        if totalPart == "*" { return .unknownTotal }
        guard let value = Int64(totalPart), value > last else { return .invalid }
        return .total(value)
    }

    /// Parses `Content-Range: bytes 0-0/TOTAL`; a `*` total means the
    /// server does not know the size. Keeps the old signature, delegating to
    /// the structured parser.
    static func totalSize(contentRange: String?) -> Int64? {
        if case .total(let value) = parseContentRange(contentRange) { return value }
        return nil
    }
}
