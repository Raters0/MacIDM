import Foundation
import IDMEngine

/// A transient, user-editable download request. Browser credentials stay in
/// memory and are never written to the task store.
struct DownloadDraft: Equatable, Sendable {
    let url: URL
    let filenameHint: String?
    let sourceKind: DownloadSourceKind
    let requestContext: DownloadRequestContext?
    let pageTitle: String?
    let mimeType: String?
    let pairAudioURL: URL?
    let pairCID: String?
    let backend: DownloadBackend
    let estimatedSize: Int64?
    let duration: Double?
    /// True when `estimatedSize` is a real Content-Length reported by the
    /// browser download itself (browser takeover) rather than a stream
    /// estimate, so the confirmation window can show it without an "approximate" marker.
    let sizeProbed: Bool
    let takeoverDraftID: String?

    init(
        url: URL,
        filenameHint: String? = nil,
        sourceKind: DownloadSourceKind = .http,
        requestContext: DownloadRequestContext? = nil,
        pageTitle: String? = nil,
        mimeType: String? = nil,
        pairAudioURL: URL? = nil,
        pairCID: String? = nil,
        backend: DownloadBackend = .native,
        estimatedSize: Int64? = nil,
        duration: Double? = nil,
        sizeProbed: Bool = false,
        takeoverDraftID: String? = nil
    ) {
        self.url = url
        self.filenameHint = filenameHint
        self.sourceKind = sourceKind
        self.requestContext = requestContext
        self.pageTitle = pageTitle
        self.mimeType = mimeType
        self.pairAudioURL = pairAudioURL
        self.pairCID = pairCID
        self.backend = backend
        self.estimatedSize = estimatedSize
        self.duration = duration
        self.sizeProbed = sizeProbed
        self.takeoverDraftID = takeoverDraftID
    }

    init?(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.init(url: url)
    }
}

struct DownloadMediaOption: Equatable, Identifiable, Sendable {
    let url: URL
    let sourceKind: DownloadSourceKind
    let filename: String
    let label: String
    let encoding: String?
    let requestContext: DownloadRequestContext?
    let pairAudioURL: URL?
    let pairCID: String?
    let backend: DownloadBackend
    let estimatedSize: Int64?
    let duration: Double?
    /// True when `estimatedSize` came from a direct Content-Length probe
    /// (MediaSizeProbe) rather than a bandwidth×duration estimate, so the
    /// UI can show it without the "approximate" marker.
    var sizeProbed: Bool

    init(
        url: URL,
        sourceKind: DownloadSourceKind,
        filename: String,
        label: String,
        encoding: String? = nil,
        requestContext: DownloadRequestContext? = nil,
        pairAudioURL: URL? = nil,
        pairCID: String? = nil,
        backend: DownloadBackend = .native,
        estimatedSize: Int64? = nil,
        duration: Double? = nil,
        sizeProbed: Bool = false
    ) {
        self.url = url
        self.sourceKind = sourceKind
        self.filename = filename
        self.label = label
        self.encoding = encoding
        self.requestContext = requestContext
        self.pairAudioURL = pairAudioURL
        self.pairCID = pairCID
        self.backend = backend
        self.estimatedSize = estimatedSize
        self.duration = duration
        self.sizeProbed = sizeProbed
    }

    /// Returns a copy carrying a freshly probed Content-Length total.
    func withProbedSize(_ size: Int64) -> DownloadMediaOption {
        DownloadMediaOption(
            url: url,
            sourceKind: sourceKind,
            filename: filename,
            label: label,
            encoding: encoding,
            requestContext: requestContext,
            pairAudioURL: pairAudioURL,
            pairCID: pairCID,
            backend: backend,
            estimatedSize: size,
            duration: duration,
            sizeProbed: true
        )
    }

    var id: String {
        url.absoluteString + "|" + label + "|" + (encoding ?? "") + "|"
            + (pairAudioURL?.absoluteString ?? "") + "|" + backend.rawValue
    }
}
