import Foundation
import IDMEngine

/// Resolves the originally selected track; contains no task mutation or file deletion.
struct SiteMediaResumeResolver {
    let adapter: BilibiliPlayurlAdapter

    func resolve(record: AppTask, pageURL: URL, context: DownloadRequestContext?) async throws -> BilibiliPlayurlOption
    {
        let options = try await adapter.resolve(pageURL: pageURL, requestContext: context)
        try Task.checkCancellation()
        let name = URL(string: record.sourceURL)?.lastPathComponent
        guard let option = options.first(where: { $0.videoURL.lastPathComponent == name }),
            record.mediaCID.map({ option.videoURL.lastPathComponent.hasPrefix($0 + "-1-") }) ?? true
        else { throw SiteMediaResumeError.selectedTrackUnavailable }
        return option
    }
}

enum SiteMediaResumeError: LocalizedError {
    case selectedTrackUnavailable
    var errorDescription: String? {
        String(localized: "原视频或画质当前不可用，请恢复网站登录状态，或重新提交并选择画质。")
    }
}
